[CmdletBinding()]
param()

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'RClauncher requires Windows PowerShell 5.1 or later.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $hostExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = (Get-Process -Id $PID).Path }
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"") -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:BaseDir = Split-Path -Parent $PSCommandPath
$script:ConfigPath = Join-Path $script:BaseDir 'config.toml'
$script:ClipboardDir = Join-Path $script:BaseDir 'clipboard'
$script:ClipboardHistoryPath = Join-Path $script:ClipboardDir 'clipboard_history.txt'
$script:FolderHistoryDir = Join-Path $script:BaseDir 'folder_launch'
$script:FolderHistoryPath = Join-Path $script:FolderHistoryDir 'folder_history.txt'
$script:LogPath = Join-Path $script:BaseDir 'rclauncher.log'
$script:MaxTextChars = 100000
$script:Config = $null
$script:History = [Collections.Generic.List[string]]::new()
$script:FolderHistory = [Collections.Generic.List[string]]::new()
$script:LastConfigWrite = [datetime]::MinValue
$script:LastRightTime = [uint32]0
$script:LastRightX = 0
$script:LastRightY = 0
$script:LastLeftTime = [uint32]0
$script:LastLeftX = 0
$script:LastLeftY = 0
$script:SwallowRightUp = $false
$script:PendingFolderPoint = $null
$script:LaunchFolderPoint = $null
$script:PendingClipPoint = $null
$script:PendingShellPath = $null
$script:MenuVisible = $false
$script:CurrentFolderMenu = $null
$script:CurrentPopupMenu = $null
$script:Mutex = $null
$script:Tray = $null
$script:Form = $null

. (Join-Path $PSScriptRoot 'functions\Native.ps1')
. (Join-Path $PSScriptRoot 'functions\Config.ps1')
. (Join-Path $PSScriptRoot 'functions\History.ps1')
. (Join-Path $PSScriptRoot 'functions\Menus.ps1')
. (Join-Path $PSScriptRoot 'functions\Settings.ps1')
. (Join-Path $PSScriptRoot 'functions\Runtime.ps1')


try { Start-Launcher } catch {
    Write-Log "Fatal error: $_"
    [Windows.Forms.MessageBox]::Show("RClauncher の起動に失敗しました:`r`n$_",'RClauncher','OK','Error') | Out-Null
}
