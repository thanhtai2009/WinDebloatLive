<#
    PSScriptAnalyzer over every script with PSScriptAnalyzerSettings.psd1 (Error + Warning). Needs the
    PSScriptAnalyzer module (Install-Module PSScriptAnalyzer -Scope CurrentUser).
#>
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Write-Host 'SKIP: PSScriptAnalyzer is not installed'; exit 0 }
Import-Module PSScriptAnalyzer
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$all = @()
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psd1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })) {
    $all += @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings)
}
foreach ($d in $all) { Write-Host ("{0}:{1} [{2}] {3}: {4}" -f $d.ScriptName, $d.Line, $d.Severity, $d.RuleName, $d.Message) -ForegroundColor Yellow }
Write-Host ("Analyzer: {0} finding(s) (PSScriptAnalyzer {1})" -f $all.Count, (Get-Module PSScriptAnalyzer).Version)
exit $all.Count
