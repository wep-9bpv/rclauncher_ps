function Write-Log([string]$Message) {
    try { Add-Content -LiteralPath $script:LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8 } catch {}
}

function Reload-LauncherConfig {
    try {
        $script:LastConfigWrite=(Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc
        $new = Read-LauncherConfig
        $script:Config = $new
        while ($script:History.Count -gt $script:Config.clipboard.max_items) { $script:History.RemoveAt($script:History.Count-1) }
        Save-ClipboardHistory
    } catch {
        Write-Log "Config reload failed: $_"
        [Windows.Forms.MessageBox]::Show("config.toml を読み込めません:`r`n$_",'RClauncher','OK','Error') | Out-Null
    }
}

function Show-TrayMenu {
    $menu=[Windows.Forms.ContextMenuStrip]::new()
    $settings=[Windows.Forms.ToolStripMenuItem]::new('設定...')
    $settings.Add_Click({ Show-Settings }); [void]$menu.Items.Add($settings)
    [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    $openCfg=[Windows.Forms.ToolStripMenuItem]::new('設定ファイルを開く')
    $openCfg.Add_Click({ Start-Process notepad.exe -ArgumentList @("`"$script:ConfigPath`"") }); [void]$menu.Items.Add($openCfg)
    $openDir=[Windows.Forms.ToolStripMenuItem]::new('設定フォルダを開く')
    $openDir.Add_Click({ Start-Process explorer.exe -ArgumentList @("`"$script:BaseDir`"") }); [void]$menu.Items.Add($openDir)
    $reload=[Windows.Forms.ToolStripMenuItem]::new('設定を再読み込み')
    $reload.Add_Click({ Reload-LauncherConfig }); [void]$menu.Items.Add($reload)
    [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    $exit=[Windows.Forms.ToolStripMenuItem]::new('終了')
    $exit.Add_Click({ $script:Form.Close() }); [void]$menu.Items.Add($exit)
    $script:Tray.ContextMenuStrip=$menu
    $menu.Add_Opened({ Set-PopupMenuState $this $true })
    $menu.Add_Closed({
        Set-PopupMenuState $this $false
    })
}

function Invoke-MouseHook([uint32]$Message, [int]$X, [int]$Y, [uint32]$Time) {
    if (Test-ActivePopupMenu) {
        if ($Message -in @(0x0201,0x0204) -and $script:CurrentPopupMenu) {
            $point = [Drawing.Point]::new($X,$Y)
            if (-not (Test-PopupContainsPoint $script:CurrentPopupMenu $point)) {
                [void]$script:Form.BeginInvoke([Action]{ Close-PopupMenu })
            }
        }
        return $false
    }
    $tol=5
    if ($Message -eq 0x0204) {
        $elapsed=($Time - $script:LastRightTime) -band 0xffffffff
        $limit=if([int]$script:Config.general.double_click_ms -gt 0){[int]$script:Config.general.double_click_ms}else{[RClauncher.MouseHook]::DoubleClickTime}
        if ($script:LastRightTime -ne 0 -and $elapsed -le $limit -and [Math]::Abs($X-$script:LastRightX) -le $tol -and [Math]::Abs($Y-$script:LastRightY) -le $tol -and -not [RClauncher.MouseHook]::IsDesktop($X,$Y)) {
            $script:LastRightTime=0
            $script:SwallowRightUp=$true
            $script:PendingClipPoint=[Drawing.Point]::new($X,$Y)
            [void]$script:Form.BeginInvoke([Action]{ $point=$script:PendingClipPoint; if($point){Show-ClipMenu $point.X $point.Y}; $script:PendingClipPoint=$null })
            return $true
        }
        if ([RClauncher.MouseHook]::IsDesktop($X,$Y)) { $script:LastRightTime=0 }
        else { $script:LastRightTime=$Time; $script:LastRightX=$X; $script:LastRightY=$Y }
    } elseif ($Message -eq 0x0205 -and $script:SwallowRightUp) {
        $script:SwallowRightUp=$false
        return $true
    } elseif ($Message -eq 0x0201) {
        $elapsed=($Time - $script:LastLeftTime) -band 0xffffffff
        $limit=if([int]$script:Config.general.double_click_ms -gt 0){[int]$script:Config.general.double_click_ms}else{[RClauncher.MouseHook]::DoubleClickTime}
        if ($script:LastLeftTime -ne 0 -and $elapsed -le $limit -and [Math]::Abs($X-$script:LastLeftX) -le $tol -and [Math]::Abs($Y-$script:LastLeftY) -le $tol -and [RClauncher.MouseHook]::IsDesktop($X,$Y)) {
            $script:PendingFolderPoint=[Drawing.Point]::new($X,$Y)
            $script:LastLeftTime=0
        } else { $script:LastLeftTime=$Time; $script:LastLeftX=$X; $script:LastLeftY=$Y }
    } elseif ($Message -eq 0x0202 -and $null -ne $script:PendingFolderPoint) {
        $script:LaunchFolderPoint=$script:PendingFolderPoint
        $script:PendingFolderPoint=$null
        [void]$script:Form.BeginInvoke([Action]{ $point=$script:LaunchFolderPoint; if($point -and [RClauncher.MouseHook]::IsEmptyDesktopSpot($point.X,$point.Y)){Show-FolderMenu $point.X $point.Y}; $script:LaunchFolderPoint=$null })
    }
    return $false
}

function Start-Launcher {
    $created = $false
    $script:Mutex=[Threading.Mutex]::new($true,'Local\RClauncher_PowerShell_SingleInstance',[ref]$created)
    if (-not $created) { return }
    $script:Config=Read-LauncherConfig
    [RClauncher.MouseHook]::RegisterClipboardExclusionFormat()
    $script:LastConfigWrite=(Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc
    Read-HistoryFiles
    try {
        if (-not [RClauncher.MouseHook]::IsClipboardExcluded()) { Add-ClipboardHistory ([Windows.Forms.Clipboard]::GetText()) }
    } catch {}
    $script:Form=[Windows.Forms.Form]::new()
    $script:Form.Text='RClauncher'; $script:Form.ShowInTaskbar=$false; $script:Form.WindowState='Minimized'; $script:Form.Opacity=0
    $script:Form.Add_Shown({ $script:Form.Hide() })
    $script:Tray=[Windows.Forms.NotifyIcon]::new()
    $script:Tray.Icon=[Drawing.SystemIcons]::Application; $script:Tray.Text='RClauncher'; $script:Tray.Visible=$true
    Show-TrayMenu
    $timer=[Windows.Forms.Timer]::new(); $timer.Interval=300; $timer.Add_Tick({
        try { if (-not [RClauncher.MouseHook]::IsClipboardExcluded()) { Add-ClipboardHistory ([Windows.Forms.Clipboard]::GetText()) } } catch {}
        try {
            $mtime=(Get-Item -LiteralPath $script:ConfigPath -ErrorAction Stop).LastWriteTimeUtc
            if ($mtime -ne $script:LastConfigWrite -and -not $script:MenuVisible) { Reload-LauncherConfig }
        } catch { Write-Log "Config watch failed: $_" }
    }); $timer.Start()
    [RClauncher.MouseHook]::Handler=[Func[uint32,int,int,uint32,bool]]{
        param($message,$x,$y,$time)
        return Invoke-MouseHook $message $x $y $time
    }
    try { [RClauncher.MouseHook]::Install() } catch {
        Write-Log "Mouse hook install failed: $_"
        [Windows.Forms.MessageBox]::Show("マウスフックを開始できません:`r`n$_",'RClauncher','OK','Error') | Out-Null
    }
    $script:Form.Add_FormClosed({
        [RClauncher.MouseHook]::Uninstall()
        $script:Tray.Visible=$false; $script:Tray.Dispose(); $timer.Dispose()
        if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() }
    })
    [Windows.Forms.Application]::Run($script:Form)
}
