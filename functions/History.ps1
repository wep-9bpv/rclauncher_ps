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
