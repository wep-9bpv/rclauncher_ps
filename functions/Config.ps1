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
