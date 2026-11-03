<#
    WinDebloat Live - debloat rules (data\apps.json, data\tweaks.json) shared with WinDebloat Tool:
    format checks, loading, and the verified auto-update (manifest + SHA256 + registry safety policy).
    Rules are JSON data only and are never executed.
    SPDX-License-Identifier: MIT
#>

$script:WdlUiLangs = @('vi', 'en', 'zh-CN', 'km')
$script:WdlHives = @('SOFTWARE', 'SYSTEM', 'DEFAULT', 'NTUSER')
$script:WdlRegTypes = @('REG_DWORD', 'REG_QWORD', 'REG_SZ', 'REG_EXPAND_SZ', 'REG_MULTI_SZ', 'REG_BINARY')
$script:WdlServiceStartTypes = @('Disabled', 'Manual', 'Automatic', 'AutomaticDelayed')

#region ---------- format checks ----------
function Get-WdlEntryOsList {
    # 'win10' | 'win11' | 'both' -> Win10 / Win11 profile names
    param([string]$Os)
    switch ($Os) { 'win10' { return @('Win10') } 'win11' { return @('Win11') } 'both' { return @('Win10', 'Win11') } }
    return @()
}

function Test-WdlLangTable {
    param($Table)
    if (-not ($Table -is [Collections.IDictionary])) { return $false }
    foreach ($l in $script:WdlUiLangs) { if (-not $Table.Contains($l) -or -not ([string]$Table[$l]).Trim()) { return $false } }
    return $true
}

function Test-WdlAppData {
    <# Problems (texts) in a parsed apps.json; empty = valid. #>
    param($Data)
    $bad = @()
    if (-not ($Data -is [Collections.IDictionary])) { return @('apps.json: not a JSON object') }
    $apps = @(Get-WdlJsonVal $Data 'apps' @())
    if ($apps.Count -eq 0) { $bad += 'apps.json: no apps' }
    $seen = @{}
    $n = 0
    foreach ($a in $apps) {
        $n++
        $p = [string](Get-WdlJsonVal $a 'pattern' '')
        $tag = "apps.json #$n ($p)"
        if (-not $p -or $p -notmatch '^[A-Za-z0-9.*_-]+$') { $bad += "${tag}: pattern missing or has characters other than A-Z 0-9 . * _ -" }
        $os = [string](Get-WdlJsonVal $a 'os' '')
        if (@('win10', 'win11', 'both') -notcontains $os) { $bad += "${tag}: os must be win10, win11 or both" }
        if (@('safe', 'aggressive', 'unsafe') -notcontains [string](Get-WdlJsonVal $a 'level' '')) { $bad += "${tag}: level must be safe, aggressive or unsafe" }
        if (-not ((Get-WdlJsonVal $a 'default') -is [bool])) { $bad += "${tag}: default must be true or false" }
        if (-not (Test-WdlLangTable (Get-WdlJsonVal $a 'name'))) { $bad += "${tag}: name needs vi, en, zh-CN and km" }
        foreach ($o in (Get-WdlEntryOsList $os)) { $k = "$o|$p"; if ($seen.ContainsKey($k)) { $bad += "${tag}: listed twice for $o" }; $seen[$k] = 1 }
    }
    foreach ($x in @(Get-WdlJsonVal $Data 'protected' @())) { if (-not ([string]$x)) { $bad += 'apps.json: empty protected pattern' } }
    return $bad
}

function Test-WdlRegOp {
    param($Op, [string]$Kind, [string]$Tag)
    $bad = @()
    if ($script:WdlHives -notcontains [string](Get-WdlJsonVal $Op 'hive' '')) { $bad += "${Tag}: hive must be SOFTWARE, SYSTEM, DEFAULT or NTUSER" }
    $k = [string](Get-WdlJsonVal $Op 'key' '')
    if (-not $k -or $k.StartsWith('\') -or $k -match '^HK') { $bad += "${Tag}: key missing (relative to the hive, without HKLM\...)" }
    if ($Kind -ne 'deleteKey' -and -not [string](Get-WdlJsonVal $Op 'name' '')) { $bad += "${Tag}: value name missing" }
    if ($Kind -eq 'set') {
        if ($script:WdlRegTypes -notcontains [string](Get-WdlJsonVal $Op 'type' '')) { $bad += "${Tag}: type must be one of $($script:WdlRegTypes -join ', ')" }
        if ($null -eq (Get-WdlJsonVal $Op 'value')) { $bad += "${Tag}: value missing" }
    }
    $u = Get-WdlJsonVal $Op 'undo'
    if (-not ($u -is [Collections.IDictionary]) -or @('delete', 'set', 'none') -notcontains [string](Get-WdlJsonVal $u 'action' '')) { $bad += "${Tag}: undo.action must be delete, set or none" }
    return $bad
}

function Test-WdlSystemOp {
    <# Optional online-only operations (services / tasks / features). WinDebloat Tool ignores these keys. #>
    param($Op, [string]$Kind, [string]$Tag)
    $bad = @()
    if (-not ($Op -is [Collections.IDictionary])) { return @("${Tag}: not a JSON object") }
    switch ($Kind) {
        'services' {
            if ([string](Get-WdlJsonVal $Op 'name' '') -notmatch '^[A-Za-z0-9_.-]{1,80}$') { $bad += "${Tag}: service name missing or invalid" }
            if ($script:WdlServiceStartTypes -notcontains [string](Get-WdlJsonVal $Op 'startType' '')) { $bad += "${Tag}: startType must be one of $($script:WdlServiceStartTypes -join ', ')" }
        }
        'tasks' {
            if ([string](Get-WdlJsonVal $Op 'path' '') -notmatch '^\\([A-Za-z0-9 _.()-]+\\)*$') { $bad += "${Tag}: task path must look like \Microsoft\Windows\Folder\" }
            if ([string](Get-WdlJsonVal $Op 'name' '') -notmatch '^[A-Za-z0-9 _.()-]{1,120}$') { $bad += "${Tag}: task name missing or invalid" }
            if ([string](Get-WdlJsonVal $Op 'state' '') -ne 'Disabled') { $bad += "${Tag}: state must be Disabled" }
        }
        'features' {
            if ([string](Get-WdlJsonVal $Op 'name' '') -notmatch '^[A-Za-z0-9_.-]{1,120}$') { $bad += "${Tag}: feature name missing or invalid" }
            if ([string](Get-WdlJsonVal $Op 'state' '') -ne 'Disabled') { $bad += "${Tag}: state must be Disabled" }
        }
    }
    return $bad
}

function Test-WdlTweakData {
    <# Problems (texts) in a parsed tweaks.json; empty = valid. #>
    param($Data)
    $bad = @()
    if (-not ($Data -is [Collections.IDictionary])) { return @('tweaks.json: not a JSON object') }
    $list = @(Get-WdlJsonVal $Data 'tweaks' @())
    if ($list.Count -eq 0) { $bad += 'tweaks.json: no tweaks' }
    $seen = @{}
    $n = 0
    foreach ($t in $list) {
        $n++
        $id = [string](Get-WdlJsonVal $t 'id' '')
        $tag = "tweaks.json #$n ($id)"
        if ($id -notmatch '^[A-Za-z][A-Za-z0-9]*$') { $bad += "${tag}: id must be letters and digits" }
        $os = [string](Get-WdlJsonVal $t 'os' '')
        if (@('win10', 'win11', 'both') -notcontains $os) { $bad += "${tag}: os must be win10, win11 or both" }
        if (@('safe', 'aggressive') -notcontains [string](Get-WdlJsonVal $t 'level' '')) { $bad += "${tag}: level must be safe or aggressive" }
        if (-not ([string](Get-WdlJsonVal $t 'category' ''))) { $bad += "${tag}: category missing" }
        if (-not ((Get-WdlJsonVal $t 'default') -is [bool])) { $bad += "${tag}: default must be true or false" }
        if (-not ((Get-WdlJsonVal $t 'bootWim' $false) -is [bool])) { $bad += "${tag}: bootWim must be true or false" }
        if (-not (Test-WdlLangTable (Get-WdlJsonVal $t 'name'))) { $bad += "${tag}: name needs vi, en, zh-CN and km" }
        if (-not (Test-WdlLangTable (Get-WdlJsonVal $t 'description'))) { $bad += "${tag}: description needs vi, en, zh-CN and km" }
        $ops = 0
        foreach ($kind in @('set', 'deleteKey', 'deleteValue')) {
            $i = 0
            foreach ($op in @(Get-WdlJsonVal $t $kind @())) { $i++; $ops++; $bad += @(Test-WdlRegOp $op $kind "$tag $kind #$i") }
        }
        foreach ($kind in @('services', 'tasks', 'features')) {
            $i = 0
            foreach ($op in @(Get-WdlJsonVal $t $kind @())) { $i++; $ops++; $bad += @(Test-WdlSystemOp $op $kind "$tag $kind #$i") }
        }
        if ($ops -eq 0) { $bad += "${tag}: no operation (set / deleteKey / deleteValue / services / tasks / features)" }
        $boot = @(Get-WdlJsonVal $t 'bootSet' @())
        if ((Get-WdlJsonVal $t 'bootWim' $false) -eq $true) {
            if ($boot.Count -eq 0) { $bad += "${tag}: bootWim is true but bootSet is empty" }
            $i = 0
            foreach ($op in $boot) {
                $i++; $bad += @(Test-WdlRegOp $op 'set' "$tag bootSet #$i")
                if (@('SYSTEM', 'SOFTWARE') -notcontains [string](Get-WdlJsonVal $op 'hive' '')) { $bad += "$tag bootSet #${i}: boot.wim only has the SYSTEM and SOFTWARE hives" }
            }
        } elseif ($boot.Count -gt 0) { $bad += "${tag}: bootSet given but bootWim is false" }
        foreach ($o in (Get-WdlEntryOsList $os)) { $k = "$o|$id"; if ($seen.ContainsKey($k)) { $bad += "${tag}: id used twice for $o" }; $seen[$k] = 1 }
    }
    return $bad
}
#endregion

#region ---------- loading ----------
function ConvertTo-WdlRegOp {
    # JSON registry operation -> engine form (Hive / Key / Value = value name / Type / Data)
    param($Op)
    $h = @{ Hive = [string]$Op['hive']; Key = [string]$Op['key'] }
    if ($Op.Contains('name')) { $h.Value = [string]$Op['name'] }
    if ($Op.Contains('type')) { $h.Type = [string]$Op['type'] }
    if ($Op.Contains('value')) { $h.Data = [string]$Op['value'] }
    return $h
}

function Import-WdlAppData {
    <# apps.json -> @{ Win11; Win10; Protected }. Entry: Id (= pattern), Names, Name, Default, Level, Os, MinBuild, MaxBuild. #>
    param([string]$Path, $Data)
    $d = $Data; if ($null -eq $d) { $d = Read-WdlJsonFile $Path }
    foreach ($b in @(Test-WdlAppData $d)) { Write-WdlLog -Level WARN -En "  $b" -Vi 'mục này trong danh sách ứng dụng bị lỗi' }
    $out = @{ Win11 = @(); Win10 = @(); Protected = @(@(Get-WdlJsonVal $d 'protected' @()) | ForEach-Object { [string]$_ }) }
    foreach ($a in @(Get-WdlJsonVal $d 'apps' @())) {
        $p = [string](Get-WdlJsonVal $a 'pattern' '')
        if (-not $p -or $p -notmatch '^[A-Za-z0-9.*_-]+$' -or -not (Test-WdlLangTable (Get-WdlJsonVal $a 'name'))) { continue }
        $e = @{ Id = $p; Names = $a['name']; Name = (Get-WdlLangText $a['name'] 'en'); Default = ((Get-WdlJsonVal $a 'default' $false) -eq $true)
            Level = [string](Get-WdlJsonVal $a 'level' 'aggressive'); Os = [string]$a['os'] }
        if (Get-WdlJsonVal $a 'minBuild') { $e.MinBuild = [int]$a['minBuild'] }
        if (Get-WdlJsonVal $a 'maxBuild') { $e.MaxBuild = [int]$a['maxBuild'] }
        foreach ($o in (Get-WdlEntryOsList $e.Os)) { $out[$o] += $e }
    }
    return $out
}

function Import-WdlTweakData {
    <# tweaks.json -> @{ Win11; Win10 }. Entry: Id, Names, Descriptions, Category, Level, Default, MinBuild, MaxBuild,
       Set / Delete / DeleteValue / BootSet (registry) and Services / Tasks / Features (online extensions). #>
    param([string]$Path, $Data)
    $d = $Data; if ($null -eq $d) { $d = Read-WdlJsonFile $Path }
    $bad = @(Test-WdlTweakData $d)
    foreach ($b in $bad) { Write-WdlLog -Level WARN -En "  $b" -Vi 'mục này trong danh sách tinh chỉnh bị lỗi' }
    $badIdx = @{}
    foreach ($b in $bad) { if ($b -match '^tweaks\.json #(\d+) ') { $badIdx[[int]$matches[1]] = 1 } }
    $out = @{ Win11 = @(); Win10 = @() }
    $n = 0
    foreach ($t in @(Get-WdlJsonVal $d 'tweaks' @())) {
        $n++
        if ($badIdx.ContainsKey($n)) { continue }
        $e = @{ Id = [string]$t['id']; Names = $t['name']; Descriptions = $t['description']
            Name = (Get-WdlLangText $t['name'] 'en'); Category = [string]$t['category']; Level = [string]$t['level']
            Default = ($t['default'] -eq $true); Os = [string]$t['os'] }
        if (Get-WdlJsonVal $t 'minBuild') { $e.MinBuild = [int]$t['minBuild'] }
        if (Get-WdlJsonVal $t 'maxBuild') { $e.MaxBuild = [int]$t['maxBuild'] }
        $map = @{ set = 'Set'; deleteKey = 'Delete'; deleteValue = 'DeleteValue'; bootSet = 'BootSet' }
        foreach ($k in @($map.Keys)) {
            $ops = @(@(Get-WdlJsonVal $t $k @()) | ForEach-Object { ConvertTo-WdlRegOp $_ })
            if ($ops.Count) { $e[$map[$k]] = $ops }
        }
        $s = @(@(Get-WdlJsonVal $t 'services' @()) | ForEach-Object { @{ Name = [string]$_['name']; StartType = [string]$_['startType'] } }); if ($s.Count) { $e.Services = $s }
        $s = @(@(Get-WdlJsonVal $t 'tasks' @()) | ForEach-Object { @{ Path = [string]$_['path']; Name = [string]$_['name'] } }); if ($s.Count) { $e.Tasks = $s }
        $s = @(@(Get-WdlJsonVal $t 'features' @()) | ForEach-Object { @{ Name = [string]$_['name'] } }); if ($s.Count) { $e.Features = $s }
        foreach ($o in (Get-WdlEntryOsList $e.Os)) { $out[$o] += $e }
    }
    return $out
}

function Get-WdlConfig {
    <# App and tweak lists from the active rule set: @{ Apps; Tweaks; Win10Apps; Win10Tweaks; Protected; RulesDir;
       RulesVersion; RulesSource }. A downloaded set that fails validation falls back to the next one. #>
    $cfg = @{ Apps = @(); Tweaks = @(); Win10Apps = @(); Win10Tweaks = @(); Protected = @() }
    foreach ($c in @(Get-WdlRulesCandidates)) {
        $ap = Join-Path $c.Dir 'apps.json'
        $tp = Join-Path $c.Dir 'tweaks.json'
        $ad = $null; $td = $null
        try { $ad = Read-WdlJsonFile $ap; $td = Read-WdlJsonFile $tp } catch { Write-WdlLog -Level WARN -En "Rules in $($c.Dir) skipped: $($_.Exception.Message)" -Vi 'Bỏ qua bộ quy tắc lỗi'; continue }
        if ($c.Source -eq 'downloaded') {
            $bad = @(Test-WdlRulesContent $ad $td)
            if ($bad.Count) { Write-WdlLog -Level WARN -En "Downloaded rules $($c.Version) skipped: $($bad[0])" -Vi 'Bộ quy tắc đã tải bị lỗi, dùng bộ quy tắc trước đó'; continue }
        }
        $a = Import-WdlAppData -Path $ap -Data $ad
        $t = Import-WdlTweakData -Path $tp -Data $td
        $cfg.Apps = $a.Win11; $cfg.Win10Apps = $a.Win10; $cfg.Protected = $a.Protected
        $cfg.Tweaks = $t.Win11; $cfg.Win10Tweaks = $t.Win10
        if ($c.Source -eq 'downloaded') {
            # a download can add protected apps, never drop the bundled ones
            $bp = Join-Path (Join-Path $script:WdlRoot 'data') 'apps.json'
            try { $cfg.Protected = @(@($cfg.Protected) + @(Get-WdlJsonVal (Read-WdlJsonFile $bp) 'protected' @()) | ForEach-Object { [string]$_ } | Sort-Object -Unique) } catch { $null = $_ }
        }
        $cfg.RulesDir = $c.Dir; $cfg.RulesVersion = [string]$c.Version; $cfg.RulesSource = $c.Source
        return $cfg
    }
    throw 'No usable debloat rules found (data\apps.json, data\tweaks.json) / Không tìm thấy bộ quy tắc hợp lệ'
}
#endregion

#region ---------- auto-update (verified download) ----------
<# Rules = data\apps.json + data\tweaks.json, listed in data\rules-manifest.json:
   { "schema": 1, "version": "2026.11.1.1", "minToolVersion": "1.1.0", "files": [ { "name": "apps.json", "sha256": "<hex>" }, ... ] }
   sha256 covers the file without UTF-8 BOM and with LF line endings (same value for CRLF and LF checkouts).
   Downloaded sets live in <tool>\rules\r-<version>-<hash>; current.txt names the active one, previous.txt the backup. #>
$script:WDL.RulesRepo = 'thanhtai2009/WinDebloatTool'   # GitHub repository that publishes the shared rule data
$script:WDL.RulesBaseUrl = 'https://raw.githubusercontent.com/' + $script:WDL.RulesRepo + '/main/data/'
$script:WDL.RulesTimeoutMs = 10000
$script:WDL.RulesStore = $null      # override of the download store (tests)
$script:WdlRulesManifestName = 'rules-manifest.json'
$script:WdlRulesFiles = @('apps.json', 'tweaks.json')
$script:WdlRulesMaxBytes = 2097152
# registry writes a downloaded rule set may not make: autostart, debugger, shell, service and DLL-load locations
$script:WdlRulesDenyKeys = @(
    '\\CurrentVersion\\Run[^\\]*(\\|$)', '\\Policies\\Explorer\\Run(\\|$)', '\\Windows NT\\CurrentVersion\\Winlogon(\\|$)',
    '\\Windows NT\\CurrentVersion\\Windows(\\|$)', '\\Image File Execution Options(\\|$)', '\\SilentProcessExit(\\|$)',
    '(^|\\)(CurrentControlSet|ControlSet\d+)\\Services(\\|$)', '(^|\\)(CurrentControlSet|ControlSet\d+)\\Control\\Session Manager(\\|$)',
    '(^|\\)Classes(\\|$)', '\\Active Setup\\', '\\Command Processor(\\|$)', '\\Group Policy\\Scripts', '\\ShellServiceObjects',
    '\\ShellExecuteHooks', '\\Browser Helper Objects', '\\Explorer\\SharedTaskScheduler', '\\Terminal Server\\', '\\Print\\Monitors',
    '\\Lsa(\\|$)', '\\NetworkProvider', '\\Winsock'
)
$script:WdlRulesDenyValues = @('Debugger', 'StubPath', 'AutoRun', 'Shell', 'Userinit', 'AppInit_DLLs', 'BootExecute', 'ImagePath', 'ServiceDll', 'GlobalFlag', 'MonitorProcess')

function Get-WdlRulesHash {
    # SHA256 (hex, upper case) of rules bytes without BOM and with LF line endings
    param([byte[]]$Bytes)
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $latin = [Text.Encoding]::GetEncoding(28591)
    $norm = $latin.GetBytes($latin.GetString($Bytes, $start, $Bytes.Length - $start).Replace("`r`n", "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($norm)) -replace '-', '') } finally { $sha.Dispose() }
}

function ConvertFrom-WdlRulesBytes {
    param([byte[]]$Bytes)
    return , (ConvertFrom-WdlJson ([Text.Encoding]::UTF8.GetString($Bytes)))
}

function Test-WdlRulesManifest {
    <# Problems (texts) in a parsed rules manifest; empty = valid. #>
    param($Data)
    if (-not ($Data -is [Collections.IDictionary])) { return @('manifest: not a JSON object') }
    $bad = @()
    if ((Get-WdlJsonVal $Data 'schema') -ne 1) { $bad += 'manifest: schema must be 1' }
    if (-not (ConvertTo-WdlVersion ([string](Get-WdlJsonVal $Data 'version' '')))) { $bad += 'manifest: version must look like 2026.11.1.1' }
    $mt = [string](Get-WdlJsonVal $Data 'minToolVersion' '')
    if ($mt -and -not (ConvertTo-WdlVersion $mt)) { $bad += 'manifest: minToolVersion is not a version' }
    $seen = @{}
    foreach ($f in @(Get-WdlJsonVal $Data 'files' @())) {
        $n = [string](Get-WdlJsonVal $f 'name' '')
        if ($script:WdlRulesFiles -notcontains $n) { $bad += "manifest: unexpected file '$n'"; continue }
        if ($seen.ContainsKey($n)) { $bad += "manifest: $n listed twice" }
        $seen[$n] = 1
        if ([string](Get-WdlJsonVal $f 'sha256' '') -notmatch '^[0-9A-Fa-f]{64}$') { $bad += "manifest: sha256 of $n is not 64 hex digits" }
    }
    foreach ($n in $script:WdlRulesFiles) { if (-not $seen.ContainsKey($n)) { $bad += "manifest: $n missing" } }
    return $bad
}

function Get-WdlManifestHash {
    param($Manifest, [string]$Name)
    foreach ($f in @(Get-WdlJsonVal $Manifest 'files' @())) { if ([string](Get-WdlJsonVal $f 'name' '') -eq $Name) { return ([string]$f['sha256']).ToUpperInvariant() } }
    return ''
}

function Test-WdlRulesText([string]$Text) {
    # registry path / name / data of a downloaded rule: printable, no quotes, no empty or relative segments
    if ($null -eq $Text) { return $true }
    if ($Text -match '["\x00-\x1F]') { return $false }
    if ($Text -match '(^|\\)\.\.?(\\|$)' -or $Text -match '\\\\') { return $false }
    return $true
}

function Test-WdlRegLocationDenied {
    # $true when a registry write to $Key / $Name would touch an autostart / execution location
    param([string]$Key, [string]$Name)
    foreach ($rx in $script:WdlRulesDenyKeys) { if (('\' + $Key) -match $rx) { return $true } }
    if ($Name -and $script:WdlRulesDenyValues -contains $Name) { return $true }
    return $false
}

function Test-WdlRulesPolicy {
    <# Extra limits for downloaded rules (bundled rules are reviewed with the code): registry writes stay out of
       autostart / execution locations, texts are plain, whole-key deletes need a specific key, protected
       patterns are safe, and service / feature changes never touch the hard-protected lists. #>
    param($AppData, $TweakData)
    $bad = @()
    foreach ($p in @(Get-WdlJsonVal $AppData 'protected' @())) { if ([string]$p -notmatch '^[A-Za-z0-9.*_-]+$') { $bad += "apps.json: protected pattern '$p' not allowed" } }
    foreach ($t in @(Get-WdlJsonVal $TweakData 'tweaks' @())) {
        $id = [string](Get-WdlJsonVal $t 'id' '')
        foreach ($kind in @('set', 'bootSet', 'deleteKey', 'deleteValue')) {
            foreach ($op in @(Get-WdlJsonVal $t $kind @())) {
                $key = [string](Get-WdlJsonVal $op 'key' '')
                $name = [string](Get-WdlJsonVal $op 'name' '')
                $tag = "tweaks.json ($id) $kind $key"
                if (-not (Test-WdlRulesText $key) -or -not (Test-WdlRulesText $name) -or -not (Test-WdlRulesText ([string](Get-WdlJsonVal $op 'value' '')))) { $bad += "${tag}: text not allowed"; continue }
                if ($key.EndsWith('\')) { $bad += "${tag}: key ends with \"; continue }
                $u = Get-WdlJsonVal $op 'undo'
                $writes = ($kind -eq 'set' -or $kind -eq 'bootSet' -or [string](Get-WdlJsonVal $u 'action' '') -eq 'set')
                if ($writes) {
                    foreach ($rx in $script:WdlRulesDenyKeys) { if (('\' + $key) -match $rx) { $bad += "${tag}: registry location not allowed for downloaded rules"; break } }
                    if ($script:WdlRulesDenyValues -contains $name) { $bad += "${tag}: value '$name' not allowed for downloaded rules" }
                    if (-not (Test-WdlRulesText ([string](Get-WdlJsonVal $u 'value' '')))) { $bad += "${tag}: undo value not allowed" }
                }
                if ($kind -eq 'deleteKey' -and @($key.Split('\') | Where-Object { $_ }).Count -lt 3) { $bad += "${tag}: key too general to delete" }
            }
        }
        foreach ($op in @(Get-WdlJsonVal $t 'services' @())) {
            $n = [string](Get-WdlJsonVal $op 'name' '')
            if (Get-WdlServiceBlockReason $n) { $bad += "tweaks.json ($id) services ${n}: protected service" }
        }
        foreach ($op in @(Get-WdlJsonVal $t 'features' @())) {
            $n = [string](Get-WdlJsonVal $op 'name' '')
            if (Get-WdlFeatureBlockReason $n) { $bad += "tweaks.json ($id) features ${n}: protected feature" }
        }
    }
    return $bad
}

function Test-WdlRulesContent {
    <# Full check of a downloaded rule set (parsed apps.json / tweaks.json): schema 1, no format errors, policy. #>
    param($AppData, $TweakData)
    $bad = @()
    if (-not ($AppData -is [Collections.IDictionary]) -or (Get-WdlJsonVal $AppData 'schema') -ne 1) { $bad += 'apps.json: schema must be 1' }
    if (-not ($TweakData -is [Collections.IDictionary]) -or (Get-WdlJsonVal $TweakData 'schema') -ne 1) { $bad += 'tweaks.json: schema must be 1' }
    if ($bad.Count) { return $bad }
    $bad += @(Test-WdlAppData $AppData)
    $bad += @(Test-WdlTweakData $TweakData)
    if ($bad.Count -eq 0) { $bad += @(Test-WdlRulesPolicy $AppData $TweakData) }
    return $bad
}

function Get-WdlRulesStores {
    <# Folder that may hold downloaded rules: <tool>\rules only. A rule set is verified against the manifest stored
       next to it, so that folder must be as trusted as the code itself; user-writable profile folders are never
       used by the elevated tool. When the tool folder is read-only, the bundled rules are used. #>
    if ($script:WDL.RulesStore) { return @($script:WDL.RulesStore) }
    if ($script:WdlRoot) { return @(Join-Path $script:WdlRoot 'rules') }
    return @()
}

function Get-WdlRulesWriteStore {
    foreach ($d in @(Get-WdlRulesStores)) {
        try {
            New-WdlDirectory $d
            $probe = Join-Path $d ('.wdlw' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, '')
            [IO.File]::Delete($probe)
            return $d
        } catch { $null = $_ }
    }
    return $null
}

function Read-WdlRulesManifestFile {
    param([string]$Dir)
    $p = Join-Path $Dir $script:WdlRulesManifestName
    if (-not (Test-WdlPathText $p -Leaf)) { return $null }
    try { $m = ConvertFrom-WdlRulesBytes ([IO.File]::ReadAllBytes($p)) } catch { return $null }
    if (@(Test-WdlRulesManifest $m).Count) { return $null }
    return , $m
}

function Test-WdlRulesDir {
    <# Version of a rules folder whose files match its manifest (and whose minToolVersion this engine meets), else $null. #>
    param([string]$Dir, [switch]$SkipHash)
    $m = Read-WdlRulesManifestFile $Dir
    if (-not $m) { return $null }
    $mt = ConvertTo-WdlVersion ([string](Get-WdlJsonVal $m 'minToolVersion' ''))
    if ($mt -and $mt -gt (ConvertTo-WdlVersion $script:WDL.RulesCompat)) { return $null }
    if (-not $SkipHash) {
        foreach ($n in $script:WdlRulesFiles) {
            $p = Join-Path $Dir $n
            if (-not (Test-WdlPathText $p -Leaf)) { return $null }
            if ((Get-WdlRulesHash ([IO.File]::ReadAllBytes($p))) -ne (Get-WdlManifestHash $m $n)) { return $null }
        }
    }
    return (ConvertTo-WdlVersion ([string]$m['version']))
}

function Get-WdlRulesPointer {
    param([string]$Store, [string]$Name)
    $p = Join-Path $Store $Name
    if (-not (Test-WdlPathText $p -Leaf)) { return $null }
    try { $n = ([IO.File]::ReadAllText($p)).Trim() } catch { return $null }
    if ($n -notmatch '^r-[0-9.]+-[0-9A-F]{8}$') { return $null }
    return (Join-Path $Store $n)
}

function Get-WdlRulesCandidates {
    <# Usable rule sets, best first: downloaded (current, previous) newer than the bundled set, then data\. #>
    $bdir = Join-Path $script:WdlRoot 'data'
    $bv = Test-WdlRulesDir $bdir -SkipHash
    if (-not $bv) { $bv = New-Object Version 0, 0 }
    $list = @()
    foreach ($s in @(Get-WdlRulesStores)) {
        foreach ($ptr in @('current.txt', 'previous.txt')) {
            $d = Get-WdlRulesPointer $s $ptr
            if (-not $d -or @($list | Where-Object { $_.Dir -eq $d }).Count) { continue }
            $v = Test-WdlRulesDir $d
            if ($v -and $v -gt $bv) { $list += @{ Dir = $d; Version = $v; Source = 'downloaded' } }
        }
    }
    $list = @($list | Sort-Object -Property @{ Expression = { $_.Version } } -Descending)
    $list += @{ Dir = $bdir; Version = $bv; Source = 'bundled' }
    return $list
}

function Get-WdlActiveRules { return (@(Get-WdlRulesCandidates))[0] }

function Get-WdlRulesHttp {
    <# GET into memory: no redirects, size cap, the remaining time of $Clock is the limit. #>
    param([string]$Url, [Diagnostics.Stopwatch]$Clock, [int]$TimeoutMs, [int]$MaxBytes)
    $left = $TimeoutMs - [int]$Clock.ElapsedMilliseconds
    if ($left -le 0) { throw (New-Object TimeoutException 'rules check: time limit reached') }
    $req = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $req.Method = 'GET'; $req.Timeout = $left; $req.ReadWriteTimeout = $left; $req.AllowAutoRedirect = $false
    $req.UserAgent = "WinDebloatLive/$($script:WDL.Version)"
    $req.Headers.Add('Cache-Control', 'no-cache')
    try { if ($req.Proxy) { $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials } } catch { $null = $_ }
    $resp = $req.GetResponse()
    try {
        if ([int]$resp.StatusCode -ne 200) { throw "HTTP $([int]$resp.StatusCode)" }
        if ($resp.ContentLength -gt $MaxBytes) { throw 'rules file too large' }
        $s = $resp.GetResponseStream()
        $ms = New-Object IO.MemoryStream
        $buf = New-Object byte[] 32768
        while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) {
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt $MaxBytes) { throw 'rules file too large' }
            if ($Clock.ElapsedMilliseconds -ge $TimeoutMs) { throw (New-Object TimeoutException 'rules check: time limit reached') }
        }
        return , ($ms.ToArray())
    } finally { $resp.Close() }
}

function Test-WdlRulesUrl {
    # only the rules repository's GitHub raw folder over HTTPS; -AllowTestUrl also accepts http://127.0.0.1 (tests)
    param([string]$Url, [switch]$AllowTestUrl)
    if ($Url -match ('^https://raw\.githubusercontent\.com/' + [regex]::Escape($script:WDL.RulesRepo) + '/[A-Za-z0-9._/-]+/$') -and $Url -notmatch '/\.\.?/') { return $true }
    if ($AllowTestUrl -and $Url -match '^http://127\.0\.0\.1:\d+/[A-Za-z0-9._/-]*$') { return $true }
    return $false
}

function Install-WdlRules {
    <# Writes a verified rule set as a new folder, then switches current.txt to it (previous.txt keeps the old one). #>
    param([string]$Store, [byte[]]$ManifestBytes, [hashtable]$Files, [string]$Version, [string]$Hash)
    $name = 'r-{0}-{1}' -f $Version, $Hash.Substring(0, 8)
    $final = Join-Path $Store $name
    $tmp = Join-Path $Store ('tmp-' + [guid]::NewGuid().ToString('N'))
    New-WdlDirectory $tmp
    try {
        foreach ($n in @($Files.Keys)) { [IO.File]::WriteAllBytes((Join-Path $tmp $n), [byte[]]$Files[$n]) }
        [IO.File]::WriteAllBytes((Join-Path $tmp $script:WdlRulesManifestName), $ManifestBytes)
        if (-not (Test-WdlRulesDir $tmp)) { throw 'rules: written files do not match the manifest' }
        if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
        [IO.Directory]::Move($tmp, $final)
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
    $cur = Join-Path $Store 'current.txt'; $prev = Join-Path $Store 'previous.txt'; $new = Join-Path $Store 'current.txt.new'
    [IO.File]::WriteAllText($new, $name)
    if (-not (Test-Path -LiteralPath $cur)) { [IO.File]::Move($new, $cur) }
    elseif ((Get-WdlRulesPointer $Store 'current.txt') -eq $final) { [IO.File]::Delete($new) }
    else {
        try { [IO.File]::Replace($new, $cur, $prev) }
        catch { [IO.File]::Copy($cur, $prev, $true); [IO.File]::Delete($cur); [IO.File]::Move($new, $cur) }
    }
    $keep = @($final, (Get-WdlRulesPointer $Store 'previous.txt'))
    foreach ($d in @(Get-ChildItem -LiteralPath $Store | Where-Object { $_.PSIsContainer -and $_.Name -match '^(r-|tmp-)' })) {
        if ($keep -notcontains $d.FullName) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $final
}

function Update-WdlRules {
    <# Checks the rules URL for a newer verified rule set and installs it. Never throws; at most -TimeoutMs
       (default 10 s). Returns @{ Status = Updated | UpToDate | Offline | Timeout | Rejected | Failed; Version; Dir;
       Error; ElapsedMs }. Anything but Updated leaves the current rules untouched. #>
    param([string]$BaseUrl, [int]$TimeoutMs = 0, [switch]$AllowTestUrl)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $res = @{ Status = 'Failed'; Version = ''; Dir = ''; Error = ''; ElapsedMs = 0 }
    if (-not $BaseUrl) { $BaseUrl = $script:WDL.RulesBaseUrl }
    if ($TimeoutMs -le 0) { $TimeoutMs = $script:WDL.RulesTimeoutMs }
    try {
        if (-not (Test-WdlRulesUrl $BaseUrl -AllowTestUrl:$AllowTestUrl)) { $res.Status = 'Rejected'; throw "rules URL not allowed: $BaseUrl" }
        [void](Enable-WdlTls12)
        $active = Get-WdlActiveRules
        $mb = Get-WdlRulesHttp -Url ($BaseUrl + $script:WdlRulesManifestName) -Clock $clock -TimeoutMs $TimeoutMs -MaxBytes 65536
        $m = $null
        try { $m = ConvertFrom-WdlRulesBytes $mb } catch { $res.Status = 'Rejected'; throw "manifest: $($_.Exception.Message)" }
        $bad = @(Test-WdlRulesManifest $m)
        if ($bad.Count) { $res.Status = 'Rejected'; throw ($bad -join '; ') }
        $ver = ConvertTo-WdlVersion ([string]$m['version'])
        $res.Version = [string]$ver
        $mt = ConvertTo-WdlVersion ([string](Get-WdlJsonVal $m 'minToolVersion' ''))
        $files = $null; $parsed = @{}; $names = @()
        if ($ver -le $active.Version -or ($mt -and $mt -gt (ConvertTo-WdlVersion $script:WDL.RulesCompat))) { $res.Status = 'UpToDate'; $res.Dir = $active.Dir }
        else { $files = @{}; $names = $script:WdlRulesFiles }
        foreach ($n in $names) {
            $b = Get-WdlRulesHttp -Url ($BaseUrl + $n) -Clock $clock -TimeoutMs $TimeoutMs -MaxBytes $script:WdlRulesMaxBytes
            if ((Get-WdlRulesHash $b) -ne (Get-WdlManifestHash $m $n)) { $res.Status = 'Rejected'; throw "SHA256 of $n does not match the manifest" }
            try { $parsed[$n] = ConvertFrom-WdlRulesBytes $b } catch { $res.Status = 'Rejected'; throw "${n}: $($_.Exception.Message)" }
            $files[$n] = $b
        }
        if ($null -ne $files) {
            $bad = @(Test-WdlRulesContent $parsed['apps.json'] $parsed['tweaks.json'])
            if ($bad.Count) { $res.Status = 'Rejected'; throw ((@($bad | Select-Object -First 5)) -join '; ') }
            if ($clock.ElapsedMilliseconds -ge $TimeoutMs) { throw (New-Object TimeoutException 'rules check: time limit reached') }
            $store = Get-WdlRulesWriteStore
            if (-not $store) { throw 'no writable folder for downloaded rules' }
            $res.Dir = Install-WdlRules -Store $store -ManifestBytes $mb -Files $files -Version ([string]$ver) -Hash (Get-WdlRulesHash $mb)
            $res.Status = 'Updated'
        }
    } catch {
        $e = $_.Exception
        while ($e.InnerException -and -not ($e -is [Net.WebException]) -and -not ($e -is [TimeoutException])) { $e = $e.InnerException }
        if ($res.Status -ne 'Rejected') {
            $res.Status = 'Failed'
            if ($e -is [TimeoutException]) { $res.Status = 'Timeout' }
            elseif ($e -is [Net.WebException]) {
                $ws = [string]$e.Status
                if ($ws -eq 'Timeout') { $res.Status = 'Timeout' }
                elseif ($ws -match 'NameResolutionFailure|ConnectFailure|ProxyNameResolutionFailure|ConnectionClosed|SendFailure|ReceiveFailure|SecureChannelFailure|TrustFailure') { $res.Status = 'Offline' }
            }
            if ($res.Status -eq 'Failed' -and -not ($e -is [Net.WebException] -and [string]$e.Status -eq 'ProtocolError')) {
                for ($x = $_.Exception; $x; $x = $x.InnerException) { if ($x.GetType().Name -match '^(SocketException|HttpRequestException)$') { $res.Status = 'Offline'; break } }
            }
        }
        $res.Error = $e.Message
    } finally { $res.ElapsedMs = [int]$clock.ElapsedMilliseconds }
    return (New-WdlObj $res)
}

function Write-WdlRulesResult {
    param($Result)
    if (-not $Result) { return }
    switch ([string]$Result.Status) {
        'Updated' { Write-WdlLog -Level OK -En "Debloat rules updated to version $($Result.Version) (SHA256 verified)" -Vi "Đã cập nhật bộ quy tắc lên phiên bản $($Result.Version) (đã xác minh SHA256)" }
        'UpToDate' { Write-WdlLog -En 'Debloat rules are up to date' -Vi 'Bộ quy tắc đã là bản mới nhất' }
        'Rejected' { Write-WdlLog -Level WARN -En "Downloaded debloat rules rejected, current rules kept: $($Result.Error)" -Vi 'Bộ quy tắc tải về không hợp lệ, giữ nguyên quy tắc hiện tại' }
        default { Write-WdlLog -En "Rules check skipped ($($Result.Status): $($Result.Error)), current rules kept" -Vi 'Không kiểm tra được bộ quy tắc mới, giữ nguyên quy tắc hiện tại' }
    }
}
#endregion
