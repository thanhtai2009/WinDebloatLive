<#
    Rules tests: bundled data validity and manifest hashes, download policy, URL checks, and the auto-update
    against a local HTTP server (tests\tools\rules_server.py): Updated, UpToDate, Rejected, minToolVersion,
    Offline, Timeout. Needs python3 for the server tests.
#>
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($f in @('Common', 'Rules', 'Plan')) { . (Join-Path $root "lib\$f.ps1") }
$script:fail = 0; $script:pass = 0
function Assert($cond, $msg) { if ($cond) { $script:pass++; Write-Host "PASS $msg" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL $msg" -ForegroundColor Red } }

# isolated tool folder (bundled rules = a copy of data\)
$work = Join-Path ([IO.Path]::GetTempPath()) ('wdlrules_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$tool = Join-Path $work 'tool'
$null = New-Item -ItemType Directory -Path $tool -Force
Copy-Item -LiteralPath (Join-Path $root 'data') -Destination (Join-Path $tool 'data') -Recurse
$script:WdlRoot = $tool
$srv = Join-Path $work 'srv'; $null = New-Item -ItemType Directory -Path $srv -Force
$bundledApps = Read-WdlJsonFile (Join-Path $root 'data\apps.json')
$bundledTweaks = Read-WdlJsonFile (Join-Path $root 'data\tweaks.json')
function Copy-Data($d) { return , (ConvertFrom-WdlJson (ConvertTo-WdlJson $d)) }
function Get-Bytes([string]$t) { return , ([Text.Encoding]::UTF8.GetBytes($t.Replace("`r`n", "`n"))) }
function Set-Mode([string]$m) { [IO.File]::WriteAllText((Join-Path $srv '.mode'), $m) }
function Publish {
    param([string]$Version, $Apps = $bundledApps, $Tweaks = $bundledTweaks, [string]$MinTool = '1.1.0', [string]$BadHash)
    $ab = Get-Bytes (ConvertTo-WdlJson $Apps); $tb = Get-Bytes (ConvertTo-WdlJson $Tweaks)
    [IO.File]::WriteAllBytes((Join-Path $srv 'apps.json'), $ab); [IO.File]::WriteAllBytes((Join-Path $srv 'tweaks.json'), $tb)
    $ha = Get-WdlRulesHash $ab; if ($BadHash) { $ha = $BadHash }
    $m = [ordered]@{ schema = 1; version = $Version; minToolVersion = $MinTool; files = @([ordered]@{ name = 'apps.json'; sha256 = $ha }, [ordered]@{ name = 'tweaks.json'; sha256 = (Get-WdlRulesHash $tb) }) }
    [IO.File]::WriteAllBytes((Join-Path $srv 'rules-manifest.json'), (Get-Bytes (ConvertTo-WdlJson $m)))
}

# ---------------- bundled data ----------------
Assert ((Test-WdlRulesDir (Join-Path $root 'data')) -eq (New-Object Version '2026.11.1.1')) 'bundled manifest matches apps.json / tweaks.json (SHA256, BOM-less LF)'
Assert (@(Test-WdlRulesContent $bundledApps $bundledTweaks).Count -eq 0) 'bundled rules pass the format and registry policy checks'
$cfg = Get-WdlConfig
Assert ($cfg.RulesSource -eq 'bundled' -and @($cfg.Apps).Count -gt 20 -and @($cfg.Tweaks).Count -gt 10 -and @($cfg.Win10Apps).Count -gt 10) "Get-WdlConfig loads the bundled rules ($(@($cfg.Apps).Count) Win11 apps, $(@($cfg.Tweaks).Count) Win11 tweaks)"
$lf = [Text.Encoding]::UTF8.GetBytes("{`n  `"a`": 1`n}`n"); $crlf = [Text.Encoding]::UTF8.GetBytes("{`r`n  `"a`": 1`r`n}`r`n")
$bom = [byte[]](@(0xEF, 0xBB, 0xBF) + @($crlf))
Assert ((Get-WdlRulesHash $lf) -eq (Get-WdlRulesHash $crlf) -and (Get-WdlRulesHash $lf) -eq (Get-WdlRulesHash $bom)) 'rules hash: LF, CRLF and BOM+CRLF give the same SHA256'

# ---------------- policy ----------------
function New-TweakWithOp($op, [string]$kind = 'set') {
    $t = Copy-Data $bundledTweaks
    $x = Copy-Data $t['tweaks'][0]; $x['id'] = 'PolicyProbe'; $x['set'] = @(); $x[$kind] = @($op)
    $t['tweaks'] = @($t['tweaks']) + @($x)
    return , $t
}
$run = [ordered]@{ hive = 'SOFTWARE'; key = 'Microsoft\Windows\CurrentVersion\Run'; name = 'x'; type = 'String'; value = 'c:\x.exe' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $run)).Count -gt 0) 'policy: a downloaded Run key write is rejected'
$ifeo = [ordered]@{ hive = 'SOFTWARE'; key = 'Microsoft\Windows NT\CurrentVersion\Image File Execution Options\a.exe'; name = 'Debugger'; type = 'String'; value = 'x' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $ifeo)).Count -gt 0) 'policy: Image File Execution Options Debugger is rejected'
$svc = [ordered]@{ name = 'WinDefend'; startType = 'Disabled' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $svc 'services')).Count -gt 0) 'policy: disabling a blocked service (WinDefend) is rejected'
$okSvc = [ordered]@{ name = 'DiagTrack'; startType = 'Disabled' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $okSvc 'services')).Count -eq 0) 'extension: disabling DiagTrack is a valid service rule'
$badTask = [ordered]@{ path = '\Microsoft\Windows\Application Experience\'; name = 'ProgramDataUpdater'; state = 'Enabled' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $badTask 'tasks')).Count -gt 0) 'extension: tasks can only be disabled'
$feat = [ordered]@{ name = 'NetFx4-AdvSrvs'; state = 'Disabled' }
Assert (@(Test-WdlRulesContent $bundledApps (New-TweakWithOp $feat 'features')).Count -gt 0) 'policy: disabling a blocked feature is rejected'

# ---------------- URL checks ----------------
Assert (Test-WdlRulesUrl $script:WDL.RulesBaseUrl) 'default rules URL accepted (HTTPS, raw.githubusercontent.com, rules repository)'
Assert (-not (Test-WdlRulesUrl ($script:WDL.RulesBaseUrl -replace '^https:', 'http:'))) 'plain HTTP refused'
Assert (-not (Test-WdlRulesUrl ($script:WDL.RulesBaseUrl -replace 'raw\.githubusercontent\.com', 'example.com'))) 'other host refused'
Assert (-not (Test-WdlRulesUrl 'http://127.0.0.1:8080/')) 'local test URL refused without -AllowTestUrl'
$r = Update-WdlRules -BaseUrl 'https://example.com/rules/'
Assert ($r.Status -eq 'Rejected' -and $r.ElapsedMs -lt 1000) 'foreign URL rejected without a request'

# ---------------- offline ----------------
$l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0; $l.Start(); $dead = $l.LocalEndpoint.Port; $l.Stop()
$r = Update-WdlRules -BaseUrl "http://127.0.0.1:$dead/" -AllowTestUrl
Assert ($r.Status -eq 'Offline' -and $r.ElapsedMs -lt 10000) "offline: status $($r.Status) in $($r.ElapsedMs) ms"
Assert ((Get-WdlActiveRules).Source -eq 'bundled') 'offline: bundled rules stay active'

# ---------------- local server ----------------
$py = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $py) { Write-Host 'SKIP server tests (python not found)' }
else {
    $psi = New-Object Diagnostics.ProcessStartInfo $py.Source, ('"{0}" "{1}"' -f (Join-Path $root 'tests/tools/rules_server.py'), $srv)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $port = [int]$proc.StandardOutput.ReadLine()
        $url = "http://127.0.0.1:$port/"
        Set-Mode ''
        Publish -Version '2026.11.1.1'
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -eq 'UpToDate') "same version: UpToDate ($($r.Status) $($r.Error))"
        Publish -Version '2099.1.1.1' -MinTool '9.0.0'
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -eq 'UpToDate' -and (Get-WdlActiveRules).Source -eq 'bundled') "minToolVersion above $($script:WDL.RulesCompat): not installed ($($r.Status))"
        Publish -Version '2099.1.1.1' -BadHash ('0' * 64)
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -eq 'Rejected' -and (Get-WdlActiveRules).Source -eq 'bundled') "SHA256 mismatch: Rejected ($($r.Error))"
        Publish -Version '2099.1.1.1' -Tweaks (New-TweakWithOp $run)
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -eq 'Rejected' -and (Get-WdlActiveRules).Source -eq 'bundled') 'policy violation in a correctly hashed download: Rejected'
        $na = Copy-Data $bundledApps
        $na['apps'] = @($na['apps']) + @([ordered]@{ pattern = 'Contoso.TestApp'; os = 'both'; default = $false; level = 'safe'; name = [ordered]@{ vi = 'Test'; en = 'Test'; 'zh-CN' = 'Test'; km = 'Test' } })
        Publish -Version '2099.1.1.1' -Apps $na
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        $ar = Get-WdlActiveRules
        Assert ($r.Status -eq 'Updated' -and $ar.Source -eq 'downloaded' -and [string]$ar.Version -eq '2099.1.1.1') "valid newer rules: Updated and active ($($r.Status) $($r.Error))"
        Assert ((Test-WdlPathInside -Path $ar.Dir -Parent (Join-Path $tool 'rules'))) 'downloaded rules stored in <tool>\rules only'
        $cfg = Get-WdlConfig
        Assert ($cfg.RulesSource -eq 'downloaded' -and @($cfg.Apps | Where-Object { $_.Id -eq 'Contoso.TestApp' }).Count -eq 1) 'Get-WdlConfig uses the downloaded rules'
        Assert (@($cfg.Protected).Count -ge @(Get-WdlJsonVal $bundledApps 'protected' @()).Count) 'bundled protected apps kept with downloaded rules'
        # tampering after install -> falls back to bundled
        [IO.File]::AppendAllText((Join-Path $ar.Dir 'apps.json'), ' ')
        Assert ((Get-WdlActiveRules).Source -eq 'bundled') 'a modified downloaded file is ignored (hash re-checked at every start)'
        Set-Mode 'redirect'
        Publish -Version '2099.2.1.1'
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -ne 'Updated') "redirects are not followed ($($r.Status))"
        Set-Mode 'slow'
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl -TimeoutMs 2000
        Assert ($r.Status -eq 'Timeout' -and $r.ElapsedMs -lt 5000) "slow server: Timeout after $($r.ElapsedMs) ms"
        $r = Update-WdlRules -BaseUrl $url -AllowTestUrl
        Assert ($r.Status -eq 'Timeout' -and $r.ElapsedMs -lt 12000) "default limit: Timeout after $($r.ElapsedMs) ms (limit $($script:WDL.RulesTimeoutMs) ms)"
    } finally { try { $proc.Kill() } catch { $null = $_ } }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Rules tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
exit $script:fail
