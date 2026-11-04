<#
    In-memory stand-ins for lib\System.ps1 (registry, Appx, services, tasks, features, System Restore) so the
    engine can be tested anywhere, including pwsh on Linux. Dot-source after the lib files.
#>
$script:MockReg = @{}          # 'ROOT\path' (lower case) -> @{ Path; Values = @{ name(lower) = @{ Name; Kind; Data } } }
$script:MockLog = New-Object Collections.ArrayList
$script:MockFail = @{}         # 'ROOT\path\name' (lower case) -> error text for Set-WdlRegValue
$script:MockMounts = 0

function Get-MockKeyId([string]$Root, [string]$Path) { return ("$Root\$Path").ToLowerInvariant().TrimEnd('\') }

function New-MockKey([string]$Root, [string]$Path) {
    $parts = $Path.Split('\'); $acc = ''
    foreach ($p in $parts) {
        if ($acc) { $acc = "$acc\$p" } else { $acc = $p }
        $id = Get-MockKeyId $Root $acc
        if (-not $script:MockReg.ContainsKey($id)) { $script:MockReg[$id] = @{ Root = $Root; Path = $acc; Values = @{} } }
    }
    return $script:MockReg[(Get-MockKeyId $Root $Path)]
}

function Set-MockValue([string]$Root, [string]$Path, [string]$Name, [string]$Kind, $Data) {
    $k = New-MockKey $Root $Path
    $k.Values[$Name.ToLowerInvariant()] = @{ Name = $Name; Kind = $Kind; Data = $Data }
}

function Get-MockRegDump {
    # stable text form of the whole mock registry (for before / after comparisons)
    $lines = @()
    foreach ($id in @($script:MockReg.Keys | Sort-Object)) {
        $lines += "[$id]"
        $k = $script:MockReg[$id]
        foreach ($n in @($k.Values.Keys | Sort-Object)) {
            $v = $k.Values[$n]; $d = $v.Data
            if (@('Binary', 'None') -contains $v.Kind) { $d = [Convert]::ToBase64String([byte[]]$d) } elseif ($v.Kind -eq 'MultiString') { $d = (@($d) -join '|') }
            $lines += ('{0}={1}:{2}' -f $v.Name, $v.Kind, $d)
        }
    }
    return ($lines -join "`n")
}

function Get-WdlRegValue {
    param([string]$Root, [string]$Path, [string]$Name)
    $k = $script:MockReg[(Get-MockKeyId $Root $Path)]
    if (-not $k -or -not $k.Values.ContainsKey($Name.ToLowerInvariant())) { return @{ Exists = $false } }
    $v = $k.Values[$Name.ToLowerInvariant()]
    return @{ Exists = $true; Kind = $v.Kind; Data = $v.Data }
}
function Set-WdlRegValue {
    param([string]$Root, [string]$Path, [string]$Name, [string]$Kind, $Data)
    $f = ("$Root\$Path\$Name").ToLowerInvariant()
    if ($script:MockFail.ContainsKey($f)) { throw $script:MockFail[$f] }
    if (@('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary', 'None') -notcontains $Kind) { throw "bad kind $Kind" }
    if ($Kind -eq 'DWord' -and -not ($Data -is [int])) { throw "DWord data must be Int32, got $($Data.GetType().Name)" }
    if ($Kind -eq 'QWord' -and -not ($Data -is [long])) { throw "QWord data must be Int64, got $($Data.GetType().Name)" }
    if (@('Binary', 'None') -contains $Kind -and -not ($Data -is [byte[]])) { throw "$Kind data must be byte[]" }
    Set-MockValue $Root $Path $Name $Kind $Data
}
function Remove-WdlRegValue {
    param([string]$Root, [string]$Path, [string]$Name)
    $k = $script:MockReg[(Get-MockKeyId $Root $Path)]
    if ($k) { $k.Values.Remove($Name.ToLowerInvariant()) }
}
function Test-WdlRegKey { param([string]$Root, [string]$Path) return $script:MockReg.ContainsKey((Get-MockKeyId $Root $Path)) }
function Get-WdlRegKeySnapshot {
    param([string]$Root, [string]$Path)
    $id = Get-MockKeyId $Root $Path
    $k = $script:MockReg[$id]
    if (-not $k) { return $null }
    $s = @{ Values = @(); Keys = @() }
    foreach ($v in $k.Values.Values) { $s.Values += @{ Name = $v.Name; Kind = $v.Kind; Data = $v.Data } }
    foreach ($cid in @($script:MockReg.Keys)) {
        if ($cid.StartsWith($id + '\') -and $cid.Substring($id.Length + 1) -notmatch '\\') {
            $c = $script:MockReg[$cid]
            $s.Keys += @{ Name = ($c.Path.Split('\'))[-1]; Snapshot = (Get-WdlRegKeySnapshot $Root $c.Path) }
        }
    }
    return $s
}
function Restore-WdlRegKeySnapshot {
    param([string]$Root, [string]$Path, $Snapshot)
    $null = New-MockKey $Root $Path
    foreach ($v in @($Snapshot.Values)) { if ($v) { Set-WdlRegValue -Root $Root -Path $Path -Name $v.Name -Kind $v.Kind -Data $v.Data } }
    foreach ($c in @($Snapshot.Keys)) { if ($c) { Restore-WdlRegKeySnapshot -Root $Root -Path "$Path\$($c.Name)" -Snapshot $c.Snapshot } }
}
function Remove-WdlRegKey {
    param([string]$Root, [string]$Path)
    $id = Get-MockKeyId $Root $Path
    foreach ($k in @($script:MockReg.Keys)) { if ($k -eq $id -or $k.StartsWith($id + '\')) { $script:MockReg.Remove($k) } }
}
function Use-WdlDefaultHive {
    param([scriptblock]$Script, [switch]$Needed)
    if ($Needed) { $script:MockMounts++ }
    return (& $Script)
}

# ---- OS / user ----
$script:MockUser = @{ Sid = 'S-1-5-21-1000-2000-3000-1001'; Name = 'PC\Người Dùng Thử'; Source = 'explorer' }
function Set-MockOs([int]$Build, [string]$Type = 'Client', [string]$Edition = 'Professional') {
    $cv = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Set-MockValue 'HKLM' $cv 'CurrentBuildNumber' 'String' ([string]$Build)
    Set-MockValue 'HKLM' $cv 'UBR' 'DWord' 1234
    Set-MockValue 'HKLM' $cv 'EditionID' 'String' $Edition
    Set-MockValue 'HKLM' $cv 'ProductName' 'String' 'Windows 10 Pro'
    Set-MockValue 'HKLM' $cv 'DisplayVersion' 'String' '24H2'
    Set-MockValue 'HKLM' $cv 'InstallationType' 'String' $Type
}
function Get-WdlInteractiveUser { return (New-WdlObj $script:MockUser) }

# ---- Appx ----
$script:MockApps = New-Object Collections.ArrayList
$script:MockProv = New-Object Collections.ArrayList
function Add-MockApp([string]$Name, [switch]$NonRemovable, [switch]$Framework, [switch]$NoProvisioned) {
    [void]$script:MockApps.Add(@{ Name = $Name; PackageFullName = "${Name}_1.0.0.0_x64__8wekyb3d8bbwe"; IsBundle = $false; NonRemovable = [bool]$NonRemovable; IsFramework = [bool]$Framework; InstallLocation = "C:\Program Files\WindowsApps\${Name}_1.0.0.0_x64__8wekyb3d8bbwe" })
    if (-not $NoProvisioned) { [void]$script:MockProv.Add(@{ DisplayName = $Name; PackageName = "${Name}_1.0.0.0_neutral_~_8wekyb3d8bbwe" }) }
}
function Get-WdlAppInventory { return @{ Installed = @($script:MockApps); Provisioned = @($script:MockProv) } }
$script:MockAppFail = @{}
function Remove-WdlAppPackage {
    param([string]$FullName, [string]$Scope, [string]$UserSid)
    [void]$script:MockLog.Add("remove-app $FullName $Scope $UserSid")
    if ($script:MockAppFail.ContainsKey($FullName)) { return $script:MockAppFail[$FullName] }
    foreach ($a in @($script:MockApps)) { if ($a.PackageFullName -eq $FullName) { $script:MockApps.Remove($a) } }
    return $null
}
function Remove-WdlProvisionedPackage { param([string]$PackageName) [void]$script:MockLog.Add("deprovision $PackageName"); foreach ($a in @($script:MockProv)) { if ($a.PackageName -eq $PackageName) { $script:MockProv.Remove($a) } }; return $null }
function Register-WdlAppPackage { param([string]$InstallLocation) [void]$script:MockLog.Add("register $InstallLocation"); return 'package files are no longer on this PC (reinstall it from Microsoft Store)' }

# ---- services (through the mock registry), tasks, features, reserved storage ----
function Set-WdlServiceStart {
    param([string]$Name, [string]$StartType)
    if ($Name -eq 'ProtectedSvc') { return 'access denied (protected service)' }
    $map = @{ Disabled = 4; Manual = 3; Automatic = 2; AutomaticDelayed = 2 }
    $p = "SYSTEM\CurrentControlSet\Services\$Name"
    Set-MockValue 'HKLM' $p 'Start' 'DWord' $map[$StartType]
    if ($StartType -eq 'AutomaticDelayed') { Set-MockValue 'HKLM' $p 'DelayedAutostart' 'DWord' 1 } elseif ($StartType -eq 'Automatic') { Set-MockValue 'HKLM' $p 'DelayedAutostart' 'DWord' 0 }
    return $null
}
$script:MockTasks = @{}
function Get-WdlTaskState { param([string]$Path, [string]$Name) $k = "$Path$Name"; if (-not $script:MockTasks.ContainsKey($k)) { return @{ Exists = $false; Enabled = $false } }; return @{ Exists = $true; Enabled = $script:MockTasks[$k] } }
function Set-WdlTaskEnabled { param([string]$Path, [string]$Name, [bool]$Enabled) $script:MockTasks["$Path$Name"] = $Enabled; return $null }
$script:MockFeatures = @{}
function Get-WdlFeatureState { param([string]$Name) if ($script:MockFeatures.ContainsKey($Name)) { return $script:MockFeatures[$Name] }; return 'Absent' }
function Set-WdlFeatureState { param([string]$Name, [string]$State) $script:MockFeatures[$Name] = $State; return @{ Error = $null; Reboot = $true } }
$script:MockReserved = 'Enabled'
function Get-WdlReservedStorageState { return $script:MockReserved }
function Set-WdlReservedStorageState { param([string]$State) $script:MockReserved = $State; return $null }

# ---- System Restore ----
$script:MockRp = @{ Seq = 5; Enabled = $true; Policy = $false; Silent = $false; EnableError = $null }
function Get-WdlRestoreStatus { return (New-WdlObj @{ Drive = 'C:'; Enabled = $script:MockRp.Enabled; PolicyDisabled = $script:MockRp.Policy }) }
function Enable-WdlSystemProtection { param([string]$Drive) if ($script:MockRp.EnableError) { return $script:MockRp.EnableError }; $script:MockRp.Enabled = $true; return $null }
function Get-WdlLastRestorePoint { return $script:MockRp.Seq }
# New-WdlRestorePoint stays real; only the CIM call inside Invoke-WdlTimed is replaced
function Invoke-WdlTimed {
    param([scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$TimeoutSec = 120)
    $f = Get-WdlRegValue -Root 'HKLM' -Path $script:WdlSrKey -Name 'SystemRestorePointCreationFrequency'
    $script:MockRp.FreqSeen = $f
    if (-not $script:MockRp.Silent -and $f.Exists -and [int]$f.Data -eq 0) { $script:MockRp.Seq++ }
    return (New-WdlObj @{ Completed = $true; TimedOut = $false; Output = @(0); Error = $null })
}

$script:MockDataDir = Join-Path ([IO.Path]::GetTempPath()) ('wdl-test-' + [guid]::NewGuid().ToString('N'))
function Get-WdlDataDir { return $script:MockDataDir }
