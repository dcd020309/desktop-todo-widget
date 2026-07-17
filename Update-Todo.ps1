param(
    [Parameter(Mandatory = $true)][string]$TargetDirectory,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [int]$SourceProcessId = 0,
    [string]$ArchivePath,
    [switch]$SkipRestart,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$repositoryArchiveUrl = 'https://github.com/dcd020309/desktop-todo-widget/archive/refs/heads/main.zip'
$targetRoot = [IO.Path]::GetFullPath($TargetDirectory)
$windowsDirectory = if ([string]::IsNullOrWhiteSpace($env:WINDIR)) { [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows) } else { $env:WINDIR }
$appDataDirectory = Join-Path $env:LOCALAPPDATA 'DesktopTodoDemo'
$logPath = Join-Path $appDataDirectory 'update.log'
$temporaryRoot = Join-Path $env:TEMP ("DesktopTodoUpdate-{0}" -f [Guid]::NewGuid().ToString('N'))
$downloadPath = Join-Path $temporaryRoot 'update.zip'
$extractPath = Join-Path $temporaryRoot 'extracted'
$backupPath = $null
$copyStarted = $false
$newDestinationFiles = [Collections.Generic.List[string]]::new()

function Write-UpdateLog {
    param([string]$Message)
    New-Item -ItemType Directory -Path $appDataDirectory -Force | Out-Null
    Add-Content -LiteralPath $logPath -Value ("{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function Show-UpdateError {
    param([string]$Message)
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show(
            "自动更新失败。`n`n$Message`n`n日志：$logPath",
            'Desktop Todo 更新',
            [Windows.MessageBoxButton]::OK,
            [Windows.MessageBoxImage]::Error
        )
    }
    catch {}
}

function Get-RelativePathFromRoot {
    param([string]$Root, [string]$FullName)
    $normalizedRoot = $Root.TrimEnd('\') + '\'
    if (-not $FullName.StartsWith($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "文件不在预期目录内：$FullName"
    }
    return $FullName.Substring($normalizedRoot.Length)
}

function Copy-FileTree {
    param([string]$SourceRoot, [string]$DestinationRoot, [AllowNull()]$CreatedDestinations)
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force)) {
        $relativePath = Get-RelativePathFromRoot $SourceRoot $sourceFile.FullName
        $destinationPath = Join-Path $DestinationRoot $relativePath
        if ($null -ne $CreatedDestinations -and -not (Test-Path -LiteralPath $destinationPath)) {
            $CreatedDestinations.Add($destinationPath)
        }
        $destinationDirectory = [IO.Path]::GetDirectoryName($destinationPath)
        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        }
        Copy-FileWithRetry $sourceFile.FullName $destinationPath
    }
}

function Copy-FileWithRetry {
    param([string]$SourcePath, [string]$DestinationPath)
    $lastError = $null
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
            return
        }
        catch {
            $lastError = $_.Exception
            if ($attempt -lt 20) { Start-Sleep -Milliseconds 250 }
        }
    }
    throw "多次尝试后仍无法写入文件 $DestinationPath：$($lastError.Message)"
}

function Start-TodoApplication {
    if ($SkipRestart) { return }
    $launcherPath = Join-Path $targetRoot 'Start-Todo.vbs'
    $wscriptPath = Join-Path $windowsDirectory 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $launcherPath)) { throw "找不到启动文件：$launcherPath" }
    Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f $launcherPath) -WindowStyle Hidden
}

try {
    Write-UpdateLog "开始更新到 $ExpectedVersion。"
    $expected = [version]$ExpectedVersion
    if (-not (Test-Path -LiteralPath $targetRoot)) { throw "程序目录不存在：$targetRoot" }

    # Wait for TodoWidget.ps1 to save state and release icon/file handles.
    if ($SourceProcessId -gt 0) {
        $sourceProcess = Get-Process -Id $SourceProcessId -ErrorAction SilentlyContinue
        if ($null -ne $sourceProcess) {
            Write-UpdateLog "正在等待旧程序进程 $SourceProcessId 完全退出。"
            if (-not $sourceProcess.WaitForExit(15000)) { throw '旧程序未能在 15 秒内退出，已取消更新；请退出程序后重试。' }
        }
    }
    else {
        Start-Sleep -Milliseconds 1800
    }
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-UpdateLog "正在从 GitHub 下载更新包。"
        try {
            Invoke-WebRequest -Uri $repositoryArchiveUrl -OutFile $downloadPath -UseBasicParsing -TimeoutSec 30 -DisableKeepAlive -Headers @{ 'User-Agent' = 'DesktopTodoUpdater' }
        }
        catch {
            throw "无法从 GitHub 下载更新包，请检查网络或代理后重试。原始错误：$($_.Exception.Message)"
        }
    }
    else {
        $resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
        if (-not (Test-Path -LiteralPath $resolvedArchive)) { throw "测试更新包不存在：$resolvedArchive" }
        Copy-Item -LiteralPath $resolvedArchive -Destination $downloadPath -Force
    }

    Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force
    $sourceRoot = Get-ChildItem -LiteralPath $extractPath -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'VERSION')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'TodoWidget.ps1'))
    } | Select-Object -First 1
    if ($null -eq $sourceRoot) { throw '更新包结构无效：未找到 VERSION 和 TodoWidget.ps1。' }
    $sourceRoot = $sourceRoot.FullName

    $packageVersionText = ([IO.File]::ReadAllText((Join-Path $sourceRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
    $packageVersion = [version]$packageVersionText
    if ($packageVersion -ne $expected) { throw "更新包版本 $packageVersionText 与预期版本 $ExpectedVersion 不一致。" }
    foreach ($requiredFile in @('TodoWidget.ps1','Start-Todo.vbs','Update-Todo.ps1','Update-Todo.vbs','VERSION','assets\todo-icon.ico')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $requiredFile))) { throw "更新包缺少文件：$requiredFile" }
    }

    $backupTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = Join-Path (Join-Path $targetRoot 'backup') "${backupTimestamp}_程序更新前备份"
    $programBackupPath = Join-Path $backupPath 'program'
    New-Item -ItemType Directory -Path $programBackupPath -Force | Out-Null
    $excludedTopLevel = @('.git','.qa','backup','detail','node_modules','output')
    foreach ($currentFile in @(Get-ChildItem -LiteralPath $targetRoot -Recurse -File -Force)) {
        $relativePath = Get-RelativePathFromRoot $targetRoot $currentFile.FullName
        $topLevel = $relativePath.Split('\')[0]
        if ($topLevel -in $excludedTopLevel -or $currentFile.Extension -in @('.lnk','.log')) { continue }
        $backupFilePath = Join-Path $programBackupPath $relativePath
        $backupFileDirectory = [IO.Path]::GetDirectoryName($backupFilePath)
        if (-not (Test-Path -LiteralPath $backupFileDirectory)) { New-Item -ItemType Directory -Path $backupFileDirectory -Force | Out-Null }
        Copy-FileWithRetry $currentFile.FullName $backupFilePath
    }
    $currentVersionPath = Join-Path $targetRoot 'VERSION'
    $fromVersion = if (Test-Path -LiteralPath $currentVersionPath) { ([IO.File]::ReadAllText($currentVersionPath)).Trim() } else { $null }
    $backupInfo = [PSCustomObject]@{
        backupVersion = 1
        reason = 'self-update'
        fromVersion = $fromVersion
        toVersion = $ExpectedVersion
        backupTime = [DateTimeOffset]::Now.ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $backupPath 'backup-info.json'), ($backupInfo | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
    Write-UpdateLog "程序文件已备份到 $backupPath。"

    $copyStarted = $true
    Copy-FileTree $sourceRoot $targetRoot $newDestinationFiles
    $installedVersion = ([IO.File]::ReadAllText((Join-Path $targetRoot 'VERSION'), [Text.Encoding]::UTF8)).Trim()
    if ([version]$installedVersion -ne $expected) { throw "安装后版本校验失败：$installedVersion" }
    Write-UpdateLog "更新完成，当前版本 $installedVersion。"

    Start-TodoApplication
}
catch {
    $message = $_.Exception.Message
    Write-UpdateLog "更新失败：$message"
    if ($copyStarted -and $null -ne $backupPath) {
        try {
            foreach ($newFile in $newDestinationFiles) {
                Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
            }
            $programBackupPath = Join-Path $backupPath 'program'
            if (Test-Path -LiteralPath $programBackupPath) {
                Copy-FileTree $programBackupPath $targetRoot $null
                Write-UpdateLog '已从更新前备份恢复原程序文件。'
            }
        }
        catch {
            Write-UpdateLog "自动恢复失败：$($_.Exception.Message)"
        }
    }
    if (-not $SkipRestart) {
        try {
            Start-TodoApplication
            Write-UpdateLog '更新失败后已重新启动原程序。'
        }
        catch {
            Write-UpdateLog "更新失败后无法重新启动原程序：$($_.Exception.Message)"
        }
    }
    if (-not $Quiet) { Show-UpdateError $message }
    exit 1
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
