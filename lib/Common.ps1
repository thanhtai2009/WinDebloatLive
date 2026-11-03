<#
    WinDebloat Live - shared helpers: state, logging, progress, JSON, paths, timed calls.
    Windows PowerShell 5.1 (Windows 10 1809+ / Windows 11). Static parts also load in PowerShell 7 for tests.
    SPDX-License-Identifier: MIT
#>

# When dot-sourced from a file the tool folder is known; when injected as text into a background runspace
# (GUI), the caller sets $script:WdlRoot afterwards.
if ($MyInvocation.MyCommand.Path) {
    $script:WdlRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$script:WDL = @{
    Name         = 'WinDebloat Live'
    Version      = '1.0.0'
    # Rule data is shared with WinDebloat Tool; its manifest "minToolVersion" refers to that tool's versions.
    # This is the WinDebloat Tool version whose rule schema this engine understands.
    RulesCompat  = '1.2.1'
    LogPath      = $null
    Sync         = $null
    MinBuild     = 17763    # Windows 10 1809
    DataDirName  = 'WinDebloatLive'
}

function New-WdlObj { param([hashtable]$Property) return New-Object PSObject -Property $Property }

#region ---------- logging / progress ----------
function Write-WdlLog {
    <# One log line (file + GUI queue or console). -Vi is the Vietnamese text; the GUI shows it when the UI
       language is Vietnamese, the file keeps both. #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$En,
        [string]$Vi,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'SKIP', 'PLAN')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($Vi) { $text = "$En | $Vi" } else { $text = $En }
    $line = "[$ts] [$Level] $text"
    if ($script:WDL.LogPath) {
        try { [IO.File]::AppendAllText($script:WDL.LogPath, $line + "`r`n", (New-Object Text.UTF8Encoding $true)) } catch { $null = $_ }
    }
    $s = $script:WDL.Sync
    if ($s) {
        $show = $En
        if ($Vi -and $s.UiLang -eq 'vi') { $show = $Vi }
        $s.LogQueue.Enqueue("[$ts] [$Level] $show")
    } else {
        $color = 'Gray'
        switch ($Level) { 'WARN' { $color = 'Yellow' } 'ERROR' { $color = 'Red' } 'OK' { $color = 'Green' } 'STEP' { $color = 'Cyan' } 'PLAN' { $color = 'Magenta' } 'SKIP' { $color = 'DarkGray' } }
        Write-Host $line -ForegroundColor $color
    }
}

function Set-WdlProgress {
    param([double]$Percent, [string]$Status)
    $s = $script:WDL.Sync
    if ($Percent -gt 100) { $Percent = 100 }
    if ($s) {
        if ($Percent -ge 0) { $s.Percent = $Percent }
        if ($Status) { $s.Status = $Status }
    } elseif ($Status -and $Percent -ge 0) {
        Write-Progress -Activity $script:WDL.Name -Status $Status -PercentComplete ([int]$Percent)
    }
}

function Assert-WdlNotCancelled {
    $s = $script:WDL.Sync
    if ($s -and $s.Cancel) { throw (New-Object System.OperationCanceledException 'Cancelled by user / Người dùng đã huỷ') }
}

function Get-WdlLocalText {
    # 'English / Tiếng Việt' engine text -> the part for the UI language (Vietnamese only for 'vi')
    param([string]$Text, [string]$Lang)
    if (-not $Text) { return $Text }
    $i = $Text.IndexOf(' / ')
    if ($i -lt 0) { return $Text }
    # only split texts whose second half looks Vietnamese (paths can contain ' / ' too)
    $vi = $Text.Substring($i + 3)
    if ($vi -notmatch '[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]') { return $Text }
    if ($Lang -eq 'vi') { return $vi }
    return $Text.Substring(0, $i)
}
#endregion

#region ---------- generic helpers ----------
function Test-WdlLike {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in @($Patterns)) { if ($p -and $Name -like $p) { return $true } }
    return $false
}

function Test-WdlPathText {
    <# Safe path check: $false (never an exception) for empty, invalid or missing paths. #>
    param([string]$Path, [switch]$Leaf, [switch]$Container)
    if (-not $Path -or -not $Path.Trim()) { return $false }
    if ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { return $false }
    try {
        if ($Leaf) { return (Test-Path -LiteralPath $Path -PathType Leaf) }
        if ($Container) { return (Test-Path -LiteralPath $Path -PathType Container) }
        return (Test-Path -LiteralPath $Path)
    } catch { return $false }
}

function Test-WdlPathInside {
    # $true when $Path is $Parent itself or below it (case-insensitive, '\' and '/' are the same)
    param([string]$Path, [string]$Parent)
    if (-not $Path -or -not $Parent) { return $false }
    $a = ($Path -replace '/', '\').TrimEnd('\') + '\'
    $b = ($Parent -replace '/', '\').TrimEnd('\') + '\'
    return $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)
}

function New-WdlDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    $null = [IO.Directory]::CreateDirectory($Path)
}

function ConvertTo-WdlVersion([string]$Text) {
    # 'a.b[.c[.d]]' -> [version], else $null
    if (-not $Text -or $Text -notmatch '^\d{1,9}(\.\d{1,9}){1,3}$') { return $null }
    try { return (New-Object Version $Text) } catch { return $null }
}

function Enable-WdlTls12 {
    # adds TLS 1.2 (3072) to the allowed protocols; $false when .NET cannot do it
    try {
        $cur = [int][Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], ($cur -bor 3072))
        return (([int][Net.ServicePointManager]::SecurityProtocol -band 3072) -eq 3072)
    } catch { return $false }
}

function Write-WdlTextFile {
    <# Writes UTF-8 (no BOM) text atomically: temp file next to the target, then replace. #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) {
        try { [IO.File]::Replace($tmp, $Path, $null) } catch { [IO.File]::Copy($tmp, $Path, $true); [IO.File]::Delete($tmp) }
    } else { [IO.File]::Move($tmp, $Path) }
}

function Invoke-WdlTimed {
    <# Runs $Script with $ArgumentList in a separate runspace and waits at most $TimeoutSec.
       Returns @{ Completed; TimedOut; Output; Error }. A timed-out call is stopped and abandoned, so one hung
       system call (Appx, CIM, DISM) cannot freeze the whole run. #>
    param([Parameter(Mandatory = $true)][scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$TimeoutSec = 120)
    $res = @{ Completed = $false; TimedOut = $false; Output = @(); Error = $null }
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
        $h = $ps.BeginInvoke()
        if (-not $h.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
            $res.TimedOut = $true
            try { [void]$ps.BeginStop($null, $null) } catch { $null = $_ }
            return (New-WdlObj $res)
        }
        try { $res.Output = @($ps.EndInvoke($h)) } catch { $res.Error = $_.Exception.InnerException; if (-not $res.Error) { $res.Error = $_.Exception } }
        if (-not $res.Error -and $ps.Streams.Error.Count -gt 0) { $res.Error = $ps.Streams.Error[0].Exception }
        $res.Completed = $true
    } finally {
        if (-not $res.TimedOut) { $ps.Dispose() }
    }
    return (New-WdlObj $res)
}

function Invoke-WdlProcess {
    <# Starts an executable without a shell and returns its exit code (output is never parsed: it is localized).
       -1 = timed out (process killed). #>
    param([Parameter(Mandatory = $true)][string]$FilePath, [string]$Arguments = '', [int]$TimeoutSec = 300)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    # drain the pipes asynchronously so a chatty tool cannot block on a full buffer
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { $null = $_ }
        return -1
    }
    $null = $o; $null = $e
    return $p.ExitCode
}

function Get-WdlSystemExe([string]$Name) {
    # 64-bit System32 tool (the tool always runs in 64-bit PowerShell, see WinDebloatLive.ps1)
    $win = $env:SystemRoot; if (-not $win) { $win = 'C:\Windows' }
    return (Join-Path (Join-Path $win 'System32') $Name)
}
#endregion

#region ---------- JSON ----------
function ConvertTo-WdlPlain {
    # ConvertFrom-Json output (PSCustomObject / arrays) -> OrderedDictionary / object[] (recursive)
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $d = New-Object Collections.Specialized.OrderedDictionary
        foreach ($k in @($Value.Keys)) { $d[[string]$k] = ConvertTo-WdlPlain $Value[$k] }
        return , $d
    }
    if ($Value -is [Collections.IEnumerable]) {
        $list = New-Object Collections.ArrayList
        foreach ($x in $Value) { [void]$list.Add((ConvertTo-WdlPlain $x)) }
        return , ($list.ToArray())
    }
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $d = New-Object Collections.Specialized.OrderedDictionary
        foreach ($p in $Value.PSObject.Properties) { $d[[string]$p.Name] = ConvertTo-WdlPlain $p.Value }
        return , $d
    }
    return $Value
}

function ConvertFrom-WdlJson {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    if (-not $Text.Trim()) { throw 'empty JSON' }
    $o = $Text | ConvertFrom-Json
    return , (ConvertTo-WdlPlain $o)
}

function Read-WdlJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try { return , (ConvertFrom-WdlJson $text) }
    catch { throw "Invalid JSON in $Path ($($_.Exception.Message)) / File JSON bị lỗi: $Path" }
}

function ConvertTo-WdlJson {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 20)
}

function Get-WdlJsonVal {
    # safe lookup in a parsed JSON object (missing key -> $Default)
    param($Object, [string]$Key, $Default = $null)
    if ($null -ne $Object -and $Object -is [Collections.IDictionary] -and $Object.Contains($Key) -and $null -ne $Object[$Key]) { return $Object[$Key] }
    return $Default
}

function Get-WdlLangText {
    # text table { vi, en, zh-CN, km } -> text in $Lang, else English, else the first non-empty one
    param($Table, [string]$Lang = 'en')
    if ($null -eq $Table) { return '' }
    if ($Table -is [string]) { return $Table }
    if ($Table -is [Collections.IDictionary]) {
        if ($Lang -and $Table.Contains($Lang) -and $Table[$Lang]) { return [string]$Table[$Lang] }
        if ($Table.Contains('en') -and $Table['en']) { return [string]$Table['en'] }
        foreach ($k in @($Table.Keys)) { if ($Table[$k]) { return [string]$Table[$k] } }
    }
    return ''
}
#endregion
