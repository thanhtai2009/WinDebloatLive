<#
.SYNOPSIS
    WinDebloat Live - debloat and optimize the running Windows 10 / 11 PC.
    Gỡ ứng dụng cài sẵn và tối ưu trực tiếp máy Windows 10 / 11 đang dùng.

.DESCRIPTION
    Without parameters a GUI opens (Simple mode: one button; Advanced mode: pick every app and setting).
    With -NoGui the recommended (or aggressive) preset runs in the console.
    Every change is written to a JSON backup first (%ProgramData%\WinDebloatLive\backups) and can be undone;
    a System Restore point is created before changes. Needs Windows 10 1809+ or Windows 11 and Windows
    PowerShell 5.1, run as administrator (run.bat elevates).

.EXAMPLE
    .\WinDebloatLive.ps1
.EXAMPLE
    .\WinDebloatLive.ps1 -Mode Advanced
.EXAMPLE
    .\WinDebloatLive.ps1 -NoGui -Preview
    (shows what the recommended preset would change on this PC, changes nothing)
.EXAMPLE
    .\WinDebloatLive.ps1 -NoGui -Preset aggressive -AppScope CurrentUser
.EXAMPLE
    .\WinDebloatLive.ps1 -NoGui -Yes -EnableSystemProtection -Restart
    (unattended: turns System Protection on if needed, restore point, recommended preset, restart)
.EXAMPLE
    .\WinDebloatLive.ps1 -ListBackups
.EXAMPLE
    .\WinDebloatLive.ps1 -Undo latest
.EXAMPLE
    .\WinDebloatLive.ps1 -UpdateRules
#>
[CmdletBinding()]
param(
    [ValidateSet('Simple', 'Advanced')][string]$Mode,    # GUI: open this mode (skips the chooser)
    [switch]$NoGui,                                      # console run
    [ValidateSet('recommended', 'aggressive')][string]$Preset = 'recommended',
    [switch]$Preview,                                    # console: show the planned changes and exit
    [switch]$Yes,                                        # console: no questions (unattended)
    [switch]$NoRestorePoint,                             # console: skip the System Restore point
    [switch]$EnableSystemProtection,                     # consent to turn System Protection on for the restore point
    [ValidateSet('AllUsers', 'CurrentUser')][string]$AppScope = 'AllUsers',
    [switch]$NoDefaultUser,                              # do not write user settings into the Default profile
    [string]$Undo,                                       # 'latest' or the path of a backup .json
    [switch]$ListBackups,
    [switch]$UpdateRules,                                # check for newer verified debloat rules now and exit
    [switch]$Restart                                     # console: restart at the end when a restart is needed
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { $null = $_ }

function Get-WdlRelaunchArgs {
    # command line for a new Windows PowerShell instance with the same parameters
    param([string]$Script, [hashtable]$Bound)
    $q = { param($s) '"' + ([string]$s).Replace('"', '\"') + '"' }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (& $q $Script))
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ([bool]$v) { $a += "-$k" } }
        else { $a += "-$k"; $a += (& $q $v) }
    }
    return ($a -join ' ')
}

function Start-WdlRelaunch {
    # runs the tool again with $Exe (and -Verb RunAs for elevation); returns its exit code
    param([string]$Exe, [switch]$Elevate)
    $argLine = Get-WdlRelaunchArgs -Script $script:EntryPath -Bound $script:EntryArgs
    $p = @{ FilePath = $Exe; ArgumentList = $argLine; PassThru = $true }
    if ($Elevate) { $p.Verb = 'RunAs' } else { $p.NoNewWindow = $true; $p.Wait = $true }
    $proc = Start-Process @p
    if ($Elevate) { return 0 }
    return $proc.ExitCode
}
$script:EntryPath = $MyInvocation.MyCommand.Path
$script:EntryArgs = @{} + $PSBoundParameters

# Smart App Control, WDAC or AppLocker run untrusted scripts in ConstrainedLanguage mode, where the tool cannot work
$langMode = 'FullLanguage'
try { $langMode = [string]$ExecutionContext.SessionState.LanguageMode } catch { $null = $_ }
if ($langMode -ne 'FullLanguage') {
    $hereQ = $here.Replace("'", "''")
    Write-Host "PowerShell runs in $langMode mode here (Smart App Control, WDAC or AppLocker), so the tool cannot start." -ForegroundColor Red
    Write-Host 'The files probably still carry the "downloaded from the Internet" mark. Unblock them and start run.bat again:'
    Write-Host '  - before extracting: right-click the .zip > Properties > tick Unblock > OK, then extract again, or'
    Write-Host "  - in PowerShell: Get-ChildItem -LiteralPath '$hereQ' -Recurse | Unblock-File"
    Write-Host "PowerShell đang chạy ở chế độ $langMode (Smart App Control, WDAC hoặc AppLocker) nên công cụ không chạy được." -ForegroundColor Red
    Write-Host 'Hãy bỏ chặn (Unblock) các file rồi chạy lại run.bat:'
    Write-Host '  - trước khi giải nén: chuột phải file .zip > Properties > tích Unblock > OK, rồi giải nén lại, hoặc'
    Write-Host "  - trong PowerShell: Get-ChildItem -LiteralPath '$hereQ' -Recurse | Unblock-File"
    exit 1
}

$winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sysnative = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
# PowerShell 7 (Core): Appx, WinForms in a runspace and DISM cmdlets behave differently -> Windows PowerShell 5.1
if ($PSVersionTable.PSEdition -eq 'Core') {
    if (Test-Path -LiteralPath $winPs) { exit (Start-WdlRelaunch -Exe $winPs) }
    Write-Host 'Windows PowerShell 5.1 is required.' -ForegroundColor Red; exit 1
}
# 32-bit PowerShell on 64-bit Windows sees a redirected registry and System32 -> 64-bit PowerShell
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    if (Test-Path -LiteralPath $sysnative) { exit (Start-WdlRelaunch -Exe $sysnative) }
    Write-Host '64-bit PowerShell is required on 64-bit Windows.' -ForegroundColor Red; exit 1
}
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "Windows PowerShell 5.1 is required (found $($PSVersionTable.PSVersion))." -ForegroundColor Red; exit 1
}

foreach ($l in @('Common', 'Rules', 'Plan', 'System', 'Engine')) { . (Join-Path $here "lib\$l.ps1") }

if (-not (Test-WdlAdmin)) {
    Write-Host 'Requesting administrator rights... / Đang xin quyền Administrator...'
    try { $null = Start-WdlRelaunch -Exe $winPs -Elevate; exit 0 }
    catch { Write-Host 'Administrator rights are required. / Cần quyền Administrator.' -ForegroundColor Red; exit 1 }
}

$guiMode = -not $NoGui -and -not $Preview -and -not $ListBackups -and -not $UpdateRules -and -not $Undo
function Show-WdlStartError([string]$Text) {
    if (-not $guiMode) { return }
    try { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($Text, $script:WDL.Name, 'OK', 'Error') } catch { $null = $_ }
}
$os = Get-WdlOsInfo
if (-not $os.Supported) {
    Write-Host "Not supported: $($os.Reason)" -ForegroundColor Red
    Show-WdlStartError "Not supported:`n$($os.Reason)"
    exit 1
}
# one instance at a time: two runs would race on the registry, the Default profile hive and the backups
if (-not $ListBackups) {
    $owned = $false
    try {
        $script:WdlMutex = New-Object Threading.Mutex($false, 'Global\WinDebloatLive')
        try { $owned = $script:WdlMutex.WaitOne(0) } catch { $owned = $true }   # abandoned by a crashed run: ours now
    } catch { $owned = $false }   # exists but not accessible: held by another user's instance
    if (-not $owned) {
        $t = "WinDebloat Live is already running. Close the other window first.`nWinDebloat Live đang chạy. Hãy đóng cửa sổ kia trước."
        Write-Host $t -ForegroundColor Red
        Show-WdlStartError $t
        exit 4
    }
}
$null = Initialize-WdlDataDir
$script:WDL.LogPath = Join-Path (Join-Path (Get-WdlDataDir) 'logs') ('WinDebloatLive_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Write-WdlLog -En "$($script:WDL.Name) $($script:WDL.Version) - $($os.ProductName) $($os.DisplayVersion) build $($os.Build).$($os.Ubr) - PowerShell $($PSVersionTable.PSVersion)"
$conLang = 'en'; if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'vi*') { $conLang = 'vi' }

function Read-WdlYes([string]$Question) {
    $a = Read-Host "$Question [y/N]"
    return ($a -match '^\s*(y|yes|c|co|có)\s*$')
}

try {
    if ($ListBackups) {
        $b = @(Get-WdlBackups)
        if (-not $b.Count) { Write-Host 'No backups yet. / Chưa có bản sao lưu.' }
        else { $b | Format-Table -AutoSize Created, Changes, Restored, Path | Out-String -Width 300 | Write-Host }
        exit 0
    }
    if ($UpdateRules) {
        $r = Update-WdlRules
        Write-WdlRulesResult $r
        if (@('Updated', 'UpToDate') -contains [string]$r.Status) { exit 0 }
        exit 1
    }
    if ($Undo) {
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Undo)   # relative to the PowerShell location
        if ($Undo -eq 'latest') {
            $b = @(Get-WdlBackups | Where-Object { -not $_.Restored })
            if (-not $b.Count) { Write-Host 'No backup to undo. / Không có bản sao lưu để hoàn tác.'; exit 1 }
            $path = $b[0].Path
        }
        if (-not (Test-WdlPathText $path -Leaf)) { throw "Backup not found: $path" }
        if (-not (Test-WdlPathInside -Path ([IO.Path]::GetFullPath($path)) -Parent (Get-WdlBackupDir))) {
            Write-WdlLog -Level WARN -En "Backup outside $(Get-WdlBackupDir): only registry locations this tool changes are restored" -Vi 'File sao lưu nằm ngoài thư mục sao lưu'
        }
        if (-not $Yes -and -not (Read-WdlYes "Undo the changes in $path ?")) { exit 0 }
        $u = Invoke-WdlUndo -Path $path
        foreach ($m in @($u.Manual | Select-Object -Unique)) { Write-Host "Reinstall from Microsoft Store if needed: $m" -ForegroundColor Yellow }
        if ($u.Restored -gt 0) {
            if ($Restart) { Restart-WdlComputer } elseif (-not $Yes -and (Read-WdlYes 'Restart now? / Khởi động lại ngay?')) { Restart-WdlComputer }
        }
        if ($u.Failed) { exit 3 }
        exit 0
    }
    if (-not $NoGui -and -not $Preview) {
        . (Join-Path $here 'lib\Gui.ps1')
        Show-WdlGui -Mode $Mode
        exit 0
    }

    # ---- console ----
    $session = Get-WdlSession
    $sel = Get-WdlPresetSelection -AppRows $session.AppRows -TweakRows $session.TweakRows -Preset $Preset
    $opt = New-WdlOptions -Session $session -AppScope $AppScope -DefaultUser (-not $NoDefaultUser) -RestorePoint (-not $NoRestorePoint) -EnableProtection ([bool]$EnableSystemProtection)
    $plan = Get-WdlResolvedPlan -Session $session -AppIds $sel.Apps -TweakIds $sel.Tweaks -Options $opt
    Write-Host ''
    Write-Host (Format-WdlPreview -Plan $plan -Lang $conLang)
    $counts = Get-WdlPlanCounts $plan
    if ($Preview) { exit 0 }
    if ($counts.Total -eq 0) { Write-Host 'Nothing to change. / Không có gì cần thay đổi.'; exit 0 }
    if (-not $Yes -and -not (Read-WdlYes 'Apply these changes? / Áp dụng các thay đổi này?')) { exit 0 }
    $rp = $null
    if (-not $NoRestorePoint) {
        $rp = Invoke-WdlRestorePointStep -EnableProtection ([bool]$EnableSystemProtection)
        if (-not $rp.Ok) {
            Write-Host "No restore point: $($rp.Error)" -ForegroundColor Yellow
            if ($Yes) {
                Write-Host 'Stopped. Use -EnableSystemProtection to allow turning System Protection on, or -NoRestorePoint to continue without one.' -ForegroundColor Red
                exit 2
            }
            if (-not (Read-WdlYes 'Continue without a restore point (the backup still allows Undo)? / Tiếp tục mà không có điểm khôi phục?')) { exit 2 }
        }
    }
    $sum = Invoke-WdlApply -Session $session -Plan $plan -RestorePoint $rp
    Write-Host "Backup: $($sum.BackupPath)"
    Write-Host "Log: $($script:WDL.LogPath)"
    if ($sum.Reboot) {
        if ($Restart) { Restart-WdlComputer }
        elseif (-not $Yes -and (Read-WdlYes 'Restart now to finish? / Khởi động lại ngay để hoàn tất?')) { Restart-WdlComputer }
        else { Write-Host 'Restart the PC to finish the changes. / Hãy khởi động lại máy để hoàn tất.' }
    }
    if ($sum.Failed) { exit 3 }
    exit 0
} catch {
    Write-WdlLog -Level ERROR -En $_.Exception.Message
    if ($script:WDL.LogPath) { try { [IO.File]::AppendAllText($script:WDL.LogPath, '    ' + $_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace + "`r`n") } catch { $null = $_ } }
    Show-WdlStartError ($_.Exception.Message + "`n`nLog: " + $script:WDL.LogPath)
    exit 1
}
