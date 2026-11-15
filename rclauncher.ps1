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
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RClauncher {
    public static class MouseHook {
        private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInfo {
            public Point point;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr extraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Point { public int x; public int y; }
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet=CharSet.Auto)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")]
        private static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint flag);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder text, int max);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, ref HitTestInfo buffer, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr ScreenToClient(IntPtr hwnd, ref Point point);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
        [StructLayout(LayoutKind.Sequential)]
        private struct HitTestInfo { public Point point; public uint flags; public int item; public int subItem; public int group; }

        private static HookProc proc = Callback;
        private static IntPtr hook;
        public static Func<uint,int,int,uint,bool> Handler;
        public static int DoubleClickTime { get { return (int)GetDoubleClickTimeNative(); } }
        [DllImport("user32.dll", EntryPoint="GetDoubleClickTime")]
        private static extern uint GetDoubleClickTimeNative();
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        private static extern uint RegisterClipboardFormat(string format);
        [DllImport("user32.dll")]
        private static extern bool IsClipboardFormatAvailable(uint format);
        private static uint excludeClipboardFormat;
        public static void RegisterClipboardExclusionFormat() {
            excludeClipboardFormat = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        }
        public static bool IsClipboardExcluded() {
            return excludeClipboardFormat != 0 && IsClipboardFormatAvailable(excludeClipboardFormat);
        }

        public static void Install() {
            if (hook != IntPtr.Zero) return;
            using (Process p = Process.GetCurrentProcess())
            using (ProcessModule m = p.MainModule) {
                hook = SetWindowsHookEx(14, proc, GetModuleHandle(m.ModuleName), 0);
            }
            if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        public static void Uninstall() {
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            Handler = null;
        }
        public static bool IsDesktop(int x, int y) {
            Point pt = new Point { x=x, y=y };
            IntPtr first = WindowFromPoint(pt), current = first;
            for (int i=0; i<8 && current != IntPtr.Zero; i++) {
                var name = new System.Text.StringBuilder(80);
                GetClassName(current, name, name.Capacity);
                string cls = name.ToString();
                if (cls == "Progman" || cls == "WorkerW") return first != IntPtr.Zero;
                current = GetAncestor(current, 1);
            }
            return false;
        }
        public static bool IsEmptyDesktopSpot(int x, int y) {
            Point pt = new Point { x=x, y=y };
            IntPtr first = WindowFromPoint(pt);
            if (first == IntPtr.Zero) return false;
            var name = new System.Text.StringBuilder(80);
            GetClassName(first, name, name.Capacity);
            if (name.ToString() == "SysListView32") return IsEmptyListView(first, pt);
            return IsDesktop(x, y);
        }
        private static bool IsEmptyListView(IntPtr list, Point screenPoint) {
            Point client = screenPoint;
            if (ScreenToClient(list, ref client) == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(list, out pid);
            IntPtr process = OpenProcess(0x0008 | 0x0020, false, pid);
            if (process == IntPtr.Zero) return false;
            IntPtr remote = IntPtr.Zero;
            try {
                HitTestInfo info = new HitTestInfo { point=client, item=-1 };
                UIntPtr size = new UIntPtr((uint)Marshal.SizeOf(typeof(HitTestInfo))), written;
                remote = VirtualAllocEx(process, IntPtr.Zero, size, 0x1000 | 0x2000, 0x04);
                if (remote == IntPtr.Zero || !WriteProcessMemory(process, remote, ref info, size, out written)) return false;
                UIntPtr result;
                IntPtr sent = SendMessageTimeout(list, 0x1012, IntPtr.Zero, remote, 0x0002, 300, out result);
                return sent != IntPtr.Zero && unchecked((int)result.ToUInt64()) == -1;
            } finally {
                if (remote != IntPtr.Zero) VirtualFreeEx(process, remote, UIntPtr.Zero, 0x8000);
                CloseHandle(process);
            }
        }
        private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0 && Handler != null) {
                try {
                    MouseInfo info = (MouseInfo)Marshal.PtrToStructure(lParam, typeof(MouseInfo));
                    if ((info.flags & 1) == 0 && Handler((uint)wParam.ToInt32(), info.point.x, info.point.y, info.time))
                        return new IntPtr(1);
                } catch { }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
}
'@

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

function Write-Log([string]$Message) {
    try { Add-Content -LiteralPath $script:LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8 } catch {}
}

function Get-DefaultConfig {
    [pscustomobject]@{
        general = [pscustomobject]@{ double_click_ms = 0 }
        clipboard = [pscustomobject]@{ max_items = 20; group_size = 10 }
        folder_menu = [pscustomobject]@{ max_entries = 50; show_hidden = $false; history_max = 10; show_icons = $true }
        application_menu = [pscustomobject]@{ layout = 'vertical' }
        folders = @()
        applications = @()
    }
}

function ConvertFrom-TomlValue([string]$Value) {
    $v = $Value.Trim()
    if ($v -match '^(true|false)$') { return [bool]::Parse($v) }
    if ($v -match '^-?\d+$') { return [int]$v }
    if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[$v.Length - 1] -eq "'") {
        return $v.Substring(1, $v.Length - 2).Replace("''", "'")
    }
    if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[$v.Length - 1] -eq '"') {
        try { return (ConvertFrom-Json -InputObject $v -ErrorAction Stop) } catch { throw "Invalid TOML string: $v" }
    }
    throw "Unsupported TOML value: $v"
}

function Remove-TomlComment([string]$Line) {
    $quote = [char]0
    $escaped = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($quote -eq '"') {
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\') { $escaped = $true; continue }
            if ($ch -eq '"') { $quote = [char]0; continue }
        } elseif ($quote -eq "'") {
            if ($ch -eq "'") { $quote = [char]0; continue }
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
        } elseif ($ch -eq '#') {
            return $Line.Substring(0, $i)
        }
    }
    return $Line
}

function Read-LauncherConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { Write-DefaultConfig }
    $cfg = Get-DefaultConfig
    $section = ''
    $item = $null
    foreach ($line in [IO.File]::ReadAllLines($script:ConfigPath, [Text.Encoding]::UTF8)) {
        $s = (Remove-TomlComment $line).Trim()
        if (-not $s) { continue }
        if ($s -match '^\[\[([A-Za-z_]+)\]\]$') {
            $section = $Matches[1]
            if ($section -notin @('folders','applications')) { throw "Unsupported array section: $section" }
            $item = [pscustomobject]@{ name = ''; path = '' }
            $cfg.$section = @($cfg.$section) + @($item)
            continue
        }
        if ($s -match '^\[([A-Za-z_]+)\]$') { $section = $Matches[1]; $item = $null; continue }
        if ($s -match '^([A-Za-z_]+)\s*=\s*(.+)$') {
            $key = $Matches[1]; $raw = $Matches[2]
            $value = ConvertFrom-TomlValue $raw
            if ($section -in @('folders','applications')) {
                if ($null -eq $item) { throw "Key outside array table: $key" }
                $item | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
            } elseif ($section -in @('general','clipboard','folder_menu','application_menu')) {
                if ($null -eq $cfg.$section) { throw "Unknown TOML section: $section" }
                $cfg.$section | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
            } else { throw "Unknown TOML section: $section" }
            continue
        }
        throw "Cannot parse config.toml line: $s"
    }
    $cfg.clipboard.max_items = [Math]::Max(1, [Math]::Min(500, [int]$cfg.clipboard.max_items))
    $cfg.clipboard.group_size = [Math]::Max(1, [Math]::Min(50, [int]$cfg.clipboard.group_size))
    $cfg.folder_menu.max_entries = [Math]::Max(10, [Math]::Min(1000, [int]$cfg.folder_menu.max_entries))
    $cfg.folder_menu.history_max = [Math]::Max(0, [Math]::Min(100, [int]$cfg.folder_menu.history_max))
    $cfg.general.double_click_ms = [Math]::Max(0, [Math]::Min(5000, [int]$cfg.general.double_click_ms))
    if ($cfg.application_menu.layout -notin @('vertical','horizontal')) { $cfg.application_menu.layout = 'vertical' }
    return $cfg
}

function Write-DefaultConfig {
    $text = @'
# RClauncher settings (UTF-8)
[general]
double_click_ms = 0

[clipboard]
max_items = 20
group_size = 10

[folder_menu]
max_entries = 50
show_hidden = false
history_max = 10
show_icons = true

[application_menu]
layout = "vertical"

[[folders]]
name = "ドキュメント"
path = '%USERPROFILE%\Documents'

[[folders]]
name = "ダウンロード"
path = '%USERPROFILE%\Downloads'

[[applications]]
name = "メモ帳"
path = '%WINDIR%\System32\notepad.exe'
'@
    [IO.File]::WriteAllText($script:ConfigPath, $text + "`r`n", [Text.UTF8Encoding]::new($false))
}

function ConvertTo-TomlString([string]$Value) {
    return '"' + $Value.Replace('\','\\').Replace('"','\"').Replace("`b",'\b').Replace("`t",'\t').Replace("`n",'\n').Replace("`f",'\f').Replace("`r",'\r') + '"'
}

function Save-LauncherConfig($Cfg) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# RClauncher settings (UTF-8)')
    $lines.Add('[general]'); $lines.Add("double_click_ms = $([int]$Cfg.general.double_click_ms)")
    $lines.Add(''); $lines.Add('[clipboard]')
    $lines.Add("max_items = $([int]$Cfg.clipboard.max_items)")
    $lines.Add("group_size = $([int]$Cfg.clipboard.group_size)")
    $lines.Add(''); $lines.Add('[folder_menu]')
    $lines.Add("max_entries = $([int]$Cfg.folder_menu.max_entries)")
    $lines.Add("show_hidden = $(([bool]$Cfg.folder_menu.show_hidden).ToString().ToLowerInvariant())")
    $lines.Add("history_max = $([int]$Cfg.folder_menu.history_max)")
    $lines.Add("show_icons = $(([bool]$Cfg.folder_menu.show_icons).ToString().ToLowerInvariant())")
    $lines.Add(''); $lines.Add('[application_menu]')
    $lines.Add("layout = $(ConvertTo-TomlString ([string]$Cfg.application_menu.layout))")
    foreach ($table in @('applications','folders')) {
        foreach ($entry in @($Cfg.$table)) {
            $lines.Add('')
            $lines.Add("[[$table]]")
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.name)) { $lines.Add("name = $(ConvertTo-TomlString ([string]$entry.name))") }
            $lines.Add("path = $(ConvertTo-TomlString ([string]$entry.path))")
        }
    }
    $tempPath = $script:ConfigPath + '.tmp'
    [IO.File]::WriteAllLines($tempPath, $lines, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
    $script:LastConfigWrite = (Get-Item -LiteralPath $script:ConfigPath).LastWriteTimeUtc
}

function Expand-LauncherPath([string]$Path) {
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Escape-HistoryLine([string]$Text) {
    return $Text.Replace('\','\\').Replace("`r",'\r').Replace("`n",'\n')
}

function Unescape-HistoryLine([string]$Text) {
    $builder = [Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq '\' -and $i + 1 -lt $Text.Length) {
            $i++
            switch ($Text[$i]) {
                'n' { [void]$builder.Append("`n") }
                'r' { [void]$builder.Append("`r") }
                '\' { [void]$builder.Append('\') }
                default { [void]$builder.Append('\'); [void]$builder.Append($Text[$i]) }
            }
        } else { [void]$builder.Append($Text[$i]) }
    }
    return $builder.ToString()
}

function Save-ClipboardHistory {
    $lines = @($script:History | Select-Object -Last $script:Config.clipboard.max_items)
    [Array]::Reverse($lines)
    $encoded = @($lines | ForEach-Object { Escape-HistoryLine $_ })
    [IO.File]::WriteAllLines($script:ClipboardHistoryPath, $encoded, [Text.UTF8Encoding]::new($false))
}

function Add-ClipboardHistory([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt $script:MaxTextChars) { return }
    if ($script:History.Count -gt 0 -and $script:History[0] -ceq $Text) { return }
    for ($i = $script:History.Count - 1; $i -ge 0; $i--) {
        if ($script:History[$i] -ceq $Text) { $script:History.RemoveAt($i) }
    }
    $script:History.Insert(0, $Text)
    while ($script:History.Count -gt $script:Config.clipboard.max_items) { $script:History.RemoveAt($script:History.Count - 1) }
    Save-ClipboardHistory
}

function Read-HistoryFiles {
    New-Item -ItemType Directory -Force -Path $script:ClipboardDir, $script:FolderHistoryDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:ClipboardHistoryPath)) { [IO.File]::WriteAllText($script:ClipboardHistoryPath, '', [Text.UTF8Encoding]::new($false)) }
    $script:History.Clear()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in [IO.File]::ReadAllLines($script:ClipboardHistoryPath, [Text.Encoding]::UTF8)) {
        $text = Unescape-HistoryLine $line
        if (-not [string]::IsNullOrWhiteSpace($text) -and $seen.Add($text)) { $script:History.Add($text) }
    }
    $script:History.Reverse()
    while ($script:History.Count -gt $script:Config.clipboard.max_items) { $script:History.RemoveAt($script:History.Count - 1) }
    $script:FolderHistory.Clear()
    if (Test-Path -LiteralPath $script:FolderHistoryPath) {
        foreach ($line in [IO.File]::ReadAllLines($script:FolderHistoryPath, [Text.Encoding]::UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($line) -and -not $script:FolderHistory.Contains($line)) { $script:FolderHistory.Add($line) }
        }
    }
}

function Save-FolderHistory {
    [IO.File]::WriteAllLines($script:FolderHistoryPath, $script:FolderHistory, [Text.UTF8Encoding]::new($false))
}

function Set-MenuState([bool]$Visible) { $script:MenuVisible = $Visible }

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
        Set-MenuState $false
        if ($script:CurrentPopupMenu -eq $this) { $script:CurrentPopupMenu = $null }
    })
    $menu.Add_Opened({ Set-MenuState $true; $script:CurrentPopupMenu = $this })
    return $menu
}

function Get-FolderChildren([string]$Path) {
    try {
        $items = Get-ChildItem -LiteralPath $Path -Directory -Force:$script:Config.folder_menu.show_hidden -ErrorAction Stop
        if (-not $script:Config.folder_menu.show_hidden) { $items = $items | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::Hidden) -and -not ($_.Attributes -band [IO.FileAttributes]::System) } }
        return @($items | Sort-Object Name | Select-Object -First $script:Config.folder_menu.max_entries)
    } catch { Write-Log "Cannot list folders '$Path': $_"; return @() }
}

function Add-FolderSubmenu([Windows.Forms.ToolStripMenuItem]$Item, [string]$Path, [int]$Depth) {
    if ($Depth -ge 16) { return }
    $Item.Tag = $Path
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
            $menu.Add_Opened({ Set-MenuState $true; $script:CurrentPopupMenu = $this })
            $menu.Add_Closed({
                Set-MenuState $false
                if ($script:CurrentPopupMenu -eq $this) { $script:CurrentPopupMenu = $null }
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
    $menu.Add_Closed({ Set-MenuState $false })
    $menu.Add_Opened({ Set-MenuState $true })
    $menu.Add_Closed({
        if ($script:CurrentPopupMenu -eq $this) { $script:CurrentPopupMenu = $null }
        foreach ($menuItem in $this.Items) {
            if ($menuItem -is [Windows.Forms.ToolStripControlHost] -and $menuItem.Tag) { $menuItem.Tag.Dispose() }
        }
        $script:CurrentFolderMenu = $null
    })
    $menu.Add_Closed({ Set-MenuState $false })
    $menu.Add_Opened({ Set-MenuState $true; $script:CurrentPopupMenu = $this })
    return $menu
}

function Show-ClipMenu([int]$X, [int]$Y) {
    if ($script:MenuVisible) { return }
    $menu = New-ClipMenu
    $script:CurrentPopupMenu = $menu
    Set-MenuState $true
    $menu.Show([Drawing.Point]::new($X, $Y))
}

function Show-FolderMenu([int]$X, [int]$Y) {
    if ($script:MenuVisible) { return }
    $menu = New-FolderMenu
    $script:CurrentFolderMenu = $menu
    $script:CurrentPopupMenu = $menu
    Set-MenuState $true
    $menu.Show([Drawing.Point]::new($X, $Y))
}

function New-EditorDialog {
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = 'RClauncher 設定'
    $dialog.Size = [Drawing.Size]::new(700, 500)
    $dialog.StartPosition = 'CenterScreen'
    $tabs = [Windows.Forms.TabControl]::new()
    $tabs.Anchor = 'Top,Bottom,Left,Right'
    [void]$dialog.Controls.Add($tabs)
    $folderTab = [Windows.Forms.TabPage]::new('フォルダ')
    $appTab = [Windows.Forms.TabPage]::new('アプリ')
    $generalTab = [Windows.Forms.TabPage]::new('一般')
    [void]$tabs.TabPages.AddRange(@($folderTab,$appTab,$generalTab))
    $models = @{}
    foreach ($spec in @(@{tab=$folderTab;key='folders';title='登録フォルダ'},@{tab=$appTab;key='applications';title='登録アプリ'})) {
        $layout = [Windows.Forms.TableLayoutPanel]::new()
        $layout.Dock = 'Fill'
        $layout.Padding = [Windows.Forms.Padding]::new(10)
        $layout.ColumnCount = 1
        $layout.RowCount = 3
        [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
        [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,24))
        [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
        [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,42))
        $label = [Windows.Forms.Label]::new()
        $label.Text = $spec.title
        $label.Dock = 'Fill'
        $label.TextAlign = 'MiddleLeft'
        $list = [Windows.Forms.ListBox]::new()
        $list.Dock = 'Fill'
        $list.IntegralHeight = $false
        $actions = [Windows.Forms.FlowLayoutPanel]::new()
        $actions.Dock = 'Fill'
        $actions.FlowDirection = 'LeftToRight'
        $actions.WrapContents = $false
        $actions.AutoScroll = $true
        [void]$layout.Controls.Add($label,0,0)
        [void]$layout.Controls.Add($list,0,1)
        [void]$layout.Controls.Add($actions,0,2)
        [void]$spec.tab.Controls.Add($layout)
        $models[$spec.key] = [Collections.ArrayList]::new()
        foreach ($entry in @($script:Config.($spec.key))) { [void]$models[$spec.key].Add([pscustomobject]@{name=[string]$entry.name;path=[string]$entry.path}) }
        $refresh = {
            $list.Items.Clear()
            foreach ($entry in $models[$spec.key]) { [void]$list.Items.Add($(if ($entry.name) { "$($entry.name) — $($entry.path)" } else { $entry.path })) }
        }.GetNewClosure()
        & $refresh
        $list.Tag = @{key=$spec.key; models=$models; refresh=$refresh}
        $add = [Windows.Forms.Button]::new(); $add.Text='追加'; $add.Size=[Drawing.Size]::new(74,27); $add.Margin=[Windows.Forms.Padding]::new(3)
        $edit = [Windows.Forms.Button]::new(); $edit.Text='編集'; $edit.Size=[Drawing.Size]::new(74,27); $edit.Margin=[Windows.Forms.Padding]::new(3)
        $remove = [Windows.Forms.Button]::new(); $remove.Text='削除'; $remove.Size=[Drawing.Size]::new(74,27); $remove.Margin=[Windows.Forms.Padding]::new(3)
        $up = [Windows.Forms.Button]::new(); $up.Text='上へ'; $up.Size=[Drawing.Size]::new(74,27); $up.Margin=[Windows.Forms.Padding]::new(3)
        $down = [Windows.Forms.Button]::new(); $down.Text='下へ'; $down.Size=[Drawing.Size]::new(74,27); $down.Margin=[Windows.Forms.Padding]::new(3)
        $add.Tag=$list; $edit.Tag=$list; $remove.Tag=$list; $up.Tag=$list; $down.Tag=$list
        $add.Add_Click([EventHandler]{
            param($sender,$eventArgs)
            $l=$sender.Tag; $key=$l.Tag.key
            $path=''
            if ($key -eq 'folders') { $pick=[Windows.Forms.FolderBrowserDialog]::new(); if ($pick.ShowDialog() -eq 'OK') { $path=$pick.SelectedPath } }
            else { $pick=[Windows.Forms.OpenFileDialog]::new(); $pick.Filter='Applications and shortcuts|*.exe;*.lnk;*.bat;*.cmd|All files|*.*'; if ($pick.ShowDialog() -eq 'OK') { $path=$pick.FileName } }
            if (-not $path) { return }
            $name=[IO.Path]::GetFileNameWithoutExtension($path)
            $value=[Microsoft.VisualBasic.Interaction]::InputBox('表示名 (空欄可)', 'RClauncher', $name)
            [void]$l.Tag.models[$key].Add([pscustomobject]@{name=$value;path=$path}); & $l.Tag.refresh
        })
        $edit.Add_Click([EventHandler]{
            param($sender,$eventArgs)
            $l=$sender.Tag; $idx=$l.SelectedIndex; if ($idx -lt 0) { return }
            $entry=$l.Tag.models[$l.Tag.key][$idx]
            $name=[Microsoft.VisualBasic.Interaction]::InputBox('表示名', 'RClauncher', $entry.name)
            $path=[Microsoft.VisualBasic.Interaction]::InputBox('パス', 'RClauncher', $entry.path)
            if ($path) { $entry.name=$name; $entry.path=$path; & $l.Tag.refresh; $l.SelectedIndex=$idx }
        })
        $remove.Add_Click([EventHandler]{
            param($sender,$eventArgs)
            $l=$sender.Tag; $idx=$l.SelectedIndex
            if ($idx -ge 0) { $l.Tag.models[$l.Tag.key].RemoveAt($idx); & $l.Tag.refresh }
        })
        $up.Add_Click([EventHandler]{
            param($sender,$eventArgs)
            $l=$sender.Tag; $idx=$l.SelectedIndex
            if ($idx -gt 0) { $x=$l.Tag.models[$l.Tag.key][$idx]; $l.Tag.models[$l.Tag.key].RemoveAt($idx); $l.Tag.models[$l.Tag.key].Insert($idx-1,$x); & $l.Tag.refresh; $l.SelectedIndex=$idx-1 }
        })
        $down.Add_Click([EventHandler]{
            param($sender,$eventArgs)
            $l=$sender.Tag; $idx=$l.SelectedIndex; $m=$l.Tag.models[$l.Tag.key]
            if ($idx -ge 0 -and $idx -lt $m.Count-1) { $x=$m[$idx]; $m.RemoveAt($idx); $m.Insert($idx+1,$x); & $l.Tag.refresh; $l.SelectedIndex=$idx+1 }
        })
        [void]$actions.Controls.AddRange(@($add,$edit,$remove,$up,$down))
    }
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
    $controls = @{}
    foreach ($spec in @(
        @{key='double_click_ms';section='general';label='クリック間隔 (ms, 0=Windows標準)';min=0;max=5000},
        @{key='max_items';section='clipboard';label='クリップボード履歴数';min=1;max=500},
        @{key='group_size';section='clipboard';label='直接表示件数';min=1;max=50},
        @{key='max_entries';section='folder_menu';label='フォルダ一覧の最大件数';min=10;max=1000},
        @{key='history_max';section='folder_menu';label='フォルダ履歴数';min=0;max=100}
    )) {
        $label=[Windows.Forms.Label]::new(); $label.Text=$spec.label; $label.Location=[Drawing.Point]::new(18,18 + $controls.Count*42); $label.AutoSize=$true
        $num=[Windows.Forms.NumericUpDown]::new(); $num.Minimum=$spec.min; $num.Maximum=$spec.max; $num.Value=[decimal][int]$script:Config.($spec.section).($spec.key); $num.Location=[Drawing.Point]::new(350,15 + $controls.Count*42); $num.Width=120
        $generalTab.Controls.AddRange(@($label,$num)); $controls["$($spec.section).$($spec.key)"]=$num
    }
    foreach ($spec in @(@{key='show_hidden';label='隠しフォルダを表示'},@{key='show_icons';label='アイコンを表示'})) {
        $cb=[Windows.Forms.CheckBox]::new(); $cb.Text=$spec.label; $cb.Checked=[bool]$script:Config.folder_menu.($spec.key); $cb.Location=[Drawing.Point]::new(18,240 + $(if($spec.key -eq 'show_icons'){32}else{0})); $cb.AutoSize=$true; $generalTab.Controls.Add($cb); $controls["folder_menu.$($spec.key)"]=$cb
    }
    $layout=[Windows.Forms.CheckBox]::new(); $layout.Text='アプリを横一列で表示'; $layout.Checked=($script:Config.application_menu.layout -eq 'horizontal'); $layout.Location=[Drawing.Point]::new(18,310); $layout.AutoSize=$true; $generalTab.Controls.Add($layout); $controls['layout']=$layout
    $footerHeight = 48
    $client = $dialog.ClientSize
    $tabs.Location = [Drawing.Point]::new(0,0)
    $tabs.Size = [Drawing.Size]::new($client.Width,$client.Height-$footerHeight)
    $footer = [Windows.Forms.Panel]::new()
    $footer.Location = [Drawing.Point]::new(0,$client.Height-$footerHeight)
    $footer.Size = [Drawing.Size]::new($client.Width,$footerHeight)
    $footer.Anchor = 'Bottom,Left,Right'
    $hint = [Windows.Forms.Label]::new()
    $hint.Text = '変更後は「保存して閉じる」を押してください。'
    $hint.AutoSize = $true
    $hint.Location = [Drawing.Point]::new(12,16)
    [void]$footer.Controls.Add($hint)
    $ok=[Windows.Forms.Button]::new(); $ok.Text='保存して閉じる'; $ok.DialogResult='OK'; $ok.Location=[Drawing.Point]::new($client.Width-215,11); $ok.Size=[Drawing.Size]::new(125,27); $ok.Anchor='Top,Right'
    $ok.Add_Click([EventHandler]{
        param($sender,$eventArgs)
        $form=$sender.FindForm()
        $form.DialogResult=[Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $cancel=[Windows.Forms.Button]::new(); $cancel.Text='キャンセル'; $cancel.DialogResult='Cancel'; $cancel.Location=[Drawing.Point]::new($client.Width-82,11); $cancel.Size=[Drawing.Size]::new(70,27); $cancel.Anchor='Top,Right'
    $cancel.Add_Click([EventHandler]{
        param($sender,$eventArgs)
        $form=$sender.FindForm()
        $form.DialogResult=[Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    [void]$footer.Controls.AddRange(@($ok,$cancel))
    [void]$dialog.Controls.Add($footer)
    $dialog.AcceptButton=$null; $dialog.CancelButton=$cancel
    $dialog.Tag=@{models=$models;controls=$controls}
    return $dialog
}

function Show-Settings {
    $dialog = New-EditorDialog
    try {
        if ($dialog.ShowDialog($script:Form) -ne [Windows.Forms.DialogResult]::OK) { return }
        foreach ($key in @('folders','applications')) { $script:Config.$key = @($dialog.Tag.models[$key] | ForEach-Object { [pscustomobject]@{name=$_.name;path=$_.path} }) }
        foreach ($key in @('general.double_click_ms','clipboard.max_items','clipboard.group_size','folder_menu.max_entries','folder_menu.history_max')) {
            $parts=$key.Split('.'); $script:Config.($parts[0]).($parts[1])=[int]$dialog.Tag.controls[$key].Value
        }
        $script:Config.folder_menu.show_hidden=[bool]$dialog.Tag.controls['folder_menu.show_hidden'].Checked
        $script:Config.folder_menu.show_icons=[bool]$dialog.Tag.controls['folder_menu.show_icons'].Checked
        $script:Config.application_menu.layout=if($dialog.Tag.controls.layout.Checked){'horizontal'}else{'vertical'}
        Save-LauncherConfig $script:Config
        while ($script:History.Count -gt $script:Config.clipboard.max_items) { $script:History.RemoveAt($script:History.Count-1) }
        Save-ClipboardHistory
    } catch {
        Write-Log "Settings save failed: $_"
        [Windows.Forms.MessageBox]::Show("設定を保存できませんでした:`r`n$_",'RClauncher','OK','Error') | Out-Null
    } finally { $dialog.Dispose() }
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
    $menu.Add_Opened({ Set-MenuState $true; $script:CurrentPopupMenu = $this })
    $menu.Add_Closed({
        Set-MenuState $false
        if ($script:CurrentPopupMenu -eq $this) { $script:CurrentPopupMenu = $null }
    })
}

function Invoke-MouseHook([uint32]$Message, [int]$X, [int]$Y, [uint32]$Time) {
    if ($script:MenuVisible) {
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

try { Start-Launcher } catch {
    Write-Log "Fatal error: $_"
    [Windows.Forms.MessageBox]::Show("RClauncher の起動に失敗しました:`r`n$_",'RClauncher','OK','Error') | Out-Null
}
