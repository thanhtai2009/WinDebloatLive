<#
    WinDebloat Live - scan, apply with a JSON backup of every change, and undo from that backup.
    SPDX-License-Identifier: MIT
#>

$script:WdlBackupSchema = 'windebloat-live-backup/1'

#region ---------- scan ----------
function Get-WdlSession {
    <# Everything the UI needs about this PC: OS facts, signed-in user, rules, applicable apps / tweaks. #>
    param($Config)
    Set-WdlProgress 5 'Reading Windows version... / Đang đọc phiên bản Windows...'
    $os = Get-WdlOsInfo
    $user = Get-WdlInteractiveUser
    if (-not $Config) { $Config = Get-WdlConfig }
    Write-WdlLog -En ("Windows: {0} {1} (build {2}.{3}, {4}), edition {5}" -f $os.ProductName, $os.DisplayVersion, $os.Build, $os.Ubr, $os.Arch, $os.EditionId) -Vi 'Phiên bản Windows'
    Write-WdlLog -En "Signed-in user: $($user.Name) ($($user.Sid), via $($user.Source))" -Vi 'Người dùng đang đăng nhập'
    Write-WdlLog -En "Rules: version $($Config.RulesVersion) ($($Config.RulesSource))" -Vi 'Bộ quy tắc'
    $prof = Get-WdlProfile -Config $Config -Os $os.Os -Build $os.Build
    Set-WdlProgress 30 'Listing installed apps... / Đang liệt kê ứng dụng...'
    $inv = Get-WdlAppInventory
    Write-WdlLog -En "Installed packages: $(@($inv.Installed).Count), provisioned: $(@($inv.Provisioned).Count)" -Vi 'Số gói ứng dụng'
    $apps = @(Get-WdlAppRows -Profile $prof -Inventory $inv)
    $tweaks = @(Get-WdlTweakRows -Profile $prof)
    foreach ($t in @($tweaks | Where-Object { -not $_.Usable })) { Write-WdlLog -Level SKIP -En "Tweak $($t.Id) not offered: $($t.SkipReason)" -Vi 'Tinh chỉnh không áp dụng cho máy đang chạy' }
    Set-WdlProgress 100 'Ready / Sẵn sàng'
    return (New-WdlObj @{ Os = $os; User = $user; Config = $Config; Profile = $prof; Inventory = $inv; AppRows = $apps; TweakRows = $tweaks })
}

function New-WdlOptions {
    <# Run options: AppScope AllUsers | CurrentUser; DefaultUser = also change the Default profile (new accounts);
       RestorePoint; EnableProtection (consent to turn System Protection on). #>
    param($Session, [string]$AppScope = 'AllUsers', [bool]$DefaultUser = $true, [bool]$RestorePoint = $true, [bool]$EnableProtection = $false)
    return @{ AppScope = $AppScope; UserSid = [string]$Session.User.Sid; UserName = [string]$Session.User.Name; DefaultUser = $DefaultUser
        RestorePoint = $RestorePoint; EnableProtection = $EnableProtection }
}

function Get-WdlResolvedPlan {
    # plan for the selection with the current values read (Default profile loaded while reading)
    param($Session, [string[]]$AppIds, [string[]]$TweakIds, $Options)
    $plan = New-WdlPlan -AppRows $Session.AppRows -TweakRows $Session.TweakRows -AppIds $AppIds -TweakIds $TweakIds -Options $Options
    $needDef = @($plan.Registry | Where-Object { $_.Scope -eq 'DefaultUser' }).Count -gt 0
    $null = Use-WdlDefaultHive -Needed:$needDef -Script { Resolve-WdlPlanState -Plan $plan }
    return $plan
}
#endregion

#region ---------- stored values (JSON-safe) ----------
function ConvertTo-WdlStoredState {
    param($State)
    if (-not $State -or -not $State.Exists) { return @{ exists = $false } }
    $d = $State.Data
    switch ([string]$State.Kind) {
        'Binary' { $d = [Convert]::ToBase64String([byte[]]$d) }
        'None' { if ($null -eq $d) { $d = '' } else { $d = [Convert]::ToBase64String([byte[]]$d) } }
        'QWord' { $d = [string][int64]$d }
        'MultiString' { $d = @([string[]]$d) }
        'DWord' { $d = [int]$d }
        default { $d = [string]$d }
    }
    return @{ exists = $true; kind = [string]$State.Kind; data = $d }
}

function ConvertFrom-WdlStoredState {
    param($Stored)
    if (-not $Stored -or -not (Get-WdlJsonVal $Stored 'exists' $false)) { return @{ Exists = $false } }
    $k = [string]$Stored['kind']; $d = $Stored['data']
    switch ($k) {
        'Binary' { $d = [Convert]::FromBase64String([string]$d) }
        'None' { $d = [Convert]::FromBase64String([string]$d) }
        'QWord' { $d = [int64]::Parse([string]$d, [Globalization.CultureInfo]::InvariantCulture) }
        'MultiString' { $d = [string[]]@(@($d) | ForEach-Object { [string]$_ }) }
        'DWord' { $d = [int]([int64]$d) }
        'String' { $d = [string]$d }
        'ExpandString' { $d = [string]$d }
        default { throw "registry value kind $k cannot be restored" }
    }
    return @{ Exists = $true; Kind = $k; Data = $d }
}

function ConvertTo-WdlStoredSnapshot {
    param($Snap)
    if (-not $Snap) { return $null }
    return @{ values = @(@($Snap.Values) | Where-Object { $_ } | ForEach-Object { $s = ConvertTo-WdlStoredState @{ Exists = $true; Kind = $_.Kind; Data = $_.Data }; $s.name = [string]$_.Name; $s })
        keys = @(@($Snap.Keys) | Where-Object { $_ } | ForEach-Object { @{ name = [string]$_.Name; snapshot = (ConvertTo-WdlStoredSnapshot $_.Snapshot) } }) }
}

function ConvertFrom-WdlStoredSnapshot {
    param($Stored)
    if (-not $Stored) { return $null }
    return @{ Values = @(@(Get-WdlJsonVal $Stored 'values' @()) | ForEach-Object { $v = ConvertFrom-WdlStoredState $_; $v.Name = [string]$_['name']; $v })
        Keys = @(@(Get-WdlJsonVal $Stored 'keys' @()) | ForEach-Object { @{ Name = [string]$_['name']; Snapshot = (ConvertFrom-WdlStoredSnapshot $_['snapshot']) } }) }
}
#endregion

#region ---------- backup files ----------
function Get-WdlBackupDir { return (Join-Path (Get-WdlDataDir) 'backups') }

function New-WdlBackup {
    param($Session, $Options)
    $b = [ordered]@{
        schema = $script:WdlBackupSchema; tool = "$($script:WDL.Name) $($script:WDL.Version)"
        created = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); computer = [string]$env:COMPUTERNAME
        os = @{ build = [int]$Session.Os.Build; ubr = [int]$Session.Os.Ubr; edition = [string]$Session.Os.EditionId }
        user = @{ sid = [string]$Options.UserSid; name = [string]$Options.UserName }
        rules = [string]$Session.Config.RulesVersion; restorePoint = @{ created = $false; sequence = 0 }; restored = ''
        changes = (New-Object Collections.ArrayList)
    }
    return $b
}

function Save-WdlBackup {
    param([Parameter(Mandatory = $true)]$Backup, [Parameter(Mandatory = $true)][string]$Path)
    Write-WdlTextFile -Path $Path -Text (ConvertTo-WdlJson $Backup)
}

function Read-WdlBackup {
    param([Parameter(Mandatory = $true)][string]$Path)
    $b = Read-WdlJsonFile $Path
    if ([string](Get-WdlJsonVal $b 'schema' '') -ne $script:WdlBackupSchema) { throw "Not a $($script:WDL.Name) backup: $Path / Không phải file sao lưu hợp lệ" }
    return , $b
}

function Get-WdlBackups {
    <# Backups, newest first: @{ Path; Created; Changes; Restored } #>
    param([string]$Dir = (Get-WdlBackupDir))
    $out = @()
    if (-not (Test-WdlPathText $Dir -Container)) { return $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter 'backup-*.json' | Sort-Object { $_.Name -replace '\.json$' } -Descending)) {
        try {
            $b = Read-WdlBackup $f.FullName
            $n = @(@(Get-WdlJsonVal $b 'changes' @()) | Where-Object { [string]$_['status'] -ne 'failed' }).Count
            $out += (New-WdlObj @{ Path = $f.FullName; Created = [string]$b['created']; Changes = $n; Restored = [string](Get-WdlJsonVal $b 'restored' '') })
        } catch { Write-WdlLog -Level WARN -En "Backup $($f.Name) unreadable: $($_.Exception.Message)" -Vi 'File sao lưu bị lỗi' }
    }
    return $out
}
#endregion

#region ---------- restore point step ----------
function Invoke-WdlRestorePointStep {
    <# Ensures System Protection (only with consent) and creates a restore point.
       Returns @{ Ok; Sequence; Error; NeedsConsent; PolicyDisabled } #>
    param([bool]$EnableProtection)
    Set-WdlProgress 2 'Creating a restore point... / Đang tạo điểm khôi phục...'
    $st = Get-WdlRestoreStatus
    $res = @{ Ok = $false; Sequence = 0; Error = ''; NeedsConsent = $false; PolicyDisabled = [bool]$st.PolicyDisabled }
    if ($st.PolicyDisabled) { $res.Error = 'System Restore is turned off by policy / System Restore bị tắt bởi chính sách'; return (New-WdlObj $res) }
    if (-not $st.Enabled) {
        if (-not $EnableProtection) { $res.NeedsConsent = $true; $res.Error = "System Protection is off on $($st.Drive) / Bảo vệ hệ thống đang tắt trên $($st.Drive)"; return (New-WdlObj $res) }
        Write-WdlLog -En "Turning on System Protection for $($st.Drive)..." -Vi "Đang bật Bảo vệ hệ thống cho $($st.Drive)..."
        $e = Enable-WdlSystemProtection -Drive $st.Drive
        if ($e) { $res.Error = "Could not turn on System Protection: $e / Không bật được Bảo vệ hệ thống"; return (New-WdlObj $res) }
        Write-WdlLog -Level OK -En 'System Protection turned on' -Vi 'Đã bật Bảo vệ hệ thống'
    }
    Write-WdlLog -Level STEP -En 'Creating a System Restore point (can take a few minutes)...' -Vi 'Đang tạo điểm khôi phục hệ thống (có thể mất vài phút)...'
    $rp = New-WdlRestorePoint -Description ("{0} {1} - before changes" -f $script:WDL.Name, $script:WDL.Version)
    $res.Ok = $rp.Ok; $res.Sequence = $rp.Sequence; $res.Error = $rp.Error
    if ($rp.Ok) { Write-WdlLog -Level OK -En "Restore point created (#$($rp.Sequence))" -Vi "Đã tạo điểm khôi phục (#$($rp.Sequence))" }
    else { Write-WdlLog -Level WARN -En "Restore point not created: $($rp.Error)" -Vi 'Không tạo được điểm khôi phục' }
    return (New-WdlObj $res)
}
#endregion

#region ---------- apply ----------
function Get-WdlMissingKey {
    # first key of $Path that does not exist yet (created by a write, removed again by undo when it stays empty)
    param([string]$Root, [string]$Path)
    $acc = ''
    foreach ($p in $Path.Split('\')) {
        if ($acc) { $acc = "$acc\$p" } else { $acc = $p }
        if (-not (Test-WdlRegKey -Root $Root -Path $acc)) { return $acc }
    }
    return $null
}

function Test-WdlSnapshotEmpty {
    param($Snapshot)
    if (-not $Snapshot) { return $true }
    if (@($Snapshot.Values | Where-Object { $_ }).Count) { return $false }
    foreach ($c in @($Snapshot.Keys)) { if ($c -and -not (Test-WdlSnapshotEmpty $c.Snapshot)) { return $false } }
    return $true
}

function Add-WdlChange {
    # records a change as 'pending' in the backup file BEFORE it is made, so a crash still leaves an undo record
    param($Backup, [string]$Path, [hashtable]$Change)
    $Change.status = 'pending'
    [void]$Backup.changes.Add($Change)
    Save-WdlBackup -Backup $Backup -Path $Path
    return $Change
}

function Complete-WdlChange {
    param($Backup, [string]$Path, [hashtable]$Change, [string]$ErrorText)
    if ($ErrorText) { $Change.status = 'failed'; $Change.error = $ErrorText } else { $Change.status = 'done' }
    Save-WdlBackup -Backup $Backup -Path $Path
}

function Invoke-WdlApply {
    <# Applies a resolved plan. Every change is backed up first; a failing item is logged and skipped, the run
       goes on. Cancel stops after the current item. Returns @{ BackupPath; Done; Failed; Unchanged; Skipped; Reboot; Cancelled } #>
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)]$Plan, $RestorePoint, [string]$BackupDir = (Get-WdlBackupDir))
    $opt = $Plan.Options
    $bk = New-WdlBackup -Session $Session -Options $opt
    if ($RestorePoint -and $RestorePoint.Ok) { $bk.restorePoint = @{ created = $true; sequence = [int]$RestorePoint.Sequence } }
    New-WdlDirectory $BackupDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $BackupDir "backup-$stamp.json"
    for ($n = 2; Test-Path -LiteralPath $path; $n++) { $path = Join-Path $BackupDir "backup-$stamp-$n.json" }
    Save-WdlBackup -Backup $bk -Path $path
    Write-WdlLog -En "Backup file: $path" -Vi 'File sao lưu'
    $sum = @{ BackupPath = $path; Done = 0; Failed = 0; Unchanged = 0; Skipped = @($Plan.Skipped).Count; Reboot = $false; Cancelled = $false }
    $total = [Math]::Max(1, (Get-WdlPlanCounts $Plan).Total)
    $step = { param($t) $script:WdlStepN++; Set-WdlProgress (5 + 90 * $script:WdlStepN / $total) $t }
    $script:WdlStepN = 0
    foreach ($s in @($Plan.Skipped)) { Write-WdlLog -Level SKIP -En "Skipped $($s.What): $($s.Reason)" -Vi 'Bỏ qua' }

    try {
        # ---- registry (Default profile loaded only while needed) ----
        $reg = @($Plan.Registry)
        $needDef = @($reg | Where-Object { $_.Scope -eq 'DefaultUser' -and -not $_.NoChange }).Count -gt 0
        if ($reg.Count) { Write-WdlLog -Level STEP -En 'Registry settings...' -Vi 'Thiết lập registry...' }
        Use-WdlDefaultHive -Needed:$needDef -Script {
            foreach ($it in $reg) {
                Assert-WdlNotCancelled
                if ($it.NoChange) { $sum.Unchanged++; continue }
                & $step "Registry: $($it.Label)"
                $ch = @{ type = 'registry'; op = $it.Kind; root = $it.Root; path = $it.Path; name = [string]$it.Name; scope = $it.Scope; label = $it.Label; tweak = $it.TweakId }
                $err = $null
                try {
                    if ($it.Kind -eq 'RegDeleteKey') { $ch.snapshot = ConvertTo-WdlStoredSnapshot (Get-WdlRegKeySnapshot -Root $it.Root -Path $it.Path) }
                    else {
                        $ch.before = ConvertTo-WdlStoredState (Get-WdlRegValue -Root $it.Root -Path $it.Path -Name $it.Name)
                        if ($it.Kind -eq 'RegSet') { $ck = Get-WdlMissingKey -Root $it.Root -Path $it.Path; if ($ck) { $ch.createdKey = $ck } }
                    }
                    $ch = Add-WdlChange $bk $path $ch
                    switch ($it.Kind) {
                        'RegSet' { Set-WdlRegValue -Root $it.Root -Path $it.Path -Name $it.Name -Kind $it.ValueKind -Data $it.Data }
                        'RegDeleteValue' { Remove-WdlRegValue -Root $it.Root -Path $it.Path -Name $it.Name }
                        'RegDeleteKey' { Remove-WdlRegKey -Root $it.Root -Path $it.Path }
                    }
                } catch { $err = $_.Exception.Message }
                if ($ch.status) { Complete-WdlChange $bk $path $ch $err }
                if ($err) { $sum.Failed++; Write-WdlLog -Level WARN -En "  FAILED $($it.Label)\$($it.Name): $err" -Vi '  Không ghi được' }
                else { $sum.Done++; Write-WdlLog -En ("  {0} {1}\{2}" -f $it.Kind, $it.Label, $it.Name) }
            }
        }

        # ---- services / tasks / features / special ----
        foreach ($s in @($Plan.Services)) {
            Assert-WdlNotCancelled
            if ($s.NoChange) { $sum.Unchanged++; continue }
            & $step "Service: $($s.Name)"
            $ch = Add-WdlChange $bk $path @{ type = 'service'; name = $s.Name; before = [string]$s.Before.StartType; after = $s.StartType; tweak = $s.TweakId }
            $err = Set-WdlServiceStart -Name $s.Name -StartType $s.StartType
            Complete-WdlChange $bk $path $ch $err
            if ($err) { $sum.Failed++; Write-WdlLog -Level WARN -En "  FAILED service $($s.Name): $err" -Vi '  Không đổi được dịch vụ' } else { $sum.Done++; Write-WdlLog -En "  service $($s.Name): $($s.Before.StartType) -> $($s.StartType)" }
        }
        foreach ($s in @($Plan.Tasks)) {
            Assert-WdlNotCancelled
            if ($s.NoChange) { $sum.Unchanged++; continue }
            & $step "Task: $($s.Name)"
            $ch = Add-WdlChange $bk $path @{ type = 'task'; path = $s.Path; name = $s.Name; beforeEnabled = $true; tweak = $s.TweakId }
            $err = Set-WdlTaskEnabled -Path $s.Path -Name $s.Name -Enabled $false
            Complete-WdlChange $bk $path $ch $err
            if ($err) { $sum.Failed++; Write-WdlLog -Level WARN -En "  FAILED task $($s.Path)$($s.Name): $err" -Vi '  Không tắt được tác vụ' } else { $sum.Done++; Write-WdlLog -En "  task disabled: $($s.Path)$($s.Name)" }
        }
        foreach ($s in @($Plan.Features)) {
            Assert-WdlNotCancelled
            if ($s.NoChange) { $sum.Unchanged++; continue }
            & $step "Feature: $($s.Name)"
            $ch = Add-WdlChange $bk $path @{ type = 'feature'; name = $s.Name; before = 'Enabled'; tweak = $s.TweakId }
            $r = Set-WdlFeatureState -Name $s.Name -State 'Disabled'
            Complete-WdlChange $bk $path $ch $r.Error
            if ($r.Reboot) { $sum.Reboot = $true }
            if ($r.Error) { $sum.Failed++; Write-WdlLog -Level WARN -En "  FAILED feature $($s.Name): $($r.Error)" -Vi '  Không tắt được tính năng' } else { $sum.Done++; Write-WdlLog -En "  feature disabled: $($s.Name)" }
        }
        foreach ($s in @($Plan.Special)) {
            Assert-WdlNotCancelled
            if ($s.NoChange) { $sum.Unchanged++; continue }
            & $step $s.Kind
            $ch = Add-WdlChange $bk $path @{ type = 'special'; kind = $s.Kind; before = [string]$s.Before; tweak = $s.TweakId }
            $err = $null
            if ($s.Kind -eq 'ReservedStorage') { $err = Set-WdlReservedStorageState -State 'Disabled' }
            Complete-WdlChange $bk $path $ch $err
            if ($err) { $sum.Failed++; Write-WdlLog -Level WARN -En "  FAILED $($s.Kind): $err" -Vi '  Thất bại' } else { $sum.Done++; Write-WdlLog -En "  $($s.Kind): $($s.Before) -> Disabled" }
        }

        # ---- apps (last: slowest, and registry policies are already in place to stop reinstalls) ----
        if (@($Plan.Apps).Count) { Write-WdlLog -Level STEP -En 'Removing apps...' -Vi 'Đang gỡ ứng dụng...' }
        foreach ($a in @($Plan.Apps)) {
            Assert-WdlNotCancelled
            & $step "App: $($a.Id)"
            $any = $false; $bad = $false
            foreach ($fn in @($a.Packages)) {
                $loc = ''
                foreach ($p in @($Session.Inventory.Installed)) { if ($p.PackageFullName -eq $fn) { $loc = [string]$p.InstallLocation } }
                $ch = Add-WdlChange $bk $path @{ type = 'app'; id = $a.Id; package = $fn; scope = $a.Scope; userSid = [string]$opt.UserSid; installLocation = $loc }
                $err = Remove-WdlAppPackage -FullName $fn -Scope $a.Scope -UserSid $opt.UserSid
                Complete-WdlChange $bk $path $ch $err
                if ($err) { $bad = $true; Write-WdlLog -Level WARN -En "  FAILED to remove $fn : $err" -Vi '  Gỡ thất bại' } else { $any = $true; Write-WdlLog -En "  removed $fn" -Vi "  đã gỡ $fn" }
            }
            foreach ($pn in @($a.Provisioned)) {
                $ch = Add-WdlChange $bk $path @{ type = 'provisioned'; id = $a.Id; package = $pn }
                $err = Remove-WdlProvisionedPackage -PackageName $pn
                Complete-WdlChange $bk $path $ch $err
                if ($err) { $bad = $true; Write-WdlLog -Level WARN -En "  FAILED to deprovision $pn : $err" -Vi '  Gỡ gói cài sẵn thất bại' } else { $any = $true; Write-WdlLog -En "  deprovisioned $pn (new users)" -Vi "  đã gỡ gói cài sẵn $pn" }
            }
            if ($bad) { $sum.Failed++ } elseif ($any) { $sum.Done++ }
        }
    } catch [OperationCanceledException] {
        # stop after the current item; the summary and the backup still describe what was changed
        $sum.Cancelled = $true
        Write-WdlLog -Level WARN -En 'Cancelled: the remaining items were not changed' -Vi 'Đã huỷ: các mục còn lại chưa được thay đổi'
    }
    if ($sum.Done -gt 0) { $sum.Reboot = $true }
    Set-WdlProgress 100 'Done / Xong'
    $lvl = 'OK'; if ($sum.Failed) { $lvl = 'WARN' }
    Write-WdlLog -Level $lvl -En ("Finished: {0} changed, {1} failed, {2} already in place, {3} skipped" -f $sum.Done, $sum.Failed, $sum.Unchanged, $sum.Skipped) -Vi ("Hoàn tất: {0} thay đổi, {1} lỗi, {2} đã đúng sẵn, {3} bỏ qua" -f $sum.Done, $sum.Failed, $sum.Unchanged, $sum.Skipped)
    return (New-WdlObj $sum)
}
#endregion

#region ---------- undo ----------
function Get-WdlRestoreExemptions {
    <# hive|key|name (lower case) of the delete operations in the bundled tweaks.json: undo may write these back
       even where the registry safety policy forbids writes (e.g. the OneDriveSetup Run value). #>
    param([string]$TweaksPath = (Join-Path (Join-Path $script:WdlRoot 'data') 'tweaks.json'))
    $set = @{}
    try {
        foreach ($t in @(Get-WdlJsonVal (Read-WdlJsonFile $TweaksPath) 'tweaks' @())) {
            foreach ($op in @(Get-WdlJsonVal $t 'deleteValue' @())) { $set[('{0}|{1}|{2}' -f $op['hive'], $op['key'], $op['name']).ToLowerInvariant()] = 1 }
            foreach ($op in @(Get-WdlJsonVal $t 'deleteKey' @())) { $set[('{0}|{1}|*' -f $op['hive'], $op['key']).ToLowerInvariant()] = 1 }
        }
    } catch { $null = $_ }
    return $set
}

function Split-WdlRegTarget {
    <# Live root/path -> @{ Hive (rule hive name); Key (hive-relative) } or $null for locations undo never writes. #>
    param([string]$Root, [string]$Path)
    if ($Path -match '(^|\\)\.\.?(\\|$)' -or $Path -match '[\x00-\x1F"]') { return $null }
    if ($Root -eq 'HKLM') {
        if ($Path -match '^SOFTWARE\\(.+)$') { return @{ Hive = 'SOFTWARE'; Key = $matches[1] } }
        if ($Path -match '^SYSTEM\\(.+)$') { return @{ Hive = 'SYSTEM'; Key = $matches[1] } }
        return $null
    }
    if ($Root -eq 'HKU') {
        if ($Path -match '^\.DEFAULT\\(.+)$') { return @{ Hive = 'DEFAULT'; Key = $matches[1] } }
        if ($Path -match ('^(S-1-5-21-[\d-]+|S-1-12-1-[\d-]+|' + [regex]::Escape($script:WdlDefaultHiveName) + ')\\(.+)$')) { return @{ Hive = 'NTUSER'; Key = $matches[2] } }
    }
    return $null
}

function Test-WdlRestoreAllowed {
    <# Undo writes a value back only to locations the tool itself changes. Autostart / execution locations are
       allowed only for values that a bundled rule deletes. #>
    param([string]$Root, [string]$Path, [string]$Name, [hashtable]$Exemptions)
    $t = Split-WdlRegTarget -Root $Root -Path $Path
    if (-not $t) { return $false }
    if (-not (Test-WdlRegLocationDenied -Key $t.Key -Name $Name)) { return $true }
    if ($Exemptions.ContainsKey(('{0}|{1}|{2}' -f $t.Hive, $t.Key, $Name).ToLowerInvariant())) { return $true }
    foreach ($k in @($Exemptions.Keys)) {
        $p = $k.Split('|')
        if ($p[2] -eq '*' -and $p[0] -eq $t.Hive.ToLowerInvariant() -and (Test-WdlPathInside $t.Key.ToLowerInvariant() $p[1])) { return $true }
    }
    return $false
}

function Test-WdlSnapshotAllowed {
    param([string]$Root, [string]$Path, $Snapshot, [hashtable]$Exemptions)
    foreach ($v in @($Snapshot.Values)) { if ($v -and -not (Test-WdlRestoreAllowed $Root $Path $v.Name $Exemptions)) { return $false } }
    if (-not (Test-WdlRestoreAllowed $Root $Path '' $Exemptions)) { return $false }
    foreach ($c in @($Snapshot.Keys)) { if ($c -and -not (Test-WdlSnapshotAllowed $Root "$Path\$($c.Name)" $c.Snapshot $Exemptions)) { return $false } }
    return $true
}

function Invoke-WdlUndo {
    <# Reverts the changes of one backup in reverse order. Registry values and service start types come back
       exactly; removed apps are registered again when their files are still on the PC, else listed for a
       Microsoft Store reinstall. Cancel stops after the current item. Returns @{ Restored; Failed; Manual (texts); Cancelled } #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $bk = Read-WdlBackup $Path
    $ex = Get-WdlRestoreExemptions
    $changes = @(Get-WdlJsonVal $bk 'changes' @())
    [array]::Reverse($changes)
    $todo = @($changes | Where-Object { @('done', 'pending') -contains [string]$_['status'] -and [string]$_['undo'] -ne 'done' })
    $sum = @{ Restored = 0; Failed = 0; Manual = @(); Cancelled = $false }
    Write-WdlLog -Level STEP -En "Undo from $Path ($($todo.Count) change(s))" -Vi "Hoàn tác từ $Path ($($todo.Count) thay đổi)"
    $needDef = @($todo | Where-Object { [string]$_['scope'] -eq 'DefaultUser' }).Count -gt 0
    $i = 0
    Use-WdlDefaultHive -Needed:$needDef -Script {
        foreach ($c in $todo) {
            if ($script:WDL.Sync -and $script:WDL.Sync.Cancel) { $sum.Cancelled = $true; break }
            $i++; Set-WdlProgress (100 * $i / [Math]::Max(1, $todo.Count)) 'Undo... / Đang hoàn tác...'
            $err = $null; $what = ''; $manual = $null
            try {
                switch ([string]$c['type']) {
                    'registry' {
                        $root = [string]$c['root']; $p = [string]$c['path']; $n = [string]$c['name']
                        $what = "$($c['label'])\$n"
                        # a signed-out user's hive is not loaded: writing would silently do nothing
                        if ($root -eq 'HKU' -and -not (Test-WdlRegKey -Root 'HKU' -Path ($p -split '\\')[0])) { throw "user profile $(($p -split '\\')[0]) is not loaded (sign in as that user first) / Hồ sơ người dùng chưa được nạp (hãy đăng nhập tài khoản đó trước)" }
                        if ([string]$c['op'] -eq 'RegDeleteKey') {
                            $snap = ConvertFrom-WdlStoredSnapshot (Get-WdlJsonVal $c 'snapshot')
                            if (-not $snap) { break }
                            if (-not (Test-WdlSnapshotAllowed $root $p $snap $ex)) { throw 'location not allowed for undo' }
                            Restore-WdlRegKeySnapshot -Root $root -Path $p -Snapshot $snap
                        } else {
                            $before = ConvertFrom-WdlStoredState (Get-WdlJsonVal $c 'before')
                            if ($before.Exists) {
                                if (-not (Test-WdlRestoreAllowed $root $p $n $ex)) { throw 'location not allowed for undo' }
                                Set-WdlRegValue -Root $root -Path $p -Name $n -Kind $before.Kind -Data $before.Data
                            } else {
                                if (-not (Split-WdlRegTarget -Root $root -Path $p)) { throw 'location not allowed for undo' }
                                Remove-WdlRegValue -Root $root -Path $p -Name $n
                            }
                        }
                    }
                    'service' {
                        $what = "service $($c['name'])"
                        if ([string]$c['name'] -notmatch '^[A-Za-z0-9_.-]{1,80}$') { throw 'invalid service name' }
                        $err = Set-WdlServiceStart -Name ([string]$c['name']) -StartType ([string]$c['before'])
                    }
                    'task' { $what = "task $($c['path'])$($c['name'])"; $err = Set-WdlTaskEnabled -Path ([string]$c['path']) -Name ([string]$c['name']) -Enabled $true }
                    'feature' { $what = "feature $($c['name'])"; $r = Set-WdlFeatureState -Name ([string]$c['name']) -State 'Enabled'; $err = $r.Error }
                    'special' { $what = [string]$c['kind']; if ([string]$c['kind'] -eq 'ReservedStorage' -and [string]$c['before'] -eq 'Enabled') { $err = Set-WdlReservedStorageState -State 'Enabled' } }
                    'app' {
                        $what = "app $($c['package'])"
                        $err = Register-WdlAppPackage -InstallLocation ([string]$c['installLocation'])
                        if ($err) { $manual = ("{0}: {1}" -f $c['id'], $err); $err = $null }
                    }
                    'provisioned' { $manual = ("{0}: removed for new users; reinstall from Microsoft Store if needed" -f $c['id']) }
                }
            } catch { $err = $_.Exception.Message }
            if ($manual) { $sum.Manual += $manual; $c['undo'] = 'manual'; continue }
            if ($err) { $sum.Failed++; $c['undo'] = 'failed'; Write-WdlLog -Level WARN -En "  FAILED to restore $what : $err" -Vi "  Không hoàn tác được $what : $err" }
            else { $sum.Restored++; $c['undo'] = 'done'; Write-WdlLog -En "  restored $what" -Vi "  đã hoàn tác $what" }
        }
    }
    # keys the run created and that are empty again
    $created = @($todo | Where-Object { [string]$_['undo'] -eq 'done' -and [string](Get-WdlJsonVal $_ 'createdKey' '') } | ForEach-Object { @{ Root = [string]$_['root']; Path = [string]$_['createdKey']; Scope = [string]$_['scope'] } })
    if ($created.Count) {
        Use-WdlDefaultHive -Needed:(@($created | Where-Object { $_.Scope -eq 'DefaultUser' }).Count -gt 0) -Script {
            foreach ($k in $created) {
                try {
                    if (-not (Split-WdlRegTarget -Root $k.Root -Path $k.Path) -or -not (Test-WdlRegKey -Root $k.Root -Path $k.Path)) { continue }
                    if (Test-WdlSnapshotEmpty (Get-WdlRegKeySnapshot -Root $k.Root -Path $k.Path)) { Remove-WdlRegKey -Root $k.Root -Path $k.Path }
                } catch { Write-WdlLog -Level WARN -En "  could not remove the empty key $($k.Root)\$($k.Path): $($_.Exception.Message)" }
            }
        }
    }
    foreach ($m in @($sum.Manual | Select-Object -Unique)) { Write-WdlLog -Level WARN -En "  manual: $m" -Vi '  cần làm thủ công (cài lại từ Microsoft Store)' }
    if ($sum.Cancelled) { Write-WdlLog -Level WARN -En 'Undo cancelled: the remaining items were not restored' -Vi 'Đã huỷ hoàn tác: các mục còn lại chưa được khôi phục' }
    elseif ($sum.Failed -eq 0) { $bk['restored'] = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
    Save-WdlBackup -Backup $bk -Path $Path
    Set-WdlProgress 100 'Done / Xong'
    Write-WdlLog -Level OK -En "Undo finished: $($sum.Restored) restored, $($sum.Failed) failed, $(@($sum.Manual).Count) need a manual reinstall" -Vi "Hoàn tác xong: $($sum.Restored) đã khôi phục, $($sum.Failed) lỗi, $(@($sum.Manual).Count) cần cài lại thủ công"
    return (New-WdlObj $sum)
}
#endregion
