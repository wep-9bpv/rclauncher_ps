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
