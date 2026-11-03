<#
    Unit tests for rule mapping, the safety lists, apply + backup + undo round trips and the restore point step.
    Every system call is mocked (tests\Mocks.ps1), so this runs on pwsh anywhere. It does not prove behaviour on
    real Windows.
#>
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($f in @('Common', 'Rules', 'Plan', 'System', 'Engine')) { . (Join-Path $root "lib\$f.ps1") }
. (Join-Path $root 'tests\Mocks.ps1')
$script:fail = 0; $script:pass = 0
function Assert($cond, $msg) { if ($cond) { $script:pass++; Write-Host "PASS $msg" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL $msg" -ForegroundColor Red } }
function Reset-Mock { $script:MockReg = @{}; $script:MockApps.Clear(); $script:MockProv.Clear(); $script:MockLog.Clear(); $script:MockFail = @{}; $script:MockMounts = 0 }
$cfg = Get-WdlConfig
$sid = $script:MockUser.Sid
$def = $script:WdlDefaultHiveName

# ---------------- OS detection ----------------
Reset-Mock; Set-MockOs 26100
$os = Get-WdlOsInfo
Assert ($os.Os -eq 'Win11' -and $os.Build -eq 26100 -and $os.Supported -and $os.ProductName -eq 'Windows 11 Pro') 'build 26100 -> Windows 11, product name fixed'
Reset-Mock; Set-MockOs 19045
Assert ((Get-WdlOsInfo).Os -eq 'Win10') 'build 19045 -> Windows 10'
Reset-Mock; Set-MockOs 17134
Assert (-not (Get-WdlOsInfo).Supported) 'build 17134 (1803) is refused'
Reset-Mock; Set-MockOs 20348 'Server'
Assert (-not (Get-WdlOsInfo).Supported) 'Windows Server is refused'

# ---------------- safety lists ----------------
foreach ($n in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs.140.00.UWPDesktop', 'Microsoft.NET.Native.Runtime.2.2',
        'Microsoft.UI.Xaml.2.8', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.SecHealthUI', 'Microsoft.WindowsTerminal')) {
    Assert ([bool](Get-WdlAppBlockReason -Name $n -Protected @())) "hard blocklist: $n"
}
Assert (-not (Get-WdlAppBlockReason -Name 'Microsoft.WindowsTerminal' -Protected @('Microsoft.WindowsTerminal') -OptIn)) 'Windows Terminal removable only with the explicit opt-in'
Assert (-not (Get-WdlAppBlockReason -Name 'Microsoft.BingNews' -Protected $cfg.Protected)) 'Microsoft.BingNews is allowed'
Assert ([bool](Get-WdlAppBlockReason -Name 'Microsoft.Paint' -Protected $cfg.Protected)) 'apps.json protected list is applied (Paint)'
Assert ([bool](Get-WdlServiceBlockReason 'WinDefend') -and [bool](Get-WdlServiceBlockReason 'wuauserv') -and -not (Get-WdlServiceBlockReason 'DiagTrack')) 'service blocklist'
Assert ([bool](Get-WdlFeatureBlockReason 'NetFx4-AdvSrvs') -and -not (Get-WdlFeatureBlockReason 'MicrosoftWindowsPowerShellV2Root')) 'feature blocklist'

# ---------------- value conversion ----------------
Assert ((ConvertTo-WdlValueData 'DWord' '4294967295') -eq -1) 'DWORD 0xFFFFFFFF -> Int32 -1'
Assert ((ConvertTo-WdlValueData 'DWord' '1') -is [int]) 'DWORD data is Int32'
Assert ((ConvertTo-WdlValueData 'QWord' '18446744073709551615') -eq [long]-1) 'QWORD max -> Int64 -1'
$bin = ConvertTo-WdlValueData 'Binary' '01ff 10'
Assert ($bin.Length -eq 3 -and $bin[1] -eq 255) 'REG_BINARY hex text'

# ---------------- mapping (Windows 11 24H2) ----------------
Reset-Mock; Set-MockOs 26100
foreach ($a in @('Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.Copilot', 'Microsoft.XboxGamingOverlay',
        'MicrosoftWindows.Client.WebExperience', 'Microsoft.WindowsStore', 'Microsoft.WindowsTerminal', 'Microsoft.Xbox.TCUI')) { Add-MockApp $a }
Add-MockApp 'Microsoft.VCLibs.140.00' -Framework
Add-MockApp 'Microsoft.Todos' -NoProvisioned
Add-MockApp 'Microsoft.GetHelp' -NonRemovable
$s = Get-WdlSession -Config $cfg
$byId = @{}; foreach ($r in $s.AppRows) { $byId[$r.Id] = $r }
Assert ($byId['Microsoft.BingNews'].Present -and @($byId['Microsoft.BingNews'].Packages).Count -eq 1 -and @($byId['Microsoft.BingNews'].Provisioned).Count -eq 1) 'installed + provisioned packages matched'
Assert (-not $byId['Microsoft.GetHelp'].Present -and @($byId['Microsoft.GetHelp'].Blocked).Count -eq 1) 'non-removable package never matched'
Assert (-not $byId['Microsoft.549981C3F5F10'].Present) 'app not installed is not offered'
Assert ($byId['Microsoft.WindowsTerminal'].OptIn -and $byId['Microsoft.WindowsTerminal'].Present) 'Windows Terminal offered as explicit opt-in'
$tw = @{}; foreach ($r in $s.TweakRows) { $tw[$r.Id] = $r }
Assert (-not $tw['BypassNRO'].Usable -and -not $tw['LabConfigBypass'].Usable) 'setup-only tweaks (BypassNRO, LabConfigBypass) skipped with a reason'
Assert ($tw['ReservedStorageOff'].Usable -and $tw['RemoveOobeSetupTasks'].Usable -and $tw['CopilotOff'].Usable) 'online tweaks usable'
Assert (-not $tw.ContainsKey('CortanaWebSearchOff')) 'Windows 10 tweaks not shown on Windows 11'
$rec = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset recommended
$agg = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset aggressive
Assert ($rec.Apps -contains 'Microsoft.BingNews' -and $rec.Apps -notcontains 'MicrosoftWindows.Client.WebExperience' -and $rec.Tweaks -contains 'ConsumerFeatures' -and $rec.Tweaks -notcontains 'BypassNRO') 'recommended preset = rule defaults, usable only'
Assert ($agg.Apps -contains 'MicrosoftWindows.Client.WebExperience' -and $agg.Apps -notcontains 'Microsoft.Xbox.TCUI' -and $agg.Apps -notcontains 'Microsoft.WindowsTerminal') 'aggressive preset never picks unsafe / opt-in apps'
Assert ($agg.Tweaks -contains 'ReservedStorageOff' -and $agg.Tweaks -notcontains 'LabConfigBypass') 'aggressive preset tweaks'

$opt = New-WdlOptions -Session $s -AppScope AllUsers -DefaultUser $true
$plan = New-WdlPlan -AppRows $s.AppRows -TweakRows $s.TweakRows -AppIds (@($agg.Apps) + 'Microsoft.WindowsStore' + 'Microsoft.GetHelp') -TweakIds (@($agg.Tweaks) + 'BypassNRO') -Options $opt
$cdm = @($plan.Registry | Where-Object { $_.Name -eq 'SubscribedContentEnabled' })
Assert ($cdm.Count -eq 2 -and @($cdm | Where-Object { $_.Path -eq "$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" }).Count -eq 1 -and @($cdm | Where-Object { $_.Scope -eq 'DefaultUser' }).Count -eq 1) 'NTUSER -> signed-in user (HKU\SID) + Default profile'
Assert (@($plan.Registry | Where-Object { $_.Path -like 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -and $_.Root -eq 'HKLM' }).Count -ge 1) 'SOFTWARE -> HKLM\SOFTWARE'
Assert (@($plan.Registry | Where-Object { $_.Kind -eq 'RegDeleteKey' -and $_.Path -like 'SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\*' }).Count -eq 3) 'deleteKey mapped'
Assert (@($plan.Special | Where-Object { $_.Kind -eq 'ReservedStorage' }).Count -eq 1 -and @($plan.Registry | Where-Object { $_.Name -eq 'ShippedWithReserves' }).Count -eq 0) 'ReservedStorageOff -> online API instead of the image value'
Assert (@($plan.Skipped | Where-Object { $_.What -like '*BypassNRO*' }).Count -eq 1) 'offline-only tweak reported as skipped'
Assert (@($plan.Apps | Where-Object { $_.Id -eq 'Microsoft.WindowsStore' -or $_.Id -eq 'Microsoft.GetHelp' }).Count -eq 0) 'Store / non-removable never planned'
$lab = @($s.TweakRows | Where-Object { $_.Id -eq 'LabConfigBypass' })
$p2 = New-WdlPlan -AppRows @() -TweakRows @(New-WdlObj @{ Id = 'X'; Usable = $true; Entry = $lab[0].Entry }) -AppIds @() -TweakIds @('X') -Options $opt
Assert (@($p2.Registry | Where-Object { $_.Path -like 'SYSTEM\Setup\LabConfig*' }).Count -eq 0 -and @($p2.Skipped | Where-Object { $_.Reason -like '*boot.wim*' }).Count -eq 5) 'LabConfig keys and bootSet never written online'
Assert (@($p2.Registry | Where-Object { $_.Path -like '.DEFAULT\*' }).Count -eq 2) 'DEFAULT hive -> HKU\.DEFAULT'

$optCu = New-WdlOptions -Session $s -AppScope CurrentUser -DefaultUser $false
$pc = New-WdlPlan -AppRows $s.AppRows -TweakRows $s.TweakRows -AppIds @('Microsoft.BingNews') -TweakIds @('NewUserSuggestionsOff') -Options $optCu
Assert (@($pc.Apps[0].Provisioned).Count -eq 0 -and @($pc.Registry | Where-Object { $_.Scope -eq 'DefaultUser' }).Count -eq 0) 'signed-in user only: no deprovisioning, no Default profile'

# ---------------- apply + undo round trip ----------------
Reset-Mock; Set-MockOs 26100
foreach ($a in @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.Copilot', 'Microsoft.WindowsStore')) { Add-MockApp $a }
Set-MockValue 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'DWord' 0
Set-MockValue 'HKU' "$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContentEnabled' 'DWord' 1
Set-MockValue 'HKU' "$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SoftLandingEnabled' 'DWord' 0
$ou = 'SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Set-MockValue 'HKLM' $ou 'workCompleted' 'DWord' 0
Set-MockValue 'HKLM' $ou 'blob' 'Binary' ([byte[]](1, 2, 250))
Set-MockValue 'HKLM' $ou 'list' 'MultiString' ([string[]]@('a', 'Tiếng Việt'))
Set-MockValue 'HKLM' $ou 'big' 'QWord' ([long]9007199254740993)
Set-MockValue 'HKLM' "$ou\Sub" 'cmd' 'ExpandString' '%ProgramFiles%\x.exe'
Set-MockValue 'HKU' "$def\Software\Microsoft\Windows\CurrentVersion\Run" 'OneDriveSetup' 'String' 'C:\Windows\System32\OneDriveSetup.exe /thfirstsetup'
Set-MockValue 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'DWord' 1
$script:MockReserved = 'Enabled'
$beforeDump = Get-MockRegDump
$s = Get-WdlSession -Config $cfg
$sel = Get-WdlPresetSelection -AppRows $s.AppRows -TweakRows $s.TweakRows -Preset aggressive
$opt = New-WdlOptions -Session $s -AppScope AllUsers -DefaultUser $true
$plan = Get-WdlResolvedPlan -Session $s -AppIds $sel.Apps -TweakIds $sel.Tweaks -Options $opt
Assert ($script:MockMounts -ge 1) 'Default profile hive loaded to read the plan'
$cdm = @($plan.Registry | Where-Object { $_.Name -eq 'SoftLandingEnabled' -and $_.Scope -eq 'User' })[0]
Assert ($cdm.NoChange) 'value already at the target is marked "already in place"'
$txt = Format-WdlPreview -Plan $plan -Lang 'en'
Assert ($txt -match 'HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent\\DisableWindowsConsumerFeatures: 0 \(DWord\) -> 1' -and $txt -match 'Microsoft.BingNews' -and $txt -match 'DefaultUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\\OneDriveSetup') 'preview lists exact before -> after changes'
$txtVi = Format-WdlPreview -Plan $plan -Lang 'vi'
Assert ($txtVi -match 'Ứng dụng sẽ gỡ') 'preview in Vietnamese'
$bdir = Join-Path $script:MockDataDir 'backups'
$res = Invoke-WdlApply -Session $s -Plan $plan -RestorePoint (New-WdlObj @{ Ok = $true; Sequence = 6 }) -BackupDir $bdir
Assert ($res.Failed -eq 0 -and $res.Done -gt 10 -and $res.Reboot) "apply finished ($($res.Done) changes, $($res.Failed) failed)"
Assert ((Get-WdlRegValue 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures').Data -eq 1) 'HKLM value written'
Assert ((Get-WdlRegValue 'HKU' "$def\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContentEnabled').Data -eq 0) 'Default profile value written'
Assert (-not (Test-WdlRegKey 'HKLM' $ou)) 'deleteKey removed the key'
Assert (-not (Get-WdlRegValue 'HKU' "$def\Software\Microsoft\Windows\CurrentVersion\Run" 'OneDriveSetup').Exists) 'deleteValue removed OneDriveSetup for new users'
Assert ($script:MockReserved -eq 'Disabled') 'reserved storage disabled through the online API'
Assert (@($script:MockLog | Where-Object { $_ -like 'remove-app Microsoft.WindowsStore*' }).Count -eq 0) 'Store never removed'
Assert (@($script:MockLog | Where-Object { $_ -like 'remove-app Microsoft.BingNews* AllUsers*' }).Count -eq 1 -and @($script:MockLog | Where-Object { $_ -like 'deprovision Microsoft.BingNews*' }).Count -eq 1) 'app removed for all users and deprovisioned'
$bk = Read-WdlBackup $res.BackupPath
$ch = @($bk['changes'])
Assert ($ch.Count -gt 10 -and @($ch | Where-Object { $_['status'] -ne 'done' }).Count -eq 0 -and $bk['restorePoint']['sequence'] -eq 6) 'backup JSON has every change, all done, restore point recorded'
Assert (@(Get-WdlBackups -Dir $bdir).Count -eq 1) 'backup listed'
$u = Invoke-WdlUndo -Path $res.BackupPath
Assert ($u.Failed -eq 0) "undo without failures ($($u.Restored) restored)"
$afterDump = Get-MockRegDump
Assert ($afterDump -eq $beforeDump) 'registry after undo is identical to before (all value kinds, deleted key with subkey, Run value)'
if ($afterDump -ne $beforeDump) { Compare-Object ($beforeDump -split "`n") ($afterDump -split "`n") | ForEach-Object { Write-Host ("  {0} {1}" -f $_.SideIndicator, $_.InputObject) } }
Assert ($script:MockReserved -eq 'Enabled') 'reserved storage enabled again'
Assert (@($u.Manual).Count -ge 3) 'removed apps reported for a Store reinstall when their files are gone'
Assert ([string](Read-WdlBackup $res.BackupPath)['restored']) 'backup marked as restored'
$u2 = Invoke-WdlUndo -Path $res.BackupPath
Assert ($u2.Restored -eq 0 -and $u2.Failed -eq 0) 'second undo does nothing'

# ---------------- failures per item, tampered backup ----------------
Reset-Mock; Set-MockOs 26100; Add-MockApp 'Microsoft.BingNews'; Add-MockApp 'Microsoft.BingWeather'
$script:MockFail[('HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableCloudOptimizedContent').ToLowerInvariant()] = 'Access is denied'
$script:MockAppFail['Microsoft.BingNews_1.0.0.0_x64__8wekyb3d8bbwe'] = 'Deployment failed with HRESULT: 0x80073CFA'
$s = Get-WdlSession -Config $cfg
$plan = Get-WdlResolvedPlan -Session $s -AppIds @('Microsoft.BingNews', 'Microsoft.BingWeather') -TweakIds @('ConsumerFeatures', 'CopilotOff') -Options (New-WdlOptions -Session $s)
$res = Invoke-WdlApply -Session $s -Plan $plan -BackupDir $bdir
Assert ($res.Failed -eq 2 -and $res.Done -ge 5) 'access denied / app failure logged per item, run continues'
Assert ((Get-WdlRegValue 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot').Data -eq 1) 'later items still applied'
$script:MockAppFail = @{}
$bk = Read-WdlBackup $res.BackupPath
Assert (@($bk['changes'] | Where-Object { $_['status'] -eq 'failed' }).Count -eq 2) 'failed items recorded as failed'
# tampered backup: autostart value and a location the tool never writes
$bk['changes'] = @($bk['changes']) + @(
    [ordered]@{ type = 'registry'; op = 'RegSet'; root = 'HKLM'; path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; name = 'Evil'; scope = 'Machine'; label = 'x'; status = 'done'; before = @{ exists = $true; kind = 'String'; data = 'C:\evil.exe' } },
    [ordered]@{ type = 'registry'; op = 'RegSet'; root = 'HKLM'; path = 'SAM\SAM'; name = 'X'; scope = 'Machine'; label = 'x'; status = 'done'; before = @{ exists = $true; kind = 'DWord'; data = 1 } },
    [ordered]@{ type = 'registry'; op = 'RegSet'; root = 'HKU'; path = "$sid\Software\Microsoft\Windows\CurrentVersion\Run"; name = 'OneDriveSetup'; scope = 'User'; label = 'x'; status = 'done'; before = @{ exists = $true; kind = 'String'; data = 'x' } })
Save-WdlBackup -Backup $bk -Path $res.BackupPath
$u = Invoke-WdlUndo -Path $res.BackupPath
Assert (-not (Get-WdlRegValue 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'Evil').Exists -and -not (Test-WdlRegKey 'HKLM' 'SAM\SAM')) 'tampered backup: autostart / foreign locations are not written'
Assert ((Get-WdlRegValue 'HKU' "$sid\Software\Microsoft\Windows\CurrentVersion\Run" 'OneDriveSetup').Exists) 'OneDriveSetup Run value (deleted by a bundled rule) may be restored'
Assert ($u.Failed -eq 2) 'refused undo entries reported as failed'

# ---------------- online rule extensions: services / tasks / features ----------------
$ext = ConvertFrom-WdlJson @'
{ "schema": 1, "tweaks": [
  { "id": "DiagOff", "os": "both", "category": "privacy", "level": "aggressive", "default": false, "bootWim": false,
    "name": { "vi": "a", "en": "a", "zh-CN": "a", "km": "a" }, "description": { "vi": "a", "en": "a", "zh-CN": "a", "km": "a" },
    "services": [ { "name": "DiagTrack", "startType": "Disabled" }, { "name": "WinDefend", "startType": "Disabled" }, { "name": "ProtectedSvc", "startType": "Disabled" } ],
    "tasks": [ { "path": "\\Microsoft\\Windows\\Application Experience\\", "name": "ProgramDataUpdater", "state": "Disabled" } ],
    "features": [ { "name": "MicrosoftWindowsPowerShellV2Root", "state": "Disabled" } ] } ] }
'@
Assert (@(Test-WdlTweakData $ext).Count -eq 0) 'services / tasks / features entries validate'
Assert (@(Test-WdlRulesPolicy @{ protected = @() } $ext | Where-Object { $_ -like '*WinDefend*' }).Count -eq 1) 'downloaded rules may not touch protected services'
$bad = ConvertFrom-WdlJson ($ext | ConvertTo-Json -Depth 20)
$bad['tweaks'][0]['services'][0]['startType'] = 'Boot'
Assert (@(Test-WdlTweakData $bad).Count -ge 1) 'invalid service start type rejected'
Reset-Mock; Set-MockOs 26100
Set-MockValue 'HKLM' 'SYSTEM\CurrentControlSet\Services\DiagTrack' 'Start' 'DWord' 2
Set-MockValue 'HKLM' 'SYSTEM\CurrentControlSet\Services\DiagTrack' 'DelayedAutostart' 'DWord' 1
Set-MockValue 'HKLM' 'SYSTEM\CurrentControlSet\Services\ProtectedSvc' 'Start' 'DWord' 3
$script:MockTasks = @{ '\Microsoft\Windows\Application Experience\ProgramDataUpdater' = $true }
$script:MockFeatures = @{ MicrosoftWindowsPowerShellV2Root = 'Enabled' }
$t = Import-WdlTweakData -Data $ext
$prof = New-WdlObj @{ Os = 'Win11'; Build = 26100; Apps = @(); Tweaks = $t.Win11; Protected = @() }
$s = New-WdlObj @{ Os = (Get-WdlOsInfo); User = (New-WdlObj $script:MockUser); Config = $cfg; Profile = $prof; Inventory = @{ Installed = @(); Provisioned = @() }; AppRows = @(); TweakRows = @(Get-WdlTweakRows -Profile $prof) }
$before = Get-MockRegDump
$plan = Get-WdlResolvedPlan -Session $s -AppIds @() -TweakIds @('DiagOff') -Options (New-WdlOptions -Session $s)
Assert (@($plan.Skipped | Where-Object { $_.What -eq 'Service WinDefend' }).Count -eq 1) 'blocked service skipped even from bundled rules'
Assert ((@($plan.Services | Where-Object { $_.Name -eq 'DiagTrack' }))[0].Before.StartType -eq 'AutomaticDelayed') 'delayed auto start read from the registry'
$res = Invoke-WdlApply -Session $s -Plan $plan -BackupDir $bdir
Assert ((Get-WdlServiceStart 'DiagTrack').StartType -eq 'Disabled' -and -not $script:MockTasks['\Microsoft\Windows\Application Experience\ProgramDataUpdater'] -and $script:MockFeatures['MicrosoftWindowsPowerShellV2Root'] -eq 'Disabled') 'service / task / feature changed'
Assert ($res.Failed -eq 1) 'access denied on a protected service is per item'
$u = Invoke-WdlUndo -Path $res.BackupPath
Assert ((Get-WdlServiceStart 'DiagTrack').StartType -eq 'AutomaticDelayed' -and $script:MockTasks['\Microsoft\Windows\Application Experience\ProgramDataUpdater'] -and $script:MockFeatures['MicrosoftWindowsPowerShellV2Root'] -eq 'Enabled') 'undo restores service start type, task and feature'
Assert ((Get-MockRegDump) -eq $before) 'service registry identical after undo'

# ---------------- restore point step ----------------
Reset-Mock
$k = $script:WdlSrKey
$script:MockRp = @{ Seq = 5; Enabled = $true; Policy = $false; Silent = $false; EnableError = $null }
$r = Invoke-WdlRestorePointStep -EnableProtection $false
Assert ($r.Ok -and $r.Sequence -eq 6 -and $script:MockRp.FreqSeen.Data -eq 0) 'restore point created with the 24 h limit lifted'
Assert (-not (Get-WdlRegValue 'HKLM' $k 'SystemRestorePointCreationFrequency').Exists) 'creation frequency value removed again (was absent)'
Set-MockValue 'HKLM' $k 'SystemRestorePointCreationFrequency' 'DWord' 1440
$r = Invoke-WdlRestorePointStep -EnableProtection $false
Assert ($r.Ok -and (Get-WdlRegValue 'HKLM' $k 'SystemRestorePointCreationFrequency').Data -eq 1440) 'existing creation frequency value put back'
$script:MockRp.Silent = $true
$r = Invoke-WdlRestorePointStep -EnableProtection $false
Assert (-not $r.Ok -and $r.Error) 'restore point silently skipped by Windows is detected'
$script:MockRp = @{ Seq = 5; Enabled = $false; Policy = $false; Silent = $false; EnableError = $null }
$r = Invoke-WdlRestorePointStep -EnableProtection $false
Assert ($r.NeedsConsent -and -not $r.Ok -and -not $script:MockRp.Enabled) 'System Protection never turned on without consent'
$r = Invoke-WdlRestorePointStep -EnableProtection $true
Assert ($r.Ok -and $script:MockRp.Enabled) 'with consent System Protection is turned on and the point created'
$script:MockRp = @{ Seq = 5; Enabled = $false; Policy = $true; Silent = $false; EnableError = $null }
$r = Invoke-WdlRestorePointStep -EnableProtection $true
Assert (-not $r.Ok -and $r.PolicyDisabled) 'System Restore disabled by policy is reported'

# ---------------- Windows 10 1809 ----------------
Reset-Mock; Set-MockOs 17763
Add-MockApp 'Microsoft.BingNews'; Add-MockApp 'Microsoft.Todos'; Add-MockApp 'Microsoft.MSPaint'
$s = Get-WdlSession -Config $cfg
Assert ($s.Os.Os -eq 'Win10' -and @($s.TweakRows | Where-Object { $_.Id -eq 'CopilotOff' }).Count -eq 0 -and @($s.TweakRows | Where-Object { $_.Id -eq 'MeetNowOff' }).Count -eq 1) 'Windows 10 1809: build ranges applied to tweaks'
Assert (@($s.AppRows | Where-Object { $_.Id -eq 'Microsoft.Todos' }).Count -eq 0 -and ($s.AppRows | Where-Object { $_.Id -eq 'Microsoft.BingNews' }).Present) 'Windows 10 1809: build ranges applied to apps'
Reset-Mock; Set-MockOs 18363
$s = Get-WdlSession -Config $cfg
$rows = @($s.TweakRows | Where-Object { $_.Id -eq 'ReservedStorageOff' })
Assert ($rows.Count -eq 1 -and -not $rows[0].Usable) 'ReservedStorageOff not offered before build 19041 (no online API)'

Remove-Item -LiteralPath $script:MockDataDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Engine tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
exit $script:fail
