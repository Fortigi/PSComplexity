# Compatibility gate: prove a consumer can gate on PSComplexity from inside a Pester 5 run,
# while this repo's own suite runs on Pester 6. The two are different promises and only one
# of them is covered by the test estate.
#
# The child runs in a SEPARATE PROCESS. Pester loads assemblies, assemblies are per-process,
# and this script is invoked from a job that has already imported a different Pester -- so
# importing the old one in-process collides instead of testing anything.
#
# The script re-invokes ITSELF with -Child rather than spawning a here-string, so the
# analyzer and the parser see every line that runs. A child contract written as an unparsed
# string is code no gate can read.
[CmdletBinding()]
param(
    # The Pester versions to prove compatibility against -- deliberately not the one tests/ uses.
    # Empty means read PESTER_COMPAT_VERSIONS from the environment or .github/pins.env, so running
    # this by hand and running it in CI are the same run with no setup step.
    [string[]]$PesterVersion,
    [switch]$Child,
    [string]$FixtureRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseDecisions.ps1')

if (-not $PesterVersion) {
    # Environment first so a workflow can override, then the pins file, then refuse. Defaulting to
    # some version here would be the failure this gate exists to find: a compatibility claim
    # proven against a number nobody chose.
    $fromEnv = $env:PESTER_COMPAT_VERSIONS
    if (-not $fromEnv) {
        $pins = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath '.github/pins.env'
        $fromEnv = Get-PSCxPinValue -Line (Get-Content -LiteralPath $pins) -Name 'PESTER_COMPAT_VERSIONS'
    }
    $PesterVersion = @($fromEnv -split ' ' | Where-Object { $_ })
    if (-not $PesterVersion) {
        throw 'PESTER_COMPAT_VERSIONS is set neither in the environment nor in .github/pins.env. Refusing to run: a compatibility gate over zero versions passes every time.'
    }
}

function Build-PSCxCompatFixture {
    param([Parameter(Mandatory)] [string]$Root)

    $src = Join-Path $Root 'src'
    New-Item -ItemType Directory -Path $src -Force | Out-Null

    # One unit well inside any ceiling, and one far over it. BOTH are needed: a fixture that
    # only passes cannot tell a working gate from one that returns $true unconditionally,
    # which is the exact defect this module shipped with.
    Set-Content -LiteralPath (Join-Path $src 'Simple.ps1') `
        'function Get-Simple { param($x) if ($x) { 1 } else { 2 } }' -Encoding utf8

    $deep = 'function Get-Deep { param($a)' + [Environment]::NewLine
    foreach ($i in 1..12) { $deep += "    if (`$a -eq $i) { return $i }" + [Environment]::NewLine }
    $deep += '}'
    Set-Content -LiteralPath (Join-Path $src 'Deep.ps1') $deep -Encoding utf8

    # The CONTROL. Asserts nothing about this module -- it asks whether the requested Pester
    # can execute a test at all on this PowerShell. Without it, a Pester that is broken in
    # the host (5.8.0 fails every test on PowerShell 7.6.x, with an EMPTY error record)
    # looks exactly like a PSComplexity incompatibility, and the gate accuses the wrong code.
    Set-Content -LiteralPath (Join-Path $Root 'Control.Tests.ps1') @'
Describe 'control -- can this Pester run anything at all' {
    It 'evaluates a trivial assertion' { (1 + 1) | Should -Be 2 }
}
'@ -Encoding utf8

    Set-Content -LiteralPath (Join-Path $Root 'Consumer.Tests.ps1') @'
Describe 'a consumer gates on complexity from inside Pester' {
    It 'passes a unit within the ceilings' {
        Test-PSComplexity -Path $env:PSCX_COMPAT_SRC -Recurse |
            Should -Be $true
    }
    It 'fails a unit over the ceilings' {
        Test-PSComplexity -Path $env:PSCX_COMPAT_SRC -Recurse -MaxCyclomatic 3 -MaxCognitive 3 -WarningAction SilentlyContinue |
            Should -Be $false
    }
    It 'refuses a path it measured nothing under' {
        { Test-PSComplexity -Path (Join-Path $env:PSCX_COMPAT_SRC 'nothing-here') -Recurse } |
            Should -Throw
    }
}
'@ -Encoding utf8

    return $src
}

function Invoke-PSCxCompatSuite {
    # The SIMPLE parameter set, deliberately, and it is the whole reason this gate can reach the
    # version the manifest promises.
    #
    # A configuration object needs New-PesterConfiguration, which did not exist until Pester 5.1.0.
    # Asking for it under 5.0.0 does not fail cleanly: the command is not found, PowerShell
    # autoloads `Pester` by NAME to the newest installed, and that collides with the 5.0.0
    # Pester.dll already in the process. The error names assembly versions and this module is
    # nowhere in it -- so the gate could not test the declared floor, and said the module was
    # broken when pointed at it.
    #
    # -Path and -PassThru are the oldest surface Pester 5 has, and they behave identically on
    # 5.0.0, 5.7.1, 5.8.0 and 6.1.0 -- verified, including the shape of .Containers, which the
    # never-ran check below reads. It is also what a plain consumer writes.
    #
    # 6>$null replaces Output.Verbosity = 'None', which lives on the configuration object this can
    # no longer build. Pester writes its progress to the information stream.
    param([Parameter(Mandatory)] [string]$Path)

    return Invoke-Pester -Path $Path -PassThru 6>$null
}

if ($Child) {
    # One version per child, always: the parent loops. Assemblies are per-process, so proving two
    # Pesters in one process is not a stronger test, it is a different and impossible one.
    #
    # A NEW variable rather than reassigning the parameter. $PesterVersion is declared [string[]],
    # and a typed parameter re-applies its constraint on every assignment -- so assigning one
    # element back to it produces a one-element ARRAY again, and [version]$PesterVersion then fails
    # with a cast error that names String[] and nothing about Pester.
    $compatVersion = @($PesterVersion)[0]
    # ABSENT is a third answer, distinct from "broken here" and "the module is wrong". The
    # import failure alone says "no valid module file was found", and the caller then
    # reported that PSComplexity does not work under this Pester -- blaming the module for
    # a version nobody installed.
    if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -eq [version]$compatVersion })) {
        Write-Output "MISSING: Pester $compatVersion is not installed on this machine."
        Write-Output 'The gate proves nothing without it. Install it, or pass -PesterVersion.'
        exit 3
    }
    Import-Module Pester -RequiredVersion $compatVersion -Force
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSComplexity.psd1') -Force

    # A THROW here is an environment failure exactly as a failed assertion is, and it has to be
    # caught to be one. Without this the child dies with an ordinary non-zero exit, the caller
    # cannot tell it apart from a consumer failure, and it reports that this module does not work
    # under a Pester that never managed to start. That is the accusation this control exists to
    # prevent, arriving through the one door it did not cover.
    try {
        $control = Invoke-PSCxCompatSuite -Path (Join-Path $FixtureRoot 'Control.Tests.ps1')
    }
    catch {
        Write-Output "ENVIRONMENT: Pester $compatVersion could not run the control on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output "This is not a PSComplexity failure. The control threw: $($_.Exception.Message)"
        exit 2
    }
    # PassedCount, not FailedCount. A control that failed to PARSE reports neither, so
    # asking only about failures would read "this Pester works" from a file that never ran.
    if ($control.PassedCount -eq 0) {
        Write-Output "ENVIRONMENT: Pester $compatVersion cannot run a trivial test on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output 'This is not a PSComplexity failure. The control assertion (1 + 1 = 2) failed.'
        exit 2
    }

    $consumer = Invoke-PSCxCompatSuite -Path (Join-Path $FixtureRoot 'Consumer.Tests.ps1')
    # The fixture is written out by this script, so a typo in it would otherwise report a
    # clean pass over a file that never parsed -- the gate certifying its own mistake.
    if (@($consumer.Containers | Where-Object { $_.Result -ne 'Passed' -and $_.Result -ne 'Skipped' }).Count -gt 0 -and
        $consumer.FailedCount -eq 0) {
        Write-Output 'The consumer fixture reported no failures because it never ran.'
        exit 4
    }
    Write-Output "Pester ${compatVersion}: control passed, consumer $($consumer.PassedCount) passed / $($consumer.FailedCount) failed."
    foreach ($f in $consumer.Failed) { Write-Output "  FAILED: $($f.Name)" }
    exit ([int]($consumer.FailedCount -gt 0))
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-compat-$([System.Guid]::NewGuid().ToString('N'))"
try {
    $srcDir = Build-PSCxCompatFixture -Root $root
    $env:PSCX_COMPAT_SRC = $srcDir

    # Every version is tried and every fault collected, rather than stopping at the first. The
    # legs are seconds apart and a CI round is not: learning about the second broken version only
    # after fixing the first costs another full run, which is the same argument the release gate
    # makes for reporting all of its faults at once.
    #
    # The fixture is built ONCE, outside the loop. It is version-independent, and rebuilding it per
    # leg would mean each version proving itself against a different directory.
    $faults = [System.Collections.Generic.List[string]]::new()
    foreach ($version in $PesterVersion) {
        Write-Output "Proving a Pester $version consumer can gate on this module (child process)."
        & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath `
            -PesterVersion $version -FixtureRoot $root -Child
        # The three non-zero codes are three different accusations, and only one of them is about
        # this module. Flattening them would put the blame for an absent or broken Pester here.
        switch ($LASTEXITCODE) {
            0 { }
            2 { $faults.Add("Pester ${version}: unusable on this PowerShell; the gate could not run.") }
            3 { $faults.Add("Pester ${version}: not installed; the gate could not run.") }
            default { $faults.Add("Pester ${version}: PSComplexity does not work correctly under it.") }
        }
    }
    if ($faults.Count -gt 0) {
        throw ("Pester compatibility gate failed for $($faults.Count) of $(@($PesterVersion).Count) version(s):" +
            [Environment]::NewLine + (($faults | ForEach-Object { "  - $_" }) -join [Environment]::NewLine))
    }
    Write-Output "Pester compatibility gate passed for $(@($PesterVersion).Count) version(s): $($PesterVersion -join ', ')."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PSCX_COMPAT_SRC -ErrorAction SilentlyContinue
}
