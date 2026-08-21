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
    # The OLD Pester to prove compatibility against -- deliberately not the one tests/ uses.
    [string]$PesterVersion = '5.7.1',
    [switch]$Child,
    [string]$FixtureRoot
)

$ErrorActionPreference = 'Stop'

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
    param([Parameter(Mandatory)] [string]$Path)

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $Path
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    return Invoke-Pester -Configuration $cfg
}

if ($Child) {
    # ABSENT is a third answer, distinct from "broken here" and "the module is wrong". The
    # import failure alone says "no valid module file was found", and the caller then
    # reported that PSComplexity does not work under this Pester -- blaming the module for
    # a version nobody installed.
    if (-not (Get-Module Pester -ListAvailable | Where-Object { $_.Version -eq [version]$PesterVersion })) {
        Write-Output "MISSING: Pester $PesterVersion is not installed on this machine."
        Write-Output 'The gate proves nothing without it. Install it, or pass -PesterVersion.'
        exit 3
    }
    Import-Module Pester -RequiredVersion $PesterVersion -Force
    Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSComplexity.psd1') -Force

    $control = Invoke-PSCxCompatSuite -Path (Join-Path $FixtureRoot 'Control.Tests.ps1')
    if ($control.FailedCount -gt 0) {
        Write-Output "ENVIRONMENT: Pester $PesterVersion cannot run a trivial test on PowerShell $($PSVersionTable.PSVersion)."
        Write-Output 'This is not a PSComplexity failure. The control assertion (1 + 1 = 2) failed.'
        exit 2
    }

    $consumer = Invoke-PSCxCompatSuite -Path (Join-Path $FixtureRoot 'Consumer.Tests.ps1')
    Write-Output "Pester ${PesterVersion}: control passed, consumer $($consumer.PassedCount) passed / $($consumer.FailedCount) failed."
    foreach ($f in $consumer.Failed) { Write-Output "  FAILED: $($f.Name)" }
    exit ([int]($consumer.FailedCount -gt 0))
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-compat-$([System.Guid]::NewGuid().ToString('N'))"
try {
    $srcDir = Build-PSCxCompatFixture -Root $root
    $env:PSCX_COMPAT_SRC = $srcDir

    Write-Output "Proving a Pester $PesterVersion consumer can gate on this module (child process)."
    & (Get-Process -Id $PID).Path -NoProfile -File $PSCommandPath `
        -PesterVersion $PesterVersion -FixtureRoot $root -Child
    $code = $LASTEXITCODE

    if ($code -eq 3) { throw "Pester $PesterVersion is not installed; the gate could not run." }
    if ($code -eq 2) { throw "Pester $PesterVersion is unusable on this PowerShell; the gate could not run." }
    if ($code -ne 0) { throw "PSComplexity does not work correctly under Pester $PesterVersion." }
    Write-Output 'Pester compatibility gate passed.'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\PSCX_COMPAT_SRC -ErrorAction SilentlyContinue
}
