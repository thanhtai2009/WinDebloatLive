<#
    WinDebloat Live - the only place that touches the running Windows system: OS facts, registry (64-bit view),
    Appx packages, services, scheduled tasks, optional features, System Restore. Uses CIM, the registry and
    exit codes only (never localized command output, never wmic). Slow calls run with a time limit.
    Tests replace these functions with in-memory mocks.
    SPDX-License-Identifier: MIT
#>

#region ---------- OS / user facts ----------
function Test-WdlAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WdlOsInfo {
    <# Facts of the running Windows from the registry (language independent): Build, Ubr, Os (Win10 / Win11),
       EditionId, ProductName, DisplayVersion, InstallationType, Supported, Reason. #>
    $cv = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $g = { param($n) $v = Get-WdlRegValue -Root 'HKLM' -Path $cv -Name $n; if ($v.Exists) { return $v.Data }; return $null }
    $build = 0; [void][int]::TryParse([string](& $g 'CurrentBuildNumber'), [ref]$build)
    if ($build -le 0) { $build = [Environment]::OSVersion.Version.Build }
    $ubr = & $g 'UBR'
    $dv = [string](& $g 'DisplayVersion'); if (-not $dv) { $dv = [string](& $g 'ReleaseId') }
    $info = @{ Build = $build; Ubr = [int]$ubr; EditionId = [string](& $g 'EditionID'); ProductName = [string](& $g 'ProductName')
        DisplayVersion = $dv; InstallationType = [string](& $g 'InstallationType'); Os = 'Win10'; Supported = $true; Reason = ''
        Arch = [string]$env:PROCESSOR_ARCHITECTURE; SystemDrive = [string]$env:SystemDrive }
    if (-not $info.SystemDrive) { $info.SystemDrive = 'C:' }
    if ($build -ge 22000) {
        $info.Os = 'Win11'
        # ProductName still says "Windows 10" on Windows 11
        $info.ProductName = $info.ProductName -replace '^Windows 10', 'Windows 11'
    }
    if ($info.InstallationType -and $info.InstallationType -ne 'Client') { $info.Supported = $false; $info.Reason = "Windows $($info.InstallationType) is not supported (Windows 10 / 11 client only)" }
    elseif ($build -lt $script:WDL.MinBuild) { $info.Supported = $false; $info.Reason = "Windows build $build is too old (Windows 10 1809 / build 17763 or newer needed)" }
    return (New-WdlObj $info)
}

function Get-WdlInteractiveUser {
    <# The user signed in to this desktop session (owner of explorer.exe in our session). An administrator may
       have elevated the tool with other credentials; HKCU of this process would then be the wrong profile. #>
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $res = @{ Sid = $me.User.Value; Name = $me.Name; Source = 'process' }
    try {
        $sess = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $r = Invoke-WdlTimed -TimeoutSec 30 -ArgumentList $sess -Script {
            param($sess)
            foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
                if ($p.SessionId -ne $sess) { continue }
                $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
                if ($o.ReturnValue -eq 0 -and $o.Sid) { return $o.Sid }
            }
        }
        $sid = [string](@($r.Output) | Select-Object -First 1)
        if ($sid -match '^S-1-5-21-[\d-]+$' -or $sid -match '^S-1-12-1-[\d-]+$') {
            $res.Sid = $sid; $res.Source = 'explorer'
            try { $res.Name = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $res.Name = $sid }
        }
    } catch { $null = $_ }
    return (New-WdlObj $res)
}
#endregion

#region ---------- registry (always the 64-bit view) ----------
function Open-WdlBaseKey([string]$Root) {
    switch ($Root) {
        'HKLM' { $h = [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKU' { $h = [Microsoft.Win32.RegistryHive]::Users }
        default { throw "unsupported registry root $Root" }
    }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-WdlRegValue {
    <# @{ Exists; Kind (RegistryValueKind name); Data } of one value; expandable strings are not expanded. #>
    param([string]$Root, [string]$Path, [string]$Name)
    $b = Open-WdlBaseKey $Root
    try {
        $k = $b.OpenSubKey($Path, $false)
        if (-not $k) { return @{ Exists = $false } }
        try {
            if (@($k.GetValueNames()) -notcontains $Name) { return @{ Exists = $false } }
            $kind = $k.GetValueKind($Name).ToString()
            $data = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return @{ Exists = $true; Kind = $kind; Data = $data }
        } finally { $k.Dispose() }
    } finally { $b.Dispose() }
}

function Set-WdlRegValue {
    param([string]$Root, [string]$Path, [string]$Name, [string]$Kind, $Data)
    $b = Open-WdlBaseKey $Root
    try {
        $k = $b.CreateSubKey($Path)
        if (-not $k) { throw "cannot open or create $Root\$Path" }
        try { $k.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Dispose() }
    } finally { $b.Dispose() }
}

function Remove-WdlRegValue {
    param([string]$Root, [string]$Path, [string]$Name)
    $b = Open-WdlBaseKey $Root
    try {
        $k = $b.OpenSubKey($Path, $true)
        if (-not $k) { return }
        try { $k.DeleteValue($Name, $false) } finally { $k.Dispose() }
    } finally { $b.Dispose() }
}

function Test-WdlRegKey {
    param([string]$Root, [string]$Path)
    $b = Open-WdlBaseKey $Root
    try { $k = $b.OpenSubKey($Path, $false); if ($k) { $k.Dispose(); return $true }; return $false } finally { $b.Dispose() }
}

function Get-WdlRegKeySnapshot {
    <# Whole key (values + subkeys, recursive) as @{ Values = @(@{ Name; Kind; Data }); Keys = @(@{ Name; Snapshot }) },
       $null when the key is missing. Limited to 5000 values so a wrong rule cannot produce a huge backup. #>
    param([string]$Root, [string]$Path, [int]$Budget = 5000)
    $b = Open-WdlBaseKey $Root
    try {
        $k = $b.OpenSubKey($Path, $false)
        if (-not $k) { return $null }
        try { return (Get-WdlKeySnapshotInner $k ([ref]$Budget)) } finally { $k.Dispose() }
    } finally { $b.Dispose() }
}

function Get-WdlKeySnapshotInner($Key, [ref]$Budget) {
    $s = @{ Values = @(); Keys = @() }
    foreach ($n in @($Key.GetValueNames())) {
        if (--$Budget.Value -lt 0) { throw 'registry key too large to back up' }
        $s.Values += @{ Name = $n; Kind = $Key.GetValueKind($n).ToString(); Data = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    foreach ($n in @($Key.GetSubKeyNames())) {
        $sk = $Key.OpenSubKey($n, $false)
        if (-not $sk) { continue }
        try { $s.Keys += @{ Name = $n; Snapshot = (Get-WdlKeySnapshotInner $sk $Budget) } } finally { $sk.Dispose() }
    }
    return $s
}

function Restore-WdlRegKeySnapshot {
    param([string]$Root, [string]$Path, $Snapshot)
    foreach ($v in @($Snapshot.Values)) { if ($v) { Set-WdlRegValue -Root $Root -Path $Path -Name $v.Name -Kind $v.Kind -Data $v.Data } }
    if (@($Snapshot.Values).Count -eq 0) { $b = Open-WdlBaseKey $Root; try { $k = $b.CreateSubKey($Path); if ($k) { $k.Dispose() } } finally { $b.Dispose() } }
    foreach ($c in @($Snapshot.Keys)) { if ($c) { Restore-WdlRegKeySnapshot -Root $Root -Path "$Path\$($c.Name)" -Snapshot $c.Snapshot } }
}

function Remove-WdlRegKey {
    param([string]$Root, [string]$Path)
    $b = Open-WdlBaseKey $Root
    try { $b.DeleteSubKeyTree($Path, $false) } finally { $b.Dispose() }
}

function Get-WdlDefaultHivePath {
    # NTUSER.DAT of the Default profile (template for new user accounts)
    $v = Get-WdlRegValue -Root 'HKLM' -Path 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name 'Default'
    $dir = $null
    if ($v.Exists -and $v.Data) { $dir = [Environment]::ExpandEnvironmentVariables([string]$v.Data) }
    if (-not $dir) { $dir = Join-Path $env:SystemDrive 'Users\Default' }
    return (Join-Path $dir 'NTUSER.DAT')
}

function Use-WdlDefaultHive {
    <# Loads the Default profile hive as HKU\WDL_DefaultUser, runs $Script, unloads it again (also on errors).
       Without -Needed the script just runs. #>
    param([Parameter(Mandatory = $true)][scriptblock]$Script, [switch]$Needed)
    if (-not $Needed) { return (& $Script) }
    $name = $script:WdlDefaultHiveName
    $reg = Get-WdlSystemExe 'reg.exe'
    $loaded = $false
    if (-not (Test-WdlRegKey -Root 'HKU' -Path $name)) {
        $file = Get-WdlDefaultHivePath
        if (-not (Test-WdlPathText $file -Leaf)) { throw "Default profile hive not found: $file / Không thấy hồ sơ người dùng mặc định" }
        $code = Invoke-WdlProcess -FilePath $reg -Arguments ('load "HKU\{0}" "{1}"' -f $name, $file) -TimeoutSec 60
        if ($code -ne 0) { throw "Could not load the Default profile hive (reg load exit $code) / Không nạp được hồ sơ mặc định" }
        $loaded = $true
    }
    try { return (& $Script) }
    finally {
        if ($loaded) {
            for ($i = 0; $i -lt 10; $i++) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
                if ((Invoke-WdlProcess -FilePath $reg -Arguments ('unload "HKU\{0}"' -f $name) -TimeoutSec 30) -eq 0) { break }
                Start-Sleep -Milliseconds 700
            }
            if (Test-WdlRegKey -Root 'HKU' -Path $name) { Write-WdlLog -Level WARN -En "The Default profile hive is still loaded as HKU\$name; it is released at the next restart" -Vi 'Hồ sơ mặc định vẫn đang được nạp, sẽ tự giải phóng khi khởi động lại' }
        }
    }
}
#endregion

#region ---------- Appx packages ----------
function Get-WdlAppInventory {
    <# Installed packages of all users (one entry per package name, the bundle when there is one) and the
       provisioned packages: @{ Installed = @(@{ Name; PackageFullName; IsBundle; NonRemovable; IsFramework;
       InstallLocation }); Provisioned = @(@{ DisplayName; PackageName }) } #>
    param([int]$TimeoutSec = 180)
    $r = Invoke-WdlTimed -TimeoutSec $TimeoutSec -Script {
        $byName = @{}
        foreach ($p in @(Get-AppxPackage -AllUsers -PackageTypeFilter Main, Bundle -ErrorAction SilentlyContinue)) {
            $e = $byName[$p.Name]
            $nr = $false; try { $nr = [bool]$p.NonRemovable } catch { $null = $_ }
            if (-not $e) { $e = @{ Name = [string]$p.Name; PackageFullName = [string]$p.PackageFullName; IsBundle = [bool]$p.IsBundle; NonRemovable = $nr; IsFramework = [bool]$p.IsFramework; InstallLocation = [string]$p.InstallLocation }; $byName[$p.Name] = $e }
            else {
                if ($nr) { $e.NonRemovable = $true }
                if ($p.IsBundle -and -not $e.IsBundle) { $e.PackageFullName = [string]$p.PackageFullName; $e.IsBundle = $true }
                if (-not $e.InstallLocation) { $e.InstallLocation = [string]$p.InstallLocation }
            }
        }
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { @{ DisplayName = [string]$_.DisplayName; PackageName = [string]$_.PackageName } })
        return @{ Installed = @($byName.Values); Provisioned = $prov }
    }
    if ($r.TimedOut) { throw "Listing the installed apps took longer than $TimeoutSec s / Liệt kê ứng dụng quá thời gian" }
    if ($r.Error) { throw "Could not list the installed apps: $($r.Error.Message) / Không liệt kê được ứng dụng" }
    $o = @($r.Output) | Select-Object -Last 1
    return @{ Installed = @($o.Installed); Provisioned = @($o.Provisioned) }
}

function Remove-WdlAppPackage {
    <# Removes one package for all users or for one user (-UserSid). Returns $null or an error text. #>
    param([string]$FullName, [ValidateSet('AllUsers', 'CurrentUser')][string]$Scope, [string]$UserSid, [int]$TimeoutSec = 300)
    $r = Invoke-WdlTimed -TimeoutSec $TimeoutSec -ArgumentList $FullName, $Scope, $UserSid -Script {
        param($fn, $scope, $sid)
        if ($scope -eq 'AllUsers') { Remove-AppxPackage -Package $fn -AllUsers -ErrorAction Stop }
        elseif ($sid) { Remove-AppxPackage -Package $fn -User $sid -ErrorAction Stop }
        else { Remove-AppxPackage -Package $fn -ErrorAction Stop }
    }
    if ($r.TimedOut) { return "timed out after $TimeoutSec s" }
    if ($r.Error) { return [string]$r.Error.Message }
    return $null
}

function Remove-WdlProvisionedPackage {
    param([string]$PackageName, [int]$TimeoutSec = 300)
    $r = Invoke-WdlTimed -TimeoutSec $TimeoutSec -ArgumentList $PackageName -Script {
        param($pn)
        $null = Remove-AppxProvisionedPackage -Online -PackageName $pn -ErrorAction Stop
    }
    if ($r.TimedOut) { return "timed out after $TimeoutSec s" }
    if ($r.Error) { return [string]$r.Error.Message }
    return $null
}

function Register-WdlAppPackage {
    <# Undo of a per-user removal: registers the package again from its install folder when it is still on disk
       (it is while another user or the provisioned copy keeps it). Returns $null or an error text. #>
    param([string]$InstallLocation, [int]$TimeoutSec = 300)
    if (-not $InstallLocation) { return 'install folder unknown' }
    $manifest = Join-Path $InstallLocation 'AppxManifest.xml'
    if (-not (Test-WdlPathText $manifest -Leaf)) { return 'package files are no longer on this PC (reinstall it from Microsoft Store)' }
    $r = Invoke-WdlTimed -TimeoutSec $TimeoutSec -ArgumentList $manifest -Script {
        param($m)
        Add-AppxPackage -Register $m -DisableDevelopmentMode -ErrorAction Stop
    }
    if ($r.TimedOut) { return "timed out after $TimeoutSec s" }
    if ($r.Error) { return [string]$r.Error.Message }
    return $null
}
#endregion

#region ---------- services / tasks / features / reserved storage ----------
$script:WdlStartNames = @{ 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled'; 0 = 'Boot'; 1 = 'System' }

function Get-WdlServiceStart {
    # start type from the registry (Start + DelayedAutostart): @{ Exists; StartType }
    param([string]$Name)
    $p = "SYSTEM\CurrentControlSet\Services\$Name"
    $v = Get-WdlRegValue -Root 'HKLM' -Path $p -Name 'Start'
    if (-not $v.Exists) { return @{ Exists = $false } }
    $st = $script:WdlStartNames[[int]$v.Data]
    if ($st -eq 'Automatic') { $d = Get-WdlRegValue -Root 'HKLM' -Path $p -Name 'DelayedAutostart'; if ($d.Exists -and [int]$d.Data -eq 1) { $st = 'AutomaticDelayed' } }
    return @{ Exists = $true; StartType = $st }
}

function Set-WdlServiceStart {
    # sc.exe config (exit code only). Returns $null or an error text (5 = access denied for protected services).
    param([string]$Name, [string]$StartType)
    $map = @{ Disabled = 'disabled'; Manual = 'demand'; Automatic = 'auto'; AutomaticDelayed = 'delayed-auto' }
    if (-not $map.ContainsKey($StartType)) { return "start type $StartType cannot be set" }
    $code = Invoke-WdlProcess -FilePath (Get-WdlSystemExe 'sc.exe') -Arguments ('config "{0}" start= {1}' -f $Name, $map[$StartType]) -TimeoutSec 60
    if ($code -eq 0) { return $null }
    if ($code -eq 5) { return 'access denied (protected service)' }
    return "sc.exe exit code $code"
}

function Get-WdlTaskState {
    param([string]$Path, [string]$Name)
    $r = Invoke-WdlTimed -TimeoutSec 60 -ArgumentList $Path, $Name -Script {
        param($p, $n)
        $t = Get-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction SilentlyContinue
        if (-not $t) { return @{ Exists = $false; Enabled = $false } }
        return @{ Exists = $true; Enabled = ([string]$t.State -ne 'Disabled') }
    }
    if ($r.TimedOut -or $r.Error -or -not $r.Output) { return @{ Exists = $false; Enabled = $false } }
    return (@($r.Output) | Select-Object -Last 1)
}

function Set-WdlTaskEnabled {
    param([string]$Path, [string]$Name, [bool]$Enabled)
    $r = Invoke-WdlTimed -TimeoutSec 60 -ArgumentList $Path, $Name, $Enabled -Script {
        param($p, $n, $e)
        if ($e) { $null = Enable-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop } else { $null = Disable-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop }
    }
    if ($r.TimedOut) { return 'timed out' }
    if ($r.Error) { return [string]$r.Error.Message }
    return $null
}

function Get-WdlFeatureState {
    # Enabled | Disabled | Absent | Unknown (Win32_OptionalFeature.InstallState 1 / 2 / 3)
    param([string]$Name)
    $r = Invoke-WdlTimed -TimeoutSec 120 -ArgumentList $Name -Script {
        param($n)
        $f = Get-CimInstance -ClassName Win32_OptionalFeature -Filter ("Name='{0}'" -f $n) -ErrorAction Stop
        if (-not $f) { return 'Absent' }
        switch ([int]$f.InstallState) { 1 { return 'Enabled' } 2 { return 'Disabled' } 3 { return 'Absent' } }
        return 'Unknown'
    }
    if ($r.TimedOut -or $r.Error) { return 'Unknown' }
    return [string](@($r.Output) | Select-Object -Last 1)
}

function Set-WdlFeatureState {
    # dism.exe /Online (exit 0 or 3010 = done, restart needed). Returns @{ Error; Reboot }
    param([string]$Name, [ValidateSet('Enabled', 'Disabled')][string]$State, [int]$TimeoutSec = 900)
    if ($State -eq 'Disabled') { $a = '/Online /Disable-Feature /FeatureName:{0} /NoRestart /Quiet' -f $Name }
    else { $a = '/Online /Enable-Feature /FeatureName:{0} /All /NoRestart /Quiet' -f $Name }
    $code = Invoke-WdlProcess -FilePath (Get-WdlSystemExe 'dism.exe') -Arguments $a -TimeoutSec $TimeoutSec
    if ($code -eq 0) { return @{ Error = $null; Reboot = $false } }
    if ($code -eq 3010) { return @{ Error = $null; Reboot = $true } }
    if ($code -eq -1) { return @{ Error = "timed out after $TimeoutSec s"; Reboot = $false } }
    return @{ Error = ('dism.exe exit code {0} (0x{0:X8})' -f $code); Reboot = $false }
}

function Get-WdlReservedStorageState {
    $r = Invoke-WdlTimed -TimeoutSec 120 -Script { [string](Get-WindowsReservedStorageState -ErrorAction Stop).ReservedStorageState }
    if ($r.TimedOut -or $r.Error) { return 'Unknown' }
    return [string](@($r.Output) | Select-Object -Last 1)
}

function Set-WdlReservedStorageState {
    param([ValidateSet('Enabled', 'Disabled')][string]$State)
    $r = Invoke-WdlTimed -TimeoutSec 300 -ArgumentList $State -Script { param($s) $null = Set-WindowsReservedStorageState -State $s -ErrorAction Stop }
    if ($r.TimedOut) { return 'timed out' }
    if ($r.Error) { return [string]$r.Error.Message }
    return $null
}
#endregion

#region ---------- System Restore ----------
$script:WdlSrKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'

function Get-WdlRestoreStatus {
    <# @{ Enabled (System Protection on the system drive); PolicyDisabled; Drive } #>
    $drive = ([string]$env:SystemDrive).TrimEnd('\'); if (-not $drive) { $drive = 'C:' }
    $res = @{ Drive = $drive; Enabled = $false; PolicyDisabled = $false }
    foreach ($n in @('DisableSR', 'DisableConfig')) {
        $p = Get-WdlRegValue -Root 'HKLM' -Path 'SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -Name $n
        if ($p.Exists -and [int]$p.Data -eq 1) { $res.PolicyDisabled = $true }
    }
    # protected volumes are listed by the volume shadow copy client; the entry ends with "(C%3A)"
    $c = Get-WdlRegValue -Root 'HKLM' -Path 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -Name '{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
    if ($c.Exists) {
        $tok = '(' + $drive.Replace(':', '%3A') + ')'
        foreach ($s in @($c.Data)) { if ([string]$s -and ([string]$s).IndexOf($tok, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $res.Enabled = $true } }
    }
    return (New-WdlObj $res)
}

function Enable-WdlSystemProtection {
    # turns System Protection on for the system drive (SystemRestore.Enable); returns $null or an error text
    param([string]$Drive)
    $r = Invoke-WdlTimed -TimeoutSec 180 -ArgumentList ($Drive.TrimEnd('\') + '\') -Script {
        param($d)
        $o = Invoke-CimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -MethodName 'Enable' -Arguments @{ Drive = $d } -ErrorAction Stop
        return [int]$o.ReturnValue
    }
    if ($r.TimedOut) { return 'timed out' }
    if ($r.Error) { return [string]$r.Error.Message }
    $rv = [int](@($r.Output) | Select-Object -Last 1)
    if ($rv -ne 0) { return ('SystemRestore.Enable returned 0x{0:X8}' -f $rv) }
    return $null
}

function Get-WdlLastRestorePoint {
    # highest restore point sequence number (0 = none)
    $r = Invoke-WdlTimed -TimeoutSec 60 -Script {
        $m = 0
        foreach ($p in @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction SilentlyContinue)) { if ([int]$p.SequenceNumber -gt $m) { $m = [int]$p.SequenceNumber } }
        return $m
    }
    if ($r.TimedOut -or $r.Error) { return 0 }
    return [int](@($r.Output) | Select-Object -Last 1)
}

function New-WdlRestorePoint {
    <# Creates a restore point and checks it really exists (Windows silently skips one within 24 h of the last).
       SystemRestorePointCreationFrequency is set to 0 for the call and put back afterwards.
       Returns @{ Ok; Sequence; Error } #>
    param([string]$Description, [int]$TimeoutSec = 600)
    $res = @{ Ok = $false; Sequence = 0; Error = '' }
    $before = Get-WdlLastRestorePoint
    $old = Get-WdlRegValue -Root 'HKLM' -Path $script:WdlSrKey -Name 'SystemRestorePointCreationFrequency'
    try {
        Set-WdlRegValue -Root 'HKLM' -Path $script:WdlSrKey -Name 'SystemRestorePointCreationFrequency' -Kind 'DWord' -Data 0
        $r = Invoke-WdlTimed -TimeoutSec $TimeoutSec -ArgumentList $Description -Script {
            param($desc)
            # 12 = MODIFY_SETTINGS, 100 = BEGIN_SYSTEM_CHANGE
            $o = Invoke-CimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -MethodName 'CreateRestorePoint' -Arguments @{ Description = $desc; RestorePointType = [uint32]12; EventType = [uint32]100 } -ErrorAction Stop
            return [int]$o.ReturnValue
        }
        if ($r.TimedOut) { $res.Error = "no answer within $TimeoutSec s" }
        elseif ($r.Error) { $res.Error = [string]$r.Error.Message }
        else {
            $rv = [int](@($r.Output) | Select-Object -Last 1)
            if ($rv -ne 0) { $res.Error = ('CreateRestorePoint returned 0x{0:X8}' -f $rv) }
        }
    } catch { $res.Error = $_.Exception.Message }
    finally {
        try {
            if ($old.Exists) { Set-WdlRegValue -Root 'HKLM' -Path $script:WdlSrKey -Name 'SystemRestorePointCreationFrequency' -Kind $old.Kind -Data $old.Data }
            else { Remove-WdlRegValue -Root 'HKLM' -Path $script:WdlSrKey -Name 'SystemRestorePointCreationFrequency' }
        } catch { Write-WdlLog -Level WARN -En "Could not restore SystemRestorePointCreationFrequency: $($_.Exception.Message)" }
    }
    $after = Get-WdlLastRestorePoint
    if ($after -gt $before) { $res.Ok = $true; $res.Sequence = $after; $res.Error = '' }
    elseif (-not $res.Error) { $res.Error = 'Windows did not create the restore point (check that System Protection has disk space)' }
    return (New-WdlObj $res)
}
#endregion

#region ---------- data folder (backups, logs) ----------
function Get-WdlDataDir {
    $base = $env:ProgramData; if (-not $base) { $base = 'C:\ProgramData' }
    return (Join-Path $base $script:WDL.DataDirName)
}

function Initialize-WdlDataDir {
    <# %ProgramData%\WinDebloatLive with backups\ and logs\, writable only by Administrators and SYSTEM (Undo
       restores registry values from these files). A folder that someone else created first is moved aside. #>
    $dir = Get-WdlDataDir
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $owner = $null
        try { $owner = (Get-Acl -LiteralPath $dir).GetOwner([Security.Principal.SecurityIdentifier]) } catch { $null = $_ }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $owner -or -not ($owner.Equals($admins) -or $owner.Equals($system) -or $owner.Equals($me))) {
            $aside = $dir + '.untrusted-' + (Get-Date -Format 'yyyyMMddHHmmss')
            Write-WdlLog -Level WARN -En "$dir was not created by an administrator; moved to $aside" -Vi 'Thư mục dữ liệu không do quản trị viên tạo, đã đổi tên'
            [IO.Directory]::Move($dir, $aside)
        }
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        $sec = New-Object Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $inh = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $none = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $admins, 'FullControl', $inh, $none, $allow))
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $system, 'FullControl', $inh, $none, $allow))
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $users, 'ReadAndExecute', $inh, $none, $allow))
        $sec.SetOwner($admins)
        $null = [IO.Directory]::CreateDirectory($dir, $sec)
    }
    foreach ($s in @('backups', 'logs')) { New-WdlDirectory (Join-Path $dir $s) }
    return $dir
}

function Restart-WdlComputer {
    $null = Invoke-WdlProcess -FilePath (Get-WdlSystemExe 'shutdown.exe') -Arguments '/r /t 10 /d p:4:1' -TimeoutSec 30
}
#endregion
