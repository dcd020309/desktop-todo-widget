Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# Some restricted launchers do not inherit WINDIR/SystemRoot. WPF needs both
# variables when it initializes the Windows font cache.
if ([string]::IsNullOrWhiteSpace($env:WINDIR)) {
    $env:WINDIR = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
}
if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    $env:SystemRoot = $env:WINDIR
}

$script:AppDirectory = Join-Path $env:LOCALAPPDATA 'DesktopTodoDemo'
$script:StatePath = Join-Path $script:AppDirectory 'state.json'
$script:LauncherPath = Join-Path $PSScriptRoot 'Start-Todo.vbs'
$script:RestartLauncherPath = Join-Path $PSScriptRoot 'Restart-Todo.vbs'
$script:IconPath = Join-Path $PSScriptRoot 'assets\todo-icon.ico'
$script:DetailDirectory = Join-Path $PSScriptRoot 'detail'
$script:BackupDirectory = Join-Path $PSScriptRoot 'backup'
$script:AutoStartRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:AutoStartValueName = 'DesktopTodoWidget'
$script:Version = '1.4.0'

trap {
    $details = ($_ | Out-String)
    try {
        New-Item -ItemType Directory -Path $script:AppDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:AppDirectory 'error.log') -Value $details -Encoding UTF8
    } catch {}
    try {
        [void][Windows.MessageBox]::Show(
            "桌面待办启动失败。`n`n$($_.Exception.Message)`n`n错误日志：$script:AppDirectory\error.log",
            '桌面待办',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
    } catch {
        [Console]::Error.WriteLine($details)
    }
    exit 1
}

$createdNewInstance = $false
$script:InstanceMutex = [Threading.Mutex]::new($true, 'Local\DesktopTodoWidget.SingleInstance', [ref]$createdNewInstance)
if (-not $createdNewInstance) {
    # Silent launchers and Windows startup may invoke the app more than once.
    # Keep the existing widget and exit before a second state writer is created.
    exit 0
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DesktopWidgetNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetParent(IntPtr child, IntPtr newParent);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int index);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int index, int value);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern IntPtr GetShellWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);

    public static IntPtr FindDesktopHost()
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate (IntPtr top, IntPtr ignored)
        {
            IntPtr defView = FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (defView != IntPtr.Zero)
            {
                result = top;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (result == IntPtr.Zero)
            result = FindWindow("Progman", null);
        return result;
    }
}
'@

$script:Tasks = @()
$script:DeletedTasks = @()
$script:CurrentFilter = 'all'
$script:IsLocked = $false
$script:UrgentDays = 3
$script:CardActionMode = 'unified'
$script:WindowLayerMode = 'desktop'
$script:AutoStartEnabled = $false
$script:DisplayTitle = '我的一天'
$script:DeviceId = $null
$script:SyncDirectory = $null
$script:LastSyncAt = $null
$script:DesktopHandle = [IntPtr]::Zero
$script:WidgetHandle = [IntPtr]::Zero
$script:BottomEnforcementTimer = $null
$script:TrayIcon = $null
$script:TrayMenu = $null
$script:AppIcon = $null
$script:IsRestoringUiState = $false
$script:ExportType = 'completed'
$script:ExportStartDate = $null
$script:ExportEndDate = $null
$script:DropTargetCard = $null
$script:DropGapKey = $null

function New-TaskId {
    return [Guid]::NewGuid().ToString('N')
}

function Get-UtcTimestamp {
    return [DateTimeOffset]::UtcNow.ToString('o')
}

function Set-ObjectProperty {
    param($InputObject, [string]$Name, $Value)
    if ($null -eq $InputObject) { return }
    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        $InputObject.$Name = $Value
    } else {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-TaskModified {
    param($Task, [AllowNull()][string]$Timestamp)
    if ($null -eq $Task) { return }
    $stamp = if ([string]::IsNullOrWhiteSpace($Timestamp)) { Get-UtcTimestamp } else { $Timestamp }
    Set-ObjectProperty $Task 'updatedAt' $stamp
    Set-ObjectProperty $Task 'updatedBy' $script:DeviceId
}

function Add-DeletionTombstone {
    param([string]$TaskId, [AllowNull()][string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return }
    $stamp = if ([string]::IsNullOrWhiteSpace($Timestamp)) { Get-UtcTimestamp } else { $Timestamp }
    $script:DeletedTasks = @($script:DeletedTasks | Where-Object { [string]$_.id -ne $TaskId }) + @(
        [PSCustomObject]@{ id = $TaskId; deletedAt = $stamp; deletedBy = $script:DeviceId }
    )
}

function Get-TimestampTicks {
    param([AllowNull()][string]$Timestamp)
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { return [long]::MinValue }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Timestamp, [ref]$parsed)) {
        return $parsed.UtcDateTime.Ticks
    }
    return [long]::MinValue
}

function Test-SyncCandidateIsNewer {
    param(
        [AllowNull()][string]$CandidateTimestamp,
        [AllowNull()][string]$CandidateDeviceId,
        [AllowNull()][string]$ExistingTimestamp,
        [AllowNull()][string]$ExistingDeviceId
    )
    $candidateTicks = Get-TimestampTicks $CandidateTimestamp
    $existingTicks = Get-TimestampTicks $ExistingTimestamp
    if ($candidateTicks -ne $existingTicks) { return $candidateTicks -gt $existingTicks }
    return [string]::CompareOrdinal([string]$CandidateDeviceId, [string]$ExistingDeviceId) -gt 0
}

function Get-DefaultSyncDirectory {
    $candidates = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return Join-Path $candidate 'DesktopTodoSync'
        }
    }
    return $null
}

function Get-FriendlySize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-BackupStorageInfo {
    $files = @()
    if (Test-Path -LiteralPath $script:BackupDirectory) {
        $files = @(Get-ChildItem -LiteralPath $script:BackupDirectory -File -Recurse -ErrorAction SilentlyContinue)
    }
    $bytes = [long]0
    foreach ($file in $files) { $bytes += [long]$file.Length }
    $backupCount = if (Test-Path -LiteralPath $script:BackupDirectory) {
        @(Get-ChildItem -LiteralPath $script:BackupDirectory -Directory -ErrorAction SilentlyContinue).Count
    } else { 0 }
    return [PSCustomObject]@{ Bytes = $bytes; FileCount = $files.Count; BackupCount = $backupCount; DisplaySize = (Get-FriendlySize $bytes) }
}

function Get-LastSyncDisplayText {
    if ([string]::IsNullOrWhiteSpace($script:LastSyncAt)) { return '尚未同步' }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($script:LastSyncAt, [ref]$parsed)) { return '尚未同步' }
    return "上次同步：$($parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))"
}

function New-SyncBackup {
    param([ValidateSet('upload','download')][string]$Direction)
    Save-State
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $directionLabel = if ($Direction -eq 'upload') { '上传前备份' } else { '下载前备份' }
    $backupPath = Join-Path $script:BackupDirectory "${timestamp}_${directionLabel}"
    $detailBackupPath = Join-Path $backupPath 'detail'
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    Copy-Item -LiteralPath $script:StatePath -Destination (Join-Path $backupPath 'state.json') -Force

    if (Test-Path -LiteralPath $script:DetailDirectory) {
        $detailFiles = @(Get-ChildItem -LiteralPath $script:DetailDirectory -File -ErrorAction SilentlyContinue)
        if ($detailFiles.Count -gt 0) {
            New-Item -ItemType Directory -Path $detailBackupPath -Force | Out-Null
            foreach ($detailFile in $detailFiles) {
                Copy-Item -LiteralPath $detailFile.FullName -Destination (Join-Path $detailBackupPath $detailFile.Name) -Force
            }
        }
    }

    [PSCustomObject]@{
        backupVersion = 1
        appVersion = $script:Version
        backupTime = (Get-UtcTimestamp)
        reason = "manual-onedrive-$Direction"
        deviceId = $script:DeviceId
        taskCount = $script:Tasks.Count
        deletedTaskCount = $script:DeletedTasks.Count
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupPath 'backup-info.json') -Encoding UTF8
    return $backupPath
}

function Update-LocalDetailMetadata {
    foreach ($task in $script:Tasks) {
        $detailPath = Resolve-TaskDetailPath ([string]$task.id)
        $storedTimestamp = [string]$task.detailUpdatedAt
        $storedTicks = Get-TimestampTicks $storedTimestamp
        if ($null -ne $detailPath -and (Test-Path -LiteralPath $detailPath)) {
            $file = Get-Item -LiteralPath $detailPath
            $fileTimestamp = [DateTimeOffset]::new($file.LastWriteTimeUtc).ToString('o')
            $fileTicks = Get-TimestampTicks $fileTimestamp
            if ([bool]$task.detailDeleted -or $fileTicks -gt $storedTicks) {
                Set-ObjectProperty $task 'detailUpdatedAt' $fileTimestamp
                Set-ObjectProperty $task 'detailUpdatedBy' $script:DeviceId
                Set-ObjectProperty $task 'detailDeleted' $false
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($storedTimestamp) -and -not [bool]$task.detailDeleted) {
            Set-ObjectProperty $task 'detailUpdatedAt' (Get-UtcTimestamp)
            Set-ObjectProperty $task 'detailUpdatedBy' $script:DeviceId
            Set-ObjectProperty $task 'detailDeleted' $true
        }
    }
}

function ConvertTo-PlainDetailContent {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }

    # 1.3.1 及更早版本通过 Get-Content 读取 TXT。Windows PowerShell 会给返回的
    # 字符串附加 PSPath、PSDrive、PSProvider 等扩展属性；ConvertTo-Json 随后可能
    # 将这些元数据递归展开成几十 MB。旧快照中的正文保存在 value 属性中。
    $rawText = if ($Value -isnot [string] -and $Value.PSObject.Properties.Name -contains 'value') {
        [string]$Value.value
    } else {
        [string]$Value
    }
    return [string]::new($rawText.ToCharArray())
}

function New-TaskSyncRecord {
    param($Task)
    $detailPath = Resolve-TaskDetailPath ([string]$Task.id)
    $hasDetailFile = $null -ne $detailPath -and (Test-Path -LiteralPath $detailPath)
    # File.ReadAllText 返回不带 PowerShell 文件系统扩展属性的纯字符串。
    $detailContent = if ($hasDetailFile) { [IO.File]::ReadAllText($detailPath, [Text.Encoding]::UTF8) } else { $null }
    return [PSCustomObject]@{
        id = [string]$Task.id
        text = [string]$Task.text
        completed = [bool]$Task.completed
        completedAt = if ([string]::IsNullOrWhiteSpace([string]$Task.completedAt)) { $null } else { [string]$Task.completedAt }
        dueDate = if ([string]::IsNullOrWhiteSpace([string]$Task.dueDate)) { $null } else { [string]$Task.dueDate }
        prerequisiteId = if ([string]::IsNullOrWhiteSpace([string]$Task.prerequisiteId)) { $null } else { [string]$Task.prerequisiteId }
        sortOrder = [double]$Task.sortOrder
        createdAt = [string]$Task.createdAt
        updatedAt = [string]$Task.updatedAt
        updatedBy = [string]$Task.updatedBy
        detailUpdatedAt = if ([string]::IsNullOrWhiteSpace([string]$Task.detailUpdatedAt)) { $null } else { [string]$Task.detailUpdatedAt }
        detailUpdatedBy = if ([string]::IsNullOrWhiteSpace([string]$Task.detailUpdatedBy)) { $null } else { [string]$Task.detailUpdatedBy }
        detailDeleted = [bool]$Task.detailDeleted
        detailContent = $detailContent
    }
}

function New-DeviceSyncSnapshot {
    return [PSCustomObject]@{
        syncVersion = 1
        appVersion = $script:Version
        deviceId = $script:DeviceId
        deviceName = [Environment]::MachineName
        generatedAt = (Get-UtcTimestamp)
        tasks = @($script:Tasks | ForEach-Object { New-TaskSyncRecord $_ })
        deletedTasks = @($script:DeletedTasks)
    }
}

function ConvertFrom-SyncTaskRecord {
    param($Record)
    return [PSCustomObject]@{
        id = [string]$Record.id
        text = [string]$Record.text
        completed = [bool]$Record.completed
        completedAt = if ([string]::IsNullOrWhiteSpace([string]$Record.completedAt)) { $null } else { [string]$Record.completedAt }
        dueDate = if ([string]::IsNullOrWhiteSpace([string]$Record.dueDate)) { $null } else { [string]$Record.dueDate }
        prerequisiteId = if ([string]::IsNullOrWhiteSpace([string]$Record.prerequisiteId)) { $null } else { [string]$Record.prerequisiteId }
        sortOrder = if ($null -eq $Record.sortOrder) { 0 } else { [double]$Record.sortOrder }
        createdAt = if ([string]::IsNullOrWhiteSpace([string]$Record.createdAt)) { [string]$Record.updatedAt } else { [string]$Record.createdAt }
        updatedAt = [string]$Record.updatedAt
        updatedBy = [string]$Record.updatedBy
        detailUpdatedAt = if ([string]::IsNullOrWhiteSpace([string]$Record.detailUpdatedAt)) { $null } else { [string]$Record.detailUpdatedAt }
        detailUpdatedBy = if ([string]::IsNullOrWhiteSpace([string]$Record.detailUpdatedBy)) { $null } else { [string]$Record.detailUpdatedBy }
        detailDeleted = [bool]$Record.detailDeleted
    }
}

function Write-LocalDeviceSyncSnapshot {
    param([string]$DevicesDirectory)
    $outputSnapshot = New-DeviceSyncSnapshot
    $snapshotPath = Join-Path $DevicesDirectory "$script:DeviceId.json"
    $temporarySnapshotPath = Join-Path $DevicesDirectory ".$script:DeviceId.tmp"
    try {
        $json = $outputSnapshot | ConvertTo-Json -Depth 8 -Compress
        [IO.File]::WriteAllText($temporarySnapshotPath, $json, [Text.UTF8Encoding]::new($false))
        [void](Get-Content -LiteralPath $temporarySnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        Move-Item -LiteralPath $temporarySnapshotPath -Destination $snapshotPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporarySnapshotPath -Force -ErrorAction SilentlyContinue
    }
    return $snapshotPath
}

function Invoke-OneDriveUpload {
    param([string]$SyncDirectory)
    if ([string]::IsNullOrWhiteSpace($SyncDirectory)) { throw '未找到 OneDrive 文件夹，请选择同步目录。' }

    $resolvedSyncDirectory = [IO.Path]::GetFullPath($SyncDirectory.Trim())
    $devicesDirectory = Join-Path $resolvedSyncDirectory 'devices'
    New-Item -ItemType Directory -Path $devicesDirectory -Force | Out-Null

    $backupPath = New-SyncBackup 'upload'
    Update-LocalDetailMetadata
    Save-State
    $snapshotPath = Write-LocalDeviceSyncSnapshot $devicesDirectory

    $script:SyncDirectory = $resolvedSyncDirectory
    $script:LastSyncAt = Get-UtcTimestamp
    Save-State
    return [PSCustomObject]@{
        TaskCount = $script:Tasks.Count
        DeletedTaskCount = $script:DeletedTasks.Count
        BackupPath = $backupPath
        SnapshotPath = $snapshotPath
        SyncDirectory = $resolvedSyncDirectory
    }
}

function Invoke-OneDriveDownload {
    param([string]$SyncDirectory)
    if ([string]::IsNullOrWhiteSpace($SyncDirectory)) { throw '未找到 OneDrive 文件夹，请选择同步目录。' }

    $resolvedSyncDirectory = [IO.Path]::GetFullPath($SyncDirectory.Trim())
    $devicesDirectory = Join-Path $resolvedSyncDirectory 'devices'
    New-Item -ItemType Directory -Path $devicesDirectory -Force | Out-Null

    # A complete local backup is the first data-changing step of every sync.
    $backupPath = New-SyncBackup 'download'
    Update-LocalDetailMetadata

    $sources = [Collections.Generic.List[object]]::new()
    $sources.Add((New-DeviceSyncSnapshot))
    $snapshotFiles = @(Get-ChildItem -LiteralPath $devicesDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $invalidSnapshotCount = 0
    foreach ($snapshotFile in $snapshotFiles) {
        try {
            $snapshot = Get-Content -LiteralPath $snapshotFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $snapshot -or [int]$snapshot.syncVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$snapshot.deviceId)) {
                $invalidSnapshotCount++
                continue
            }
            $sources.Add($snapshot)
        }
        catch {
            $invalidSnapshotCount++
        }
    }

    $coreWinners = @{}
    $detailWinners = @{}
    foreach ($source in $sources) {
        $sourceDeviceId = [string]$source.deviceId
        foreach ($record in @($source.tasks)) {
            $taskId = [string]$record.id
            if ([string]::IsNullOrWhiteSpace($taskId)) { continue }
            $recordTimestamp = [string]$record.updatedAt
            $recordDeviceId = if ([string]::IsNullOrWhiteSpace([string]$record.updatedBy)) { $sourceDeviceId } else { [string]$record.updatedBy }
            $existing = $coreWinners[$taskId]
            if ($null -eq $existing -or (Test-SyncCandidateIsNewer $recordTimestamp $recordDeviceId $existing.Timestamp $existing.DeviceId)) {
                $coreWinners[$taskId] = [PSCustomObject]@{ Kind = 'task'; Timestamp = $recordTimestamp; DeviceId = $recordDeviceId; Record = $record }
            }

            $detailTimestamp = [string]$record.detailUpdatedAt
            if (-not [string]::IsNullOrWhiteSpace($detailTimestamp)) {
                $detailDeviceId = if ([string]::IsNullOrWhiteSpace([string]$record.detailUpdatedBy)) { $sourceDeviceId } else { [string]$record.detailUpdatedBy }
                $existingDetail = $detailWinners[$taskId]
                if ($null -eq $existingDetail -or (Test-SyncCandidateIsNewer $detailTimestamp $detailDeviceId $existingDetail.Timestamp $existingDetail.DeviceId)) {
                    $detailWinners[$taskId] = [PSCustomObject]@{ Timestamp = $detailTimestamp; DeviceId = $detailDeviceId; Record = $record }
                }
            }
        }
        foreach ($deletion in @($source.deletedTasks)) {
            $taskId = [string]$deletion.id
            if ([string]::IsNullOrWhiteSpace($taskId)) { continue }
            $deletedAt = [string]$deletion.deletedAt
            $deletedBy = if ([string]::IsNullOrWhiteSpace([string]$deletion.deletedBy)) { $sourceDeviceId } else { [string]$deletion.deletedBy }
            $existing = $coreWinners[$taskId]
            if ($null -eq $existing -or (Test-SyncCandidateIsNewer $deletedAt $deletedBy $existing.Timestamp $existing.DeviceId)) {
                $coreWinners[$taskId] = [PSCustomObject]@{ Kind = 'deleted'; Timestamp = $deletedAt; DeviceId = $deletedBy; Record = $deletion }
            }
        }
    }

    $oldDetailPaths = @{}
    foreach ($oldTask in $script:Tasks) {
        $oldPath = Resolve-TaskDetailPath ([string]$oldTask.id)
        if ($null -ne $oldPath -and (Test-Path -LiteralPath $oldPath)) { $oldDetailPaths[[string]$oldTask.id] = $oldPath }
    }

    $mergedTasks = [Collections.Generic.List[object]]::new()
    $mergedDeletedTasks = [Collections.Generic.List[object]]::new()
    foreach ($taskId in $coreWinners.Keys) {
        $winner = $coreWinners[$taskId]
        if ($winner.Kind -eq 'deleted') {
            $mergedDeletedTasks.Add([PSCustomObject]@{ id = $taskId; deletedAt = $winner.Timestamp; deletedBy = $winner.DeviceId })
            continue
        }
        $mergedTask = ConvertFrom-SyncTaskRecord $winner.Record
        $detailWinner = $detailWinners[$taskId]
        if ($null -ne $detailWinner) {
            Set-ObjectProperty $mergedTask 'detailUpdatedAt' $detailWinner.Timestamp
            Set-ObjectProperty $mergedTask 'detailUpdatedBy' $detailWinner.DeviceId
            Set-ObjectProperty $mergedTask 'detailDeleted' ([bool]$detailWinner.Record.detailDeleted)
        }
        $mergedTasks.Add($mergedTask)
    }

    $script:Tasks = @($mergedTasks)
    $script:DeletedTasks = @($mergedDeletedTasks)
    $activeIds = @{}
    foreach ($task in $script:Tasks) { $activeIds[[string]$task.id] = $true }

    foreach ($oldTaskId in $oldDetailPaths.Keys) {
        if (-not $activeIds.ContainsKey($oldTaskId)) {
            Remove-Item -LiteralPath $oldDetailPaths[$oldTaskId] -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($task in $script:Tasks) {
        $taskId = [string]$task.id
        $detailWinner = $detailWinners[$taskId]
        if ($null -eq $detailWinner) { continue }
        $oldPath = $oldDetailPaths[$taskId]
        $detailPath = Resolve-TaskDetailPath $taskId
        if ([bool]$detailWinner.Record.detailDeleted) {
            if ($null -ne $oldPath -and (Test-Path -LiteralPath $oldPath)) { Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $detailPath -and (Test-Path -LiteralPath $detailPath)) { Remove-Item -LiteralPath $detailPath -Force -ErrorAction SilentlyContinue }
            continue
        }
        New-Item -ItemType Directory -Path $script:DetailDirectory -Force | Out-Null
        $detailContent = ConvertTo-PlainDetailContent $detailWinner.Record.detailContent
        if ($null -eq $detailContent) { $detailContent = '' }
        Set-Content -LiteralPath $detailPath -Value $detailContent -Encoding UTF8 -NoNewline
        $detailTime = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($detailWinner.Timestamp, [ref]$detailTime)) {
            (Get-Item -LiteralPath $detailPath).LastWriteTimeUtc = $detailTime.UtcDateTime
        }
        if ($null -ne $oldPath -and $oldPath -ne $detailPath -and (Test-Path -LiteralPath $oldPath)) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
        }
    }

    # A prerequisite removed on another device must not leave an unusable task.
    $dependencyRepairTimestamp = $null
    foreach ($task in $script:Tasks) {
        if (-not [string]::IsNullOrWhiteSpace([string]$task.prerequisiteId) -and -not $activeIds.ContainsKey([string]$task.prerequisiteId)) {
            if ($null -eq $dependencyRepairTimestamp) { $dependencyRepairTimestamp = Get-UtcTimestamp }
            $task.prerequisiteId = $null
            Set-TaskModified $task $dependencyRepairTimestamp
        }
    }

    $script:SyncDirectory = $resolvedSyncDirectory
    $script:LastSyncAt = Get-UtcTimestamp
    Save-State
    return [PSCustomObject]@{
        TaskCount = $script:Tasks.Count
        DeletedTaskCount = $script:DeletedTasks.Count
        DeviceSnapshotCount = [Math]::Max(0, $sources.Count - 1)
        InvalidSnapshotCount = $invalidSnapshotCount
        BackupPath = $backupPath
        SyncDirectory = $resolvedSyncDirectory
    }
}

function Set-AutoStartEnabled {
    param([bool]$Enabled)

    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $script:LauncherPath)) {
            throw "找不到静默启动文件：$script:LauncherPath"
        }
        $wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $startupCommand = '"{0}" "{1}"' -f $wscriptPath, $script:LauncherPath
        New-ItemProperty -Path $script:AutoStartRunKey -Name $script:AutoStartValueName -Value $startupCommand -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $script:AutoStartRunKey -Name $script:AutoStartValueName -ErrorAction SilentlyContinue
    }
}

function Get-TaskById {
    param([AllowNull()][string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
    return $script:Tasks | Where-Object { [string]$_.id -eq $TaskId } | Select-Object -First 1
}

function Get-TaskDetailPath {
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
    $task = Get-TaskById $TaskId
    if ($null -eq $task) { return $null }

    $safeName = ([string]$task.text -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.')
    $safeName = $safeName -replace '\s+', ' '
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = '待办' }
    if ($safeName.Length -gt 40) { $safeName = $safeName.Substring(0, 40).Trim().TrimEnd('.') }

    $safeId = ([string]$task.id -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($safeId)) { $safeId = 'detail' }
    if ($safeId.Length -gt 8) { $safeId = $safeId.Substring(0, 8) }
    return Join-Path $script:DetailDirectory "${safeName}_${safeId}.txt"
}

function Resolve-TaskDetailPath {
    param([string]$TaskId)
    $meaningfulPath = Get-TaskDetailPath $TaskId
    if ($null -eq $meaningfulPath) { return $null }
    if (Test-Path -LiteralPath $meaningfulPath) { return $meaningfulPath }

    $legacyPath = Join-Path $script:DetailDirectory "$TaskId.txt"
    if (Test-Path -LiteralPath $legacyPath) {
        try {
            Move-Item -LiteralPath $legacyPath -Destination $meaningfulPath
            return $meaningfulPath
        }
        catch {
            return $legacyPath
        }
    }
    return $meaningfulPath
}

function Open-TaskDetail {
    param([string]$TaskId)
    $task = Get-TaskById $TaskId
    if ($null -eq $task) { return }

    try {
        New-Item -ItemType Directory -Path $script:DetailDirectory -Force | Out-Null
        $detailPath = Resolve-TaskDetailPath $TaskId
        if (-not (Test-Path -LiteralPath $detailPath)) {
            Set-Content -LiteralPath $detailPath -Value "待办：$([string]$task.text)`r`n`r`n" -Encoding UTF8
            Set-ObjectProperty $task 'detailUpdatedAt' ([DateTimeOffset]::new((Get-Item -LiteralPath $detailPath).LastWriteTimeUtc).ToString('o'))
            Set-ObjectProperty $task 'detailUpdatedBy' $script:DeviceId
            Set-ObjectProperty $task 'detailDeleted' $false
            Save-State
        }

        $notepadPath = Join-Path $env:WINDIR 'System32\notepad.exe'
        Start-Process -FilePath $notepadPath -ArgumentList ('"{0}"' -f $detailPath)
        Refresh-Tasks
    }
    catch {
        [void][Windows.MessageBox]::Show(
            $window,
            "无法打开详细说明：`n$($_.Exception.Message)",
            '详细说明',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
    }
}

function Remove-TaskDetail {
    param([string]$TaskId)
    $task = Get-TaskById $TaskId
    if ($null -eq $task) { return $false }

    $detailPath = Resolve-TaskDetailPath $TaskId
    if ($null -eq $detailPath -or -not (Test-Path -LiteralPath $detailPath)) { return $false }

    Remove-Item -LiteralPath $detailPath -Force -ErrorAction Stop
    $deletionTimestamp = Get-UtcTimestamp
    Set-ObjectProperty $task 'detailUpdatedAt' $deletionTimestamp
    Set-ObjectProperty $task 'detailUpdatedBy' $script:DeviceId
    Set-ObjectProperty $task 'detailDeleted' $true
    Set-TaskModified $task $deletionTimestamp
    Save-State
    Refresh-Tasks
    return $true
}

function Backup-AndRemoveTasks {
    param([bool]$Completed)

    $originalTasks = @($script:Tasks)
    $originalDeletedTasks = @($script:DeletedTasks)
    $originalPrerequisites = @{}
    foreach ($task in $originalTasks) { $originalPrerequisites[[string]$task.id] = [string]$task.prerequisiteId }
    $tasksToRemove = @($script:Tasks | Where-Object { [bool]$_.completed -eq $Completed })
    if ($tasksToRemove.Count -eq 0) { return $null }

    $category = if ($Completed) { '已完成' } else { '未完成' }
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $backupPath = Join-Path $script:BackupDirectory "${timestamp}_${category}"
    $backupDetailPath = Join-Path $backupPath 'detail'

    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    $backupData = [PSCustomObject]@{
        backupVersion = 1
        appVersion = $script:Version
        backupTime = (Get-Date).ToString('o')
        category = $category
        taskCount = $tasksToRemove.Count
        tasks = @($tasksToRemove)
    }
    $backupData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backupPath 'tasks.json') -Encoding UTF8

    $detailFiles = [Collections.Generic.List[string]]::new()
    foreach ($task in $tasksToRemove) {
        $detailPath = Resolve-TaskDetailPath ([string]$task.id)
        if ($null -ne $detailPath -and (Test-Path -LiteralPath $detailPath)) {
            if (-not (Test-Path -LiteralPath $backupDetailPath)) {
                New-Item -ItemType Directory -Path $backupDetailPath -Force | Out-Null
            }
            Copy-Item -LiteralPath $detailPath -Destination (Join-Path $backupDetailPath ([IO.Path]::GetFileName($detailPath))) -Force
            $detailFiles.Add($detailPath)
        }
    }

    $removedIds = @{}
    $deletionTimestamp = Get-UtcTimestamp
    foreach ($task in $tasksToRemove) {
        $removedIds[[string]$task.id] = $true
        Add-DeletionTombstone ([string]$task.id) $deletionTimestamp
    }
    $script:Tasks = @($script:Tasks | Where-Object { -not $removedIds.ContainsKey([string]$_.id) })
    foreach ($task in $script:Tasks) {
        if ($removedIds.ContainsKey([string]$task.prerequisiteId)) {
            $task.prerequisiteId = $null
            Set-TaskModified $task $deletionTimestamp
        }
    }
    $previousRestoreState = $script:IsRestoringUiState
    $script:IsRestoringUiState = $true
    try { Update-PrerequisitePicker } finally { $script:IsRestoringUiState = $previousRestoreState }
    try {
        Save-State
    }
    catch {
        $script:Tasks = @($originalTasks)
        $script:DeletedTasks = @($originalDeletedTasks)
        foreach ($task in $script:Tasks) {
            $oldPrerequisiteId = [string]$originalPrerequisites[[string]$task.id]
            $task.prerequisiteId = if ([string]::IsNullOrWhiteSpace($oldPrerequisiteId)) { $null } else { $oldPrerequisiteId }
        }
        $previousRestoreState = $script:IsRestoringUiState
        $script:IsRestoringUiState = $true
        try { Update-PrerequisitePicker } finally { $script:IsRestoringUiState = $previousRestoreState }
        throw
    }

    foreach ($detailPath in $detailFiles) {
        Remove-Item -LiteralPath $detailPath -Force -ErrorAction SilentlyContinue
    }

    Refresh-Tasks
    return [PSCustomObject]@{ Count = $tasksToRemove.Count; Path = $backupPath; Category = $category }
}

function Remove-TaskById {
    param([string]$TaskId)
    $deletionTimestamp = Get-UtcTimestamp
    foreach ($dependentTask in @($script:Tasks | Where-Object { [string]$_.prerequisiteId -eq $TaskId })) {
        $dependentTask.prerequisiteId = $null
        Set-TaskModified $dependentTask $deletionTimestamp
    }
    $script:Tasks = @($script:Tasks | Where-Object { [string]$_.id -ne $TaskId })
    Add-DeletionTombstone $TaskId $deletionTimestamp
    Save-State
    Refresh-Tasks
}

function Test-TaskBlocked {
    param($Task)
    if ($null -eq $Task -or [bool]$Task.completed -or [string]::IsNullOrWhiteSpace([string]$Task.prerequisiteId)) { return $false }
    $prerequisite = Get-TaskById ([string]$Task.prerequisiteId)
    return $null -ne $prerequisite -and -not [bool]$prerequisite.completed
}

function Test-WouldCreateDependencyCycle {
    param([string]$TaskId, [AllowNull()][string]$CandidateId)
    if ([string]::IsNullOrWhiteSpace($CandidateId)) { return $false }
    $visited = @{}
    $cursorId = $CandidateId
    while (-not [string]::IsNullOrWhiteSpace($cursorId)) {
        if ($cursorId -eq $TaskId) { return $true }
        if ($visited.ContainsKey($cursorId)) { return $true }
        $visited[$cursorId] = $true
        $cursor = Get-TaskById $cursorId
        if ($null -eq $cursor) { return $false }
        $cursorId = [string]$cursor.prerequisiteId
    }
    return $false
}

function Get-TaskReorderLevel {
    param($Task)
    if ($null -eq $Task -or [bool]$Task.completed) { return $null }
    $blockedKey = if (Test-TaskBlocked $Task) { 'blocked' } else { 'active' }
    $dueKey = if ([string]::IsNullOrWhiteSpace([string]$Task.dueDate)) { 'no-ddl' } else { ([datetime]$Task.dueDate).ToString('yyyy-MM-dd') }
    return "$blockedKey|$dueKey"
}

function Move-TaskWithinLevel {
    param([string]$SourceTaskId, [string]$TargetTaskId, [bool]$PlaceAfter)
    if ($SourceTaskId -eq $TargetTaskId) { return }
    $sourceTask = Get-TaskById $SourceTaskId
    $targetTask = Get-TaskById $TargetTaskId
    if ($null -eq $sourceTask -or $null -eq $targetTask) { return }
    $sourceLevel = Get-TaskReorderLevel $sourceTask
    $targetLevel = Get-TaskReorderLevel $targetTask
    if ($null -eq $sourceLevel -or $sourceLevel -ne $targetLevel) { return }

    $ordered = [Collections.Generic.List[object]]::new()
    foreach ($task in @($script:Tasks | Where-Object { (Get-TaskReorderLevel $_) -eq $sourceLevel } | Sort-Object @{ Expression = { [double]$_.sortOrder } }, @{ Expression = { [datetime]$_.createdAt } })) {
        $ordered.Add($task)
    }
    [void]$ordered.Remove($sourceTask)
    $targetIndex = $ordered.IndexOf($targetTask)
    if ($targetIndex -lt 0) { return }
    if ($PlaceAfter) { $targetIndex++ }
    $ordered.Insert($targetIndex, $sourceTask)
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $ordered[$index].sortOrder = $index
        Set-TaskModified $ordered[$index] $null
    }
    Save-State
    Refresh-Tasks
}

function New-CardAnimationEase {
    $ease = [Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
    return $ease
}

function Animate-CardOpacity {
    param($Card, [double]$To, [int]$Milliseconds)
    if ($null -eq $Card) { return }
    $animation = [Windows.Media.Animation.DoubleAnimation]::new()
    $animation.To = $To
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Milliseconds))
    $animation.EasingFunction = New-CardAnimationEase
    $Card.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Animate-CardScale {
    param($Card, [double]$To, [int]$Milliseconds)
    if ($null -eq $Card -or $null -eq $Card.RenderTransform -or $Card.RenderTransform.Children.Count -eq 0) { return }
    $scale = $Card.RenderTransform.Children[0]
    $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Milliseconds))
    $xAnimation = [Windows.Media.Animation.DoubleAnimation]::new()
    $xAnimation.To = $To
    $xAnimation.Duration = $duration
    $xAnimation.EasingFunction = New-CardAnimationEase
    $yAnimation = [Windows.Media.Animation.DoubleAnimation]::new()
    $yAnimation.To = $To
    $yAnimation.Duration = $duration
    $yAnimation.EasingFunction = New-CardAnimationEase
    $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $xAnimation)
    $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $yAnimation)
}

function Animate-CardTranslateY {
    param($Card, [double]$To, [int]$Milliseconds)
    if ($null -eq $Card -or $null -eq $Card.RenderTransform -or $Card.RenderTransform.Children.Count -lt 2) { return }
    $translate = $Card.RenderTransform.Children[1]
    $animation = [Windows.Media.Animation.DoubleAnimation]::new()
    $animation.To = $To
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Milliseconds))
    $animation.EasingFunction = New-CardAnimationEase
    $translate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $animation)
}

function Reset-TaskDropGapAnimation {
    if ($null -eq $script:DropGapKey) { return }
    foreach ($child in $taskList.Children) {
        if ($child -is [Windows.Controls.Border]) {
            Animate-CardTranslateY $child 0 120
        }
    }
    $script:DropGapKey = $null
}

function Update-TaskDropGapAnimation {
    param([string]$SourceTaskId, $DropLocation)
    if ($null -eq $DropLocation -or [string]$DropLocation.TargetId -eq $SourceTaskId) {
        Reset-TaskDropGapAnimation
        return
    }

    $gapKey = "$([string]$DropLocation.TargetId)|$([bool]$DropLocation.PlaceAfter)"
    if ($script:DropGapKey -eq $gapKey) { return }
    $script:DropGapKey = $gapKey

    $sourceTask = Get-TaskById $SourceTaskId
    $sourceLevel = Get-TaskReorderLevel $sourceTask
    if ($null -eq $sourceLevel) {
        Reset-TaskDropGapAnimation
        return
    }

    $validCards = [Collections.Generic.List[object]]::new()
    foreach ($child in $taskList.Children) {
        if ($child -isnot [Windows.Controls.Border] -or [string]$child.Tag -eq $SourceTaskId) { continue }
        $candidateTask = Get-TaskById ([string]$child.Tag)
        if ((Get-TaskReorderLevel $candidateTask) -eq $sourceLevel) {
            $validCards.Add($child)
        }
    }

    $targetIndex = -1
    for ($index = 0; $index -lt $validCards.Count; $index++) {
        if ([string]$validCards[$index].Tag -eq [string]$DropLocation.TargetId) {
            $targetIndex = $index
            break
        }
    }
    if ($targetIndex -lt 0) {
        Reset-TaskDropGapAnimation
        return
    }

    $beforeIndex = if ([bool]$DropLocation.PlaceAfter) { $targetIndex } else { $targetIndex - 1 }
    $afterIndex = if ([bool]$DropLocation.PlaceAfter) { $targetIndex + 1 } else { $targetIndex }
    $beforeCard = if ($beforeIndex -ge 0 -and $beforeIndex -lt $validCards.Count) { $validCards[$beforeIndex] } else { $null }
    $afterCard = if ($afterIndex -ge 0 -and $afterIndex -lt $validCards.Count) { $validCards[$afterIndex] } else { $null }

    foreach ($child in $taskList.Children) {
        if ($child -isnot [Windows.Controls.Border] -or [string]$child.Tag -eq $SourceTaskId) { continue }
        $offset = if ($child -eq $beforeCard) { -9 } elseif ($child -eq $afterCard) { 9 } else { 0 }
        Animate-CardTranslateY $child $offset 135
    }
}

function Animate-CardEntry {
    param($Card)
    if ($null -eq $Card -or $Card.RenderTransform.Children.Count -lt 2) { return }
    $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(190))
    $fade = [Windows.Media.Animation.DoubleAnimation]::new()
    $fade.From = 0
    $fade.To = 1
    $fade.Duration = $duration
    $fade.EasingFunction = New-CardAnimationEase
    $slide = [Windows.Media.Animation.DoubleAnimation]::new()
    $slide.From = 8
    $slide.To = 0
    $slide.Duration = $duration
    $slide.EasingFunction = New-CardAnimationEase
    $Card.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    $Card.RenderTransform.Children[1].BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Get-TaskDropLocation {
    param([string]$SourceTaskId, [double]$PointerY)
    $sourceTask = Get-TaskById $SourceTaskId
    $sourceLevel = Get-TaskReorderLevel $sourceTask
    if ($null -eq $sourceLevel) { return $null }

    $validCards = [Collections.Generic.List[object]]::new()
    foreach ($child in $taskList.Children) {
        if ($child -isnot [Windows.Controls.Border]) { continue }
        $candidateTask = Get-TaskById ([string]$child.Tag)
        if ((Get-TaskReorderLevel $candidateTask) -eq $sourceLevel) {
            $validCards.Add($child)
        }
    }
    if ($validCards.Count -eq 0) { return $null }

    foreach ($card in $validCards) {
        $top = $card.TranslatePoint([Windows.Point]::new(0, 0), $taskList).Y
        if ($null -ne $card.RenderTransform -and $card.RenderTransform.Children.Count -ge 2) {
            # RenderTransform 会参与 TranslatePoint；减去动画位移后，命中判断始终基于原始布局，避免让位动画造成边界抖动。
            $top -= [double]$card.RenderTransform.Children[1].Y
        }
        $bottom = $top + $card.ActualHeight
        if ($PointerY -lt $top) {
            return [PSCustomObject]@{ Card = $card; TargetId = [string]$card.Tag; PlaceAfter = $false }
        }
        if ($PointerY -le $bottom) {
            $placeAfter = $PointerY -ge ($top + ($card.ActualHeight / 2))
            return [PSCustomObject]@{ Card = $card; TargetId = [string]$card.Tag; PlaceAfter = $placeAfter }
        }
    }

    $lastCard = $validCards[$validCards.Count - 1]
    return [PSCustomObject]@{ Card = $lastCard; TargetId = [string]$lastCard.Tag; PlaceAfter = $true }
}

function Send-WidgetToDesktopBottom {
    if ($script:WidgetHandle -eq [IntPtr]::Zero) { return }

    if ($script:DesktopHandle -eq [IntPtr]::Zero) {
        $script:DesktopHandle = [DesktopWidgetNative]::FindDesktopHost()
    }
    if ($script:DesktopHandle -ne [IntPtr]::Zero) {
        # An owned top-level window stays above its desktop owner. HWND_BOTTOM
        # therefore places the widget directly above the desktop, but below
        # every ordinary application window.
        [void][DesktopWidgetNative]::SetWindowLongPtr(
            $script:WidgetHandle,
            -8,
            $script:DesktopHandle
        )
        [void][DesktopWidgetNative]::SetWindowPos(
            $script:WidgetHandle,
            [IntPtr]1,
            0,
            0,
            0,
            0,
            0x0213
        )
    }
}

function Send-WidgetToNormalWindowLayer {
    if ($script:WidgetHandle -eq [IntPtr]::Zero) { return }

    # Wallpaper mode assigns the desktop window as the native owner. Remove
    # that owner so window mode participates in the ordinary window z-order.
    [void][DesktopWidgetNative]::SetWindowLongPtr(
        $script:WidgetHandle,
        -8,
        [IntPtr]::Zero
    )
    # HWND_TOP with SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
    # SWP_NOOWNERZORDER makes the widget visible above ordinary windows now,
    # while still allowing another window to cover it when that window is used.
    [void][DesktopWidgetNative]::SetWindowPos(
        $script:WidgetHandle,
        [IntPtr]::Zero,
        0,
        0,
        0,
        0,
        0x0213
    )
}

function Apply-WindowLayerMode {
    if ($null -ne $script:BottomEnforcementTimer) {
        $script:BottomEnforcementTimer.Stop()
    }

    if ($script:WindowLayerMode -eq 'alwaysBottom') {
        Send-WidgetToDesktopBottom
        if ($null -eq $script:BottomEnforcementTimer) {
            $script:BottomEnforcementTimer = [Windows.Threading.DispatcherTimer]::new()
            $script:BottomEnforcementTimer.Interval = [TimeSpan]::FromMilliseconds(400)
            $script:BottomEnforcementTimer.Add_Tick({ Send-WidgetToDesktopBottom })
        }
        $script:BottomEnforcementTimer.Start()
    } else {
        Send-WidgetToNormalWindowLayer
    }
}

function Ensure-WidgetOnVisibleScreen {
    if ($script:WidgetHandle -eq [IntPtr]::Zero -or $null -eq $window) { return }

    $windowRect = New-Object DesktopWidgetNative+RECT
    if (-not [DesktopWidgetNative]::GetWindowRect($script:WidgetHandle, [ref]$windowRect)) { return }

    $hasUsableIntersection = $false
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $bounds = $screen.Bounds
        $intersectionWidth = [Math]::Min($windowRect.Right, $bounds.Right) - [Math]::Max($windowRect.Left, $bounds.Left)
        $intersectionHeight = [Math]::Min($windowRect.Bottom, $bounds.Bottom) - [Math]::Max($windowRect.Top, $bounds.Top)
        if ($intersectionWidth -ge 80 -and $intersectionHeight -ge 60) {
            $hasUsableIntersection = $true
            break
        }
    }
    if ($hasUsableIntersection) { return }

    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    if ($null -eq $primaryScreen) { return }
    $workingArea = $primaryScreen.WorkingArea
    $windowWidth = [Math]::Max(1, $windowRect.Right - $windowRect.Left)
    $windowHeight = [Math]::Max(1, $windowRect.Bottom - $windowRect.Top)
    $newLeft = [int]($workingArea.Left + [Math]::Max(0, ($workingArea.Width - $windowWidth) / 2))
    $newTop = [int]($workingArea.Top + [Math]::Max(0, ($workingArea.Height - $windowHeight) / 2))

    # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
    [void][DesktopWidgetNative]::SetWindowPos(
        $script:WidgetHandle,
        [IntPtr]::Zero,
        $newLeft,
        $newTop,
        0,
        0,
        0x0015
    )
    Apply-WindowLayerMode
    Save-State
}

function Move-WidgetToPrimaryScreen {
    if ($script:WidgetHandle -eq [IntPtr]::Zero) { return }
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    if ($null -eq $primaryScreen) { return }

    $windowRect = New-Object DesktopWidgetNative+RECT
    if (-not [DesktopWidgetNative]::GetWindowRect($script:WidgetHandle, [ref]$windowRect)) { return }
    $workingArea = $primaryScreen.WorkingArea
    $windowWidth = [Math]::Max(1, $windowRect.Right - $windowRect.Left)
    $windowHeight = [Math]::Max(1, $windowRect.Bottom - $windowRect.Top)
    $newLeft = [int]($workingArea.Left + [Math]::Max(0, ($workingArea.Width - $windowWidth) / 2))
    $newTop = [int]($workingArea.Top + [Math]::Max(0, ($workingArea.Height - $windowHeight) / 2))

    [void][DesktopWidgetNative]::SetWindowPos($script:WidgetHandle, [IntPtr]::Zero, $newLeft, $newTop, 0, 0, 0x0015)
    Apply-WindowLayerMode
    Save-State
}

function Locate-WidgetFromTray {
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) { $window.WindowState = [Windows.WindowState]::Normal }
    if (-not $window.IsVisible) { $window.Show() }
    Move-WidgetToPrimaryScreen
    [void]$window.Activate()
}

function Minimize-OtherWindowsOnWidgetScreen {
    if ($script:WidgetHandle -eq [IntPtr]::Zero) { return }

    # MONITOR_DEFAULTTONEAREST selects the monitor containing the largest
    # part of the widget when it spans two screens.
    $targetMonitor = [DesktopWidgetNative]::MonitorFromWindow($script:WidgetHandle, 2)
    if ($targetMonitor -eq [IntPtr]::Zero) { return }

    $currentProcessId = [uint32][Diagnostics.Process]::GetCurrentProcess().Id
    $shellWindow = [DesktopWidgetNative]::GetShellWindow()
    $callback = [DesktopWidgetNative+EnumWindowsProc]{
        param([IntPtr]$candidateHandle, [IntPtr]$ignored)

        try {
            if ($candidateHandle -eq $script:WidgetHandle -or $candidateHandle -eq $shellWindow) { return $true }
            if (-not [DesktopWidgetNative]::IsWindowVisible($candidateHandle)) { return $true }
            if ([DesktopWidgetNative]::IsIconic($candidateHandle)) { return $true }
            if ([DesktopWidgetNative]::MonitorFromWindow($candidateHandle, 0) -ne $targetMonitor) { return $true }

            $candidateProcessId = [uint32]0
            [void][DesktopWidgetNative]::GetWindowThreadProcessId($candidateHandle, [ref]$candidateProcessId)
            if ($candidateProcessId -eq $currentProcessId) { return $true }

            # Owned windows and non-activating tool windows are not independent
            # application windows; minimizing them can disturb trays, widgets,
            # floating palettes, and other system UI.
            if ([DesktopWidgetNative]::GetWindow($candidateHandle, 4) -ne [IntPtr]::Zero) { return $true }
            $extendedStyle = [uint32][DesktopWidgetNative]::GetWindowLong($candidateHandle, -20)
            $isToolWindow = ($extendedStyle -band [uint32]0x00000080) -ne 0
            $isAppWindow = ($extendedStyle -band [uint32]0x00040000) -ne 0
            $doesNotActivate = ($extendedStyle -band [uint32]0x08000000) -ne 0
            if (($isToolWindow -and -not $isAppWindow) -or $doesNotActivate) { return $true }

            $className = [Text.StringBuilder]::new(256)
            [void][DesktopWidgetNative]::GetClassName($candidateHandle, $className, $className.Capacity)
            if ([string]$className -in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW')) { return $true }

            # SW_MINIMIZE is asynchronous so one unresponsive application
            # cannot block the tray double-click handler.
            [void][DesktopWidgetNative]::ShowWindowAsync($candidateHandle, 6)
        }
        catch {
            # A window may close while EnumWindows is running. Continue with
            # the remaining windows instead of failing the whole operation.
        }
        return $true
    }

    [void][DesktopWidgetNative]::EnumWindows($callback, [IntPtr]::Zero)
}

function Reveal-WidgetByMinimizingWindows {
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) { $window.WindowState = [Windows.WindowState]::Normal }
    if (-not $window.IsVisible) { $window.Show() }
    Minimize-OtherWindowsOnWidgetScreen
}

function Restart-TodoWidget {
    if (-not (Test-Path -LiteralPath $script:RestartLauncherPath)) {
        [void][Windows.MessageBox]::Show(
            "找不到静默重启文件：`n$script:RestartLauncherPath",
            '重启桌面待办',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
        return
    }

    try {
        $wscriptPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f $script:RestartLauncherPath) -WindowStyle Hidden
        $window.Close()
    }
    catch {
        [void][Windows.MessageBox]::Show(
            "无法重启桌面待办：`n$($_.Exception.Message)",
            '重启桌面待办',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
    }
}

function Initialize-TrayIcon {
    if ($null -ne $script:TrayIcon) { return }

    $script:TrayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
    $locateItem = $script:TrayMenu.Items.Add('定位待办窗口')
    $settingsItem = $script:TrayMenu.Items.Add('打开待办设置')
    $restartItem = $script:TrayMenu.Items.Add('重启桌面待办')
    [void]$script:TrayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $exitItem = $script:TrayMenu.Items.Add('退出桌面待办')

    $locateItem.Add_Click({ Locate-WidgetFromTray })
    $settingsItem.Add_Click({ Show-Settings })
    $restartItem.Add_Click({ Restart-TodoWidget })
    $exitItem.Add_Click({ $window.Close() })

    $script:TrayIcon = [System.Windows.Forms.NotifyIcon]::new()
    if (Test-Path -LiteralPath $script:IconPath) {
        $script:AppIcon = [System.Drawing.Icon]::new($script:IconPath)
        $script:TrayIcon.Icon = $script:AppIcon
    } else {
        $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
    $script:TrayIcon.Text = "$($script:DisplayTitle) · 桌面待办 v$script:Version"
    $script:TrayIcon.ContextMenuStrip = $script:TrayMenu
    $script:TrayIcon.Add_DoubleClick({ Reveal-WidgetByMinimizingWindows })
    $script:TrayIcon.Visible = $true
}

function Load-State {
    $defaultDeviceId = [Guid]::NewGuid().ToString('N')
    $defaultCreatedAt = Get-UtcTimestamp
    $defaultState = [PSCustomObject]@{
        tasks = @(
            [PSCustomObject]@{ id = (New-TaskId); text = '体验桌面待办小组件'; completed = $false; completedAt = $null; dueDate = (Get-Date).AddDays(2).ToString('yyyy-MM-dd'); prerequisiteId = $null; sortOrder = 0; createdAt = $defaultCreatedAt; updatedAt = $defaultCreatedAt; updatedBy = $defaultDeviceId; detailUpdatedAt = $null; detailUpdatedBy = $null; detailDeleted = $false },
            [PSCustomObject]@{ id = (New-TaskId); text = '勾选一条已完成的任务'; completed = $true; completedAt = $defaultCreatedAt; dueDate = $null; prerequisiteId = $null; sortOrder = 1; createdAt = (Get-Date).AddMinutes(-1).ToString('o'); updatedAt = $defaultCreatedAt; updatedBy = $defaultDeviceId; detailUpdatedAt = $null; detailUpdatedBy = $null; detailDeleted = $false }
        )
        deletedTasks = @()
        left = $null
        top = $null
        height = 610
        locked = $false
        settings = [PSCustomObject]@{ urgentDays = 3; cardActionMode = 'unified'; windowLayerMode = 'desktop'; autoStartEnabled = $false; displayTitle = '我的一天'; deviceId = $defaultDeviceId; syncDirectory = (Get-DefaultSyncDirectory); lastSyncAt = $null }
        ui = [PSCustomObject]@{ useDueDate = $false; dueDate = $null; usePrerequisite = $false; prerequisiteId = $null; currentFilter = 'all'; exportType = 'completed'; exportStartDate = $null; exportEndDate = $null }
    }

    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $defaultState
    }

    try {
        $loaded = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $loaded.tasks) { $loaded | Add-Member -NotePropertyName tasks -NotePropertyValue @() }
        if ($loaded.PSObject.Properties.Name -notcontains 'deletedTasks') {
            $loaded | Add-Member -NotePropertyName deletedTasks -NotePropertyValue @()
        }
        $taskIndex = 0
        foreach ($task in @($loaded.tasks)) {
            if ($task.PSObject.Properties.Name -notcontains 'dueDate') {
                $task | Add-Member -NotePropertyName dueDate -NotePropertyValue $null
            }
            if ($task.PSObject.Properties.Name -notcontains 'completedAt') {
                $legacyCompletedAt = if ([bool]$task.completed) { [string]$task.createdAt } else { $null }
                $task | Add-Member -NotePropertyName completedAt -NotePropertyValue $legacyCompletedAt
            }
            if ($task.PSObject.Properties.Name -notcontains 'prerequisiteId') {
                $task | Add-Member -NotePropertyName prerequisiteId -NotePropertyValue $null
            }
            if ($task.PSObject.Properties.Name -notcontains 'sortOrder') {
                $task | Add-Member -NotePropertyName sortOrder -NotePropertyValue $taskIndex
            }
            if ($task.PSObject.Properties.Name -notcontains 'updatedAt') {
                $legacyUpdatedAt = if (-not [string]::IsNullOrWhiteSpace([string]$task.completedAt)) { [string]$task.completedAt } elseif (-not [string]::IsNullOrWhiteSpace([string]$task.createdAt)) { [string]$task.createdAt } else { Get-UtcTimestamp }
                $task | Add-Member -NotePropertyName updatedAt -NotePropertyValue $legacyUpdatedAt
            }
            if ($task.PSObject.Properties.Name -notcontains 'updatedBy') {
                $task | Add-Member -NotePropertyName updatedBy -NotePropertyValue ''
            }
            if ($task.PSObject.Properties.Name -notcontains 'detailUpdatedAt') {
                $task | Add-Member -NotePropertyName detailUpdatedAt -NotePropertyValue $null
            }
            if ($task.PSObject.Properties.Name -notcontains 'detailUpdatedBy') {
                $task | Add-Member -NotePropertyName detailUpdatedBy -NotePropertyValue $null
            }
            if ($task.PSObject.Properties.Name -notcontains 'detailDeleted') {
                $task | Add-Member -NotePropertyName detailDeleted -NotePropertyValue $false
            }
            $taskIndex++
        }
        if ($null -eq $loaded.settings) {
            $loaded | Add-Member -NotePropertyName settings -NotePropertyValue ([PSCustomObject]@{ urgentDays = 3; cardActionMode = 'unified'; windowLayerMode = 'desktop'; autoStartEnabled = $false; displayTitle = '我的一天'; deviceId = $defaultDeviceId; syncDirectory = (Get-DefaultSyncDirectory); lastSyncAt = $null })
        } else {
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'cardActionMode') {
                $loaded.settings | Add-Member -NotePropertyName cardActionMode -NotePropertyValue 'unified'
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'windowLayerMode') {
                $loaded.settings | Add-Member -NotePropertyName windowLayerMode -NotePropertyValue 'desktop'
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'autoStartEnabled') {
                $loaded.settings | Add-Member -NotePropertyName autoStartEnabled -NotePropertyValue $false
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'displayTitle') {
                $loaded.settings | Add-Member -NotePropertyName displayTitle -NotePropertyValue '我的一天'
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'deviceId' -or [string]::IsNullOrWhiteSpace([string]$loaded.settings.deviceId)) {
                if ($loaded.settings.PSObject.Properties.Name -contains 'deviceId') { $loaded.settings.deviceId = $defaultDeviceId } else { $loaded.settings | Add-Member -NotePropertyName deviceId -NotePropertyValue $defaultDeviceId }
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'syncDirectory') {
                $loaded.settings | Add-Member -NotePropertyName syncDirectory -NotePropertyValue (Get-DefaultSyncDirectory)
            }
            if ($loaded.settings.PSObject.Properties.Name -notcontains 'lastSyncAt') {
                $loaded.settings | Add-Member -NotePropertyName lastSyncAt -NotePropertyValue $null
            }
        }
        if ($null -eq $loaded.ui) {
            $loaded | Add-Member -NotePropertyName ui -NotePropertyValue ([PSCustomObject]@{ useDueDate = $false; dueDate = $null; usePrerequisite = $false; prerequisiteId = $null; currentFilter = 'all'; exportType = 'completed'; exportStartDate = $null; exportEndDate = $null })
        }
        return $loaded
    }
    catch {
        return $defaultState
    }
}

function Save-State {
    if (-not (Test-Path -LiteralPath $script:AppDirectory)) {
        New-Item -ItemType Directory -Path $script:AppDirectory -Force | Out-Null
    }

    $savedLeft = $window.Left
    $savedTop = $window.Top
    if ($script:WidgetHandle -ne [IntPtr]::Zero) {
        $windowRect = New-Object DesktopWidgetNative+RECT
        if ([DesktopWidgetNative]::GetWindowRect($script:WidgetHandle, [ref]$windowRect)) {
            $savedLeft = $windowRect.Left
            $savedTop = $windowRect.Top
        }
    }

    $state = [PSCustomObject]@{
        tasks = @($script:Tasks)
        deletedTasks = @($script:DeletedTasks)
        left = $savedLeft
        top = $savedTop
        height = $window.ActualHeight
        locked = $script:IsLocked
        settings = [PSCustomObject]@{ urgentDays = $script:UrgentDays; cardActionMode = $script:CardActionMode; windowLayerMode = $script:WindowLayerMode; autoStartEnabled = $script:AutoStartEnabled; displayTitle = $script:DisplayTitle; deviceId = $script:DeviceId; syncDirectory = $script:SyncDirectory; lastSyncAt = $script:LastSyncAt }
        ui = [PSCustomObject]@{
            useDueDate = [bool]$useDueDateCheckBox.IsChecked
            dueDate = if ($null -eq $dueDatePicker.SelectedDate) { $null } else { ([datetime]$dueDatePicker.SelectedDate).ToString('yyyy-MM-dd') }
            usePrerequisite = [bool]$usePrerequisiteCheckBox.IsChecked
            prerequisiteId = if ($null -eq $prerequisiteComboBox.SelectedItem) { $null } else { [string]$prerequisiteComboBox.SelectedItem.Tag }
            currentFilter = $script:CurrentFilter
            exportType = $script:ExportType
            exportStartDate = $script:ExportStartDate
            exportEndDate = $script:ExportEndDate
        }
    }
    $temporaryStatePath = "$script:StatePath.tmp"
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryStatePath -Encoding UTF8
    Move-Item -LiteralPath $temporaryStatePath -Destination $script:StatePath -Force
}

function Save-UiStateIfReady {
    if (-not $script:IsRestoringUiState -and $null -ne $window -and $window.IsLoaded) {
        Save-State
    }
}

function Disable-ButtonFocusVisuals {
    param($Root)
    if ($null -eq $Root) { return }
    if ($Root -is [Windows.Controls.Button]) {
        $Root.FocusVisualStyle = $null
    }
    if ($Root -isnot [Windows.DependencyObject]) { return }
    foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($Root)) {
        if ($child -is [Windows.DependencyObject]) {
            Disable-ButtonFocusVisuals $child
        }
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面待办" Width="380" MinWidth="380" MaxWidth="380" Height="610" MinHeight="500"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" ShowInTaskbar="False" Topmost="False"
        FontFamily="Microsoft YaHei UI">
    <Window.Resources>
        <SolidColorBrush x:Key="Ink" Color="#FF20242C"/>
        <SolidColorBrush x:Key="Muted" Color="#FF8B909B"/>
        <SolidColorBrush x:Key="Accent" Color="#FF6C5CE7"/>
        <Style TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="ToolTipService.InitialShowDelay" Value="250"/>
            <Setter Property="ToolTipService.ShowDuration" Value="6000"/>
        </Style>
        <Style x:Key="FilterButton" TargetType="Button">
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#FF8B909B"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="12">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FFF1EFFD"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border CornerRadius="22" Background="#FFF9FAFC" BorderBrush="#18000000" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="28" ShadowDepth="7" Opacity="0.22" Color="#FF1E2030"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="72"/>
                <RowDefinition Height="140"/>
                <RowDefinition Height="48"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="42"/>
            </Grid.RowDefinitions>

            <Grid x:Name="DragArea" Grid.Row="0" Background="Transparent" Margin="22,0,16,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="TitleText" Text="我的一天" FontSize="23" FontWeight="SemiBold" Foreground="{StaticResource Ink}" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="DateText" FontSize="11" Foreground="{StaticResource Muted}" Margin="1,3,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="ExportButton" Content="⇩" Width="34" Height="34" FontSize="17" Foreground="#FF8B909B" Background="Transparent" ToolTip="导出 Markdown 待办记录"/>
                    <Button x:Name="SettingsButton" Content="⚙" Width="34" Height="34" FontSize="15" Foreground="#FF8B909B" Background="Transparent" ToolTip="打开待办设置"/>
                    <Button x:Name="LockButton" Content="◇" Width="34" Height="34" FontSize="17" Foreground="#FF8B909B" Background="Transparent" ToolTip="固定组件位置"/>
                    <Button x:Name="CloseButton" Content="×" Width="34" Height="34" FontSize="22" Foreground="#FF707580" Background="Transparent" ToolTip="关闭"/>
                </StackPanel>
            </Grid>

            <Border Grid.Row="1" Margin="20,8,20,14" CornerRadius="16" Background="White" BorderBrush="#12000000" BorderThickness="1">
                <Grid Margin="14,12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="38"/>
                        <RowDefinition Height="34"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="46"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="NewTaskText" BorderThickness="0" Background="Transparent"
                             VerticalContentAlignment="Center" FontSize="14" Foreground="{StaticResource Ink}"
                             TextWrapping="Wrap" AcceptsReturn="False" ToolTip="输入待办，按回车添加"/>
                    <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <CheckBox x:Name="UseDueDateCheckBox" Content="DDL" Width="72" VerticalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}" Margin="0,0,8,0" ToolTip="勾选后为待办设置截止日期"/>
                        <DatePicker x:Name="DueDatePicker" Width="156" Height="26" FontSize="11" SelectedDateFormat="Short" IsEnabled="False" ToolTip="选择截止日期"/>
                    </StackPanel>
                    <StackPanel Grid.Row="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <CheckBox x:Name="UsePrerequisiteCheckBox" Content="前置任务" Width="72" VerticalAlignment="Center" FontSize="11" Foreground="{StaticResource Muted}" Margin="0,0,8,0" ToolTip="勾选后，新待办会等待所选任务完成"/>
                        <ComboBox x:Name="PrerequisiteComboBox" Width="156" Height="26" FontSize="11" IsEnabled="False" ToolTip="选择必须先完成的任务"/>
                    </StackPanel>
                    <Button x:Name="AddButton" Grid.RowSpan="3" Grid.Column="1" Content="+" Width="38" Height="38" FontSize="24"
                            Foreground="White" Background="{StaticResource Accent}">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border Background="{TemplateBinding Background}" CornerRadius="12">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </Grid>
            </Border>

            <Grid Grid.Row="2" Margin="20,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="AllFilter" Content="全部" Style="{StaticResource FilterButton}" Margin="0,0,10,0"/>
                <Button x:Name="ActiveFilter" Grid.Column="1" Content="待完成" Style="{StaticResource FilterButton}" Margin="0,0,10,0"/>
                <Button x:Name="DoneFilter" Grid.Column="2" Content="已完成" Style="{StaticResource FilterButton}"/>
                <TextBlock x:Name="CountText" Grid.Column="4" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontSize="11"/>
            </Grid>

            <ScrollViewer Grid.Row="3" Margin="14,0,10,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="TaskList" Margin="6,4,10,8" Background="Transparent"/>
            </ScrollViewer>

            <TextBlock x:Name="FooterText" Grid.Row="4" Text="桌面插件模式 · 拖动顶部移动" HorizontalAlignment="Center" VerticalAlignment="Center"
                       Foreground="#FFA7ABB3" FontSize="10"/>
            <ResizeGrip Grid.RowSpan="5" HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="20" Height="20" Margin="0,0,6,6" Cursor="SizeNS" ToolTip="上下拖动调整高度"/>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Disable-ButtonFocusVisuals $window
$window.Title = "桌面待办 v$script:Version"
if (Test-Path -LiteralPath $script:IconPath) {
    $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($script:IconPath, [UriKind]::Absolute))
}

$taskList = $window.FindName('TaskList')
$newTaskText = $window.FindName('NewTaskText')
$useDueDateCheckBox = $window.FindName('UseDueDateCheckBox')
$dueDatePicker = $window.FindName('DueDatePicker')
$usePrerequisiteCheckBox = $window.FindName('UsePrerequisiteCheckBox')
$prerequisiteComboBox = $window.FindName('PrerequisiteComboBox')
$addButton = $window.FindName('AddButton')
$closeButton = $window.FindName('CloseButton')
$exportButton = $window.FindName('ExportButton')
$settingsButton = $window.FindName('SettingsButton')
$lockButton = $window.FindName('LockButton')
$dragArea = $window.FindName('DragArea')
$footerText = $window.FindName('FooterText')
$titleText = $window.FindName('TitleText')
$dateText = $window.FindName('DateText')
$countText = $window.FindName('CountText')
$allFilter = $window.FindName('AllFilter')
$activeFilter = $window.FindName('ActiveFilter')
$doneFilter = $window.FindName('DoneFilter')

$dateText.Text = (Get-Date).ToString('yyyy年M月d日 dddd', [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))

function Set-FilterAppearance {
    $buttons = @($allFilter, $activeFilter, $doneFilter)
    foreach ($button in $buttons) {
        $button.Background = [Windows.Media.Brushes]::Transparent
        $button.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF8B909B')
        $button.FontWeight = [Windows.FontWeights]::Normal
    }
    $activeButton = switch ($script:CurrentFilter) {
        'active' { $activeFilter }
        'done' { $doneFilter }
        default { $allFilter }
    }
    $activeButton.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFECE9FF')
    $activeButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF5A49DA')
    $activeButton.FontWeight = [Windows.FontWeights]::SemiBold
}

function Update-PrerequisitePicker {
    $selectedId = if ($null -eq $prerequisiteComboBox.SelectedItem) { $null } else { [string]$prerequisiteComboBox.SelectedItem.Tag }
    $prerequisiteComboBox.Items.Clear()
    foreach ($task in @($script:Tasks | Sort-Object @{ Expression = { [bool]$_.completed } }, @{ Expression = { [string]$_.text } })) {
        $item = [Windows.Controls.ComboBoxItem]::new()
        $item.Tag = [string]$task.id
        $prefix = if ($task.completed) { '✓ ' } else { '' }
        $displayText = [string]$task.text
        if ($displayText.Length -gt 15) { $displayText = $displayText.Substring(0, 15) + '…' }
        $item.Content = $prefix + $displayText
        $item.ToolTip = [string]$task.text
        [void]$prerequisiteComboBox.Items.Add($item)
        if ([string]$task.id -eq $selectedId) { $prerequisiteComboBox.SelectedItem = $item }
    }
    if ($prerequisiteComboBox.Items.Count -eq 0) {
        $prerequisiteComboBox.IsEnabled = $false
    }
}

function Show-PrerequisiteEditor {
    param([string]$TaskId)
    $targetTask = Get-TaskById $TaskId
    if ($null -eq $targetTask) { return }

    [xml]$editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="修改前置任务" Width="380" Height="260"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False"
        Background="#FFF9FAFC" FontFamily="Microsoft YaHei UI">
    <Grid Margin="24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="修改前置任务" FontSize="19" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <TextBlock x:Name="TaskNameText" Grid.Row="1" Margin="0,10,0,14" FontSize="12" Foreground="#FF707580" TextWrapping="Wrap"/>
        <ComboBox x:Name="EditorComboBox" Grid.Row="2" Height="32" FontSize="12"/>
        <TextBlock x:Name="EditorValidation" Grid.Row="3" Margin="0,10,0,0" FontSize="11" Foreground="#FFE05252" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelEditorButton" Content="取消" Width="72" Height="32" Margin="0,0,10,0"/>
            <Button x:Name="SaveEditorButton" Content="保存" Width="72" Height="32" Background="#FF6C5CE7" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $editorReader = New-Object System.Xml.XmlNodeReader $editorXaml
    $editorWindow = [Windows.Markup.XamlReader]::Load($editorReader)
    Disable-ButtonFocusVisuals $editorWindow
    $editorWindow.Owner = $window
    $editorWindow.FindName('TaskNameText').Text = "待办：$([string]$targetTask.text)"
    $editorComboBox = $editorWindow.FindName('EditorComboBox')
    $editorValidation = $editorWindow.FindName('EditorValidation')
    $saveEditorButton = $editorWindow.FindName('SaveEditorButton')
    $cancelEditorButton = $editorWindow.FindName('CancelEditorButton')

    $noneItem = [Windows.Controls.ComboBoxItem]::new()
    $noneItem.Content = '无前置任务'
    $noneItem.Tag = ''
    [void]$editorComboBox.Items.Add($noneItem)
    if ([string]::IsNullOrWhiteSpace([string]$targetTask.prerequisiteId)) { $editorComboBox.SelectedItem = $noneItem }

    foreach ($candidate in @($script:Tasks | Where-Object {
        [string]$_.id -ne $TaskId -and -not (Test-WouldCreateDependencyCycle $TaskId ([string]$_.id))
    } | Sort-Object @{ Expression = { [bool]$_.completed } }, @{ Expression = { [string]$_.text } })) {
        $item = [Windows.Controls.ComboBoxItem]::new()
        $item.Tag = [string]$candidate.id
        $candidatePrefix = if ($candidate.completed) { '✓ ' } else { '' }
        $item.Content = $candidatePrefix + [string]$candidate.text
        [void]$editorComboBox.Items.Add($item)
        if ([string]$candidate.id -eq [string]$targetTask.prerequisiteId) { $editorComboBox.SelectedItem = $item }
    }
    if ($null -eq $editorComboBox.SelectedItem) { $editorComboBox.SelectedItem = $noneItem }

    $saveEditorButton.Add_Click({
        $candidateId = if ($null -eq $editorComboBox.SelectedItem) { '' } else { [string]$editorComboBox.SelectedItem.Tag }
        if (Test-WouldCreateDependencyCycle $TaskId $candidateId) {
            $editorValidation.Text = '该选择会形成循环依赖，请选择其他任务。'
            return
        }
        $taskToUpdate = Get-TaskById $TaskId
        if ($null -ne $taskToUpdate) {
            $taskToUpdate.prerequisiteId = if ([string]::IsNullOrWhiteSpace($candidateId)) { $null } else { $candidateId }
            Set-TaskModified $taskToUpdate $null
            Save-State
            Refresh-Tasks
        }
        $editorWindow.DialogResult = $true
    })
    $cancelEditorButton.Add_Click({ $editorWindow.Close() })
    [void]$editorWindow.ShowDialog()
    Apply-WindowLayerMode
}

function Show-TaskTextEditor {
    param([string]$TaskId)
    $targetTask = Get-TaskById $TaskId
    if ($null -eq $targetTask) { return }

    [xml]$textEditorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="修改待办文字" Width="400" Height="230"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False"
        Background="#FFF9FAFC" FontFamily="Microsoft YaHei UI">
    <Grid Margin="24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="修改待办文字" FontSize="19" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <TextBox x:Name="TaskTextEditor" Grid.Row="1" Height="34" Margin="0,16,0,0"
                 Padding="9,0" FontSize="13" VerticalContentAlignment="Center"/>
        <TextBlock x:Name="TextEditorValidation" Grid.Row="2" Margin="0,10,0,0"
                   FontSize="11" Foreground="#FFE05252" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelTextEditorButton" Content="取消" Width="72" Height="32" Margin="0,0,10,0"/>
            <Button x:Name="SaveTextEditorButton" Content="保存" Width="72" Height="32"
                    Background="#FF6C5CE7" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $textEditorReader = New-Object System.Xml.XmlNodeReader $textEditorXaml
    $textEditorWindow = [Windows.Markup.XamlReader]::Load($textEditorReader)
    Disable-ButtonFocusVisuals $textEditorWindow
    $textEditorWindow.Owner = $window
    $taskTextEditor = $textEditorWindow.FindName('TaskTextEditor')
    $textEditorValidation = $textEditorWindow.FindName('TextEditorValidation')
    $saveTextEditorButton = $textEditorWindow.FindName('SaveTextEditorButton')
    $cancelTextEditorButton = $textEditorWindow.FindName('CancelTextEditorButton')
    $taskTextEditor.Text = [string]$targetTask.text
    $taskTextEditor.SelectAll()

    $saveTaskText = {
        $newText = $taskTextEditor.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newText)) {
            $textEditorValidation.Text = '待办文字不能为空。'
            $taskTextEditor.Focus() | Out-Null
            return
        }

        $taskToUpdate = Get-TaskById $TaskId
        if ($null -eq $taskToUpdate) {
            $textEditorValidation.Text = '该待办已不存在，无法保存。'
            return
        }
        if ($newText -eq [string]$taskToUpdate.text) {
            $textEditorWindow.DialogResult = $true
            return
        }

        $oldText = [string]$taskToUpdate.text
        $oldDetailPath = Resolve-TaskDetailPath $TaskId
        $hasDetail = $null -ne $oldDetailPath -and (Test-Path -LiteralPath $oldDetailPath)
        $taskToUpdate.text = $newText
        $newDetailPath = Get-TaskDetailPath $TaskId

        try {
            if ($hasDetail -and $oldDetailPath -ne $newDetailPath) {
                if (Test-Path -LiteralPath $newDetailPath) {
                    throw "新的详细说明文件名已存在，请先处理：$newDetailPath"
                }
                Move-Item -LiteralPath $oldDetailPath -Destination $newDetailPath -ErrorAction Stop
            }
            Set-TaskModified $taskToUpdate $null
            Save-State
            Refresh-Tasks
            $textEditorWindow.DialogResult = $true
        }
        catch {
            $taskToUpdate.text = $oldText
            if ($hasDetail -and $oldDetailPath -ne $newDetailPath -and
                -not (Test-Path -LiteralPath $oldDetailPath) -and (Test-Path -LiteralPath $newDetailPath)) {
                try { Move-Item -LiteralPath $newDetailPath -Destination $oldDetailPath -ErrorAction Stop } catch {}
            }
            $textEditorValidation.Text = "无法保存修改：$($_.Exception.Message)"
        }
    }

    $saveTextEditorButton.Add_Click($saveTaskText)
    $taskTextEditor.Add_KeyDown({
        if ($_.Key -eq [Windows.Input.Key]::Enter) {
            & $saveTaskText
            $_.Handled = $true
        }
    })
    $cancelTextEditorButton.Add_Click({ $textEditorWindow.Close() })
    $textEditorWindow.Add_ContentRendered({ $taskTextEditor.Focus() | Out-Null })
    [void]$textEditorWindow.ShowDialog()
    Apply-WindowLayerMode
}

function Show-TaskActions {
    param([string]$TaskId)
    $targetTask = Get-TaskById $TaskId
    if ($null -eq $targetTask) { return }

    [xml]$actionsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="管理待办" Width="360" Height="392"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False"
        Background="#FFF9FAFC" FontFamily="Microsoft YaHei UI">
    <Grid Margin="24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="管理待办" FontSize="19" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <TextBlock x:Name="ActionTaskName" Grid.Row="1" Margin="0,10,0,16" FontSize="12" Foreground="#FF707580" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="2">
            <Button x:Name="EditTaskTextButton" Content="修改待办文字" Height="36" Margin="0,0,0,10" Background="#FFF0EEFC" Foreground="#FF6257C5" BorderThickness="0"/>
            <Button x:Name="EditPrerequisiteButton" Content="修改或取消前置任务" Height="36" Margin="0,0,0,10" Background="#FFECE9FF" Foreground="#FF5A49DA" BorderThickness="0"/>
            <Button x:Name="EditDetailButton" Content="编辑详细说明" Height="36" Margin="0,0,0,10" Background="#FFEDF4FF" Foreground="#FF376CA8" BorderThickness="0"/>
            <Button x:Name="DeleteDetailButton" Content="删除详细说明" Height="36" Margin="0,0,0,10" Background="#FFFFF3E8" Foreground="#FFB46B29" BorderThickness="0"/>
            <Button x:Name="DeleteTaskButton" Content="删除待办" Height="36" Background="#FFFFECEC" Foreground="#FFC94B4B" BorderThickness="0"/>
        </StackPanel>
        <Button x:Name="CloseActionsButton" Grid.Row="3" Content="关闭" Width="72" Height="30" Margin="0,14,0,0" HorizontalAlignment="Right"/>
    </Grid>
</Window>
'@
    $actionsReader = New-Object System.Xml.XmlNodeReader $actionsXaml
    $actionsWindow = [Windows.Markup.XamlReader]::Load($actionsReader)
    Disable-ButtonFocusVisuals $actionsWindow
    $actionsWindow.Owner = $window
    $actionsWindow.FindName('ActionTaskName').Text = [string]$targetTask.text
    $editTaskTextButton = $actionsWindow.FindName('EditTaskTextButton')
    $editPrerequisiteButton = $actionsWindow.FindName('EditPrerequisiteButton')
    $editDetailButton = $actionsWindow.FindName('EditDetailButton')
    $deleteDetailButton = $actionsWindow.FindName('DeleteDetailButton')
    $deleteTaskButton = $actionsWindow.FindName('DeleteTaskButton')
    $closeActionsButton = $actionsWindow.FindName('CloseActionsButton')
    $existingDetailPath = Resolve-TaskDetailPath $TaskId
    $deleteDetailButton.IsEnabled = $null -ne $existingDetailPath -and (Test-Path -LiteralPath $existingDetailPath)
    if (-not $deleteDetailButton.IsEnabled) {
        $deleteDetailButton.Content = '暂无详细说明可删除'
        $deleteDetailButton.Opacity = 0.58
    }

    $editTaskTextButton.Add_Click({
        $actionsWindow.Close()
        Show-TaskTextEditor $TaskId
    })
    $editPrerequisiteButton.Add_Click({
        $actionsWindow.Close()
        Show-PrerequisiteEditor $TaskId
    })
    $editDetailButton.Add_Click({
        $actionsWindow.Close()
        Open-TaskDetail $TaskId
    })
    $deleteDetailButton.Add_Click({
        $currentTask = Get-TaskById $TaskId
        if ($null -eq $currentTask) {
            $actionsWindow.Close()
            return
        }
        $answer = [Windows.MessageBox]::Show(
            $actionsWindow,
            "确定删除「$([string]$currentTask.text)」的详细说明吗？`n`n删除会在下次手动同步时应用到其他电脑。",
            '删除详细说明',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        try {
            if (Remove-TaskDetail $TaskId) {
                $actionsWindow.Close()
            } else {
                $deleteDetailButton.IsEnabled = $false
                $deleteDetailButton.Content = '暂无详细说明可删除'
                $deleteDetailButton.Opacity = 0.58
            }
        }
        catch {
            [void][Windows.MessageBox]::Show(
                $actionsWindow,
                "无法删除详细说明：`n$($_.Exception.Message)",
                '删除详细说明',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Error
            )
        }
    })
    $deleteTaskButton.Add_Click({
        $answer = [Windows.MessageBox]::Show(
            $actionsWindow,
            "确定删除「$([string]$targetTask.text)」吗？",
            '删除待办',
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
        Remove-TaskById $TaskId
        $actionsWindow.Close()
    })
    $closeActionsButton.Add_Click({ $actionsWindow.Close() })
    [void]$actionsWindow.ShowDialog()
    Apply-WindowLayerMode
}

function Show-Settings {
    [xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面待办设置" Width="440" Height="760"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False"
        Background="#FFF9FAFC" FontFamily="Microsoft YaHei UI">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="24,20,24,12">
            <TextBlock Text="待办设置" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="名称" Width="64" VerticalAlignment="Center" FontSize="13" Foreground="#FF40444C"/>
                <TextBox x:Name="DisplayTitleText" Width="310" Height="30" MaxLength="30" FontSize="13" VerticalContentAlignment="Center" Padding="8,0"/>
            </StackPanel>
            <TextBlock Margin="0,12,0,8" Text="剩余天数小于或等于此数值的待办会优先排列："
                       FontSize="12" Foreground="#FF707580" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal">
                <TextBox x:Name="UrgentDaysText" Width="80" Height="30" FontSize="13" VerticalContentAlignment="Center" Padding="8,0"/>
                <TextBlock Text="天" Margin="8,0,0,0" VerticalAlignment="Center" FontSize="13" Foreground="#FF40444C"/>
            </StackPanel>

            <TextBlock Margin="0,20,0,8" Text="卡片操作方式" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <RadioButton x:Name="UnifiedModeRadio" Content="单一管理按钮" Margin="0,0,0,9"/>
            <RadioButton x:Name="SeparateModeRadio" Content="前置任务和删除两个按钮"/>

            <TextBlock Margin="0,20,0,8" Text="窗口层级" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <RadioButton x:Name="DesktopLayerRadio" Content="窗口模式" Margin="0,0,0,9"/>
            <RadioButton x:Name="AlwaysBottomRadio" Content="壁纸模式"/>

            <TextBlock Margin="0,20,0,8" Text="启动" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <CheckBox x:Name="AutoStartCheckBox" Content="开机自启动"/>

            <TextBlock Margin="0,20,0,8" Text="OneDrive 手动同步" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <TextBlock Text="上传只写入本机设备快照；下载会读取云端快照并与本地合并，但不会自动回传。两种操作都会先完整备份本机数据。"
                       FontSize="11" Foreground="#FF707580" TextWrapping="Wrap" Margin="0,0,0,9"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="SyncDirectoryText" Height="31" FontSize="12" VerticalContentAlignment="Center" Padding="8,0"/>
                <Button x:Name="BrowseSyncDirectoryButton" Grid.Column="1" Content="选择…" Width="72" Height="31" Margin="8,0,0,0"/>
            </Grid>
            <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="10"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="UploadSyncButton" Grid.Column="0" Content="上传同步信息" Height="34" Background="#FF6C5CE7" Foreground="White"/>
                <Button x:Name="DownloadSyncButton" Grid.Column="2" Content="下载同步信息" Height="34" Background="#FF5879B8" Foreground="White"/>
            </Grid>
            <TextBlock x:Name="LastSyncText" Margin="0,7,0,0" FontSize="11" Foreground="#FF707580" TextWrapping="Wrap"/>
            <TextBlock x:Name="SyncStatusText" Margin="0,8,0,0" FontSize="11" Foreground="#FF707580" TextWrapping="Wrap"/>
            <TextBlock x:Name="BackupStorageText" Margin="0,5,0,0" FontSize="11" Foreground="#FF707580" TextWrapping="Wrap"/>

            <TextBlock Margin="0,20,0,8" Text="数据管理" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="ClearCompletedButton" Grid.Column="0" Content="备份并清除已完成" Height="34" Margin="0,0,5,0"
                        Background="#FFF0EEFC" Foreground="#FF6257C5"/>
                <Button x:Name="ClearIncompleteButton" Grid.Column="1" Content="备份并清除未完成" Height="34" Margin="5,0,0,0"
                        Background="#FFFBEFF2" Foreground="#FFAD5668"/>
            </Grid>
            <TextBlock x:Name="ValidationText" Margin="0,10,0,0" Foreground="#FFE05252" FontSize="11" TextWrapping="Wrap"/>
        </StackPanel>
        </ScrollViewer>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="24,12,24,18">
            <Button x:Name="CancelButton" Content="取消" Width="72" Height="32" Margin="0,0,10,0"/>
            <Button x:Name="SaveButton" Content="保存" Width="72" Height="32" Background="#FF6C5CE7" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $settingsReader = New-Object System.Xml.XmlNodeReader $settingsXaml
    $settingsWindow = [Windows.Markup.XamlReader]::Load($settingsReader)
    Disable-ButtonFocusVisuals $settingsWindow
    $settingsWindow.Owner = $window
    $settingsWindow.MaxHeight = [Math]::Max(520, [Windows.SystemParameters]::WorkArea.Height - 40)
    if ($settingsWindow.Height -gt $settingsWindow.MaxHeight) { $settingsWindow.Height = $settingsWindow.MaxHeight }
    $displayTitleText = $settingsWindow.FindName('DisplayTitleText')
    $urgentDaysText = $settingsWindow.FindName('UrgentDaysText')
    $validationText = $settingsWindow.FindName('ValidationText')
    $unifiedModeRadio = $settingsWindow.FindName('UnifiedModeRadio')
    $separateModeRadio = $settingsWindow.FindName('SeparateModeRadio')
    $desktopLayerRadio = $settingsWindow.FindName('DesktopLayerRadio')
    $alwaysBottomRadio = $settingsWindow.FindName('AlwaysBottomRadio')
    $autoStartCheckBox = $settingsWindow.FindName('AutoStartCheckBox')
    $syncDirectoryText = $settingsWindow.FindName('SyncDirectoryText')
    $browseSyncDirectoryButton = $settingsWindow.FindName('BrowseSyncDirectoryButton')
    $uploadSyncButton = $settingsWindow.FindName('UploadSyncButton')
    $downloadSyncButton = $settingsWindow.FindName('DownloadSyncButton')
    $lastSyncText = $settingsWindow.FindName('LastSyncText')
    $syncStatusText = $settingsWindow.FindName('SyncStatusText')
    $backupStorageText = $settingsWindow.FindName('BackupStorageText')
    $clearCompletedButton = $settingsWindow.FindName('ClearCompletedButton')
    $clearIncompleteButton = $settingsWindow.FindName('ClearIncompleteButton')
    $saveSettingsButton = $settingsWindow.FindName('SaveButton')
    $cancelSettingsButton = $settingsWindow.FindName('CancelButton')
    $displayTitleText.Text = $script:DisplayTitle
    $urgentDaysText.Text = [string]$script:UrgentDays
    $unifiedModeRadio.IsChecked = $script:CardActionMode -ne 'separate'
    $separateModeRadio.IsChecked = $script:CardActionMode -eq 'separate'
    $desktopLayerRadio.IsChecked = $script:WindowLayerMode -ne 'alwaysBottom'
    $alwaysBottomRadio.IsChecked = $script:WindowLayerMode -eq 'alwaysBottom'
    $autoStartCheckBox.IsChecked = $script:AutoStartEnabled
    $syncDirectoryText.Text = if ([string]::IsNullOrWhiteSpace($script:SyncDirectory)) { [string](Get-DefaultSyncDirectory) } else { $script:SyncDirectory }
    $lastSyncText.Text = Get-LastSyncDisplayText
    $backupInfo = Get-BackupStorageInfo
    $backupStorageText.Text = "永久备份：$($backupInfo.BackupCount) 份，共 $($backupInfo.DisplaySize)。如占用过大，请手动清理 backup 文件夹。"

    $browseSyncDirectoryButton.Add_Click({
        $folderDialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $folderDialog.Description = '选择或新建 DesktopTodoSync 同步文件夹'
        $folderDialog.ShowNewFolderButton = $true
        if (-not [string]::IsNullOrWhiteSpace($syncDirectoryText.Text) -and (Test-Path -LiteralPath $syncDirectoryText.Text)) {
            $folderDialog.SelectedPath = $syncDirectoryText.Text
        }
        try {
            if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $syncDirectoryText.Text = $folderDialog.SelectedPath
            }
        }
        finally {
            $folderDialog.Dispose()
        }
    })

    $runSyncAction = {
        param([ValidateSet('upload','download')][string]$direction)
        $requestedSyncDirectory = $syncDirectoryText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($requestedSyncDirectory)) {
            $requestedSyncDirectory = Get-DefaultSyncDirectory
            $syncDirectoryText.Text = [string]$requestedSyncDirectory
        }
        $uploadSyncButton.IsEnabled = $false
        $downloadSyncButton.IsEnabled = $false
        $browseSyncDirectoryButton.IsEnabled = $false
        $syncStatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF6C5CE7')
        $syncStatusText.Text = if ($direction -eq 'upload') { '正在备份本机数据并上传设备快照…' } else { '正在备份本机数据并下载、合并云端快照…' }
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $result = if ($direction -eq 'upload') { Invoke-OneDriveUpload $requestedSyncDirectory } else { Invoke-OneDriveDownload $requestedSyncDirectory }
            Refresh-Tasks
            $syncDirectoryText.Text = $script:SyncDirectory
            $lastSyncText.Text = Get-LastSyncDisplayText
            $syncStatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF438563')
            if ($direction -eq 'upload') {
                $syncStatusText.Text = "上传完成：已写入 $($result.TaskCount) 项待办和 $($result.DeletedTaskCount) 条删除记录。请等待 OneDrive 完成云端传输。"
            } else {
                $warningText = if ($result.InvalidSnapshotCount -gt 0) { "；跳过 $($result.InvalidSnapshotCount) 个无效快照" } else { '' }
                $syncStatusText.Text = "下载完成：已合并 $($result.DeviceSnapshotCount) 个云端设备快照，当前共 $($result.TaskCount) 项待办$warningText。本次结果尚未上传。"
            }
            $backupInfo = Get-BackupStorageInfo
            $backupStorageText.Text = "永久备份：$($backupInfo.BackupCount) 份，共 $($backupInfo.DisplaySize)。如占用过大，请手动清理 backup 文件夹。"
        }
        catch {
            $syncStatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
            $actionLabel = if ($direction -eq 'upload') { '上传' } else { '下载' }
            $syncStatusText.Text = "${actionLabel}失败：$($_.Exception.Message)"
            $backupInfo = Get-BackupStorageInfo
            $backupStorageText.Text = "永久备份：$($backupInfo.BackupCount) 份，共 $($backupInfo.DisplaySize)。如占用过大，请手动清理 backup 文件夹。"
        }
        finally {
            $uploadSyncButton.IsEnabled = $true
            $downloadSyncButton.IsEnabled = $true
            $browseSyncDirectoryButton.IsEnabled = $true
        }
    }
    $uploadSyncButton.Add_Click({ & $runSyncAction 'upload' })
    $downloadSyncButton.Add_Click({ & $runSyncAction 'download' })

    $runBulkClear = {
        param([bool]$completed, [string]$category)
        $count = @($script:Tasks | Where-Object { [bool]$_.completed -eq $completed }).Count
        if ($count -eq 0) {
            $validationText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF707580')
            $validationText.Text = "当前没有${category}待办。"
            return
        }
        $answer = [Windows.MessageBox]::Show(
            $settingsWindow,
            "将先备份，再从主列表清除 $count 项${category}待办。是否继续？",
            "清除${category}待办",
            [Windows.MessageBoxButton]::YesNo,
            [Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }

        try {
            $result = Backup-AndRemoveTasks $completed
            $validationText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF438563')
            $validationText.Text = "已备份并清除 $($result.Count) 项。备份位置：$($result.Path)"
            $backupInfo = Get-BackupStorageInfo
            $backupStorageText.Text = "永久备份：$($backupInfo.BackupCount) 份，共 $($backupInfo.DisplaySize)。如占用过大，请手动清理 backup 文件夹。"
        }
        catch {
            $validationText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
            $validationText.Text = "备份失败，未清除待办：$($_.Exception.Message)"
        }
    }
    $clearCompletedButton.Add_Click({ & $runBulkClear $true '已完成' })
    $clearIncompleteButton.Add_Click({ & $runBulkClear $false '未完成' })

    $saveSettingsButton.Add_Click({
        $validationText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
        $requestedTitle = $displayTitleText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($requestedTitle)) {
            $validationText.Text = '名称不能为空。'
            return
        }
        $value = 0
        if (-not [int]::TryParse($urgentDaysText.Text.Trim(), [ref]$value) -or $value -lt 0 -or $value -gt 365) {
            $validationText.Text = '请输入 0 到 365 之间的整数。'
            return
        }
        $requestedSyncDirectory = $syncDirectoryText.Text.Trim()
        try {
            $normalizedSyncDirectory = if ([string]::IsNullOrWhiteSpace($requestedSyncDirectory)) { Get-DefaultSyncDirectory } else { [IO.Path]::GetFullPath($requestedSyncDirectory) }
        }
        catch {
            $validationText.Text = "同步目录无效：$($_.Exception.Message)"
            return
        }
        $requestedAutoStart = [bool]$autoStartCheckBox.IsChecked
        try {
            Set-AutoStartEnabled $requestedAutoStart
        }
        catch {
            $validationText.Text = "无法修改开机自启动：$($_.Exception.Message)"
            return
        }

        $script:UrgentDays = $value
        $script:CardActionMode = if ([bool]$separateModeRadio.IsChecked) { 'separate' } else { 'unified' }
        $script:WindowLayerMode = if ([bool]$alwaysBottomRadio.IsChecked) { 'alwaysBottom' } else { 'desktop' }
        $script:AutoStartEnabled = $requestedAutoStart
        $script:DisplayTitle = $requestedTitle
        $script:SyncDirectory = $normalizedSyncDirectory
        $titleText.Text = $script:DisplayTitle
        if ($null -ne $script:TrayIcon) { $script:TrayIcon.Text = "$($script:DisplayTitle) · 桌面待办 v$script:Version" }
        Save-State
        Refresh-Tasks
        Apply-WindowLayerMode
        $settingsWindow.DialogResult = $true
    })
    $cancelSettingsButton.Add_Click({ $settingsWindow.Close() })
    [void]$settingsWindow.ShowDialog()
    Apply-WindowLayerMode
}

function ConvertTo-MarkdownCell {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace('\', '\\').Replace('|', '\|').Replace("`r`n", '<br>').Replace("`n", '<br>')
}

function Show-ExportDialog {
    [xml]$exportXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="导出 Markdown" Width="420" Height="390"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        WindowStyle="ToolWindow" ShowInTaskbar="False"
        Background="#FFF9FAFC" FontFamily="Microsoft YaHei UI">
    <Grid Margin="24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="导出 Markdown 待办记录" FontSize="19" FontWeight="SemiBold" Foreground="#FF20242C"/>

        <StackPanel Grid.Row="1" Margin="0,18,0,0">
            <TextBlock Text="导出内容" FontSize="12" FontWeight="SemiBold" Foreground="#FF555A64" Margin="0,0,0,8"/>
            <CheckBox x:Name="CompletedCheckBox" Content="已完成事项（按完成时间筛选）" IsChecked="True" Margin="0,0,0,8"/>
            <CheckBox x:Name="PlannedCheckBox" Content="未来计划（按 DDL 筛选，仅未完成）"/>
        </StackPanel>

        <TextBlock Grid.Row="2" Text="时间范围" FontSize="12" FontWeight="SemiBold" Foreground="#FF555A64" Margin="0,18,0,8"/>
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="36"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <DatePicker x:Name="StartDatePicker" Height="30" SelectedDateFormat="Short"/>
            <TextBlock Grid.Column="1" Text="至" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#FF707580"/>
            <DatePicker x:Name="EndDatePicker" Grid.Column="2" Height="30" SelectedDateFormat="Short"/>
        </Grid>

        <TextBlock x:Name="ExportHint" Grid.Row="4" Margin="0,12,0,0" FontSize="11" Foreground="#FF7D828C"
                   Text="日期均可留空：无开始日期表示从最早记录开始，无结束日期表示不限制未来时间。" TextWrapping="Wrap"/>
        <TextBlock x:Name="ExportValidation" Grid.Row="5" Margin="0,10,0,0" FontSize="11" Foreground="#FFE05252" TextWrapping="Wrap"/>

        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelExportButton" Content="取消" Width="76" Height="34" Margin="0,0,10,0"/>
            <Button x:Name="ConfirmExportButton" Content="导出 Markdown" Width="126" Height="34"
                    Background="#FF6C5CE7" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $exportReader = New-Object System.Xml.XmlNodeReader $exportXaml
    $exportWindow = [Windows.Markup.XamlReader]::Load($exportReader)
    Disable-ButtonFocusVisuals $exportWindow
    $exportWindow.Owner = $window
    $completedCheckBox = $exportWindow.FindName('CompletedCheckBox')
    $plannedCheckBox = $exportWindow.FindName('PlannedCheckBox')
    $startDatePicker = $exportWindow.FindName('StartDatePicker')
    $endDatePicker = $exportWindow.FindName('EndDatePicker')
    $exportHint = $exportWindow.FindName('ExportHint')
    $exportValidation = $exportWindow.FindName('ExportValidation')
    $confirmExportButton = $exportWindow.FindName('ConfirmExportButton')
    $cancelExportButton = $exportWindow.FindName('CancelExportButton')

    $completedCheckBox.IsChecked = $script:ExportType -ne 'planned'
    $plannedCheckBox.IsChecked = $script:ExportType -in @('planned', 'both')
    $startDatePicker.SelectedDate = if ([string]::IsNullOrWhiteSpace([string]$script:ExportStartDate)) { $null } else { [datetime]$script:ExportStartDate }
    $endDatePicker.SelectedDate = if ([string]::IsNullOrWhiteSpace([string]$script:ExportEndDate)) { $null } else { [datetime]$script:ExportEndDate }
    $updateExportSelection = {
        $includeCompleted = [bool]$completedCheckBox.IsChecked
        $includePlanned = [bool]$plannedCheckBox.IsChecked
        $script:ExportType = if ($includeCompleted -and $includePlanned) { 'both' } elseif ($includePlanned) { 'planned' } else { 'completed' }
        $exportHint.Text = if ($includeCompleted -and $includePlanned) {
            '将导出两类内容：已完成事项按“完成日期”筛选，未来计划按“DDL 日期”筛选。上方起止日期同时用于这两种筛选，也可以留空。'
        } elseif ($includePlanned) {
            '按 DDL 导出尚未完成的计划；开始和结束日期均可留空。'
        } else {
            '按完成时间导出；开始和结束日期均可留空。'
        }
        Save-UiStateIfReady
    }
    & $updateExportSelection
    $completedCheckBox.Add_Click($updateExportSelection)
    $plannedCheckBox.Add_Click($updateExportSelection)
    $startDatePicker.Add_SelectedDateChanged({
        $script:ExportStartDate = if ($null -eq $startDatePicker.SelectedDate) { $null } else { ([datetime]$startDatePicker.SelectedDate).ToString('yyyy-MM-dd') }
        Save-UiStateIfReady
    })
    $endDatePicker.Add_SelectedDateChanged({
        $script:ExportEndDate = if ($null -eq $endDatePicker.SelectedDate) { $null } else { ([datetime]$endDatePicker.SelectedDate).ToString('yyyy-MM-dd') }
        Save-UiStateIfReady
    })
    $cancelExportButton.Add_Click({ $exportWindow.Close() })

    $confirmExportButton.Add_Click({
        $exportValidation.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
        $startDate = $startDatePicker.SelectedDate
        $endDate = $endDatePicker.SelectedDate
        if ($null -ne $startDate) { $startDate = ([datetime]$startDate).Date }
        if ($null -ne $endDate) { $endDate = ([datetime]$endDate).Date }
        if ($null -ne $startDate -and $null -ne $endDate -and $startDate -gt $endDate) {
            $exportValidation.Text = '开始日期不能晚于结束日期。'
            return
        }

        $includeCompleted = [bool]$completedCheckBox.IsChecked
        $includePlanned = [bool]$plannedCheckBox.IsChecked
        if (-not $includeCompleted -and -not $includePlanned) {
            $exportValidation.Text = '请至少选择一种导出内容。'
            return
        }

        $completedTasks = @()
        $plannedTasks = @()
        if ($includeCompleted) {
            $completedTasks = @($script:Tasks | Where-Object {
                $_.completed -and
                -not [string]::IsNullOrWhiteSpace([string]$_.completedAt) -and
                ($null -eq $startDate -or ([datetime]$_.completedAt).Date -ge $startDate) -and
                ($null -eq $endDate -or ([datetime]$_.completedAt).Date -le $endDate)
            } | Sort-Object { [datetime]$_.completedAt })
        }
        if ($includePlanned) {
            $plannedTasks = @($script:Tasks | Where-Object {
                -not $_.completed -and
                -not [string]::IsNullOrWhiteSpace([string]$_.dueDate) -and
                ($null -eq $startDate -or ([datetime]$_.dueDate).Date -ge $startDate) -and
                ($null -eq $endDate -or ([datetime]$_.dueDate).Date -le $endDate)
            } | Sort-Object { [datetime]$_.dueDate })
        }
        $filteredTasks = @($completedTasks) + @($plannedTasks)

        $typeLabel = if ($includeCompleted -and $includePlanned) { '已完成与未来计划' } elseif ($includeCompleted) { '已完成' } else { '未来计划' }
        $startLabel = if ($null -eq $startDate) { '最早记录' } else { $startDate.ToString('yyyy-MM-dd') }
        $endLabel = if ($null -eq $endDate) { '不限' } else { $endDate.ToString('yyyy-MM-dd') }
        $outputDirectory = Join-Path $PSScriptRoot 'output'
        $outputName = "桌面待办_$typeLabel`_$((Get-Date).ToString('yyyyMMdd-HHmmss')).md"
        $outputPath = Join-Path $outputDirectory $outputName
        $exportValidation.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF6C5CE7')
        $exportValidation.Text = '正在生成 Markdown…'
        $confirmExportButton.IsEnabled = $false
        try {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
            $markdown = [Collections.Generic.List[string]]::new()
            $markdown.Add("# 桌面待办 · $typeLabel")
            $markdown.Add('')
            $markdown.Add("- 导出时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
            $markdown.Add("- 时间范围：$startLabel 至 $endLabel")
            $markdown.Add("- 事项数量：$($filteredTasks.Count)")
            $markdown.Add('')
            $markdown.Add('| 待办事项 | 状态 | DDL | 前置任务 | 创建时间 | 完成时间 |')
            $markdown.Add('|---|---|---|---|---|---|')
            foreach ($task in $filteredTasks) {
                $taskText = ConvertTo-MarkdownCell $task.text
                $statusText = if ($task.completed) { '已完成' } elseif (Test-TaskBlocked $task) { '等待中' } else { '计划中' }
                $dueText = if ([string]::IsNullOrWhiteSpace([string]$task.dueDate)) { '' } else { ([datetime]$task.dueDate).ToString('yyyy-MM-dd') }
                $dependencyTask = Get-TaskById ([string]$task.prerequisiteId)
                $dependencyText = if ($null -eq $dependencyTask) { '' } else { ConvertTo-MarkdownCell $dependencyTask.text }
                $createdText = if ([string]::IsNullOrWhiteSpace([string]$task.createdAt)) { '' } else { ([datetime]$task.createdAt).ToString('yyyy-MM-dd HH:mm') }
                $completedText = if ([string]::IsNullOrWhiteSpace([string]$task.completedAt)) { '' } else { ([datetime]$task.completedAt).ToString('yyyy-MM-dd HH:mm') }
                $markdown.Add("| $taskText | $statusText | $dueText | $dependencyText | $createdText | $completedText |")
            }
            if ($filteredTasks.Count -eq 0) {
                $markdown.Add('')
                $markdown.Add('_所选条件下没有符合的待办事项。_')
            }
            Set-Content -LiteralPath $outputPath -Value $markdown -Encoding UTF8
            $exportValidation.Text = "导出成功：$($filteredTasks.Count) 项"
            [void][Windows.MessageBox]::Show(
                $exportWindow,
                "已导出 $($filteredTasks.Count) 项到：`n$outputPath",
                '导出完成',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Information
            )
        }
        catch {
            $exportValidation.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
            $exportValidation.Text = $_.Exception.Message
        }
        finally {
            $confirmExportButton.IsEnabled = $true
        }
    })

    [void]$exportWindow.ShowDialog()
    Apply-WindowLayerMode
}

function Refresh-Tasks {
    $taskList.Children.Clear()
    $remaining = @($script:Tasks | Where-Object { -not $_.completed }).Count
    $countText.Text = "$remaining 项待办"

    $visible = @($script:Tasks | Where-Object {
        ($script:CurrentFilter -eq 'all') -or
        ($script:CurrentFilter -eq 'active' -and -not $_.completed) -or
        ($script:CurrentFilter -eq 'done' -and $_.completed)
    } | Sort-Object `
        @{ Expression = {
            if ($_.completed) { return 3 }
            if (Test-TaskBlocked $_) { return 2 }
            if (-not [string]::IsNullOrWhiteSpace([string]$_.dueDate)) {
                $daysLeft = ([datetime]$_.dueDate).Date.Subtract((Get-Date).Date).Days
                if ($daysLeft -le $script:UrgentDays) { return 0 }
            }
            return 1
        } }, `
        @{ Expression = {
            if ([string]::IsNullOrWhiteSpace([string]$_.dueDate)) { return [datetime]::MaxValue }
            return ([datetime]$_.dueDate).Date
        } }, `
        @{ Expression = { [double]$_.sortOrder } }, `
        @{ Expression = { [datetime]$_.createdAt }; Descending = $true })

    if ($visible.Count -eq 0) {
        $empty = [Windows.Controls.TextBlock]::new()
        $empty.Text = if ($script:CurrentFilter -eq 'done') { '还没有完成的任务' } else { '今天的任务都完成啦  ✓' }
        $empty.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF9A9FAA')
        $empty.FontSize = 13
        $empty.HorizontalAlignment = 'Center'
        $empty.Margin = '0,54,0,0'
        [void]$taskList.Children.Add($empty)
        Set-FilterAppearance
        return
    }

    foreach ($task in $visible) {
        $isBlocked = Test-TaskBlocked $task
        $prerequisiteTask = Get-TaskById ([string]$task.prerequisiteId)
        $taskId = [string]$task.id
        $detailPath = Resolve-TaskDetailPath $taskId
        $hasDetail = $null -ne $detailPath -and (Test-Path -LiteralPath $detailPath)
        $card = [Windows.Controls.Border]::new()
        $card.Background = [Windows.Media.Brushes]::White
        $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#10000000')
        $card.BorderThickness = '1'
        $card.CornerRadius = '13'
        $card.Margin = '0,0,0,8'
        $card.Padding = '12,10'
        $transformGroup = [Windows.Media.TransformGroup]::new()
        [void]$transformGroup.Children.Add([Windows.Media.ScaleTransform]::new(1, 1))
        [void]$transformGroup.Children.Add([Windows.Media.TranslateTransform]::new(0, 0))
        $card.RenderTransform = $transformGroup
        $card.RenderTransformOrigin = [Windows.Point]::new(0.5, 0.5)
        if ($isBlocked) {
            $card.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFF0F1F3')
            $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFD8DADE')
        }

        $grid = [Windows.Controls.Grid]::new()
        [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $grid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(34)
        [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $grid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
        $grid.ColumnDefinitions[2].Width = [Windows.GridLength]::new(34)
        if ($script:CardActionMode -eq 'separate') {
            [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            $grid.ColumnDefinitions[3].Width = [Windows.GridLength]::new(34)
        }
        if ($hasDetail) {
            [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
            $grid.ColumnDefinitions[$grid.ColumnDefinitions.Count - 1].Width = [Windows.GridLength]::new(34)
        }

        $check = [Windows.Controls.CheckBox]::new()
        $check.IsChecked = [bool]$task.completed
        $check.VerticalAlignment = 'Center'
        $check.Cursor = 'Hand'
        $check.IsEnabled = -not $isBlocked
        if ($isBlocked) { $check.ToolTip = '请先完成前置任务' }
        [Windows.Controls.Grid]::SetColumn($check, 0)

        $label = [Windows.Controls.TextBlock]::new()
        $label.Text = [string]$task.text
        $label.TextWrapping = 'Wrap'
        $label.VerticalAlignment = 'Center'
        $label.FontSize = 13
        $label.Margin = '0,1,8,1'
        if ($task.completed) {
            $label.TextDecorations = [Windows.TextDecorations]::Strikethrough
            $label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFA1A5AE')
        } elseif ($isBlocked) {
            $label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF858A93')
        } else {
            $label.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF30343B')
        }

        $labelHost = [Windows.Controls.StackPanel]::new()
        $labelHost.Margin = '0,0,8,0'
        [void]$labelHost.Children.Add($label)
        if (-not [string]::IsNullOrWhiteSpace([string]$task.dueDate)) {
            $due = ([datetime]$task.dueDate).Date
            $daysLeft = $due.Subtract((Get-Date).Date).Days
            $dueLabel = [Windows.Controls.TextBlock]::new()
            $dueLabel.FontSize = 10
            $dueLabel.Margin = '0,4,0,0'
            if ($task.completed) {
                $dueLabel.Text = "DDL  $($due.ToString('M月d日'))"
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFAFB2B9')
            } elseif ($isBlocked) {
                $dueLabel.Text = "DDL  $($due.ToString('M月d日'))"
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFA1A5AE')
            } elseif ($daysLeft -lt 0) {
                $dueLabel.Text = "DDL  已逾期 $([Math]::Abs($daysLeft)) 天"
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
                $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#55E05252')
            } elseif ($daysLeft -eq 0) {
                $dueLabel.Text = 'DDL  今天截止'
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE05252')
                $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#55E05252')
            } elseif ($daysLeft -le $script:UrgentDays) {
                $dueLabel.Text = "DDL  还剩 $daysLeft 天 · $($due.ToString('M月d日'))"
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFE0823D')
                $card.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#55E0823D')
            } else {
                $dueLabel.Text = "DDL  $($due.ToString('M月d日'))"
                $dueLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF90959F')
            }
            [void]$labelHost.Children.Add($dueLabel)
        }
        if ($null -ne $prerequisiteTask) {
            $dependencyLabel = [Windows.Controls.TextBlock]::new()
            $dependencyLabel.FontSize = 10
            $dependencyLabel.Margin = '0,4,0,0'
            $dependencyLabel.TextWrapping = 'Wrap'
            if ($isBlocked) {
                $dependencyLabel.Text = "等待前置任务：$([string]$prerequisiteTask.text)"
                $dependencyLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF777C85')
            } elseif ($task.completed) {
                $dependencyLabel.Text = "前置任务：$([string]$prerequisiteTask.text)"
                $dependencyLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFA1A5AE')
            } else {
                $dependencyLabel.Text = "前置任务已完成：$([string]$prerequisiteTask.text)  ✓"
                $dependencyLabel.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF6E9B80')
            }
            [void]$labelHost.Children.Add($dependencyLabel)
        }
        [Windows.Controls.Grid]::SetColumn($labelHost, 1)

        $manage = $null
        $editPrerequisite = $null
        $delete = $null
        $detailButton = $null
        if ($script:CardActionMode -eq 'separate') {
            $editPrerequisite = [Windows.Controls.Button]::new()
            $editPrerequisite.Content = '↳'
            $editPrerequisite.FontSize = 16
            $editPrerequisite.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF8B909B')
            $editPrerequisite.Background = [Windows.Media.Brushes]::Transparent
            $editPrerequisite.BorderThickness = '0'
            $editPrerequisite.Cursor = 'Hand'
            $editPrerequisite.ToolTip = '修改或取消前置任务'
            [Windows.Controls.Grid]::SetColumn($editPrerequisite, 2)

            $delete = [Windows.Controls.Button]::new()
            $delete.Content = '×'
            $delete.FontSize = 17
            $delete.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFB0B3BB')
            $delete.Background = [Windows.Media.Brushes]::Transparent
            $delete.BorderThickness = '0'
            $delete.Cursor = 'Hand'
            $delete.ToolTip = '删除待办'
            [Windows.Controls.Grid]::SetColumn($delete, 3)
        } else {
            $manage = [Windows.Controls.Button]::new()
            $manage.Content = '⋯'
            $manage.FontSize = 18
            $manage.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF8B909B')
            $manage.Background = [Windows.Media.Brushes]::Transparent
            $manage.BorderThickness = '0'
            $manage.Cursor = 'Hand'
            $manage.ToolTip = '管理待办'
            [Windows.Controls.Grid]::SetColumn($manage, $(if ($hasDetail) { 3 } else { 2 }))
        }

        if ($hasDetail) {
            $detailButton = [Windows.Controls.Button]::new()
            $detailButton.Content = '文'
            $detailButton.FontSize = 12
            $detailButton.FontWeight = [Windows.FontWeights]::SemiBold
            $detailButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF527CA8')
            $detailButton.Background = [Windows.Media.Brushes]::Transparent
            $detailButton.BorderThickness = '0'
            $detailButton.Cursor = 'Hand'
            $detailButton.ToolTip = '打开详细说明'
            [Windows.Controls.Grid]::SetColumn($detailButton, $(if ($script:CardActionMode -eq 'separate') { 4 } else { 2 }))
        }

        $check.Tag = $taskId
        if ($null -ne $manage) { $manage.Tag = $taskId }
        if ($null -ne $editPrerequisite) { $editPrerequisite.Tag = $taskId }
        if ($null -ne $delete) { $delete.Tag = $taskId }
        if ($null -ne $detailButton) { $detailButton.Tag = $taskId }
        $card.Tag = $taskId
        if (-not $task.completed) {
            $labelHost.Tag = $taskId
            $labelHost.DataContext = $card
            $labelHost.Cursor = 'SizeAll'
            $labelHost.ToolTip = '拖动可调整同状态、同 DDL 的待办顺序'
            $labelHost.Add_MouseMove({
                param($sender, $eventArgs)
                if ($eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) {
                    $sourceCard = $sender.DataContext
                    Animate-CardOpacity $sourceCard 0.48 110
                    Animate-CardScale $sourceCard 0.985 110
                    try {
                        [void][Windows.DragDrop]::DoDragDrop($sender, [string]$sender.Tag, [Windows.DragDropEffects]::Move)
                    }
                    finally {
                        Reset-TaskDropGapAnimation
                        if ($null -ne $script:DropTargetCard) {
                            Animate-CardScale $script:DropTargetCard 1 100
                            $script:DropTargetCard = $null
                        }
                        Animate-CardOpacity $sourceCard 1 150
                        Animate-CardScale $sourceCard 1 150
                    }
                }
            })
        }
        $check.Add_Click({
            param($sender, $eventArgs)
            $clickedTaskId = [string]$sender.Tag
            $target = $script:Tasks | Where-Object { $_.id -eq $clickedTaskId } | Select-Object -First 1
            if ($null -ne $target) {
                $target.completed = [bool]$sender.IsChecked
                $target.completedAt = if ($target.completed) { (Get-Date).ToString('o') } else { $null }
                Set-TaskModified $target $null
            }
            Save-State
            Refresh-Tasks
        })
        if ($null -ne $manage) {
            $manage.Add_Click({
                param($sender, $eventArgs)
                Show-TaskActions ([string]$sender.Tag)
            })
        } else {
            $editPrerequisite.Add_Click({
                param($sender, $eventArgs)
                Show-PrerequisiteEditor ([string]$sender.Tag)
            })
            $delete.Add_Click({
                param($sender, $eventArgs)
                Remove-TaskById ([string]$sender.Tag)
            })
        }
        if ($null -ne $detailButton) {
            $detailButton.Add_Click({
                param($sender, $eventArgs)
                Open-TaskDetail ([string]$sender.Tag)
            })
        }

        [void]$grid.Children.Add($check)
        [void]$grid.Children.Add($labelHost)
        if ($null -ne $manage) {
            [void]$grid.Children.Add($manage)
        } else {
            [void]$grid.Children.Add($editPrerequisite)
            [void]$grid.Children.Add($delete)
        }
        if ($null -ne $detailButton) { [void]$grid.Children.Add($detailButton) }
        $card.Child = $grid
        [void]$taskList.Children.Add($card)
        Animate-CardEntry $card
    }
    Set-FilterAppearance
    Update-PrerequisitePicker
}

function Add-NewTask {
    $text = $newTaskText.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $selectedDueDate = $dueDatePicker.SelectedDate
    if ([bool]$useDueDateCheckBox.IsChecked -and $null -eq $selectedDueDate) {
        [void][Windows.MessageBox]::Show(
            $window,
            '已启用 DDL，请先选择截止日期。',
            '请选择 DDL',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Information
        )
        $dueDatePicker.Focus() | Out-Null
        return
    }
    $selectedPrerequisiteId = $null
    if ([bool]$usePrerequisiteCheckBox.IsChecked) {
        if ($null -eq $prerequisiteComboBox.SelectedItem) {
            [void][Windows.MessageBox]::Show(
                $window,
                '已启用前置任务，请先选择一项任务。',
                '请选择前置任务',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Information
            )
            $prerequisiteComboBox.Focus() | Out-Null
            return
        }
        $selectedPrerequisiteId = [string]$prerequisiteComboBox.SelectedItem.Tag
    }
    $nextSortOrder = if ($script:Tasks.Count -eq 0) { 0 } else { [double](($script:Tasks | Measure-Object -Property sortOrder -Maximum).Maximum) + 1 }
    $newTask = [PSCustomObject]@{
        id = (New-TaskId)
        text = $text
        completed = $false
        completedAt = $null
        dueDate = if (-not [bool]$useDueDateCheckBox.IsChecked -or $null -eq $selectedDueDate) { $null } else { ([datetime]$selectedDueDate).ToString('yyyy-MM-dd') }
        prerequisiteId = $selectedPrerequisiteId
        sortOrder = $nextSortOrder
        createdAt = (Get-Date).ToString('o')
        updatedAt = (Get-UtcTimestamp)
        updatedBy = $script:DeviceId
        detailUpdatedAt = $null
        detailUpdatedBy = $null
        detailDeleted = $false
    }
    $script:Tasks = @($newTask) + @($script:Tasks)
    $newTaskText.Clear()
    $script:CurrentFilter = 'all'
    Save-State
    Refresh-Tasks
    $newTaskText.Focus() | Out-Null
}

$state = Load-State
$script:Tasks = @($state.tasks)
$script:DeletedTasks = @($state.deletedTasks)
$script:DeviceId = if ($null -ne $state.settings -and -not [string]::IsNullOrWhiteSpace([string]$state.settings.deviceId)) { [string]$state.settings.deviceId } else { [Guid]::NewGuid().ToString('N') }
$savedSyncDirectory = if ($null -eq $state.settings) { $null } else { [string]$state.settings.syncDirectory }
$script:SyncDirectory = if ([string]::IsNullOrWhiteSpace($savedSyncDirectory)) { Get-DefaultSyncDirectory } else { $savedSyncDirectory }
$script:LastSyncAt = if ($null -eq $state.settings -or [string]::IsNullOrWhiteSpace([string]$state.settings.lastSyncAt)) { $null } else { [string]$state.settings.lastSyncAt }
$script:IsLocked = if ($null -eq $state.locked) { $false } else { [bool]$state.locked }
$script:UrgentDays = if ($null -eq $state.settings -or $null -eq $state.settings.urgentDays) { 3 } else { [Math]::Max(0, [Math]::Min(365, [int]$state.settings.urgentDays)) }
$script:CardActionMode = if ($null -ne $state.settings -and [string]$state.settings.cardActionMode -eq 'separate') { 'separate' } else { 'unified' }
$script:WindowLayerMode = if ($null -ne $state.settings -and [string]$state.settings.windowLayerMode -eq 'alwaysBottom') { 'alwaysBottom' } else { 'desktop' }
$script:AutoStartEnabled = $null -ne $state.settings -and [bool]$state.settings.autoStartEnabled
$savedDisplayTitle = if ($null -eq $state.settings) { '' } else { [string]$state.settings.displayTitle }
$script:DisplayTitle = if ([string]::IsNullOrWhiteSpace($savedDisplayTitle)) { '我的一天' } else { $savedDisplayTitle.Trim() }
if ($script:DisplayTitle.Length -gt 30) { $script:DisplayTitle = $script:DisplayTitle.Substring(0, 30) }
$titleText.Text = $script:DisplayTitle
if ($script:AutoStartEnabled) {
    try { Set-AutoStartEnabled $true } catch {}
}
$savedUi = $state.ui
$script:CurrentFilter = if ($null -ne $savedUi -and [string]$savedUi.currentFilter -in @('all', 'active', 'done')) { [string]$savedUi.currentFilter } else { 'all' }
$script:ExportType = if ($null -ne $savedUi -and [string]$savedUi.exportType -in @('planned', 'both')) { [string]$savedUi.exportType } else { 'completed' }
$script:ExportStartDate = if ($null -eq $savedUi) { $null } else { [string]$savedUi.exportStartDate }
$script:ExportEndDate = if ($null -eq $savedUi) { $null } else { [string]$savedUi.exportEndDate }
$savedHeight = if ($null -eq $state.height) { 610 } else { [double]$state.height }
$window.Height = [Math]::Max($window.MinHeight, [Math]::Min([Windows.SystemParameters]::VirtualScreenHeight - 40, $savedHeight))
if ($script:IsLocked) {
    $lockButton.Content = '◆'
    $lockButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF6C5CE7')
    $lockButton.ToolTip = '取消固定组件位置'
    $footerText.Text = "桌面插件 v$script:Version · 位置已锁定"
} else {
    $footerText.Text = "桌面插件 v$script:Version · 拖动顶部移动"
}
if ($null -ne $state.left -and $null -ne $state.top) {
    $window.WindowStartupLocation = 'Manual'
    $minimumLeft = [Windows.SystemParameters]::VirtualScreenLeft
    $minimumTop = [Windows.SystemParameters]::VirtualScreenTop
    $maximumLeft = $minimumLeft + [Windows.SystemParameters]::VirtualScreenWidth - $window.Width
    $maximumTop = $minimumTop + [Windows.SystemParameters]::VirtualScreenHeight - $window.Height
    $window.Left = [Math]::Min($maximumLeft, [Math]::Max($minimumLeft, [double]$state.left))
    $window.Top = [Math]::Min($maximumTop, [Math]::Max($minimumTop, [double]$state.top))
} else {
    $window.WindowStartupLocation = 'CenterScreen'
}

$addButton.Add_Click({ Add-NewTask })
$useDueDateCheckBox.Add_Checked({
    $dueDatePicker.IsEnabled = $true
    Save-UiStateIfReady
})
$useDueDateCheckBox.Add_Unchecked({
    $dueDatePicker.SelectedDate = $null
    $dueDatePicker.IsEnabled = $false
    Save-UiStateIfReady
})
$dueDatePicker.Add_SelectedDateChanged({ Save-UiStateIfReady })
$usePrerequisiteCheckBox.Add_Checked({
    Update-PrerequisitePicker
    $prerequisiteComboBox.IsEnabled = [bool]$usePrerequisiteCheckBox.IsChecked -and $prerequisiteComboBox.Items.Count -gt 0
    Save-UiStateIfReady
})
$usePrerequisiteCheckBox.Add_Unchecked({
    $prerequisiteComboBox.SelectedIndex = -1
    $prerequisiteComboBox.IsEnabled = $false
    Save-UiStateIfReady
})
$prerequisiteComboBox.Add_SelectionChanged({ Save-UiStateIfReady })
$newTaskText.Add_KeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Enter) {
        Add-NewTask
        $_.Handled = $true
    }
})
$settingsButton.Add_Click({ Show-Settings })
$exportButton.Add_Click({ Show-ExportDialog })
$closeButton.Add_Click({ $window.Close() })
$lockButton.Add_Click({
    $script:IsLocked = -not $script:IsLocked
    if ($script:IsLocked) {
        $lockButton.Content = '◆'
        $lockButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF6C5CE7')
        $lockButton.ToolTip = '取消固定组件位置'
        $footerText.Text = "桌面插件 v$script:Version · 位置已锁定"
    } else {
        $lockButton.Content = '◇'
        $lockButton.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF8B909B')
        $lockButton.ToolTip = '固定组件位置'
        $footerText.Text = "桌面插件 v$script:Version · 拖动顶部移动"
    }
    Save-State
})
$dragArea.Add_MouseLeftButtonDown({
    if (-not $script:IsLocked -and $_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        $window.DragMove()
        Save-State
    }
})
$allFilter.Add_Click({ $script:CurrentFilter = 'all'; Refresh-Tasks; Save-State })
$activeFilter.Add_Click({ $script:CurrentFilter = 'active'; Refresh-Tasks; Save-State })
$doneFilter.Add_Click({ $script:CurrentFilter = 'done'; Refresh-Tasks; Save-State })
$taskList.AllowDrop = $true
$taskList.Add_DragOver({
    param($sender, $eventArgs)
    $sourceId = [string]$eventArgs.Data.GetData([string])
    $pointer = $eventArgs.GetPosition($taskList)
    $dropLocation = Get-TaskDropLocation $sourceId $pointer.Y
    if ($null -eq $dropLocation) {
        $eventArgs.Effects = [Windows.DragDropEffects]::None
        Reset-TaskDropGapAnimation
        if ($null -ne $script:DropTargetCard) {
            Animate-CardScale $script:DropTargetCard 1 100
            $script:DropTargetCard = $null
        }
    } else {
        $eventArgs.Effects = [Windows.DragDropEffects]::Move
        Update-TaskDropGapAnimation $sourceId $dropLocation
        if ($script:DropTargetCard -ne $dropLocation.Card) {
            if ($null -ne $script:DropTargetCard) { Animate-CardScale $script:DropTargetCard 1 100 }
            $script:DropTargetCard = $dropLocation.Card
            if ([string]$dropLocation.TargetId -ne $sourceId) { Animate-CardScale $script:DropTargetCard 1.018 100 }
        }
    }
    $eventArgs.Handled = $true
})
$taskList.Add_DragLeave({
    param($sender, $eventArgs)
    if ($null -ne $script:DropTargetCard) {
        Animate-CardScale $script:DropTargetCard 1 100
        $script:DropTargetCard = $null
    }
    Reset-TaskDropGapAnimation
})
$taskList.Add_Drop({
    param($sender, $eventArgs)
    $sourceId = [string]$eventArgs.Data.GetData([string])
    $pointer = $eventArgs.GetPosition($taskList)
    $dropLocation = Get-TaskDropLocation $sourceId $pointer.Y
    if ($null -ne $script:DropTargetCard) { Animate-CardScale $script:DropTargetCard 1 80 }
    $script:DropTargetCard = $null
    Reset-TaskDropGapAnimation
    if ($null -ne $dropLocation) {
        Move-TaskWithinLevel $sourceId $dropLocation.TargetId ([bool]$dropLocation.PlaceAfter)
        $eventArgs.Effects = [Windows.DragDropEffects]::Move
    } else {
        $eventArgs.Effects = [Windows.DragDropEffects]::None
    }
    $eventArgs.Handled = $true
})

$script:IsRestoringUiState = $true
try {
    $useDueDateCheckBox.IsChecked = $null -ne $savedUi -and [bool]$savedUi.useDueDate
    $dueDatePicker.IsEnabled = [bool]$useDueDateCheckBox.IsChecked
    $dueDatePicker.SelectedDate = if ($null -eq $savedUi -or [string]::IsNullOrWhiteSpace([string]$savedUi.dueDate)) { $null } else { [datetime]$savedUi.dueDate }
    Refresh-Tasks
    $usePrerequisiteCheckBox.IsChecked = $null -ne $savedUi -and [bool]$savedUi.usePrerequisite
    if ($usePrerequisiteCheckBox.IsChecked) {
        Update-PrerequisitePicker
        $savedPrerequisiteId = [string]$savedUi.prerequisiteId
        foreach ($item in $prerequisiteComboBox.Items) {
            if ([string]$item.Tag -eq $savedPrerequisiteId) {
                $prerequisiteComboBox.SelectedItem = $item
                break
            }
        }
    }
    $prerequisiteComboBox.IsEnabled = [bool]$usePrerequisiteCheckBox.IsChecked -and $prerequisiteComboBox.Items.Count -gt 0
}
finally {
    $script:IsRestoringUiState = $false
}
$window.Add_SourceInitialized({
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $script:WidgetHandle = $helper.Handle
    $script:DesktopHandle = [DesktopWidgetNative]::FindDesktopHost()

    if ($script:DesktopHandle -ne [IntPtr]::Zero) {
        # Keep the widget as a top-level WPF window for reliable transparent
        # rendering, then apply either ordinary z-order or desktop ownership.
        Apply-WindowLayerMode
    }
})
$window.Add_Activated({
    # Restore the selected behavior after activation: ordinary z-order in
    # window mode, or the desktop layer in wallpaper mode.
    Apply-WindowLayerMode
})
$window.Add_ContentRendered({
    $newTaskText.Focus() | Out-Null
    Apply-WindowLayerMode
    Ensure-WidgetOnVisibleScreen
    Initialize-TrayIcon
})
$window.Add_Closing({
    if ($null -ne $script:BottomEnforcementTimer) { $script:BottomEnforcementTimer.Stop() }
    try {
        Save-State
    }
    finally {
        if ($null -ne $script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
            $script:TrayIcon = $null
        }
        if ($null -ne $script:AppIcon) {
            $script:AppIcon.Dispose()
            $script:AppIcon = $null
        }
        if ($null -ne $script:TrayMenu) {
            $script:TrayMenu.Dispose()
            $script:TrayMenu = $null
        }
        if ($null -ne $script:InstanceMutex) {
            try { $script:InstanceMutex.ReleaseMutex() } catch {}
            $script:InstanceMutex.Dispose()
        }
    }
})
[void]$window.ShowDialog()

