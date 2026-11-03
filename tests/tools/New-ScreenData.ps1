<#
    Sample data for the screenshot harness (Shots.cs): app / tweak rows, preview text and an apply log produced by
    the real engine against the mocked Windows 11 PC of tests\Mocks.ps1.
#>
param([Parameter(Mandatory = $true)][string]$OutDir)
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
foreach ($f in @('Common', 'Rules', 'Plan', 'System', 'Engine')) { . (Join-Path $root "lib\$f.ps1") }
. (Join-Path $root 'tests\Mocks.ps1')
$null = New-Item -ItemType Directory -Path $OutDir -Force
Set-MockOs 26100
$cfg = Get-WdlConfig
foreach ($a in @($cfg.Apps | Select-Object -First 30)) { Add-MockApp ($a.Id -replace '\*', '') }
Add-MockApp 'Microsoft.WindowsTerminal'
$s = Get-WdlSession -Config $cfg
$sel = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset recommended
$enc = New-Object Text.UTF8Encoding $false
foreach ($lang in @('en', 'vi')) {
    $rows = foreach ($r in @($s.AppRows | Where-Object { $_.Present })) {
        $lvl = $r.Level; if ($r.OptIn) { $lvl = 'optin' }
        "{0}`t{1}`t{2}`t{3}" -f (Get-WdlLangText $r.Names $lang), $r.Id, [int]($sel.Apps -contains $r.Id), $lvl
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "apps_$lang.tsv"), ($rows -join "`n"), $enc)
    $rows = foreach ($r in @($s.TweakRows | Where-Object { $_.Usable })) {
        "{0}`t{1}`t{2}`t{3}" -f (Get-WdlLangText $r.Names $lang), (Get-WdlLangText $r.Descriptions $lang), [int]($sel.Tweaks -contains $r.Id), $r.Level
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "tweaks_$lang.tsv"), ($rows -join "`n"), $enc)
    $opt = New-WdlOptions -Session $s
    $plan = Get-WdlResolvedPlan -Session $s -AppIds $sel.Apps -TweakIds $sel.Tweaks -Options $opt
    [IO.File]::WriteAllText((Join-Path $OutDir "preview_$lang.txt"), (Format-WdlPreview -Plan $plan -Lang $lang), $enc)
}
$log = Join-Path $OutDir 'apply.log'
$script:WDL.LogPath = $log
$opt = New-WdlOptions -Session $s
$plan = Get-WdlResolvedPlan -Session $s -AppIds @($sel.Apps | Select-Object -First 4) -TweakIds @($sel.Tweaks | Select-Object -First 3) -Options $opt
$null = Invoke-WdlApply -Session $s -Plan $plan -RestorePoint (New-WdlObj @{ Ok = $true; Sequence = 42 }) 6>$null
$lines = @([IO.File]::ReadAllLines($log) | Where-Object { $_ -notmatch 'Backup file' })
foreach ($lang in @('en', 'vi')) {
    $out = foreach ($l in $lines) {
        $i = $l.IndexOf(' | ')
        if ($i -lt 0) { $l } elseif ($lang -eq 'vi') { $l.Substring(0, $l.IndexOf('] ', $l.IndexOf('] ') + 2) + 2) + $l.Substring($i + 3).TrimStart() } else { $l.Substring(0, $i) }
    }
    [IO.File]::WriteAllText((Join-Path $OutDir "log_$lang.txt"), (@($out | Select-Object -Last 14) -join "`n"), $enc)
}
Remove-Item -LiteralPath $script:MockDataDir -Recurse -Force -ErrorAction SilentlyContinue
