<#
    Static checks: every script parses, language files are complete and consistent, files that contain non-ASCII
    text carry a UTF-8 BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI), no personal names, no wmic, and
    the GUI helpers that do not need Windows Forms (texts, fonts, settings, background job text, relaunch command).
#>
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:fail = 0; $script:pass = 0
function Assert($cond, $msg) { if ($cond) { $script:pass++; Write-Host "PASS $msg" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL $msg" -ForegroundColor Red } }

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
$scripts = @($files | Where-Object { @('.ps1', '.psd1') -contains $_.Extension })

# ---------------- parse ----------------
foreach ($f in $scripts) {
    $tok = $null; $err = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    Assert (@($err).Count -eq 0) ("parses: {0}{1}" -f $f.FullName.Substring($root.Length + 1), $(if (@($err).Count) { ' - ' + $err[0].Message + ' line ' + $err[0].Extent.StartLineNumber } else { '' }))
}

# ---------------- encoding ----------------
foreach ($f in $scripts) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    $ascii = -not @($b | Where-Object { $_ -gt 127 }).Count
    Assert ($bom -or $ascii) "UTF-8 BOM or pure ASCII: $($f.Name)"
}
foreach ($f in @($files | Where-Object { $_.Extension -eq '.bat' })) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    Assert (-not @($b | Where-Object { $_ -gt 127 }).Count) "batch file is ASCII: $($f.Name)"
    $t = [Text.Encoding]::ASCII.GetString($b)
    Assert (($t -replace "`r`n", '') -notmatch "`n") "batch file uses CRLF: $($f.Name)"
}

# ---------------- names / forbidden calls ----------------
$textFiles = @($files | Where-Object { @('.png', '.ico') -notcontains $_.Extension })
$hits = @()
foreach ($f in $textFiles) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        if ($line -match '(?i)tainT13|PNC\s*STG|designed by|thanhtai') {
            # the only allowed occurrence: the GitHub repository the shared rule data is downloaded from
            if ($f.Name -eq 'Rules.ps1' -and $line -match '^\$script:WDL\.RulesRepo = ') { continue }
            if ($f.Name -eq 'Test-Parse.ps1') { continue }
            $hits += "$($f.Name):$n"
        }
    }
}
Assert ($hits.Count -eq 0) "no personal names or watermark ($($hits -join ', '))"
$wmi = @($scripts | Where-Object { $_.Name -ne 'Test-Parse.ps1' } | Select-String -Pattern '(?i)\bwmic(\.exe)?\s|Get-WmiObject' | Where-Object { $_.Line -notmatch '^\s*#|never wmic' })
Assert ($wmi.Count -eq 0) 'no wmic / Get-WmiObject (CIM and registry only)'

# ---------------- languages ----------------
function Read-Lang([string]$code) { $t = $null; Import-LocalizedData -BaseDirectory (Join-Path $root 'lang') -FileName $code -BindingVariable t -UICulture 'en-US'; return $t }
function Get-Holes([string]$s) { return @([regex]::Matches($s, '\{(\d+)\}') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique) }
$en = Read-Lang 'en'
foreach ($code in @('vi', 'km', 'zh-CN')) {
    $l = Read-Lang $code
    Assert ($l.Count -gt 0) "lang\$code.psd1 loads ($($l.Count) keys)"
    $extra = @($l.Keys | Where-Object { -not $en.ContainsKey($_) })
    Assert ($extra.Count -eq 0) "lang\${code}: no keys unknown to English ($($extra -join ', '))"
    $bad = @($l.Keys | Where-Object { $en.ContainsKey($_) -and ((Get-Holes $l[$_]) -join ',') -ne ((Get-Holes $en[$_]) -join ',') })
    Assert ($bad.Count -eq 0) "lang\${code}: placeholders match English ($($bad -join ', '))"
}
$vi = Read-Lang 'vi'
$missing = @($en.Keys | Where-Object { -not $vi.ContainsKey($_) })
Assert ($missing.Count -eq 0) "lang\vi covers every English key ($($missing -join ', '))"
$viText = ($vi.Values -join ' ')
Assert ($viText -notmatch '(?i)\bmình\b') 'Vietnamese UI text avoids "mình"'
$gui = [IO.File]::ReadAllText((Join-Path $root 'lib\Gui.ps1'))
$used = @([regex]::Matches($gui, "(?:\bT\s+'|'@)([a-zA-Z]+\.[a-zA-Z.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$unknown = @($used | Where-Object { -not $en.ContainsKey($_) })
Assert ($used.Count -gt 40 -and $unknown.Count -eq 0) "every text key used by the GUI exists in en.psd1 ($($used.Count) used; unknown: $($unknown -join ', '))"
Assert (-not $en.ContainsKey('tip.author')) 'no author tooltip key'

# ---------------- GUI helpers (no Windows Forms needed) ----------------
foreach ($f in @('Common', 'Rules', 'Plan', 'System', 'Engine', 'Gui')) { . (Join-Path $root "lib\$f.ps1") }
Set-WdlLanguage 'vi'
Assert ((T 'btn.apply') -eq 'Áp dụng' -and (T 'grp.apps' 5) -eq 'Ứng dụng sẽ gỡ (tìm thấy 5 trên máy)') 'T: Vietnamese text with a placeholder'
Set-WdlLanguage 'km'
Assert ((T 'btn.preview') -eq 'Preview' -and (T 'btn.cancel') -ne 'Cancel') 'T: Khmer falls back to English for new keys, keeps shared translations'
Assert ((T 'no.such.key') -eq 'no.such.key') 'T: unknown key shows the key'
Set-WdlLanguage 'xx'
Assert ($script:UiLang -eq 'vi') 'unknown language code falls back to Vietnamese'
Set-WdlLanguage ''
Assert ($script:UiLang -eq 'vi' -and (Get-WdlDefaultLanguage) -eq 'vi') 'no saved language starts in Vietnamese'
Set-WdlLanguage 'en'
Assert ($script:UiLang -eq 'en') 'a saved language is respected'
Set-WdlLanguage 'en'
Assert ((T 'msg.error' 'scan' 'boom') -match "scan[\s\S]*boom" -and (T 'msg.error' 'a' 'b') -match "`n") 'T: \n becomes a line break'
Assert ((Get-WdlFontFor -Code 'km' -Installed @('Segoe UI', 'Leelawadee UI')) -eq 'Leelawadee UI' -and (Get-WdlFontFor -Code 'zh-CN' -Installed @('Segoe UI')) -eq 'Segoe UI') 'font choice for Khmer / Chinese'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wdlgui_Người Dùng ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$null = New-Item -ItemType Directory -Path (Join-Path $tmp $script:WDL.DataDirName) -Force
$oldPd = $env:ProgramData; $env:ProgramData = $tmp
try {
    Save-WdlSettings @{ Language = 'vi'; Mode = 'Advanced'; RememberMode = '1'; 'bad key' = 'x'; Note = "it's" }
    $s = Read-WdlSettings
    Assert ($s.Language -eq 'vi' -and $s.Mode -eq 'Advanced' -and $s.Note -eq "it's" -and -not $s.ContainsKey('bad key')) 'settings round trip (Unicode path, quotes, invalid keys dropped)'
} finally { $env:ProgramData = $oldPd; Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# background job text: libs + script, result and errors come back through $sync
$script:WdlRoot = $root
function Invoke-JobText([string]$Script) {
    $sync = [hashtable]::Synchronized(@{ LogQueue = [Collections.Queue]::Synchronized((New-Object Collections.Queue)); Cancel = $false; UiLang = 'vi' })
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace(); $ps.Runspace.Open()
    $ps.Runspace.SessionStateProxy.SetVariable('sync', $sync)
    $ps.Runspace.SessionStateProxy.SetVariable('JobArgs', @{ A = 40 })
    $ps.Runspace.SessionStateProxy.SetVariable('WdlRootPath', $root)
    $ps.Runspace.SessionStateProxy.SetVariable('WdlLogPath', $null)
    [void]$ps.AddScript((Get-WdlJobText -Script $Script))
    [void]$ps.Invoke(); $ps.Runspace.Close(); $ps.Dispose()
    return $sync
}
$r = Invoke-JobText 'Write-WdlLog -En "hello" -Vi "xin chào"; $sync.Result = $JobArgs.A + 2; $sync.Root = $script:WdlRoot'
Assert ($r.Result -eq 42 -and $r.Root -eq $root -and [string]$r.LogQueue.Dequeue() -match 'xin chào') 'job text: libs load, result, root and Vietnamese log line reach the UI'
$r = Invoke-JobText 'throw "boom"'
Assert ($r.Error -eq 'boom' -and -not $r.Cancelled) 'job text: an exception lands in $sync.Error'
$r = Invoke-JobText '$sync.Cancel = $true; Assert-WdlNotCancelled'
Assert ($r.Cancelled -and $r.Error) 'job text: Cancel is reported as cancelled'

# time limits (real calls, before any mock)
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-WdlTimed -TimeoutSec 1 -Script { Start-Sleep -Seconds 5; 'late' }
Assert ($r.TimedOut -and -not $r.Completed -and $sw.ElapsedMilliseconds -lt 3000) "Invoke-WdlTimed: a hung call is abandoned after 1 s ($($sw.ElapsedMilliseconds) ms)"
$r = Invoke-WdlTimed -TimeoutSec 5 -ArgumentList 2 -Script { param($x) $x * 21 }
Assert ($r.Completed -and $r.Output[0] -eq 42) 'Invoke-WdlTimed: result and arguments'
$r = Invoke-WdlTimed -TimeoutSec 5 -Script { throw 'bad' }
Assert ($r.Completed -and $r.Error -and $r.Error.Message -match 'bad') 'Invoke-WdlTimed: an exception is returned, not thrown'
$sleep = Get-Command sleep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sleep) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-WdlProcess -FilePath $sleep.Source -Arguments '5' -TimeoutSec 1
    Assert ($code -eq -1 -and $sw.ElapsedMilliseconds -lt 3000) "Invoke-WdlProcess: a hung process is killed after 1 s (exit $code)"
}

# entry script: relaunch command line (Sysnative / elevation)
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'WinDebloatLive.ps1'), [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-WdlRelaunchArgs' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$line = Get-WdlRelaunchArgs -Script "C:\Users\Người Dùng Thử\user's tools\WinDebloatLive.ps1" -Bound ([ordered]@{ NoGui = [switch]$true; Yes = [switch]$false; Preset = 'aggressive'; Undo = 'C:\a b\backup.json' })
$want = @("-NoProfile -ExecutionPolicy Bypass -STA -File `"C:\Users\Người Dùng Thử\user's tools\WinDebloatLive.ps1`"", ' -NoGui', ' -Preset "aggressive"', ' -Undo "C:\a b\backup.json"')
Assert ($line.StartsWith($want[0]) -and @($want | Where-Object { -not $line.Contains($_) }).Count -eq 0 -and $line -notmatch '-Yes') "relaunch arguments keep Unicode / apostrophe paths and switches ($line)"
$entry = [IO.File]::ReadAllText((Join-Path $root 'WinDebloatLive.ps1'))
Assert ($entry -match 'Sysnative' -and $entry -match 'Is64BitProcess' -and $entry -match "PSEdition -eq 'Core'" -and $entry -match 'LanguageMode') 'entry script: WOW64, PowerShell 7 and ConstrainedLanguage handling present'
$bat = [IO.File]::ReadAllText((Join-Path $root 'run.bat'))
Assert ($bat -match 'fltmc\.exe' -and $bat -match '__WDL_ELEVATED__' -and $bat -match '\$env:WDL_SELF' -and $bat -match 'Sysnative' -and $bat -match '-STA -File') 'run.bat: fltmc check, elevation marker, path via environment, 64-bit, STA'
Assert ($bat -match "Start-Process -FilePath \(\`$env:SystemRoot \+ '\\System32\\cmd\.exe'\) -ArgumentList \('/c ' \+ \`$q \+ \`$q \+ \`$env:WDL_SELF \+ \`$q" -and $bat -notmatch '-FilePath \$env:WDL_SELF') 'run.bat: elevates cmd.exe /c ""bat" args" (folder names with brackets or &)'
$main = [IO.File]::ReadAllText((Join-Path $root 'WinDebloatLive.ps1'))
Assert ($main -match "Threading\.Mutex\(\`$false, 'Global\\WinDebloatLive'\)" -and $main.IndexOf('Threading.Mutex') -lt $main.IndexOf('Initialize-WdlDataDir')) 'single instance: global mutex taken before any change'

Write-Host ''
Write-Host ("Parse tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
exit $script:fail
