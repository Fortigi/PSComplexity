<#
.SYNOPSIS
    Prove this module loads and computes the same answers on every supported PowerShell.

.DESCRIPTION
    The manifest declares a PowerShellVersion floor and CI runs whatever the runners ship, which is
    several minors newer. So the number consumers are told has never been executed, and a floor
    nothing runs on is a claim rather than a guarantee -- the same defect the Pester gate beside
    this one exists to close, from the other side.

    Deliberately NO Pester. The two compatibility questions are different: the Pester gate asks
    whether a consumer can gate on this module from inside Pester N, and this one asks whether the
    module loads and computes correctly on PowerShell N. Crossing them would multiply the legs, and
    worse, would confound this one -- Pester 6.1.0 does not load on PowerShell 7.0 at all, so a
    fixture driven through Pester would fail the floor for a reason that is not about this module.
    Nothing in src/ calls a Pester API, so the assertions can be direct.

    Each leg runs in a SEPARATE PROCESS, because that is what a different PowerShell is. The script
    re-invokes ITSELF with -Child under the downloaded host rather than passing a here-string, so
    every line each leg runs is parsed, linted and diffable. A child contract written as a string is
    code no gate can read.

.PARAMETER Version
    The PowerShell versions to prove. Empty means read PS_COMPAT_VERSIONS from the environment or
    .github/pins.env, so running this by hand and running it in CI are the same run.

.PARAMETER RuntimeRoot
    Where downloaded runtimes are kept. Defaults to a stable directory under TEMP, so a second run
    on the same machine downloads nothing.

.EXAMPLE
    ./tools/Test-PSCxPowerShellCompatibility.ps1
#>
[CmdletBinding()]
[OutputType([void])]
param(
    [string[]]$Version,
    [switch]$Child,
    [string]$FixtureRoot,
    [string]$RuntimeRoot,
    [string]$Expected
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseDecisions.ps1')

function Get-PSCxFixtureRow {
    # Every measured row of a corpus, as one canonical string.
    #
    # The comparison this gate makes is EQUIVALENCE ACROSS HOSTS, not agreement with numbers written
    # here. Hardcoding expected scores would pin the metric a second time -- tests/Cognitive.Tests.ps1
    # already does that against the published reference examples -- and would have to be edited
    # whenever the metric legitimately changes, which is exactly when a compatibility gate should
    # keep working.
    #
    # Sorted, because a difference in ENUMERATION order between hosts is not a difference in the
    # answer; the ordering contract is the suite's job.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(Measure-PSComplexity -Path $Path -Recurse |
            Sort-Object File, Unit |
            ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.File, $_.Unit, $_.Cyclomatic, $_.Cognitive })
    return ($rows -join "`n")
}

function Build-PSCxRuntimeFixture {
    # A corpus with something to count in it, written rather than pointed at src/.
    #
    # src/ would work and is tempting, but it changes with every commit, so a leg that failed would
    # not say whether the host or the source moved. This is fixed, small, and holds one unit
    # comfortably inside any ceiling and one well over it -- BOTH, because a fixture that only
    # passes cannot tell a working gate from one that returns $true unconditionally.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Root)
    $src = Join-Path $Root 'src'
    New-Item -ItemType Directory -Path $src -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $src 'Simple.ps1') -Encoding utf8 -Value @'
function Get-Simple {
    param($x)
    if ($x) { return 1 }
    return 2
}
'@

    $deep = @('function Get-Deep {', '    param($a)')
    foreach ($i in 1..12) { $deep += "    if (`$a -eq $i) { foreach (`$n in 1..$i) { if (`$n -gt 2) { return `$n } } }" }
    $deep += '}'
    Set-Content -LiteralPath (Join-Path $src 'Deep.ps1') -Value ($deep -join [Environment]::NewLine) -Encoding utf8

    return $src
}

function Get-PSCxRuntimeArchive {
    # The official release archive for this platform, as a URL and a file name.
    #
    # x64 only, and that is a stated limit rather than an oversight: the question here is whether a
    # PowerShell VERSION runs this module, and the architecture the gate happens to run on does not
    # change the answer for a module that is pure PowerShell.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$PSVersion)
    if ($IsWindows) { $name = "PowerShell-$PSVersion-win-x64.zip" }
    elseif ($IsMacOS) { $name = "powershell-$PSVersion-osx-x64.tar.gz" }
    else { $name = "powershell-$PSVersion-linux-x64.tar.gz" }
    return @{
        Name = $name
        Uri  = "https://github.com/PowerShell/PowerShell/releases/download/v$PSVersion/$name"
    }
}

function Install-PSCxRuntime {
    # Fetch and unpack one PowerShell, unless it is already unpacked. Returns the pwsh path.
    #
    # The MARKER file is written last and is what "already unpacked" means. An interrupted download
    # or a half-extracted archive otherwise looks identical to a finished one, and the leg then
    # fails against a runtime that was never whole -- an environment fault reported as a module
    # fault, which is the confusion this gate family exists to prevent.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$PSVersion,
        [Parameter(Mandatory)] [string]$Root
    )
    $dir = Join-Path $Root $PSVersion
    $exe = Join-Path $dir $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $marker = Join-Path $dir '.pscx-complete'
    if (Test-Path -LiteralPath $marker) { return $exe }

    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $archive = Get-PSCxRuntimeArchive -PSVersion $PSVersion
    $file = Join-Path $Root $archive.Name
    # No progress written HERE. This function returns the pwsh path, and PSAvoidUsingWriteHost is
    # not excluded in this repo, so anything written to the output stream inside it joins the return
    # value -- the caller then tries to execute "message + path" and fails naming a command that is
    # a whole sentence. Progress belongs to the caller, whose output nobody captures.
    Invoke-WebRequest -Uri $archive.Uri -OutFile $file -UseBasicParsing

    if ($archive.Name.EndsWith('.zip')) {
        # Expand-Archive, not an external unzip: some unzip builds write the nested lib/ paths as
        # literal names containing backslashes, and the host then starts but cannot resolve an
        # assembly -- a failure that names a NuGet package and nothing about PowerShell.
        Expand-Archive -LiteralPath $file -DestinationPath $dir -Force
    }
    else {
        tar -xzf $file -C $dir
        if ($LASTEXITCODE -ne 0) { throw "tar failed to unpack $($archive.Name) (exit $LASTEXITCODE)." }
        chmod +x $exe
    }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $exe)) { throw "PowerShell $PSVersion unpacked without a pwsh at $exe." }
    Set-Content -LiteralPath $marker -Value $PSVersion -Encoding utf8
    return $exe
}

if ($Child) {
    # One host, one leg. Everything here runs under the DOWNLOADED PowerShell, so it must not use
    # anything newer than the oldest version in the list -- which is the point of the exercise.
    #
    # This line is FIRST and is load-bearing: it is how the caller tells a host that never started
    # from a module that misbehaved. PowerShell 7.0 and 7.1 are built on .NET Core 3.1 and .NET 5
    # and need libssl 1.1, which a current Linux distribution no longer ships -- they die with "No
    # usable version of libssl was found" before executing a single line of this file. Reporting
    # that as "the module is wrong under 7.0" would be the exact accusation this gate family exists
    # to prevent.
    Write-Output "STARTED $($PSVersionTable.PSVersion)"
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSComplexity.psd1') -Force

    $actual = Get-PSCxFixtureRow -Path $FixtureRoot
    if ($actual -ne $Expected) {
        Write-Output "SCORES DIFFER on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output "  expected: $($Expected -replace "`n", ' ; ')"
        Write-Output "  actual  : $($actual -replace "`n", ' ; ')"
        exit 1
    }
    # The gate itself, not just the measurement: a ceiling below the fixture MUST fail. Without the
    # failing half, a Test-PSComplexity that returned $true unconditionally would pass this leg.
    $generous = Test-PSComplexity -Path $FixtureRoot -Recurse -MaxCyclomatic 99 -MaxCognitive 99
    $tight = Test-PSComplexity -Path $FixtureRoot -Recurse -MaxCyclomatic 2 -MaxCognitive 2 -WarningAction SilentlyContinue
    if ($generous -ne $true -or $tight -ne $false) {
        Write-Output "GATE WRONG on PowerShell $($PSVersionTable.PSVersion): generous=$generous tight=$tight (want True/False)."
        exit 1
    }
    Write-Output "  PowerShell $($PSVersionTable.PSVersion): scores identical, gate passes and fails correctly."
    exit 0
}

if (-not $Version) {
    $fromEnv = $env:PS_COMPAT_VERSIONS
    if (-not $fromEnv) {
        $pins = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '.github/pins.env'
        $fromEnv = Get-PSCxPinValue -Line (Get-Content -LiteralPath $pins) -Name 'PS_COMPAT_VERSIONS'
    }
    $Version = @($fromEnv -split ' ' | Where-Object { $_ })
    if (-not $Version) {
        throw 'PS_COMPAT_VERSIONS is set neither in the environment nor in .github/pins.env. Refusing to run: a compatibility gate over zero versions passes every time.'
    }
}
if (-not $RuntimeRoot) { $RuntimeRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'pscx-pwsh' }
New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null

$root = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-psver-$([System.Guid]::NewGuid().ToString('N'))"
try {
    $srcDir = Build-PSCxRuntimeFixture -Root $root
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSComplexity.psd1') -Force
    # The answer THIS host gives, which every leg must reproduce. Computed once, from the same
    # fixture, so a leg reports a disagreement between hosts and never a disagreement about which
    # corpus was measured.
    $expected = Get-PSCxFixtureRow -Path $srcDir
    Write-Output "Proving $(@($Version).Count) PowerShell version(s) against $(@($expected -split "`n").Count) measured rows."

    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $Version) {
        Write-Output "  PowerShell ${v}: obtaining runtime if it is not already unpacked"
        try { $exe = Install-PSCxRuntime -PSVersion $v -Root $RuntimeRoot }
        catch {
            # An unobtainable runtime is not this module failing, and must never be reported as one.
            $faults.Add("PowerShell ${v}: could not be obtained -- $($_.Exception.Message)")
            continue
        }
        # The call is guarded, not just its result. A host that exits non-zero sets LASTEXITCODE and
        # is handled below; a host that cannot be LAUNCHED -- a truncated or wrong-architecture
        # binary -- throws instead, and under ErrorActionPreference = Stop that kills the whole gate
        # rather than recording one leg. Both are the same finding: this version proved nothing.
        try {
            $out = & $exe -NoProfile -File $PSCommandPath -Child -FixtureRoot $srcDir -Expected $expected 2>&1
            $code = $LASTEXITCODE
        }
        catch {
            $out = @("could not launch: $($_.Exception.Message)")
            $code = 1
        }
        $out | ForEach-Object { Write-Output "  $_" }
        if ($code -ne 0) {
            # Silence before the marker means the host never got as far as running our code, so the
            # fault is the platform's and saying otherwise sends the reader to the wrong file. It is
            # still a FAULT rather than a skip: a leg that cannot run is a version that is not
            # proven, and passing over it would be a green gate covering less than it claims.
            if (@($out) -notmatch '^STARTED ') {
                $faults.Add("PowerShell ${v}: the host would not start on this platform, so nothing was proven. Not a module failure.")
            }
            else {
                $faults.Add("PowerShell ${v}: this module does not behave correctly on it.")
            }
        }
    }

    if ($faults.Count -gt 0) {
        throw ("PowerShell compatibility gate failed for $($faults.Count) of $(@($Version).Count) version(s):" +
            [Environment]::NewLine + (($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine))
    }
    Write-Output "PowerShell compatibility gate passed for $(@($Version).Count) version(s): $($Version -join ', ')."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
