<#
    Runs every test script; exit code = number of failed scripts.
#>
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$failed = 0
foreach ($t in @('Test-Parse.ps1', 'Test-Rules.ps1', 'Test-Engine.ps1', 'Test-Analyzer.ps1')) {
    Write-Host "=== $t ===" -ForegroundColor Cyan
    $exe = (Get-Process -Id $PID).Path
    & $exe -NoProfile -File (Join-Path $here $t)
    if ($LASTEXITCODE -ne 0) { $failed++; Write-Host "$t failed ($LASTEXITCODE)" -ForegroundColor Red }
}
Write-Host ''
if ($failed) { Write-Host "$failed test script(s) failed" -ForegroundColor Red } else { Write-Host 'All test scripts passed' -ForegroundColor Green }
exit $failed
