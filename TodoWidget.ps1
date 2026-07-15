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
$script:IconPath = Join-Path $PSScriptRoot 'assets\todo-icon.ico'
$script:DetailDirectory = Join-Path $PSScriptRoot 'detail'
$script:BackupDirectory = Join-Path $PSScriptRoot 'backup'
$script:AutoStartRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:AutoStartValueName = 'DesktopTodoWidget'
$script:Version = '0.20.0'

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
$script:CurrentFilter = 'all'
$script:IsLocked = $false
$script:UrgentDays = 3
$script:CardActionMode = 'unified'
$script:WindowLayerMode = 'desktop'
$script:AutoStartEnabled = $false
$script:DisplayTitle = '我的一天'
$script:DesktopHandle = [IntPtr]::Zero
$script:WidgetHandle = [IntPtr]::Zero
$script:BottomEnforcementTimer = $null
$script:ScreenCheckTimer = $null
$script:TrayIcon = $null
$script:TrayMenu = $null
$script:AppIcon = $null
$script:IsRestoringUiState = $false
$script:ExportType = 'completed'
$script:ExportStartDate = $null
$script:ExportEndDate = $null
$script:DropTargetCard = $null

function New-TaskId {
    return [Guid]::NewGuid().ToString('N')
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

function Backup-AndRemoveTasks {
    param([bool]$Completed)

    $originalTasks = @($script:Tasks)
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
    foreach ($task in $tasksToRemove) { $removedIds[[string]$task.id] = $true }
    $script:Tasks = @($script:Tasks | Where-Object { -not $removedIds.ContainsKey([string]$_.id) })
    foreach ($task in $script:Tasks) {
        if ($removedIds.ContainsKey([string]$task.prerequisiteId)) { $task.prerequisiteId = $null }
    }
    $previousRestoreState = $script:IsRestoringUiState
    $script:IsRestoringUiState = $true
    try { Update-PrerequisitePicker } finally { $script:IsRestoringUiState = $previousRestoreState }
    try {
        Save-State
    }
    catch {
        $script:Tasks = @($originalTasks)
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
    foreach ($dependentTask in @($script:Tasks | Where-Object { [string]$_.prerequisiteId -eq $TaskId })) {
        $dependentTask.prerequisiteId = $null
    }
    $script:Tasks = @($script:Tasks | Where-Object { [string]$_.id -ne $TaskId })
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

function Apply-WindowLayerMode {
    if ($null -ne $script:BottomEnforcementTimer) {
        $script:BottomEnforcementTimer.Stop()
    }

    Send-WidgetToDesktopBottom

    if ($script:WindowLayerMode -eq 'alwaysBottom') {
        if ($null -eq $script:BottomEnforcementTimer) {
            $script:BottomEnforcementTimer = [Windows.Threading.DispatcherTimer]::new()
            $script:BottomEnforcementTimer.Interval = [TimeSpan]::FromMilliseconds(400)
            $script:BottomEnforcementTimer.Add_Tick({ Send-WidgetToDesktopBottom })
        }
        $script:BottomEnforcementTimer.Start()
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
    Send-WidgetToDesktopBottom
    Save-State
}

function Start-ScreenMonitoring {
    if ($null -eq $script:ScreenCheckTimer) {
        $script:ScreenCheckTimer = [Windows.Threading.DispatcherTimer]::new()
        $script:ScreenCheckTimer.Interval = [TimeSpan]::FromSeconds(2)
        $script:ScreenCheckTimer.Add_Tick({ Ensure-WidgetOnVisibleScreen })
    }
    if (-not $script:ScreenCheckTimer.IsEnabled) { $script:ScreenCheckTimer.Start() }
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
    Send-WidgetToDesktopBottom
    Save-State
}

function Show-WidgetFromTray {
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) { $window.WindowState = [Windows.WindowState]::Normal }
    if (-not $window.IsVisible) { $window.Show() }
    Move-WidgetToPrimaryScreen
    [void]$window.Activate()
}

function Initialize-TrayIcon {
    if ($null -ne $script:TrayIcon) { return }

    $script:TrayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
    $locateItem = $script:TrayMenu.Items.Add('定位待办窗口')
    $settingsItem = $script:TrayMenu.Items.Add('打开待办设置')
    [void]$script:TrayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    $exitItem = $script:TrayMenu.Items.Add('退出桌面待办')

    $locateItem.Add_Click({ Show-WidgetFromTray })
    $settingsItem.Add_Click({ Show-Settings })
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
    $script:TrayIcon.Add_DoubleClick({ Show-WidgetFromTray })
    $script:TrayIcon.Visible = $true
}

function Load-State {
    $defaultState = [PSCustomObject]@{
        tasks = @(
            [PSCustomObject]@{ id = (New-TaskId); text = '体验桌面待办小组件'; completed = $false; completedAt = $null; dueDate = (Get-Date).AddDays(2).ToString('yyyy-MM-dd'); prerequisiteId = $null; sortOrder = 0; createdAt = (Get-Date).ToString('o') },
            [PSCustomObject]@{ id = (New-TaskId); text = '勾选一条已完成的任务'; completed = $true; completedAt = (Get-Date).ToString('o'); dueDate = $null; prerequisiteId = $null; sortOrder = 1; createdAt = (Get-Date).AddMinutes(-1).ToString('o') }
        )
        left = $null
        top = $null
        height = 610
        locked = $false
        settings = [PSCustomObject]@{ urgentDays = 3; cardActionMode = 'unified'; windowLayerMode = 'desktop'; autoStartEnabled = $false; displayTitle = '我的一天' }
        ui = [PSCustomObject]@{ useDueDate = $false; dueDate = $null; usePrerequisite = $false; prerequisiteId = $null; currentFilter = 'all'; exportType = 'completed'; exportStartDate = $null; exportEndDate = $null }
    }

    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $defaultState
    }

    try {
        $loaded = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $loaded.tasks) { $loaded | Add-Member -NotePropertyName tasks -NotePropertyValue @() }
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
            $taskIndex++
        }
        if ($null -eq $loaded.settings) {
            $loaded | Add-Member -NotePropertyName settings -NotePropertyValue ([PSCustomObject]@{ urgentDays = 3; cardActionMode = 'unified'; windowLayerMode = 'desktop'; autoStartEnabled = $false; displayTitle = '我的一天' })
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
        left = $savedLeft
        top = $savedTop
        height = $window.ActualHeight
        locked = $script:IsLocked
        settings = [PSCustomObject]@{ urgentDays = $script:UrgentDays; cardActionMode = $script:CardActionMode; windowLayerMode = $script:WindowLayerMode; autoStartEnabled = $script:AutoStartEnabled; displayTitle = $script:DisplayTitle }
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
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Save-UiStateIfReady {
    if (-not $script:IsRestoringUiState -and $null -ne $window -and $window.IsLoaded) {
        Save-State
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
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
            <Setter Property="ToolTipService.InitialShowDelay" Value="250"/>
            <Setter Property="ToolTipService.ShowDuration" Value="6000"/>
        </Style>
        <Style x:Key="FilterButton" TargetType="Button">
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
            Save-State
            Refresh-Tasks
        }
        $editorWindow.DialogResult = $true
    })
    $cancelEditorButton.Add_Click({ $editorWindow.Close() })
    [void]$editorWindow.ShowDialog()
    Send-WidgetToDesktopBottom
}

function Show-TaskActions {
    param([string]$TaskId)
    $targetTask = Get-TaskById $TaskId
    if ($null -eq $targetTask) { return }

    [xml]$actionsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="管理待办" Width="360" Height="300"
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
            <Button x:Name="EditPrerequisiteButton" Content="修改或取消前置任务" Height="36" Margin="0,0,0,10" Background="#FFECE9FF" Foreground="#FF5A49DA" BorderThickness="0"/>
            <Button x:Name="EditDetailButton" Content="编辑详细说明" Height="36" Margin="0,0,0,10" Background="#FFEDF4FF" Foreground="#FF376CA8" BorderThickness="0"/>
            <Button x:Name="DeleteTaskButton" Content="删除待办" Height="36" Background="#FFFFECEC" Foreground="#FFC94B4B" BorderThickness="0"/>
        </StackPanel>
        <Button x:Name="CloseActionsButton" Grid.Row="3" Content="关闭" Width="72" Height="30" Margin="0,14,0,0" HorizontalAlignment="Right"/>
    </Grid>
</Window>
'@
    $actionsReader = New-Object System.Xml.XmlNodeReader $actionsXaml
    $actionsWindow = [Windows.Markup.XamlReader]::Load($actionsReader)
    $actionsWindow.Owner = $window
    $actionsWindow.FindName('ActionTaskName').Text = [string]$targetTask.text
    $editPrerequisiteButton = $actionsWindow.FindName('EditPrerequisiteButton')
    $editDetailButton = $actionsWindow.FindName('EditDetailButton')
    $deleteTaskButton = $actionsWindow.FindName('DeleteTaskButton')
    $closeActionsButton = $actionsWindow.FindName('CloseActionsButton')

    $editPrerequisiteButton.Add_Click({
        $actionsWindow.Close()
        Show-PrerequisiteEditor $TaskId
    })
    $editDetailButton.Add_Click({
        $actionsWindow.Close()
        Open-TaskDetail $TaskId
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
    Send-WidgetToDesktopBottom
}

function Show-Settings {
    [xml]$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面待办设置" Width="380" Height="680"
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
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Text="待办设置" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
            <TextBlock Text="名称" Width="64" VerticalAlignment="Center" FontSize="13" Foreground="#FF40444C"/>
            <TextBox x:Name="DisplayTitleText" Width="240" Height="30" MaxLength="30" FontSize="13" VerticalContentAlignment="Center" Padding="8,0"/>
        </StackPanel>
        <TextBlock Grid.Row="2" Margin="0,12,0,8" Text="剩余天数小于或等于此数值的待办会优先排列："
                   FontSize="12" Foreground="#FF707580" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal">
            <TextBox x:Name="UrgentDaysText" Width="80" Height="30" FontSize="13" VerticalContentAlignment="Center" Padding="8,0"/>
            <TextBlock Text="天" Margin="8,0,0,0" VerticalAlignment="Center" FontSize="13" Foreground="#FF40444C"/>
        </StackPanel>
        <TextBlock Grid.Row="4" Margin="0,20,0,8" Text="卡片操作方式" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <StackPanel Grid.Row="5">
            <RadioButton x:Name="UnifiedModeRadio" Content="单一管理按钮" Margin="0,0,0,9"/>
            <RadioButton x:Name="SeparateModeRadio" Content="前置任务和删除两个按钮"/>
        </StackPanel>
        <TextBlock Grid.Row="6" Margin="0,20,0,8" Text="窗口层级" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <StackPanel Grid.Row="7">
            <RadioButton x:Name="DesktopLayerRadio" Content="窗口模式" Margin="0,0,0,9"/>
            <RadioButton x:Name="AlwaysBottomRadio" Content="壁纸模式"/>
        </StackPanel>
        <TextBlock Grid.Row="8" Margin="0,20,0,8" Text="启动" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <CheckBox x:Name="AutoStartCheckBox" Grid.Row="9" Content="开机自启动"/>
        <TextBlock Grid.Row="10" Margin="0,20,0,8" Text="数据管理" FontSize="16" FontWeight="SemiBold" Foreground="#FF20242C"/>
        <StackPanel Grid.Row="11" Orientation="Horizontal">
            <Button x:Name="ClearCompletedButton" Content="备份并清除已完成" Width="150" Height="34" Margin="0,0,10,0" Background="#FFFFF1E8" Foreground="#FFB45C28" BorderThickness="0"/>
            <Button x:Name="ClearIncompleteButton" Content="备份并清除未完成" Width="150" Height="34" Background="#FFFFECEC" Foreground="#FFC94B4B" BorderThickness="0"/>
        </StackPanel>
        <TextBlock x:Name="ValidationText" Grid.Row="12" Margin="0,10,0,0" Foreground="#FFE05252" FontSize="11" TextWrapping="Wrap"/>
        <StackPanel Grid.Row="13" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelButton" Content="取消" Width="72" Height="32" Margin="0,0,10,0"/>
            <Button x:Name="SaveButton" Content="保存" Width="72" Height="32" Background="#FF6C5CE7" Foreground="White" BorderThickness="0"/>
        </StackPanel>
    </Grid>
</Window>
'@
    $settingsReader = New-Object System.Xml.XmlNodeReader $settingsXaml
    $settingsWindow = [Windows.Markup.XamlReader]::Load($settingsReader)
    $settingsWindow.Owner = $window
    $displayTitleText = $settingsWindow.FindName('DisplayTitleText')
    $urgentDaysText = $settingsWindow.FindName('UrgentDaysText')
    $validationText = $settingsWindow.FindName('ValidationText')
    $unifiedModeRadio = $settingsWindow.FindName('UnifiedModeRadio')
    $separateModeRadio = $settingsWindow.FindName('SeparateModeRadio')
    $desktopLayerRadio = $settingsWindow.FindName('DesktopLayerRadio')
    $alwaysBottomRadio = $settingsWindow.FindName('AlwaysBottomRadio')
    $autoStartCheckBox = $settingsWindow.FindName('AutoStartCheckBox')
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
    Send-WidgetToDesktopBottom
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
    } else {
        $eventArgs.Effects = [Windows.DragDropEffects]::Move
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
})
$taskList.Add_Drop({
    param($sender, $eventArgs)
    $sourceId = [string]$eventArgs.Data.GetData([string])
    $pointer = $eventArgs.GetPosition($taskList)
    $dropLocation = Get-TaskDropLocation $sourceId $pointer.Y
    if ($null -ne $script:DropTargetCard) { Animate-CardScale $script:DropTargetCard 1 80 }
    $script:DropTargetCard = $null
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
        # Keep the widget as a top-level WPF window so transparent rendering
        # remains reliable. Giving it the desktop as owner keeps it associated
        # with the desktop without turning it into a layered child window.
        Apply-WindowLayerMode
    }
})
$window.Add_Activated({
    # Clicking the widget normally raises a top-level window. Correct its
    # z-order immediately so it always returns to the desktop layer.
    Apply-WindowLayerMode
})
$window.Add_ContentRendered({
    $newTaskText.Focus() | Out-Null
    Apply-WindowLayerMode
    Ensure-WidgetOnVisibleScreen
    Start-ScreenMonitoring
    Initialize-TrayIcon
})
$window.Add_Closing({
    if ($null -ne $script:BottomEnforcementTimer) { $script:BottomEnforcementTimer.Stop() }
    if ($null -ne $script:ScreenCheckTimer) { $script:ScreenCheckTimer.Stop() }
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

