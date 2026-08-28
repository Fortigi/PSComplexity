# Run the suite in reverse file order, and fail if that changes the answer or if the run leaves
# an environment variable behind.
#
# This project runs its own suite in TWO orders and nothing checked they agree. Invoke-Pester
# over ./tests discovers files alphabetically; the mutation baseline runs the mapped covering
# suites in the order psmutant.self.config.json lists them, and those orders differ. A developer
# running the suite by hand and the gate running it therefore never see the same sequence, so an
# order-dependent suite is green in one and red in the other -- which is exactly how it went in
# another repository, where three CI rounds went into finding a variable one file had cleared and
# not restored.
#
# Two checks, because they fail on opposite halves of the problem:
#
#   The reversed RUN catches a dependency by its symptom. It is a probe rather than a proof: it
#   exercises one more permutation, not all of them, so a dependency whose two files happen to
#   keep their relative order under reversal survives it.
#
#   The state COMPARISON catches the cause, and is direction-blind. Anything a file leaves behind
#   is visible to every file after it, so a leak is order-dependence waiting for a reader -- and
#   this fires on the file that leaks whether or not anything reads it yet. That is the half the
#   reversed run misses, and the half that shipped in that project.
#
# It is a committed script rather than a snippet in ci.yml so that running it by hand and running
# it in CI cannot drift, and so that a developer can settle "is this mine?" without pushing.
#
# Known limit, stated rather than left to be rediscovered: the comparison spans the whole run, so
# a file that leaks and a later file that coincidentally restores cancel out. Per-file granularity
# needs a hook Pester does not offer, and would cost one process per file.
#
# Two other kinds of state were tried and are deliberately NOT compared. Both were measured, and
# both would have been checks that cannot do their job -- which reads exactly like a check that
# keeps passing:
#
#   The working DIRECTORY. Pester restores it around a run, so a test file that wanders off with
#   Set-Location leaves it back where it started. Verified with a test that changes directory and
#   passes: the location afterwards is unchanged. A cwd comparison here could never fire.
#
#   GLOBAL variables. A clean run of this suite already adds several -- Pester promotes a
#   -ForEach case table to global scope, so every data-driven test file leaves one behind. The
#   comparison would fail on a green suite, and the only way to keep it would be an allowlist
#   that grows with the tests it is supposed to be watching.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Get-ProcessStateSnapshot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'The literal @{} is case-INSENSITIVE, which is the one property this map must not have. On Linux PATH and Path are two different variables and the literal would silently merge them into one entry, so a change to either would compare equal.')]
    param()
    $snap = [hashtable]::new(0, [StringComparer]::Ordinal)
    # Keyed by the path you would type, so the failure message names something the reader can go
    # and look at. A second kind of state, if one ever earns its place, is a second key prefix
    # here rather than a second comparison someone has to remember to invert correctly.
    foreach ($item in Get-ChildItem env:) { $snap["env:$($item.Name)"] = [string]$item.Value }
    return $snap
}

$before = Get-ProcessStateSnapshot

$files = @(Get-ChildItem (Join-Path $root 'tests') -Filter *.Tests.ps1 |
        Sort-Object Name -Descending | ForEach-Object FullName)
# Refuse to certify order-independence over fewer than two files. Reversing a list of one yields
# the same list, so the run would pass without ever having exercised a second order -- the shape
# of green this whole script exists to distrust.
if ($files.Count -lt 2) {
    throw ("Found $($files.Count) test file(s) under $(Join-Path $root 'tests'): reversing that " +
        'exercises no second order, so a pass here would certify nothing.')
}

Import-Module (Join-Path $root 'PSComplexity.psd1') -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = $files
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
# Match the other gates: the classic `Should -Be` form is an error here too.
$cfg.Should.DisableV5 = $true
$result = Invoke-Pester -Configuration $cfg

# Pester is asked for a specific list; a file silently dropped from it would leave the run green
# over less than it was given, and the count is the only place that shows.
if ($result.Containers.Count -ne $files.Count) {
    throw ("Asked Pester for $($files.Count) test file(s) and it ran $($result.Containers.Count). " +
        'A reversed run over a subset proves nothing about the whole.')
}

. (Join-Path $PSScriptRoot 'ReleaseDecisions.ps1')
$fault = Get-PSCxTestRunFault -FailedCount $result.FailedCount `
    -ContainerResult @($result.Containers | ForEach-Object { [string]$_.Result }) `
    -ContainerName @($result.Containers | ForEach-Object { Split-Path $_.Item -Leaf })
if ($fault) {
    throw ("$fault This is the suite in REVERSE file order. If it passes alphabetically, the " +
        'failure is not in the test that reported it -- it is in what ran before it.')
}

$stateFault = Get-PSCxProcessStateFault -Before $before -After (Get-ProcessStateSnapshot)
if ($stateFault) { throw $stateFault }

Write-Output ("Order independence: $($files.Count) test file(s) reversed, " +
    "$($result.PassedCount) test(s) passed, environment unchanged.")
