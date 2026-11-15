function Set-PopupMenuState($Menu, [bool]$Visible) {
    if ($Visible) {
        $script:CurrentPopupMenu = $Menu
        $script:MenuVisible = $true
    } elseif ($script:CurrentPopupMenu -eq $Menu) {
        $script:CurrentPopupMenu = $null
        $script:MenuVisible = $false
    }
}

function Test-ActivePopupMenu {
    $menu = $script:CurrentPopupMenu
    if (-not $menu) {
        $script:MenuVisible = $false
        return $false
    }
    try {
        if ($menu.IsDisposed -or -not $menu.Visible) {
            if ($script:CurrentPopupMenu -eq $menu) {
                $script:CurrentPopupMenu = $null
                $script:MenuVisible = $false
            }
            return $false
        }
        $script:MenuVisible = $true
        return $true
    } catch [ObjectDisposedException] {
        if ($script:CurrentPopupMenu -eq $menu) {
            $script:CurrentPopupMenu = $null
            $script:MenuVisible = $false
        }
        return $false
    }
}

function Test-PopupContainsPoint($Menu, [Drawing.Point]$Point) {
    if ($Menu.Visible -and $Menu.Bounds.Contains($Point)) { return $true }
    foreach ($item in $Menu.Items) {
        if ($item -is [Windows.Forms.ToolStripDropDownItem] -and $item.DropDown.Visible) {
            if (Test-PopupContainsPoint $item.DropDown $Point) { return $true }
        }
    }
    return $false
}

function Close-PopupMenu {
    $menu = $script:CurrentPopupMenu
    if ($menu -and -not $menu.IsDisposed) {
        $menu.Close([Windows.Forms.ToolStripDropDownCloseReason]::AppClicked)
    }
}

function New-ClipMenu {
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    $groupSize = [Math]::Max(1, [int]$script:Config.clipboard.group_size)
    for ($i = 0; $i -lt $script:History.Count; $i++) {
        $text = ($script:History[$i] -replace '[\s\p{C}]+',' ').Trim()
        if ($text.Length -gt 10) { $text = $text.Substring(0,10) + '...' }
        if (-not $text) { $text = '(空白)' }
        $label = '{0}  {1}' -f $(if ($i -lt 9) { $i + 1 } elseif ($i -lt 35) { [char](65 + $i - 9) } else { ' ' }), $text
        $entry = [Windows.Forms.ToolStripMenuItem]::new($label)
        $entry.Tag = $script:History[$i]
        $entry.Add_Click({
            $value = [string]$this.Tag
            try {
                [Windows.Forms.Clipboard]::SetText($value)
                Add-ClipboardHistory $value
                $script:Form.BeginInvoke([Action]{ Start-Sleep -Milliseconds 40; [Windows.Forms.SendKeys]::SendWait('^v') }) | Out-Null
            } catch { Write-Log "Clipboard paste failed: $_" }
        })
        if ($i -ge $groupSize) {
            $groupStart = [Math]::Floor($i / $groupSize) * $groupSize
            $caption = '{0}-{1}' -f ($groupStart + 1), ([Math]::Min($groupStart + $groupSize, $script:History.Count))
            $parent = $menu.Items | Where-Object { $_.Text -eq $caption } | Select-Object -First 1
            if (-not $parent) { $parent = [Windows.Forms.ToolStripMenuItem]::new($caption); [void]$menu.Items.Add($parent) }
            [void]$parent.DropDownItems.Add($entry)
        } else { [void]$menu.Items.Add($entry) }
    }
    if ($menu.Items.Count -gt 0) { [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new()) }
    $clear = [Windows.Forms.ToolStripMenuItem]::new('履歴クリア')
    $clear.Add_Click({
        $script:History.Clear()
        [IO.File]::WriteAllText($script:ClipboardHistoryPath, '', [Text.UTF8Encoding]::new($false))
    })
    [void]$menu.Items.Add($clear)
    $menu.Add_Closed({
        Set-PopupMenuState $this $false
    })
    $menu.Add_Opened({ Set-PopupMenuState $this $true })
    return $menu
}

function Get-FolderChildren([string]$Path) {
    try {
        $items = Get-ChildItem -LiteralPath $Path -Directory -Force:$script:Config.folder_menu.show_hidden -ErrorAction Stop
        if (-not $script:Config.folder_menu.show_hidden) { $items = $items | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and -not ($_.Attributes -band [IO.FileAttributes]::System) } }
        return @($items | Sort-Object Name | Select-Object -First $script:Config.folder_menu.max_entries)
    } catch { Write-Log "Cannot list folders '$Path': $_"; return @() }
}

function Set-FolderMenuIcon([Windows.Forms.ToolStripMenuItem]$Item, [string]$Path) {
    if (-not $script:Config.folder_menu.show_icons -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $iconHandle = [IntPtr]::Zero
    try {
        $iconHandle = [RClauncher.FolderIcon]::Get($Path)
        if ($iconHandle -ne [IntPtr]::Zero) { $Item.Image = [Drawing.Icon]::FromHandle($iconHandle).ToBitmap() }
    } catch { Write-Log "Cannot load folder icon '$Path': $_" }
    finally { [RClauncher.FolderIcon]::Release($iconHandle) }
}

function Add-FolderSubmenu([Windows.Forms.ToolStripMenuItem]$Item, [string]$Path, [int]$Depth) {
    if ($Depth -ge 16) { return }
    $Item.Tag = $Path
    Set-FolderMenuIcon $Item $Path
    $Item.AccessibleDescription = [string]$Depth
    $Item.Add_MouseUp({
        if ($_.Button -eq [Windows.Forms.MouseButtons]::Right) {
            $script:PendingShellPath=[string]$this.Tag
            [void]$script:Form.BeginInvoke([Action]{ $path=$script:PendingShellPath; if($path){Show-ShellContextMenu $path}; $script:PendingShellPath=$null })
        } elseif ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
            Open-LauncherFolder ([string]$this.Tag)
        }
    })
    $placeholder = [Windows.Forms.ToolStripMenuItem]::new('読み込み中...')
    [void]$Item.DropDownItems.Add($placeholder)
    $Item.Add_DropDownOpening({
        if ($this.DropDownItems.Count -ne 1 -or $this.DropDownItems[0].Text -ne '読み込み中...') { return }
        $this.DropDownItems.Clear()
        $currentPath = [string]$this.Tag
        $currentDepth = [int]$this.AccessibleDescription
        $open = [Windows.Forms.ToolStripMenuItem]::new('このフォルダを開く')
        $open.Tag = $currentPath
        Set-FolderMenuIcon $open $currentPath
        $open.Add_Click({ Open-LauncherFolder ([string]$this.Tag) })
        [void]$this.DropDownItems.Add($open)
        [void]$this.DropDownItems.Add([Windows.Forms.ToolStripSeparator]::new())
        foreach ($child in (Get-FolderChildren $currentPath)) {
            $sub = [Windows.Forms.ToolStripMenuItem]::new($child.Name)
            Add-FolderSubmenu $sub $child.FullName ($currentDepth + 1)
            [void]$this.DropDownItems.Add($sub)
        }
    })
}

function Open-LauncherFolder([string]$Path) {
    $expanded = Expand-LauncherPath $Path
    if (-not (Test-Path -LiteralPath $expanded -PathType Container)) {
        $script:FolderHistory.RemoveAll([Predicate[string]]{ param($p) $p -ieq $Path })
        Save-FolderHistory
        [Windows.Forms.MessageBox]::Show("フォルダが見つかりません:`r`n$expanded", 'RClauncher', 'OK', 'Error') | Out-Null
        return
    }
    try { Start-Process -FilePath explorer.exe -ArgumentList @("`"$expanded`"") } catch {
        Write-Log "Folder launch failed for '$expanded': $_"
        [Windows.Forms.MessageBox]::Show("フォルダを開けません:`r`n$expanded", 'RClauncher', 'OK', 'Error') | Out-Null
        return
    }
    if ($script:CurrentFolderMenu) { $script:CurrentFolderMenu.Close() }
    if ($script:Config.folder_menu.history_max -gt 0) {
        $script:FolderHistory.RemoveAll([Predicate[string]]{ param($p) $p -ieq $Path })
        $script:FolderHistory.Insert(0, $Path)
        while ($script:FolderHistory.Count -gt $script:Config.folder_menu.history_max) { $script:FolderHistory.RemoveAt($script:FolderHistory.Count - 1) }
        Save-FolderHistory
    }
}

function Start-RegisteredApplication([string]$Path) {
    try { Start-Process -FilePath $Path } catch {
        Write-Log "Application launch failed for '$Path': $_"
        [Windows.Forms.MessageBox]::Show("アプリケーションを起動できません:`r`n$Path", 'RClauncher', 'OK', 'Error') | Out-Null
    } finally {
        if ($script:CurrentFolderMenu) { $script:CurrentFolderMenu.Close() }
    }
}

function Show-ShellContextMenu([string]$Path) {
    try {
        $shell = New-Object -ComObject Shell.Application
        $parent = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path
        $folder = $shell.Namespace($parent)
        $shellItem = if ($folder) { $folder.ParseName($leaf) } else { $null }
        if (-not $shellItem) { return }
        $menu = [Windows.Forms.ContextMenuStrip]::new()
        foreach ($verb in @($shellItem.Verbs())) {
            $caption = ([string]$verb.Name).Replace('&','').Trim()
            if (-not $caption) { continue }
            $entry = [Windows.Forms.ToolStripMenuItem]::new($caption)
            $entry.Tag = $verb
            $entry.Add_Click({ try { $this.Tag.DoIt() } catch { Write-Log "Shell verb failed: $_" } })
            [void]$menu.Items.Add($entry)
        }
        if ($menu.Items.Count -gt 0) {
            $menu.Add_Opened({ Set-PopupMenuState $this $true })
            $menu.Add_Closed({
                Set-PopupMenuState $this $false
            })
            $menu.Show([Windows.Forms.Cursor]::Position)
        }
    } catch { Write-Log "Cannot build shell context menu for '$Path': $_" }
}

function New-FolderMenu {
    $menu = [Windows.Forms.ContextMenuStrip]::new()
    if ($script:Config.application_menu.layout -eq 'horizontal' -and $script:Config.applications.Count -gt 0) {
        $panel = [Windows.Forms.FlowLayoutPanel]::new()
        $panel.AutoSize = $true; $panel.WrapContents = $false; $panel.FlowDirection = 'LeftToRight'; $panel.Padding = [Windows.Forms.Padding]::new(5)
        $toolTips = [Windows.Forms.ToolTip]::new()
        foreach ($app in @($script:Config.applications)) {
            $appPath = Expand-LauncherPath ([string]$app.path)
            $title = if ($app.name) { [string]$app.name } else { [IO.Path]::GetFileNameWithoutExtension($appPath) }
            $button = [Windows.Forms.Button]::new()
            $button.Size = [Drawing.Size]::new(36,36); $button.Margin = [Windows.Forms.Padding]::new(1); $button.FlatStyle = 'Flat'
            $button.FlatAppearance.BorderSize = 0; $button.Tag = $appPath
            try {
                if ($script:Config.folder_menu.show_icons -and (Test-Path -LiteralPath $appPath)) {
                    $icon = [Drawing.Icon]::ExtractAssociatedIcon($appPath)
                    if ($icon) { $button.Image = $icon.ToBitmap(); $icon.Dispose() }
                }
            } catch { Write-Log "Cannot load application icon '$appPath': $_" }
            $button.Add_Click({ Start-RegisteredApplication ([string]$this.Tag) })
            $toolTips.SetToolTip($button, $title)
            [void]$panel.Controls.Add($button)
        }
        $hostItem = [Windows.Forms.ToolStripControlHost]::new($panel)
        $hostItem.AutoSize = $true; $hostItem.Margin = [Windows.Forms.Padding]::Empty; $hostItem.Padding = [Windows.Forms.Padding]::Empty
        $hostItem.Tag = $toolTips
        [void]$menu.Items.Add($hostItem)
    } else {
        foreach ($app in @($script:Config.applications)) {
            $appPath = Expand-LauncherPath ([string]$app.path)
            $title = if ($app.name) { [string]$app.name } else { [IO.Path]::GetFileNameWithoutExtension($appPath) }
            $item = [Windows.Forms.ToolStripMenuItem]::new($title)
            $item.Tag = $appPath
            try { if ($script:Config.folder_menu.show_icons -and (Test-Path -LiteralPath $appPath)) { $item.Image = [Drawing.Icon]::ExtractAssociatedIcon($appPath).ToBitmap() } } catch { Write-Log "Cannot load application icon '$appPath': $_" }
            $item.Add_Click({ Start-RegisteredApplication ([string]$this.Tag) })
            [void]$menu.Items.Add($item)
        }
    }
    if ($script:Config.applications.Count -gt 0) { [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new()) }
    if ($script:Config.folder_menu.history_max -gt 0 -and $script:FolderHistory.Count -gt 0) {
        $history = [Windows.Forms.ToolStripMenuItem]::new('履歴')
        foreach ($path in @($script:FolderHistory | Select-Object -First $script:Config.folder_menu.history_max)) {
            $entry = [Windows.Forms.ToolStripMenuItem]::new($path)
            $entry.Tag = $path
            Set-FolderMenuIcon $entry $path
            $entry.Add_Click({ Open-LauncherFolder ([string]$this.Tag) })
            [void]$history.DropDownItems.Add($entry)
        }
        [void]$menu.Items.Add($history)
        [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    }
    foreach ($folder in @($script:Config.folders)) {
        $path = Expand-LauncherPath ([string]$folder.path)
        $name = if ($folder.name) { [string]$folder.name } else { [IO.Path]::GetFileName($path.TrimEnd('\')) }
        $item = [Windows.Forms.ToolStripMenuItem]::new($name)
        Add-FolderSubmenu $item $path 0
        [void]$menu.Items.Add($item)
    }
    if ($script:Config.folder_menu.history_max -gt 0) {
        if ($menu.Items.Count -gt 0) { [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new()) }
        $clear = [Windows.Forms.ToolStripMenuItem]::new('フォルダ履歴クリア')
        $clear.Add_Click({ $script:FolderHistory.Clear(); Save-FolderHistory })
        [void]$menu.Items.Add($clear)
    }
    $menu.Add_Closed({
        Set-PopupMenuState $this $false
        foreach ($menuItem in $this.Items) {
            if ($menuItem -is [Windows.Forms.ToolStripControlHost] -and $menuItem.Tag) { $menuItem.Tag.Dispose() }
        }
        if ($script:CurrentFolderMenu -eq $this) { $script:CurrentFolderMenu = $null }
    })
    $menu.Add_Opened({ Set-PopupMenuState $this $true })
    return $menu
}

function Show-ClipMenu([int]$X, [int]$Y) {
    if (Test-ActivePopupMenu) { return }
    $menu = New-ClipMenu
    $script:CurrentPopupMenu = $menu
    $menu.Show([Drawing.Point]::new($X, $Y))
}

function Show-FolderMenu([int]$X, [int]$Y) {
    if (Test-ActivePopupMenu) { return }
    $menu = New-FolderMenu
    $script:CurrentFolderMenu = $menu
    $script:CurrentPopupMenu = $menu
    $menu.Show([Drawing.Point]::new($X, $Y))
}
