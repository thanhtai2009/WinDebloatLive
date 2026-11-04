<#
    WinDebloat Live - maps the shared (offline-oriented) rules to changes on the running system and builds the
    plan that is previewed, applied and backed up. Pure logic: every system read goes through lib\System.ps1.
    SPDX-License-Identifier: MIT
#>

#region ---------- hard safety lists (code, not data: downloaded rules cannot change them) ----------
# Appx packages that are never removed, whatever the rules or the user select
$script:WdlHardBlockedApps = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.Services.Store.Engagement',
    'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.WinAppRuntime*',
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'MicrosoftWindows.Client.CBS',
    'MicrosoftWindows.Client.Core', 'MicrosoftWindows.Client.FileExp', 'MicrosoftWindows.Client.AIX', 'Microsoft.Windows.Search',
    'Microsoft.SecHealthUI', 'Microsoft.Windows.SecHealthUI', 'Microsoft.Windows.Apprep.ChxApp', 'Microsoft.Windows.CloudExperienceHost',
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.CredDialogHost', 'Microsoft.BioEnrollment',
    'Microsoft.Windows.OOBENetworkConnectionFlow', 'Microsoft.Windows.OOBENetworkCaptivePortal', 'windows.immersivecontrolpanel',
    'Microsoft.Windows.XGpuEjectDialog', 'Microsoft.Win32WebViewHost', 'Microsoft.Windows.CapturePicker', 'Microsoft.Windows.PinningConfirmationDialog',
    'Microsoft.Windows.AssignedAccessLockApp', 'Microsoft.Windows.FileExplorer', 'Microsoft.MicrosoftEdge*', 'Microsoft.WebView2*',
    'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator',
    'Microsoft.HEIFImageExtension', 'Microsoft.WebMediaExtensions', 'Microsoft.*VideoExtension*', 'Microsoft.*ImageExtension*',
    'Microsoft.LanguageExperiencePack*', 'Microsoft.Windows.ContentDeliveryManager', 'Microsoft.ECApp', 'NcsiUwpApp', 'Windows.CBSPreview',
    'Microsoft.Windows.PrintQueueActionCenter', 'Microsoft.Windows.ParentalControls', 'Microsoft.Windows.NarratorQuickStart'
)
# packages that are hard-blocked unless the user ticks their explicit opt-in entry in Advanced mode
$script:WdlOptInApps = @(
    @{ Id = 'Microsoft.WindowsTerminal'; Default = $false; Level = 'unsafe'; Os = 'both'; OptIn = $true
        Names = @{ en = 'Windows Terminal (explicit choice only)'; vi = 'Windows Terminal (chỉ khi chọn rõ ràng)'; 'zh-CN' = 'Windows Terminal (仅在明确选择时)'; km = 'Windows Terminal (explicit choice only)' } }
)
# services whose start type is never changed
$script:WdlBlockedServices = @(
    'RpcSs', 'RpcEptMapper', 'DcomLaunch', 'LSM', 'SamSs', 'Winmgmt', 'EventLog', 'WinDefend', 'WdNisSvc', 'WdFilter', 'WdBoot',
    'SecurityHealthService', 'Sense', 'wscsvc', 'mpssvc', 'BFE', 'CryptSvc', 'Dhcp', 'Dnscache', 'nsi', 'Power', 'ProfSvc',
    'Schedule', 'SENS', 'SystemEventsBroker', 'UserManager', 'gpsvc', 'AppXSvc', 'ClipSVC', 'StateRepository', 'TrustedInstaller',
    'msiserver', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'DoSvc', 'sppsvc', 'TokenBroker', 'CoreMessagingRegistrar',
    'BrokerInfrastructure', 'Audiosrv', 'AudioEndpointBuilder', 'PlugPlay', 'LanmanWorkstation', 'netprofm', 'NlaSvc', 'VaultSvc',
    'KeyIso', 'Netlogon', 'StorSvc', 'DeviceInstall', 'DsmSvc', 'wlidsvc', 'InstallService', 'camsvc', 'EFS', 'TimeBrokerSvc',
    'CDPSvc', 'Wcmsvc', 'WlanSvc', 'iphlpsvc', 'ShellHWDetection', 'Themes', 'FontCache', 'WinHttpAutoProxySvc', 'Appinfo', 'seclogon',
    'VSS', 'swprv', 'SDRSVC', 'smphost', 'TabletInputService', 'TextInputManagementService', 'DispBrokerDesktopSvc', 'WpnService',
    'EventSystem', 'NgcSvc', 'NgcCtnrSvc', 'WbioSrvc', 'AppReadiness', 'LicenseManager', 'SgrmBroker', 'webthreatdefsvc', 'webthreatdefusersvc*',
    'MDCoreSvc', 'mpsdrv'
)
# scheduled task folders that are never disabled (security, updates, restore points, encryption, licensing)
$script:WdlBlockedTasks = @(
    '\Microsoft\Windows\Windows Defender\*', '\Microsoft\Windows\WindowsUpdate\*', '\Microsoft\Windows\UpdateOrchestrator\*',
    '\Microsoft\Windows\WaaSMedic\*', '\Microsoft\Windows\SystemRestore\*', '\Microsoft\Windows\BitLocker\*', '\Microsoft\Windows\TPM\*',
    '\Microsoft\Windows\Time Synchronization\*', '\Microsoft\Windows\SoftwareProtectionPlatform\*', '\Microsoft\Windows\TaskScheduler\*',
    '\Microsoft\Windows\AppxDeploymentClient\*', '\Microsoft\Windows\User Profile Service\*', '\Microsoft\Windows\Servicing\*'
)
# optional features that are never disabled
$script:WdlBlockedFeatures = @('NetFx4*', 'Windows-Defender*', 'SearchEngine-Client-Package', 'Microsoft-Windows-Client-*', 'Printing-PrintToPDFServices-Features', 'MSRDC-Infrastructure')

function Get-WdlAppBlockReason {
    <# Why a package name may not be removed ($null = allowed). -OptIn: the user explicitly chose this opt-in entry. #>
    param([string]$Name, [string[]]$Protected, [switch]$OptIn)
    if (-not $Name) { return 'empty package name' }
    foreach ($o in $script:WdlOptInApps) { if ($OptIn -and $Name -like $o.Id) { return $null } }
    if (Test-WdlLike $Name $script:WdlHardBlockedApps) { return 'critical system package (built-in blocklist)' }
    if (Test-WdlLike $Name $Protected) { return 'protected by the rules (apps.json)' }
    return $null
}

function Get-WdlServiceBlockReason([string]$Name) {
    if (Test-WdlLike $Name $script:WdlBlockedServices) { return 'critical service (built-in blocklist)' }
    return $null
}

function Get-WdlTaskBlockReason([string]$Path, [string]$Name) {
    if (Test-WdlLike ($Path + $Name) $script:WdlBlockedTasks) { return 'critical scheduled task (built-in blocklist)' }
    return $null
}

function Get-WdlFeatureBlockReason([string]$Name) {
    if (Test-WdlLike $Name $script:WdlBlockedFeatures) { return 'critical feature (built-in blocklist)' }
    return $null
}
#endregion

#region ---------- what only makes sense offline ----------
# whole tweaks that only change Windows Setup / installation media behaviour
$script:WdlOfflineOnlyTweaks = @{
    BypassNRO       = 'only affects Windows Setup (OOBE) of a new installation'
    LabConfigBypass = 'only affects the hardware checks of Windows Setup (installation media)'
}
# registry locations that are only read by Windows Setup (any rule, also future ones)
$script:WdlOfflineOnlyKeys = @(
    @{ Hive = 'SYSTEM'; Rx = '^Setup\\LabConfig(\\|$)'; Reason = 'read only by Windows Setup (installation media)' }
    @{ Hive = 'SOFTWARE'; Rx = '^Microsoft\\Windows\\CurrentVersion\\OOBE(\\|$)'; Reason = 'only affects Windows Setup (OOBE) of a new installation' }
)
# tweaks whose registry form only works in an image; the running system has a supported API instead
$script:WdlOnlineEquivalents = @{
    ReservedStorageOff = @{ Kind = 'ReservedStorage'; MinBuild = 19041; Note = 'uses DISM Set-WindowsReservedStorageState on a running system' }
}

function Get-WdlOfflineOnlyReason {
    param([string]$Hive, [string]$Key)
    foreach ($k in $script:WdlOfflineOnlyKeys) { if ($Hive -eq $k.Hive -and $Key -match $k.Rx) { return $k.Reason } }
    return $null
}
#endregion

#region ---------- profile / selection ----------
function Test-WdlForBuild {
    param($Entry, [int]$Build)
    if ($Build -le 0) { return $true }
    if ($Entry.MinBuild -and $Build -lt [int]$Entry.MinBuild) { return $false }
    if ($Entry.MaxBuild -and $Build -gt [int]$Entry.MaxBuild) { return $false }
    return $true
}

function Get-WdlProfile {
    <# Apps and tweaks that apply to this OS and build. #>
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][ValidateSet('Win10', 'Win11')][string]$Os, [int]$Build)
    if ($Os -eq 'Win10') { $apps = $Config.Win10Apps; $tweaks = $Config.Win10Tweaks } else { $apps = $Config.Apps; $tweaks = $Config.Tweaks }
    $ka = @(); $kt = @()
    foreach ($a in @($apps)) { if ($a -and (Test-WdlForBuild $a $Build)) { $ka += $a } }
    foreach ($o in $script:WdlOptInApps) { $ka += $o }
    foreach ($t in @($tweaks)) { if ($t -and (Test-WdlForBuild $t $Build)) { $kt += $t } }
    return (New-WdlObj @{ Os = $Os; Build = $Build; Apps = $ka; Tweaks = $kt; Protected = @($Config.Protected) })
}

function Get-WdlAppRows {
    <# One row per rule app: installed / provisioned packages it matches on this PC and why parts are blocked.
       Only rows with Present = $true are offered; frameworks and non-removable system packages never match. #>
    param([Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)]$Inventory)
    $rows = @()
    foreach ($a in @($Profile.Apps)) {
        $optIn = [bool]$a.OptIn
        $pk = @(); $pv = @(); $blocked = @(); $system = @()
        foreach ($p in @($Inventory.Installed)) {
            if (-not ($p.Name -like $a.Id)) { continue }
            if ($p.IsFramework -or $p.NonRemovable) { $blocked += "$($p.Name): system package (non-removable)"; $system += $p.Name; continue }
            $r = Get-WdlAppBlockReason -Name $p.Name -Protected $Profile.Protected -OptIn:$optIn
            if ($r) { $blocked += "$($p.Name): $r"; continue }
            if ($pk -notcontains $p.PackageFullName) { $pk += $p.PackageFullName }
        }
        foreach ($p in @($Inventory.Provisioned)) {
            if (-not ($p.DisplayName -like $a.Id) -or $system -contains $p.DisplayName) { continue }
            $r = Get-WdlAppBlockReason -Name $p.DisplayName -Protected $Profile.Protected -OptIn:$optIn
            if ($r) { $blocked += "$($p.DisplayName): $r"; continue }
            if ($pv -notcontains $p.PackageName) { $pv += $p.PackageName }
        }
        $rows += (New-WdlObj @{ Id = $a.Id; Entry = $a; Names = $a.Names; Default = [bool]$a.Default; Level = [string]$a.Level; OptIn = $optIn
                Packages = $pk; Provisioned = $pv; Blocked = @($blocked | Select-Object -Unique); Present = (($pk.Count + $pv.Count) -gt 0) })
    }
    return $rows
}

function Get-WdlTweakRows {
    <# One row per rule tweak with the reason it cannot be used on a running system ($null = usable). #>
    param([Parameter(Mandatory = $true)]$Profile)
    $rows = @()
    foreach ($t in @($Profile.Tweaks)) {
        $why = $null
        if ($script:WdlOfflineOnlyTweaks.ContainsKey($t.Id)) { $why = $script:WdlOfflineOnlyTweaks[$t.Id] }
        $eq = $script:WdlOnlineEquivalents[$t.Id]
        if (-not $why -and $eq -and $eq.MinBuild -and $Profile.Build -gt 0 -and $Profile.Build -lt $eq.MinBuild) { $why = "needs Windows build $($eq.MinBuild) or newer on a running system" }
        if (-not $why -and -not $eq) {
            $ops = @(@($t.Set) + @($t.Delete) + @($t.DeleteValue) | Where-Object { $_ })
            $sys = @(@($t.Services) + @($t.Tasks) + @($t.Features) | Where-Object { $_ })
            $off = @($ops | Where-Object { Get-WdlOfflineOnlyReason $_.Hive $_.Key })
            if ($ops.Count -gt 0 -and $off.Count -eq $ops.Count -and $sys.Count -eq 0) { $why = Get-WdlOfflineOnlyReason $off[0].Hive $off[0].Key }
            if ($ops.Count -eq 0 -and $sys.Count -eq 0) { $why = 'only changes Windows Setup media (boot.wim)' }
        }
        $rows += (New-WdlObj @{ Id = $t.Id; Entry = $t; Names = $t.Names; Descriptions = $t.Descriptions; Default = [bool]$t.Default
                Level = [string]$t.Level; Category = [string]$t.Category; SkipReason = $why; Usable = (-not $why) })
    }
    return $rows
}

function Get-WdlPresetSelection {
    <# Preset -> @{ Apps = ids; Tweaks = ids } among usable rows. recommended = rule defaults; aggressive = every
       safe or aggressive entry. Unsafe and opt-in entries are never chosen by a preset. #>
    param([object[]]$AppRows, [object[]]$TweakRows, [ValidateSet('recommended', 'aggressive')][string]$Preset = 'recommended')
    $ok = { param($r) if ($r.OptIn -or $r.Level -eq 'unsafe') { return $false }; if ($Preset -eq 'aggressive') { return $true }; return [bool]$r.Default }
    $a = @(@($AppRows) | Where-Object { $_.Present -and (& $ok $_) } | ForEach-Object { $_.Id })
    $t = @(@($TweakRows) | Where-Object { $_.Usable -and (& $ok $_) } | ForEach-Object { $_.Id })
    return @{ Apps = $a; Tweaks = $t }
}
#endregion

#region ---------- plan ----------
function ConvertTo-WdlValueKind {
    # REG_* type of a rule -> RegistryValueKind name
    param([string]$Type)
    switch ($Type) {
        'REG_DWORD' { return 'DWord' } 'REG_QWORD' { return 'QWord' } 'REG_SZ' { return 'String' }
        'REG_EXPAND_SZ' { return 'ExpandString' } 'REG_MULTI_SZ' { return 'MultiString' } 'REG_BINARY' { return 'Binary' }
    }
    throw "unknown registry type $Type"
}

function ConvertTo-WdlValueData {
    # rule value text -> data in the form the registry layer writes (DWORD as signed Int32, QWORD as Int64)
    param([string]$Kind, [string]$Text)
    switch ($Kind) {
        'DWord' { $u = [uint32]0; if (-not [uint32]::TryParse($Text, [ref]$u)) { $i = [int]0; if ([int]::TryParse($Text, [ref]$i)) { return $i }; throw "not a DWORD: $Text" }; return [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
        'QWord' { $u = [uint64]0; if (-not [uint64]::TryParse($Text, [ref]$u)) { throw "not a QWORD: $Text" }; return [BitConverter]::ToInt64([BitConverter]::GetBytes($u), 0) }
        'MultiString' { return , ([string[]]@($Text -split '\\0')) }
        'Binary' { $h = $Text -replace '[\s,]', ''; if ($h.Length % 2) { throw "not hex: $Text" }; $b = New-Object byte[] ($h.Length / 2); for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring(2 * $i, 2), 16) }; return , $b }
    }
    return [string]$Text
}

function Get-WdlRegTargets {
    <# Live registry locations of a rule hive/key: @{ Root (HKLM|HKU); Path; Scope; Label }.
       NTUSER (Default user template in the image) -> the signed-in user and, optionally, the Default profile. #>
    param([string]$Hive, [string]$Key, [Parameter(Mandatory = $true)]$Options)
    $out = @()
    switch ($Hive) {
        'SOFTWARE' { $out += @{ Root = 'HKLM'; Path = "SOFTWARE\$Key"; Scope = 'Machine' } }
        'SYSTEM' { $out += @{ Root = 'HKLM'; Path = "SYSTEM\$Key"; Scope = 'Machine' } }
        'DEFAULT' { $out += @{ Root = 'HKU'; Path = ".DEFAULT\$Key"; Scope = 'DotDefault' } }
        'NTUSER' {
            if ($Options.UserSid) { $out += @{ Root = 'HKU'; Path = "$($Options.UserSid)\$Key"; Scope = 'User' } }
            if ($Options.DefaultUser) { $out += @{ Root = 'HKU'; Path = "$($script:WdlDefaultHiveName)\$Key"; Scope = 'DefaultUser' } }
        }
    }
    foreach ($t in $out) { $t.Label = Get-WdlRegLabel $t.Root $t.Path $t.Scope }
    return $out
}

$script:WdlDefaultHiveName = 'WDL_DefaultUser'

function Get-WdlRegLabel {
    # readable location: HKLM\SOFTWARE\..., HKCU\... (signed-in user), Default user\..., HKU\.DEFAULT\...
    param([string]$Root, [string]$Path, [string]$Scope)
    switch ($Scope) {
        'User' { return ('HKCU\' + ($Path -replace '^[^\\]+\\', '')) }
        'DefaultUser' { return ('DefaultUser\' + ($Path -replace '^[^\\]+\\', '')) }
    }
    return "$Root\$Path"
}

function New-WdlPlan {
    <# Selected app / tweak ids -> plan of single changes:
       Apps (packages per user scope + provisioned), Registry (RegSet / RegDeleteValue / RegDeleteKey), Services,
       Tasks, Features, Special (online equivalents) and Skipped (with the reason).
       Options: AppScope (AllUsers | CurrentUser), UserSid, UserName, DefaultUser (bool). #>
    param([object[]]$AppRows, [object[]]$TweakRows, [string[]]$AppIds, [string[]]$TweakIds, [Parameter(Mandatory = $true)]$Options)
    $plan = @{ Apps = @(); Registry = @(); Services = @(); Tasks = @(); Features = @(); Special = @(); Skipped = @(); Options = $Options; Tweaks = @() }
    foreach ($r in @($AppRows)) {
        if (@($AppIds) -notcontains $r.Id) { continue }
        foreach ($b in @($r.Blocked)) { $plan.Skipped += @{ What = "App $b"; Reason = 'blocked' } }
        if (-not $r.Present) { $plan.Skipped += @{ What = "App $($r.Id)"; Reason = 'not installed on this PC' }; continue }
        $prov = @(); if ($Options.AppScope -eq 'AllUsers') { $prov = @($r.Provisioned) }
        if (@($r.Packages).Count -eq 0 -and $prov.Count -eq 0) { $plan.Skipped += @{ What = "App $($r.Id)"; Reason = 'only provisioned for new users (choose All users to remove it)' }; continue }
        $plan.Apps += @{ Id = $r.Id; Names = $r.Names; Packages = @($r.Packages); Provisioned = $prov; Scope = [string]$Options.AppScope; OptIn = [bool]$r.OptIn }
    }
    foreach ($row in @($TweakRows)) {
        if (@($TweakIds) -notcontains $row.Id) { continue }
        if (-not $row.Usable) { $plan.Skipped += @{ What = "Tweak $($row.Id)"; Reason = $row.SkipReason }; continue }
        $t = $row.Entry
        $plan.Tweaks += @{ Id = $t.Id; Names = $t.Names; Descriptions = $t.Descriptions; Effects = $t.Effects }
        $eq = $script:WdlOnlineEquivalents[$t.Id]
        if ($eq) { $plan.Special += @{ Kind = $eq.Kind; TweakId = $t.Id; State = 'Disabled'; Note = $eq.Note }; continue }
        foreach ($op in @($t.BootSet)) { if ($op) { $plan.Skipped += @{ What = "Tweak $($t.Id): boot.wim $($op.Hive)\$($op.Key)\$($op.Value)"; Reason = 'applies to Windows Setup media (boot.wim) only' } } }
        $kinds = @(@{ List = $t.Set; Kind = 'RegSet' }, @{ List = $t.DeleteValue; Kind = 'RegDeleteValue' }, @{ List = $t.Delete; Kind = 'RegDeleteKey' })
        foreach ($k in $kinds) {
            foreach ($op in @($k.List)) {
                if (-not $op) { continue }
                $off = Get-WdlOfflineOnlyReason $op.Hive $op.Key
                if ($off) { $plan.Skipped += @{ What = "Tweak $($t.Id): $($op.Hive)\$($op.Key)"; Reason = $off }; continue }
                $targets = @(Get-WdlRegTargets -Hive $op.Hive -Key $op.Key -Options $Options)
                if ($targets.Count -eq 0) { $plan.Skipped += @{ What = "Tweak $($t.Id): $($op.Hive)\$($op.Key)"; Reason = 'no user profile chosen' }; continue }
                foreach ($tg in $targets) {
                    $it = @{ Kind = $k.Kind; TweakId = $t.Id; Root = $tg.Root; Path = $tg.Path; Scope = $tg.Scope; Label = $tg.Label; Name = [string]$op.Value }
                    if ($k.Kind -eq 'RegSet') {
                        $it.ValueKind = ConvertTo-WdlValueKind $op.Type
                        $it.Data = ConvertTo-WdlValueData $it.ValueKind $op.Data
                        $it.DataText = [string]$op.Data
                    }
                    $plan.Registry += $it
                }
            }
        }
        foreach ($s in @($t.Services)) {
            if (-not $s) { continue }
            $b = Get-WdlServiceBlockReason $s.Name
            if ($b) { $plan.Skipped += @{ What = "Service $($s.Name)"; Reason = $b }; continue }
            $plan.Services += @{ TweakId = $t.Id; Name = $s.Name; StartType = $s.StartType }
        }
        foreach ($s in @($t.Tasks)) {
            if (-not $s) { continue }
            $b = Get-WdlTaskBlockReason $s.Path $s.Name
            if ($b) { $plan.Skipped += @{ What = "Task $($s.Path)$($s.Name)"; Reason = $b }; continue }
            $plan.Tasks += @{ TweakId = $t.Id; Path = $s.Path; Name = $s.Name }
        }
        foreach ($s in @($t.Features)) {
            if (-not $s) { continue }
            $b = Get-WdlFeatureBlockReason $s.Name
            if ($b) { $plan.Skipped += @{ What = "Feature $($s.Name)"; Reason = $b }; continue }
            $plan.Features += @{ TweakId = $t.Id; Name = $s.Name }
        }
    }
    return $plan
}

function Test-WdlSameValue {
    # current value equals the planned one (kind and data)
    param($Before, [string]$Kind, $Data)
    if (-not $Before -or -not $Before.Exists -or [string]$Before.Kind -ne $Kind) { return $false }
    if ($Kind -eq 'MultiString' -or $Kind -eq 'Binary') { return ((@($Before.Data) -join "`0") -eq (@($Data) -join "`0")) }
    return ([string]$Before.Data -eq [string]$Data)
}

function Resolve-WdlPlanState {
    <# Reads the current state of every planned change and marks changes that are already in place (NoChange).
       Registry reads under the Default profile need it loaded (caller: Use-WdlDefaultHive). #>
    param([Parameter(Mandatory = $true)]$Plan)
    foreach ($it in @($Plan.Registry)) {
        if ($it.Kind -eq 'RegDeleteKey') {
            $it.Before = @{ Exists = (Test-WdlRegKey -Root $it.Root -Path $it.Path) }
            $it.NoChange = -not $it.Before.Exists
        } else {
            $it.Before = Get-WdlRegValue -Root $it.Root -Path $it.Path -Name $it.Name
            if ($it.Kind -eq 'RegSet') { $it.NoChange = Test-WdlSameValue $it.Before $it.ValueKind $it.Data }
            else { $it.NoChange = -not $it.Before.Exists }
        }
    }
    foreach ($s in @($Plan.Services)) {
        $s.Before = Get-WdlServiceStart -Name $s.Name
        $s.NoChange = ($s.Before -and $s.Before.Exists -and $s.Before.StartType -eq $s.StartType)
        if ($s.Before -and -not $s.Before.Exists) { $s.NoChange = $true; $s.Missing = $true }
    }
    foreach ($s in @($Plan.Tasks)) {
        $s.Before = Get-WdlTaskState -Path $s.Path -Name $s.Name
        $s.NoChange = (-not $s.Before.Exists -or -not $s.Before.Enabled)
    }
    foreach ($s in @($Plan.Features)) {
        $s.Before = Get-WdlFeatureState -Name $s.Name
        $s.NoChange = ($s.Before -ne 'Enabled')
    }
    foreach ($s in @($Plan.Special)) {
        if ($s.Kind -eq 'ReservedStorage') { $s.Before = Get-WdlReservedStorageState; $s.NoChange = ($s.Before -eq 'Disabled') }
    }
    return $Plan
}

function Get-WdlPlanCounts {
    param($Plan)
    $c = @{ Apps = @($Plan.Apps).Count; Registry = @($Plan.Registry | Where-Object { -not $_.NoChange }).Count
        Services = @($Plan.Services | Where-Object { -not $_.NoChange }).Count; Tasks = @($Plan.Tasks | Where-Object { -not $_.NoChange }).Count
        Features = @($Plan.Features | Where-Object { -not $_.NoChange }).Count; Special = @($Plan.Special | Where-Object { -not $_.NoChange }).Count
        Unchanged = @(@($Plan.Registry) + @($Plan.Services) + @($Plan.Tasks) + @($Plan.Features) + @($Plan.Special) | Where-Object { $_.NoChange }).Count
        Skipped = @($Plan.Skipped).Count }
    $c.Total = $c.Apps + $c.Registry + $c.Services + $c.Tasks + $c.Features + $c.Special
    return $c
}

function Format-WdlRegData {
    param($State)
    if (-not $State -or -not $State.Exists) { return '(not set)' }
    $d = $State.Data
    if ($State.Kind -eq 'Binary') { return ('hex:' + ((@($d) | ForEach-Object { '{0:X2}' -f $_ }) -join '')) }
    if ($State.Kind -eq 'MultiString') { return ('[' + (@($d) -join ', ') + ']') }
    return ('{0} ({1})' -f $d, $State.Kind)
}

$script:WdlPreviewText = @{
    en = @{ head = 'Changes that will be made'; apps = 'Apps to remove'; tweaks = 'Settings to change'; other = 'Other changes'; sameItem = '{0} value(s) already have the target setting'; reg = 'Registry'; svc = 'Services (start type)'; task = 'Scheduled tasks (disable)'
        feat = 'Optional features (disable)'; special = 'System settings'; same = 'Already in place (left as is)'; skip = 'Skipped'
        none = '(nothing)'; allUsers = 'all users + new users'; curUser = 'signed-in user only'; set = 'set'; del = 'delete value'; delKey = 'delete key'
        total = 'Total: {0} change(s), {1} already in place, {2} skipped' }
    vi = @{ head = 'Các thay đổi sẽ thực hiện'; apps = 'Ứng dụng sẽ gỡ'; tweaks = 'Thiết lập sẽ thay đổi'; other = 'Thay đổi khác'; sameItem = '{0} giá trị đã đúng sẵn'; reg = 'Registry'; svc = 'Dịch vụ (kiểu khởi động)'; task = 'Tác vụ theo lịch (tắt)'
        feat = 'Tính năng tuỳ chọn (tắt)'; special = 'Thiết lập hệ thống'; same = 'Đã đúng sẵn (giữ nguyên)'; skip = 'Bỏ qua'
        none = '(không có)'; allUsers = 'mọi người dùng + người dùng mới'; curUser = 'chỉ người dùng đang đăng nhập'; set = 'đặt'; del = 'xoá giá trị'; delKey = 'xoá key'
        total = 'Tổng: {0} thay đổi, {1} đã đúng sẵn, {2} bỏ qua' }
}

function Get-WdlPreviewTech {
    # technical change lines of a plan, each tagged with its tweak id
    param($Plan, $L)
    $tech = @()
    foreach ($r in @($Plan.Registry | Where-Object { -not $_.NoChange })) {
        switch ($r.Kind) {
            'RegSet' { $tech += @{ Id = $r.TweakId; T = ('{0}\{1}: {2} -> {3} ({4})' -f $r.Label, $r.Name, (Format-WdlRegData $r.Before), $r.DataText, $r.ValueKind) } }
            'RegDeleteValue' { $tech += @{ Id = $r.TweakId; T = ('{0}\{1}: {2} ({3})' -f $r.Label, $r.Name, $L.del, (Format-WdlRegData $r.Before)) } }
            'RegDeleteKey' { $tech += @{ Id = $r.TweakId; T = ('{0}: {1}' -f $r.Label, $L.delKey) } }
        }
    }
    foreach ($x in @(@($Plan.Services) | Where-Object { $_ -and -not $_.NoChange })) { $tech += @{ Id = $x.TweakId; T = ('{0}: {1} -> {2} ({3})' -f $x.Name, $x.Before.StartType, $x.StartType, $L.svc) } }
    foreach ($x in @(@($Plan.Tasks) | Where-Object { $_ -and -not $_.NoChange })) { $tech += @{ Id = $x.TweakId; T = ('{0}{1} ({2})' -f $x.Path, $x.Name, $L.task) } }
    foreach ($x in @(@($Plan.Features) | Where-Object { $_ -and -not $_.NoChange })) { $tech += @{ Id = $x.TweakId; T = ('{0} ({1})' -f $x.Name, $L.feat) } }
    foreach ($x in @(@($Plan.Special) | Where-Object { $_ -and -not $_.NoChange })) { $tech += @{ Id = $x.TweakId; T = ('{0}: {1} -> {2}' -f $x.Kind, $x.Before, $x.State) } }
    return $tech
}

function Format-WdlPreview {
    <# Plain-text preview of a resolved plan in $Lang (vi, else English). #>
    param([Parameter(Mandatory = $true)]$Plan, [string]$Lang = 'en')
    $L = $script:WdlPreviewText['en']; if ($Lang -eq 'vi') { $L = $script:WdlPreviewText['vi'] }
    $sb = New-Object Text.StringBuilder
    $add = { param($s) [void]$sb.Append($s); [void]$sb.Append("`r`n") }
    & $add ('== ' + $L.head + ' ==')
    & $add ''
    & $add ('[' + $L.apps + ']')
    if (@($Plan.Apps).Count -eq 0) { & $add ('  ' + $L.none) }
    foreach ($a in @($Plan.Apps)) {
        $sc = $L.curUser; if ($a.Scope -eq 'AllUsers') { $sc = $L.allUsers }
        & $add ('  - {0}  [{1}]  ({2})' -f (Get-WdlLangText $a.Names $Lang), $a.Id, $sc)
        foreach ($p in @($a.Packages)) { & $add ('      ' + $p) }
        foreach ($p in @($a.Provisioned)) { & $add ('      provisioned: ' + $p) }
    }
    $tech = @(Get-WdlPreviewTech -Plan $Plan -L $L)
    & $add ''
    & $add ('[' + $L.tweaks + ']')
    $shown = 0
    foreach ($tw in @($Plan.Tweaks)) {
        $lines = @($tech | Where-Object { $_.Id -eq $tw.Id })
        if ($lines.Count -eq 0) { continue }
        $shown++
        $what = Get-WdlLangText $tw.Effects $Lang
        if (-not $what) { $what = Get-WdlLangText $tw.Descriptions $Lang }
        & $add ('  - ' + (Get-WdlLangText $tw.Names $Lang))
        if ($what) { & $add ('    ' + $what) }
        foreach ($l in $lines) { & $add ('      ' + $l.T) }
    }
    $known = @(@($Plan.Tweaks) | ForEach-Object { $_.Id })
    foreach ($l in @($tech | Where-Object { $known -notcontains $_.Id })) { $shown++; & $add ('  - ' + $l.T) }
    if ($shown -eq 0) { & $add ('  ' + $L.none) }
    $same = @(@($Plan.Registry) + @($Plan.Services) + @($Plan.Tasks) + @($Plan.Features) + @($Plan.Special) | Where-Object { $_ -and $_.NoChange })
    if ($same.Count) {
        & $add ''
        & $add ('[' + $L.same + ']')
        foreach ($x in $same) { if ($x.Label) { & $add ('  {0}\{1}' -f $x.Label, $x.Name) } else { & $add ('  ' + [string]$x.Name + [string]$x.Kind) } }
    }
    if (@($Plan.Skipped).Count) {
        & $add ''
        & $add ('[' + $L.skip + ']')
        foreach ($s in @($Plan.Skipped)) { & $add ('  {0}: {1}' -f $s.What, $s.Reason) }
    }
    $c = Get-WdlPlanCounts $Plan
    & $add ''
    & $add ($L.total -f $c.Total, $c.Unchanged, $c.Skipped)
    return $sb.ToString()
}
function Get-WdlPreviewModel {
    <# Structured preview for the GUI: rows @{ Kind = Header | Item | Summary; Title; Body; Sub; Detail (lines); Count }. #>
    param([Parameter(Mandatory = $true)]$Plan, [string]$Lang = 'en')
    $L = $script:WdlPreviewText['en']; if ($Lang -eq 'vi') { $L = $script:WdlPreviewText['vi'] }
    $rows = New-Object Collections.ArrayList
    $c = Get-WdlPlanCounts $Plan
    [void]$rows.Add(@{ Kind = 'Summary'; Title = ($L.total -f $c.Total, $c.Unchanged, $c.Skipped) })
    $apps = @($Plan.Apps)
    [void]$rows.Add(@{ Kind = 'Header'; Title = $L.apps; Count = $apps.Count })
    foreach ($a in $apps) {
        $sc = $L.curUser; if ($a.Scope -eq 'AllUsers') { $sc = $L.allUsers }
        $det = @(@($a.Packages) | ForEach-Object { [string]$_ }) + @(@($a.Provisioned) | ForEach-Object { 'provisioned: ' + $_ })
        [void]$rows.Add(@{ Kind = 'Item'; Title = (Get-WdlLangText $a.Names $Lang); Sub = ('{0}  ·  {1}' -f $a.Id, $sc); Detail = $det })
    }
    $tech = @(Get-WdlPreviewTech -Plan $Plan -L $L)
    $items = @()
    foreach ($tw in @($Plan.Tweaks)) {
        $lines = @($tech | Where-Object { $_.Id -eq $tw.Id } | ForEach-Object { $_.T })
        if ($lines.Count -eq 0) { continue }
        $what = Get-WdlLangText $tw.Effects $Lang
        if (-not $what) { $what = Get-WdlLangText $tw.Descriptions $Lang }
        $items += @{ Kind = 'Item'; Title = (Get-WdlLangText $tw.Names $Lang); Body = $what; Detail = $lines }
    }
    $known = @(@($Plan.Tweaks) | ForEach-Object { $_.Id })
    $other = @($tech | Where-Object { $known -notcontains $_.Id } | ForEach-Object { $_.T })
    if ($other.Count) { $items += @{ Kind = 'Item'; Title = $L.other; Detail = $other } }
    [void]$rows.Add(@{ Kind = 'Header'; Title = $L.tweaks; Count = $items.Count })
    foreach ($x in $items) { [void]$rows.Add($x) }
    $same = @(@($Plan.Registry) + @($Plan.Services) + @($Plan.Tasks) + @($Plan.Features) + @($Plan.Special) | Where-Object { $_ -and $_.NoChange })
    if ($same.Count) {
        $det = @($same | ForEach-Object { if ($_.Label) { '{0}\{1}' -f $_.Label, $_.Name } else { [string]$_.Name + [string]$_.Kind } })
        [void]$rows.Add(@{ Kind = 'Header'; Title = $L.same; Count = $same.Count })
        [void]$rows.Add(@{ Kind = 'Item'; Title = ($L.sameItem -f $same.Count); Detail = $det })
    }
    $sk = @($Plan.Skipped)
    if ($sk.Count) {
        [void]$rows.Add(@{ Kind = 'Header'; Title = $L.skip; Count = $sk.Count })
        foreach ($x in $sk) { [void]$rows.Add(@{ Kind = 'Item'; Title = [string]$x.What; Sub = [string]$x.Reason }) }
    }
    return $rows.ToArray()
}
#endregion
