<#
    WinDebloat Live - Windows Forms GUI (Windows PowerShell 5.1 / .NET Framework 4.x).
    Work runs in a background runspace; a timer pumps log lines and progress into the window, so the UI never
    blocks. Controls and windows come from lib\WdlUi.cs (Material 3 Expressive, light/dark, high DPI).
    SPDX-License-Identifier: MIT
#>

#region ---------- languages, settings, fonts, UI library ----------
$script:WdlLangs = @(
    @{ Code = 'vi'; Name = 'Tiếng Việt' }
    @{ Code = 'en'; Name = 'English' }
    @{ Code = 'zh-CN'; Name = '简体中文' }
    @{ Code = 'km'; Name = 'ភាសាខ្មែរ' }
)

function Import-WdlLang {
    # lang\<code>.psd1 (UTF-8 BOM, data only) -> hashtable; empty when missing / broken
    param([string]$Code)
    $dir = Join-Path $script:WdlRoot 'lang'
    if (-not $Code -or -not (Test-WdlPathText (Join-Path $dir "$Code.psd1") -Leaf)) { return @{} }
    try {
        $t = $null
        Import-LocalizedData -BaseDirectory $dir -FileName $Code -BindingVariable t -UICulture 'en-US' -ErrorAction Stop
        if ($t -is [hashtable]) { return $t }
    } catch { $null = $_ }
    return @{}
}

function Get-WdlDefaultLanguage {
    # Vietnamese until the user picks and saves another language
    return 'vi'
}

function Set-WdlLanguage {
    param([string]$Code)
    if (-not (@($script:WdlLangs | ForEach-Object { $_.Code }) -contains $Code)) { $Code = Get-WdlDefaultLanguage }
    $script:UiLang = $Code
    $script:LEn = Import-WdlLang 'en'
    if ($Code -eq 'en') { $script:L = $script:LEn } else { $script:L = Import-WdlLang $Code }
    if ($script:Sync) { $script:Sync.UiLang = $Code }
}

function T {
    # T 'key' [arg0 arg1 ...] -> text in the UI language (fallback English, then the key itself)
    param([string]$Key)
    $s = $null
    if ($script:L -and $script:L.ContainsKey($Key)) { $s = [string]$script:L[$Key] }
    if (-not $s -and $script:LEn -and $script:LEn.ContainsKey($Key)) { $s = [string]$script:LEn[$Key] }
    if (-not $s) { $s = $Key }
    $s = $s.Replace('\n', "`n")
    if ($args.Count -gt 0) { try { $s = $s -f $args } catch { $s = $s + ' ' + ($args -join ' ') } }
    return $s
}

function Get-WdlFontFor {
    # first installed font that can show the language (Khmer / Chinese need their own fonts)
    param([string]$Code, [string[]]$Installed)
    switch ($Code) {
        'zh-CN' { $c = @('Microsoft YaHei UI', 'Microsoft YaHei', 'SimSun', 'Segoe UI') }
        'km' { $c = @('Leelawadee UI', 'Khmer UI', 'DaunPenh', 'Segoe UI') }
        default { $c = @('Segoe UI', 'Tahoma', 'Microsoft Sans Serif') }
    }
    foreach ($n in $c) { if (@($Installed) -contains $n) { return $n } }
    return $c[$c.Count - 1]
}

function Get-WdlSettingsPath { return (Join-Path (Get-WdlDataDir) 'settings.psd1') }

function Read-WdlSettings {
    $p = Get-WdlSettingsPath
    if (-not (Test-WdlPathText $p -Leaf)) { return @{} }
    try {
        $t = $null
        Import-LocalizedData -BaseDirectory (Split-Path -Parent $p) -FileName 'settings' -BindingVariable t -UICulture 'en-US' -ErrorAction Stop
        if ($t -is [hashtable]) { return $t }
    } catch { $null = $_ }
    return @{}
}

function Save-WdlSettings {
    param([hashtable]$Settings)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("# WinDebloat Live settings (written by the tool)`r`n@{`r`n")
    foreach ($k in @($Settings.Keys | Sort-Object)) {
        if ($k -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
        [void]$sb.Append(("    {0} = '{1}'`r`n" -f $k, ([string]$Settings[$k]).Replace("'", "''")))
    }
    [void]$sb.Append("}`r`n")
    try { [IO.File]::WriteAllText((Get-WdlSettingsPath), $sb.ToString(), (New-Object Text.UTF8Encoding $true)) } catch { $null = $_ }
}

function Initialize-WdlUiLib {
    # compiles lib\WdlUi.cs once per process (C# 5, .NET Framework 4.x); the Material controls and windows live there
    if (-not ('WdlUi.Theme' -as [type])) {
        $src = [IO.File]::ReadAllText((Join-Path $script:WdlRoot 'lib\WdlUi.cs'))
        Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -ErrorAction Stop
    }
    [WdlUi.Theme]::EnableDpiAwareness()
    [WdlUi.Theme]::Tr = [Func[string, string]] { param($k) T $k }
    [WdlUi.Theme]::Init([WdlUi.Theme]::DetectDark(), (Join-Path $script:WdlRoot 'assets\icons'))
    Set-WdlUiFont
}

function Set-WdlUiFont {
    # Latin / Vietnamese: Segoe UI Variable or Segoe UI; Khmer and Chinese need a font with their script
    $fam = $null
    if (@('km', 'zh-CN') -contains $script:UiLang) { $fam = Get-WdlFontFor -Code $script:UiLang -Installed $script:InstalledFonts }
    [WdlUi.Theme]::SetFamily($fam)
}
#endregion

#region ---------- background jobs ----------
function Get-WdlJobText {
    <# Script text for a background runspace: the engine libs as text (independent of the execution policy),
       then $Script inside try/catch; errors land in $sync.Error and the log. #>
    param([string]$Script, [string[]]$Libs = @('Common', 'Rules', 'Plan', 'System', 'Engine'))
    $sb = New-Object Text.StringBuilder
    foreach ($l in $Libs) { [void]$sb.Append([IO.File]::ReadAllText((Join-Path $script:WdlRoot "lib\$l.ps1"))); [void]$sb.Append("`r`n") }
    [void]$sb.Append(@'
$script:WdlRoot = $WdlRootPath
$script:WDL.Sync = $sync
if ($WdlLogPath) { $script:WDL.LogPath = $WdlLogPath }
$ErrorActionPreference = 'Stop'
try {
'@)
    [void]$sb.Append("`r`n" + $Script + "`r`n")
    [void]$sb.Append(@'
} catch {
    $sync.Error = $_.Exception.Message
    if (-not ($_.Exception -is [OperationCanceledException])) {
        Write-WdlLog -Level ERROR -En $_.Exception.Message
        $detail = $_.Exception.ToString()
        if ($_.ScriptStackTrace) { $detail += "`r`n" + $_.ScriptStackTrace }
        if ($script:WDL.LogPath) { try { [IO.File]::AppendAllText($script:WDL.LogPath, '    ' + $detail + "`r`n") } catch { $null = $_ } }
    } else { $sync.Cancelled = $true; Write-WdlLog -Level WARN -En 'Cancelled' -Vi 'Đã huỷ' }
}
'@)
    return $sb.ToString()
}

function Start-WdlJob {
    <# Runs $Script in a background runspace with $sync and $JobArgs. One task at a time. #>
    param([string]$Script, [hashtable]$JobArgs = @{}, [scriptblock]$OnDone, [string]$Name = 'task', [string]$Status)
    if ($script:Job) { Show-WdlMsg (T 'msg.jobRunning') 'Warning' | Out-Null; return $false }
    $script:Sync.Cancel = $false; $script:Sync.Cancelled = $false; $script:Sync.Error = $null; $script:Sync.Result = $null
    $script:Sync.Percent = 0; $script:Sync.Status = ''
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('JobArgs', $JobArgs)
    $rs.SessionStateProxy.SetVariable('WdlRootPath', $script:WdlRoot)
    $rs.SessionStateProxy.SetVariable('WdlLogPath', $script:WDL.LogPath)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript((Get-WdlJobText -Script $Script))
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Name = $Name }
    if ($Status) { $script:ui.lblStatus.Text = $Status }
    Set-WdlBusy $true
    return $true
}

function Start-WdlRulesUpdate {
    # rules check in its own runspace (at most 10 s); never blocks the UI or a task. -Manual: from the button
    param([switch]$Manual)
    if ($script:RulesJob) { return }
    if (-not $Manual -and [string]$script:Settings.RulesAutoUpdate -eq '0') { Write-WdlLog -En 'Rules auto-update is off' -Vi 'Đã tắt tự cập nhật bộ quy tắc'; return }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $rs.SessionStateProxy.SetVariable('WdlRootPath', $script:WdlRoot)
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $txt = [IO.File]::ReadAllText((Join-Path $script:WdlRoot 'lib\Common.ps1')) + "`r`n" + [IO.File]::ReadAllText((Join-Path $script:WdlRoot 'lib\Rules.ps1'))
        [void]$ps.AddScript($txt + "`r`n" + '$script:WdlRoot = $WdlRootPath' + "`r`n" + 'Update-WdlRules')
        $script:RulesJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Clock = [Diagnostics.Stopwatch]::StartNew(); Manual = [bool]$Manual }
        if ($Manual -and $script:ui) { $script:ui.btnRulesCheck.Enabled = $false; $script:ui.lblStatus.Text = T 'status.rulesChecking' }
    } catch { Write-WdlLog -En "Rules check not started: $($_.Exception.Message)" -Vi 'Không chạy được kiểm tra bộ quy tắc' }
}

function Invoke-WdlRulesTick {
    $j = $script:RulesJob
    if (-not $j) { return }
    $r = $null
    if (-not $j.Handle.IsCompleted) {
        if ($j.Clock.ElapsedMilliseconds -lt $script:WDL.RulesTimeoutMs + 2000) { return }
        $script:RulesJob = $null
        try { [void]$j.PS.BeginStop($null, $null) } catch { $null = $_ }
        $r = New-WdlObj @{ Status = 'Timeout'; Version = ''; Dir = ''; Error = 'no answer within the time limit' }
    } else {
        $script:RulesJob = $null
        try { $out = @($j.PS.EndInvoke($j.Handle)); if ($out.Count) { $r = $out[$out.Count - 1] } } catch { $null = $_ }
        try { $j.PS.Dispose(); $j.RS.Close() } catch { $null = $_ }
        if (-not $r -or -not $r.Status) { $r = New-WdlObj @{ Status = 'Failed'; Version = ''; Dir = ''; Error = 'rules check ended without a result' } }
    }
    Write-WdlRulesResult $r
    if ([string]$r.Status -eq 'Updated') { $script:RulesReload = $true }
    if ($j.Manual -and $script:ui) {
        $script:ui.btnRulesCheck.Enabled = $true
        $script:ui.lblStatus.Text = T (Get-WdlRulesResultKey $r) ([string]$r.Version)
    }
}

function Set-WdlBusy {
    param([bool]$Busy)
    foreach ($c in $script:BusyControls) { if ($c) { $c.Enabled = -not $Busy } }
    $script:ui.btnCancel.Enabled = $Busy
    if ($Busy) { $script:ui.form.Cursor = [Windows.Forms.Cursors]::AppStarting } else { $script:ui.form.Cursor = [Windows.Forms.Cursors]::Default; Update-WdlCommandStates }
}

function Invoke-WdlTick {
    try {
        Invoke-WdlRulesTick
        # the timer keeps ticking while a callback shows a modal dialog: never start a rescan from there
        if ($script:RulesReload -and -not $script:Job -and -not $script:InCallback) { $script:RulesReload = $false; Start-WdlScan }
        $q = $script:Sync.LogQueue
        $sb = New-Object Text.StringBuilder
        while ($q.Count -gt 0) { [void]$sb.Append([string]$q.Dequeue()); [void]$sb.Append("`r`n") }
        if ($sb.Length -gt 0) { $script:ui.tbLog.AppendText($sb.ToString()) }
        $j = $script:Job
        if (-not $j) { return }
        $p = [int]$script:Sync.Percent; if ($p -lt 0) { $p = 0 }; if ($p -gt 100) { $p = 100 }
        $script:ui.pb.Value = $p
        if ($script:Sync.Status) { $script:ui.lblStatus.Text = Get-WdlLocalText ([string]$script:Sync.Status) $script:UiLang }
        if (-not $j.Handle.IsCompleted) { return }
        $script:Job = $null
        try { [void]$j.PS.EndInvoke($j.Handle) } catch { if (-not $script:Sync.Error) { $script:Sync.Error = $_.Exception.Message } }
        try { foreach ($er in @($j.PS.Streams.Error)) { if ($er) { Write-WdlLog -Level WARN -En "[$($j.Name)] $er" } } } catch { $null = $_ }
        try { $j.PS.Dispose(); $j.RS.Close() } catch { $null = $_ }
        Invoke-WdlTick
        Set-WdlBusy $false
        if ($script:Sync.Cancelled) { $script:ui.lblStatus.Text = T 'status.cancelled'; return }
        if ($script:Sync.Error) { Show-WdlError -Context $j.Name -Message ([string]$script:Sync.Error); return }
        $script:ui.lblStatus.Text = T 'status.done'
        if ($j.OnDone) {
            $script:InCallback = $true
            try { & $j.OnDone } catch { Show-WdlError -Context $j.Name -ErrorRecord $_ } finally { $script:InCallback = $false }
        }
    } catch {
        if (-not $script:TickFailed) { $script:TickFailed = $true; Show-WdlError -Context 'UI timer' -ErrorRecord $_ }
    }
}
#endregion

#region ---------- messages ----------
function Show-WdlMsg {
    # themed message box; returns 'OK', 'Yes' or 'No'
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    $t = Get-WdlLocalText $Text $script:UiLang
    if (-not ('WdlUi.MessageDialog' -as [type])) {
        return [string][Windows.Forms.MessageBox]::Show($t, $script:WDL.Name, [Windows.Forms.MessageBoxButtons]$Buttons, [Windows.Forms.MessageBoxIcon]$Icon)
    }
    $glyph = switch ($Icon) { 'Warning' { 'Warning' } 'Error' { 'Error' } 'Question' { 'Question' } default { 'Info' } }
    $owner = $null
    if ($script:ui -and $script:ui.form -and $script:ui.form.Visible) { $owner = $script:ui.form }
    return [string][WdlUi.MessageDialog]::Show($owner, $t, $script:WDL.Name, ($Buttons -eq 'YesNo'), [WdlUi.Glyph]$glyph)
}


function Show-WdlError {
    # every failure in a handler or job callback ends here: log (with details) + message box, never silent
    param([string]$Context, $ErrorRecord, [string]$Message)
    $msg = $Message
    if ($ErrorRecord) {
        $msg = $ErrorRecord.Exception.Message
        try { Write-WdlLog -Level ERROR -En "[$Context] $msg" } catch { $null = $_ }
        $detail = $ErrorRecord.Exception.ToString()
        if ($ErrorRecord.ScriptStackTrace) { $detail += "`r`n" + $ErrorRecord.ScriptStackTrace }
        if ($script:WDL.LogPath) { try { [IO.File]::AppendAllText($script:WDL.LogPath, '    ' + $detail + "`r`n") } catch { $null = $_ } }
    }
    $msg = Get-WdlLocalText $msg $script:UiLang
    try { if ($script:ui -and $script:ui.lblStatus) { $script:ui.lblStatus.Text = T 'status.error' $msg } } catch { $null = $_ }
    $logTxt = ''; if ($script:WDL.LogPath) { $logTxt = "`n`n" + (T 'msg.logFile' $script:WDL.LogPath) }
    try { Show-WdlMsg ((T 'msg.error' $Context $msg) + $logTxt) 'Error' | Out-Null } catch { $null = $_ }
}

function Invoke-WdlHandler {
    # event handlers live in $script:H and run through here, so an exception can never vanish
    param([string]$Name, $HandlerArgs)
    try { & $script:H[$Name] $HandlerArgs }
    catch { Show-WdlError -Context $Name -ErrorRecord $_ }
}
#endregion

#region ---------- mode chooser ----------
function Show-WdlModeChooser {
    # 'Simple', 'Advanced' or '' (window closed)
    $d = New-Object WdlUi.ModeDialog
    try {
        $d.Text = T 'app.title' $script:WDL.Version
        $d.chkRemember.Checked = ([string]$script:Settings.RememberMode -eq '1')
        $d.ApplyTheme()
        [void]$d.ShowDialog()
        $mode = [string]$d.Chosen
        if ($mode) {
            $script:Settings.Mode = $mode
            if ($d.chkRemember.Checked) { $script:Settings.RememberMode = '1' } else { $script:Settings.RememberMode = '0' }
            Save-WdlSettings $script:Settings
        }
        return $mode
    } finally { $d.Dispose() }
}
#endregion

#region ---------- main window ----------
function Set-WdlUiTexts {
    # (re)applies the UI language: fonts, tagged texts ('@key' in .Tag), formatted texts
    $ui = $script:ui
    Set-WdlUiFont
    $ui.form.ApplyTheme()
    $ui.form.Text = T 'app.title' $script:WDL.Version
    $drive = $env:SystemDrive; if (-not $drive) { $drive = 'C:' }
    $ui.chkProtect.Text = T 'chk.protect' $drive
    $ui.cbPreset.SetTexts(@((T 'preset.recommended'), (T 'preset.aggressive')))
    if ($ui.cbPreset.SelectedIndex -lt 0) { $ui.cbPreset.SelectedIndex = 0 }
    $ui.tip.SetToolTip($ui.cbLang, (T 'tip.uiLang'))
    $ui.tip.SetToolTip($ui.chkRules, (T 'tip.rulesUpdate'))
    $ui.tip.SetToolTip($ui.chkDefaultUser, (T 'tip.defaultUser'))
    $ui.tip.SetToolTip($ui.chkProtect, (T 'tip.protect'))
    Update-WdlSessionTexts
}

function New-WdlAppItem($Row, [bool]$Checked) {
    $it = New-Object WdlUi.WdlItem
    $it.Title = Get-WdlLangText $Row.Names $script:UiLang
    $it.Subtitle = [string]$Row.Id; $it.Checked = $Checked
    if ($Row.OptIn) { $it.Badge = T 'app.optIn'; $it.Warn = $true }
    elseif ($Row.Level -eq 'unsafe') { $it.Badge = T 'app.unsafe'; $it.Warn = $true }
    return $it
}

function New-WdlTweakItem($Row, [bool]$Checked) {
    $it = New-Object WdlUi.WdlItem
    $it.Title = Get-WdlLangText $Row.Names $script:UiLang
    $d = Get-WdlLangText $Row.Descriptions $script:UiLang
    $it.Subtitle = $d; $it.Tooltip = $d; $it.Checked = $Checked
    if ($Row.Level -eq 'aggressive') { $it.Badge = T 'lvl.aggressive' }
    return $it
}

function Set-WdlLists {
    <# Fills the app / tweak lists from the scan. -KeepChecks keeps the user's ticks (language switch, rescan). #>
    param([switch]$KeepChecks)
    $ui = $script:ui; $s = $script:Session
    if (-not $s) { return }
    $oldA = @{}; $oldT = @{}
    if ($KeepChecks) {
        for ($i = 0; $i -lt $ui.clbApps.Count; $i++) { $oldA[$script:AppItems[$i].Id] = $ui.clbApps.GetItemChecked($i) }
        for ($i = 0; $i -lt $ui.clbTweaks.Count; $i++) { $oldT[$script:TweakItems[$i].Id] = $ui.clbTweaks.GetItemChecked($i) }
    }
    $def = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset recommended
    $script:AppItems = @($s.AppRows | Where-Object { $_.Present })
    $items = New-Object 'Collections.Generic.List[WdlUi.WdlItem]'
    foreach ($r in $script:AppItems) {
        $c = $def.Apps -contains $r.Id; if ($oldA.ContainsKey($r.Id)) { $c = $oldA[$r.Id] }
        $items.Add((New-WdlAppItem $r ([bool]$c)))
    }
    $ui.clbApps.SetItems($items.ToArray())
    $script:TweakItems = @($s.TweakRows | Where-Object { $_.Usable })
    $items = New-Object 'Collections.Generic.List[WdlUi.WdlItem]'
    foreach ($r in $script:TweakItems) {
        $c = $def.Tweaks -contains $r.Id; if ($oldT.ContainsKey($r.Id)) { $c = $oldT[$r.Id] }
        $items.Add((New-WdlTweakItem $r ([bool]$c)))
    }
    $ui.clbTweaks.SetItems($items.ToArray())
    Update-WdlSessionTexts
}

function Update-WdlSessionTexts {
    $ui = $script:ui; $s = $script:Session
    $src = T 'rules.bundled'
    if (-not $s) {
        $ui.lblSys.Text = T 'hdr.scanning'
        $ui.lblAppsTitle.Text = T 'grp.apps' '-'
        $ui.statApps.Value = '–'; $ui.statTweaks.Value = '–'
        return
    }
    $ui.lblSys.Text = T 'hdr.system' $s.Os.ProductName $s.Os.DisplayVersion ('{0}.{1}' -f $s.Os.Build, $s.Os.Ubr) $s.User.Name
    $ui.lblAppsTitle.Text = T 'grp.apps' @($script:AppItems).Count
    $def = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset recommended
    $ui.statApps.Value = [string]@($def.Apps).Count
    $ui.statTweaks.Value = [string]@($def.Tweaks).Count
    $n = @($s.TweakRows | Where-Object { -not $_.Usable }).Count
    $ui.lblNotOffered.Text = ''; if ($n) { $ui.lblNotOffered.Text = T 'lbl.notOffered' $n }
    if ([string]$s.Config.RulesSource -eq 'downloaded') { $src = T 'rules.downloaded' }
    $ui.lblRules.Text = T 'lbl.rulesInfo' $s.Config.RulesVersion $src
}

function Update-WdlCommandStates {
    $ok = [bool]$script:Session -and -not $script:Job
    foreach ($b in @($script:ui.btnPreview, $script:ui.btnApply, $script:ui.btnGo, $script:ui.btnSimplePreview)) { $b.Enabled = $ok }
}

function Set-WdlMode {
    param([string]$Mode)
    $script:ModeNow = $Mode
    $script:ui.form.SetMode(($Mode -eq 'Simple'))
    $script:Settings.Mode = $Mode
    Save-WdlSettings $script:Settings
}

function Get-WdlGuiSelection {
    # Simple mode: the recommended preset; Advanced: the ticked items
    $s = $script:Session
    if ($script:ModeNow -eq 'Simple') { return (Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset recommended) }
    $a = @(); $t = @()
    foreach ($i in $script:ui.clbApps.CheckedIndices) { $a += $script:AppItems[$i].Id }
    foreach ($i in $script:ui.clbTweaks.CheckedIndices) { $t += $script:TweakItems[$i].Id }
    return @{ Apps = $a; Tweaks = $t }
}

function Get-WdlGuiOptions {
    $ui = $script:ui
    $scope = 'AllUsers'; $defUser = $true
    if ($script:ModeNow -ne 'Simple') {
        if ($ui.rbCur.Checked) { $scope = 'CurrentUser' }
        $defUser = [bool]$ui.chkDefaultUser.Checked
    }
    return (New-WdlOptions -Session $script:Session -AppScope $scope -DefaultUser $defUser -RestorePoint ([bool]$ui.chkRestore.Checked) -EnableProtection ([bool]$ui.chkProtect.Checked))
}

function Show-WdlTextDialog {
    <# Read-only text window (preview). -ApplyText adds a confirm button; returns $true when it was pressed. #>
    param([string]$Title, [string]$Text, [string]$ApplyText, [object[]]$Model)
    $d = New-Object WdlUi.TextDialog
    try {
        $d.Text = $Title; $d.lblHead.Text = $Title
        $d.ApplyTheme()
        $d.tbText.Text = $Text
        if ($Model) {
            $d.UsePreview()
            foreach ($m in $Model) {
                switch ([string]$m.Kind) {
                    'Header' { $d.preview.AddHeader([string]$m.Title, [int]$m.Count) }
                    'Summary' { $d.preview.AddSummary([string]$m.Title) }
                    default { $d.preview.AddItem([string]$m.Title, [string]$m.Body, [string]$m.Sub, [string[]]@($m.Detail | Where-Object { $null -ne $_ })) }
                }
            }
        }
        if ($ApplyText) { $d.btnOk.Text = $ApplyText; $d.AcceptButton = $d.btnOk } else { $d.btnOk.Visible = $false }
        $d.ApplyMono()
        return ($d.ShowDialog($script:ui.form) -eq 'OK')
    } finally { $d.Dispose() }
}

function Start-WdlScan {
    $null = Start-WdlJob -Name 'scan' -Status (T 'status.scanning') -Script '$sync.Result = Get-WdlSession' -OnDone {
        $script:Session = $script:Sync.Result
        if (-not $script:Session) { return }
        Set-WdlLists -KeepChecks:([bool]$script:AppItems)
        $script:ui.lblStatus.Text = T 'status.ready'
        Update-WdlCommandStates
    }
}

function Start-WdlPreview {
    <# Reads the current values for the selection and shows the exact changes; -Apply continues with
       restore point + apply when the user confirms. #>
    param([switch]$Apply)
    if (-not $script:Session) { return }
    $sel = Get-WdlGuiSelection
    if (@($sel.Apps).Count + @($sel.Tweaks).Count -eq 0) { Show-WdlMsg (T 'msg.nothingSelected') | Out-Null; return }
    $script:PendingOptions = Get-WdlGuiOptions
    $script:PendingApply = [bool]$Apply
    $a = @{ Session = $script:Session; AppIds = @($sel.Apps); TweakIds = @($sel.Tweaks); Options = $script:PendingOptions }
    $null = Start-WdlJob -Name 'preview' -Status (T 'status.previewing') -JobArgs $a -Script @'
$plan = Get-WdlResolvedPlan -Session $JobArgs.Session -AppIds $JobArgs.AppIds -TweakIds $JobArgs.TweakIds -Options $JobArgs.Options
$sync.Result = @{ Plan = $plan; Text = (Format-WdlPreview -Plan $plan -Lang $sync.UiLang); Model = (Get-WdlPreviewModel -Plan $plan -Lang $sync.UiLang); Counts = (Get-WdlPlanCounts $plan) }
'@ -OnDone {
        $r = $script:Sync.Result
        if ($script:Sync.Cancel) { $script:ui.lblStatus.Text = T 'status.cancelled'; return }
        $btn = $null
        if ($script:PendingApply -and $r.Counts.Total -gt 0) { $btn = T 'dlg.applyBtn' }
        $go = Show-WdlTextDialog -Title (T 'dlg.previewTitle') -Text $r.Text -ApplyText $btn -Model @($r.Model)
        if ($script:PendingApply -and $r.Counts.Total -eq 0) { Show-WdlMsg (T 'msg.nothing') | Out-Null; return }
        if ($go) { Start-WdlRestorePoint -Plan $r.Plan }
    }
}

function Start-WdlRestorePoint {
    param($Plan)
    $script:PendingPlan = $Plan
    if (-not $script:PendingOptions.RestorePoint) { Start-WdlApplyJob -RestorePoint $null; return }
    $null = Start-WdlJob -Name 'restore point' -Status (T 'status.restorePoint') -JobArgs @{ Enable = [bool]$script:PendingOptions.EnableProtection } -Script '$sync.Result = Invoke-WdlRestorePointStep -EnableProtection $JobArgs.Enable' -OnDone {
        $rp = $script:Sync.Result
        # the restore point call cannot be interrupted; a Cancel pressed meanwhile stops before any change
        if ($script:Sync.Cancel) { $script:ui.lblStatus.Text = T 'status.cancelled'; return }
        if ($rp.Ok) { Start-WdlApplyJob -RestorePoint $rp; return }
        $drive = $env:SystemDrive; if (-not $drive) { $drive = 'C:' }
        if ($rp.NeedsConsent) { $q = T 'msg.rpConsent' $drive } else { $q = T 'msg.rpFailed' (Get-WdlLocalText ([string]$rp.Error) $script:UiLang) }
        if ((Show-WdlMsg $q 'Warning' 'YesNo') -eq 'Yes') { Start-WdlApplyJob -RestorePoint $rp }
        else { $script:ui.lblStatus.Text = T 'status.cancelled' }
    }
}

function Start-WdlApplyJob {
    param($RestorePoint)
    $a = @{ Session = $script:Session; Plan = $script:PendingPlan; RestorePoint = $RestorePoint }
    $null = Start-WdlJob -Name 'apply' -Status (T 'status.applying') -JobArgs $a -Script '$sync.Result = Invoke-WdlApply -Session $JobArgs.Session -Plan $JobArgs.Plan -RestorePoint $JobArgs.RestorePoint' -OnDone {
        $r = $script:Sync.Result
        $icon = 'Information'; if ($r.Failed) { $icon = 'Warning' }
        if ($r.Cancelled) { $script:ui.lblStatus.Text = T 'status.cancelled'; Show-WdlMsg (T 'msg.appliedCancelled' $r.Done $r.Failed $r.BackupPath) 'Warning' | Out-Null }
        else { Show-WdlMsg (T 'msg.applied' $r.Done $r.Failed $r.Unchanged $r.BackupPath) $icon | Out-Null }
        $reboot = [bool]$r.Reboot
        Start-WdlScan
        if ($reboot -and (Show-WdlMsg (T 'msg.reboot') 'Question' 'YesNo') -eq 'Yes') { Restart-WdlComputer }
    }
}

function Format-WdlBackupDate([string]$Text) {
    # backups store ISO 8601 with offset; show local 'yyyy-MM-dd HH:mm:ss', or the raw text if it does not parse
    $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    return $Text
}

function Show-WdlUndoDialog {
    $list = @(Get-WdlBackups)
    if ($list.Count -eq 0) { Show-WdlMsg (T 'msg.noBackups') | Out-Null; return }
    $d = New-Object WdlUi.UndoDialog
    $sel = $null
    try {
        $d.Text = T 'dlg.undoTitle'
        $d.ApplyTheme()
        $items = New-Object 'Collections.Generic.List[WdlUi.WdlItem]'
        foreach ($b in $list) {
            $it = New-Object WdlUi.WdlItem
            $it.Title = Format-WdlBackupDate ([string]$b.Created); $it.Subtitle = '{0}: {1}' -f (T 'col.changes'), $b.Changes; $it.Tag = [string]$b.Path
            if ($b.Restored) { $it.Badge = T 'state.restored' } else { $it.Badge = T 'state.active'; $it.Warn = $true }
            $items.Add($it)
        }
        $d.list.SetItems($items.ToArray())
        $d.btnRstrui.Add_Click({ try { Start-Process -FilePath (Get-WdlSystemExe 'rstrui.exe') } catch { Show-WdlError -Context 'rstrui' -ErrorRecord $_ } })
        $r = $d.ShowDialog($script:ui.form)
        if ($r -eq 'OK') { $sel = $d.list.SelectedItem }
    } finally { $d.Dispose() }
    if (-not $sel) { return }
    if ((Show-WdlMsg (T 'msg.undoConfirm' $sel.Title) 'Question' 'YesNo') -ne 'Yes') { return }
    $null = Start-WdlJob -Name 'undo' -Status (T 'status.undoing') -JobArgs @{ Path = [string]$sel.Tag } -Script '$sync.Result = Invoke-WdlUndo -Path $JobArgs.Path' -OnDone {
        $r = $script:Sync.Result
        $icon = 'Information'; if ($r.Failed) { $icon = 'Warning' }
        if ($r.Cancelled) { $script:ui.lblStatus.Text = T 'status.cancelled'; Show-WdlMsg (T 'msg.undoCancelled' $r.Restored $r.Failed) 'Warning' | Out-Null }
        else { Show-WdlMsg (T 'msg.undone' $r.Restored $r.Failed) $icon | Out-Null }
        $man = @(@($r.Manual) | Select-Object -Unique)
        if ($man.Count) {
            # keep the dialog on screen: the full list is in the log
            $txt = ($man | Select-Object -First 12) -join "`n"
            if ($man.Count -gt 12) { $txt += "`n" + (T 'msg.more' ($man.Count - 12)) }
            Show-WdlMsg (T 'msg.undoManual' $txt) 'Warning' | Out-Null
        }
        Start-WdlScan
        if ($r.Restored -gt 0 -and (Show-WdlMsg (T 'msg.reboot') 'Question' 'YesNo') -eq 'Yes') { Restart-WdlComputer }
    }
}

function Show-WdlGui {
    <# Main window. -Mode Simple | Advanced; empty = remembered choice or the mode chooser. #>
    param([string]$Mode)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { $null = $_ }
    # any UI-thread exception goes to the log and our own error dialog instead of the raw .NET one
    $script:OnThreadEx = [Threading.ThreadExceptionEventHandler] {
        param($s, $e)
        $rec = New-Object Management.Automation.ErrorRecord $e.Exception, 'ui', ([Management.Automation.ErrorCategory]::NotSpecified), $null
        Show-WdlError -Context 'ui' -ErrorRecord $rec
    }
    [Windows.Forms.Application]::add_ThreadException($script:OnThreadEx)
    $script:Sync = [hashtable]::Synchronized(@{ LogQueue = [Collections.Queue]::Synchronized((New-Object Collections.Queue)); Percent = 0; Status = ''; Cancel = $false; Cancelled = $false; Result = $null; Error = $null; UiLang = 'vi' })
    $script:WDL.Sync = $script:Sync
    $script:Job = $null; $script:RulesJob = $null; $script:RulesReload = $false; $script:Session = $null; $script:AppItems = @(); $script:TweakItems = @()
    $script:Settings = Read-WdlSettings
    Set-WdlLanguage ([string]$script:Settings.Language)
    try { $script:InstalledFonts = @((New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }) } catch { $script:InstalledFonts = @() }
    Initialize-WdlUiLib
    if (-not $Mode) {
        if ([string]$script:Settings.RememberMode -eq '1' -and @('Simple', 'Advanced') -contains [string]$script:Settings.Mode) { $Mode = [string]$script:Settings.Mode }
        else { $Mode = Show-WdlModeChooser; if (-not $Mode) { return } }
    }
    $script:H = @{}
    $f = New-Object WdlUi.MainForm
    $ui = @{ form = $f; tip = (New-Object Windows.Forms.ToolTip) }
    foreach ($n in @('lblSys', 'lblAppsTitle', 'lblNotOffered', 'lblStatus', 'lblRules', 'statApps', 'statTweaks', 'segMode', 'cbLang', 'cbPreset',
            'btnGo', 'btnSimplePreview', 'btnAppDef', 'btnAppAll', 'btnAppNone', 'btnPresetApply', 'btnPreview', 'btnApply', 'btnUndo', 'btnRescan', 'btnCancel',
            'btnLogs', 'btnBackups', 'btnRulesCheck', 'clbApps', 'clbTweaks', 'rbAll', 'rbCur', 'chkRestore', 'chkProtect', 'chkDefaultUser', 'chkRules', 'pb', 'tbLog')) { $ui[$n] = $f.$n }
    $script:ui = $ui
    $ui.cbLang.SetItems([string[]]@($script:WdlLangs | ForEach-Object { $_.Name }))
    for ($i = 0; $i -lt $script:WdlLangs.Count; $i++) { if ($script:WdlLangs[$i].Code -eq $script:UiLang) { $ui.cbLang.SelectedIndex = $i } }
    $ui.cbPreset.SetItems([string[]]@((T 'preset.recommended'), (T 'preset.aggressive')))
    $ui.chkRules.Checked = ([string]$script:Settings.RulesAutoUpdate -ne '0')
    $script:BusyControls = @($ui.btnPreview, $ui.btnApply, $ui.btnGo, $ui.btnSimplePreview, $ui.btnUndo, $ui.btnRescan, $ui.clbApps, $ui.clbTweaks, $ui.btnAppDef, $ui.btnAppAll, $ui.btnAppNone,
        $ui.btnPresetApply, $ui.cbPreset, $ui.rbAll, $ui.rbCur, $ui.chkRestore, $ui.chkProtect, $ui.chkDefaultUser, $ui.segMode)

    # ---- handlers ----
    $script:H.Go = { Start-WdlPreview -Apply }
    $script:H.Apply = { Start-WdlPreview -Apply }
    $script:H.Preview = { Start-WdlPreview }
    $script:H.Undo = { Show-WdlUndoDialog }
    $script:H.Rescan = { Start-WdlScan }
    $script:H.Cancel = { $script:Sync.Cancel = $true; Write-WdlLog -Level WARN -En 'Cancelling after the current item...' -Vi 'Đang huỷ sau mục hiện tại...' }
    $script:H.Mode = { $m = 'Advanced'; if ($script:ui.segMode.SelectedIndex -eq 0) { $m = 'Simple' }; if ($m -ne $script:ModeNow) { Set-WdlMode $m } }
    $script:H.RulesCheck = { Start-WdlRulesUpdate -Manual }
    $script:H.Logs = { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Join-Path (Get-WdlDataDir) 'logs')) }
    $script:H.Backups = { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Get-WdlBackupDir)) }
    $script:H.AppDef = { Set-WdlChecks -Preset recommended -AppsOnly }
    $script:H.AppAll = { for ($i = 0; $i -lt $script:ui.clbApps.Count; $i++) { $r = $script:AppItems[$i]; $script:ui.clbApps.SetItemChecked($i, (-not $r.OptIn -and $r.Level -ne 'unsafe')) } }
    $script:H.AppNone = { for ($i = 0; $i -lt $script:ui.clbApps.Count; $i++) { $script:ui.clbApps.SetItemChecked($i, $false) } }
    $script:H.PresetApply = { $p = 'recommended'; if ($script:ui.cbPreset.SelectedIndex -eq 1) { $p = 'aggressive' }; Set-WdlChecks -Preset $p }
    $script:H.Rules = { if ($script:ui.chkRules.Checked) { $script:Settings.RulesAutoUpdate = '1' } else { $script:Settings.RulesAutoUpdate = '0' }; Save-WdlSettings $script:Settings }
    $script:H.Lang = {
        $i = $script:ui.cbLang.SelectedIndex
        if ($i -lt 0 -or $script:WdlLangs[$i].Code -eq $script:UiLang) { return }
        Set-WdlLanguage $script:WdlLangs[$i].Code
        $script:Settings.Language = $script:UiLang; Save-WdlSettings $script:Settings
        Set-WdlUiTexts
        Set-WdlLists -KeepChecks
    }
    $script:H.AppCheck = {
        param($e)
        if (-not $e.NewValue) { return }
        $r = $script:AppItems[$e.Index]
        if ($r.OptIn -and (Show-WdlMsg (T 'msg.optIn' (Get-WdlLangText $r.Names $script:UiLang)) 'Warning' 'YesNo') -ne 'Yes') { $e.Cancel = $true }
    }
    $ui.btnGo.Add_Click({ Invoke-WdlHandler 'Go' })
    $ui.btnApply.Add_Click({ Invoke-WdlHandler 'Apply' })
    $ui.btnPreview.Add_Click({ Invoke-WdlHandler 'Preview' })
    $ui.btnSimplePreview.Add_Click({ Invoke-WdlHandler 'Preview' })
    $ui.btnUndo.Add_Click({ Invoke-WdlHandler 'Undo' })
    $ui.btnRescan.Add_Click({ Invoke-WdlHandler 'Rescan' })
    $ui.btnCancel.Add_Click({ Invoke-WdlHandler 'Cancel' })
    $ui.segMode.Add_SelectedIndexChanged({ Invoke-WdlHandler 'Mode' })
    $ui.btnLogs.Add_Click({ Invoke-WdlHandler 'Logs' })
    $ui.btnRulesCheck.Add_Click({ Invoke-WdlHandler 'RulesCheck' })
    $ui.btnBackups.Add_Click({ Invoke-WdlHandler 'Backups' })
    $ui.btnAppDef.Add_Click({ Invoke-WdlHandler 'AppDef' })
    $ui.btnAppAll.Add_Click({ Invoke-WdlHandler 'AppAll' })
    $ui.btnAppNone.Add_Click({ Invoke-WdlHandler 'AppNone' })
    $ui.btnPresetApply.Add_Click({ Invoke-WdlHandler 'PresetApply' })
    $ui.chkRules.Add_CheckedChanged({ Invoke-WdlHandler 'Rules' })
    $ui.cbLang.Add_SelectedIndexChanged({ Invoke-WdlHandler 'Lang' })
    $ui.clbApps.Add_ItemChecking({ param($s, $e) Invoke-WdlHandler 'AppCheck' $e })
    $f.Add_FormClosing({
            param($s, $e)
            if ($script:Job -and $script:Job.Name -ne 'scan') { Show-WdlMsg (T 'msg.jobRunning') 'Warning' | Out-Null; $e.Cancel = $true }
        })
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ Invoke-WdlTick })
    $f.Add_Shown({
            try {
                Write-WdlLog -En "$($script:WDL.Name) $($script:WDL.Version) started (log: $($script:WDL.LogPath))" -Vi 'Đã khởi động'
                Start-WdlRulesUpdate
                Start-WdlScan
            } catch { Show-WdlError -Context 'start' -ErrorRecord $_ }
        })
    Set-WdlMode $Mode
    Set-WdlUiTexts
    Update-WdlCommandStates
    $timer.Start()
    $script:GuiClosed = $false
    $f.Add_FormClosed({ $script:GuiClosed = $true })
    try { [void]$f.ShowDialog() }
    catch {
        # only a disposed-object error raised after the window has closed is ignored
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        if (-not ($script:GuiClosed -and $ex -is [ObjectDisposedException])) { throw }
        Write-WdlLog -Level WARN -En "Ignored after close: $($ex.Message)" -Vi 'Bỏ qua lỗi sau khi đóng cửa sổ'
    } finally {
        $timer.Stop()
        $j = $script:RulesJob; $script:RulesJob = $null
        if ($j) { try { [void]$j.PS.BeginStop($null, $null); $j.RS.Dispose() } catch { $null = $_ } }
        $f.Dispose()
        try { [Windows.Forms.Application]::remove_ThreadException($script:OnThreadEx) } catch { $null = $_ }
    }
}

function Set-WdlChecks {
    # ticks the items of a preset (-AppsOnly: only the app list)
    param([string]$Preset, [switch]$AppsOnly)
    $s = $script:Session
    if (-not $s) { return }
    $sel = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset $Preset
    for ($i = 0; $i -lt $script:ui.clbApps.Count; $i++) { $script:ui.clbApps.SetItemChecked($i, ($sel.Apps -contains $script:AppItems[$i].Id)) }
    if (-not $AppsOnly) { for ($i = 0; $i -lt $script:ui.clbTweaks.Count; $i++) { $script:ui.clbTweaks.SetItemChecked($i, ($sel.Tweaks -contains $script:TweakItems[$i].Id)) } }
}
#endregion
