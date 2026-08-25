# Run PSScriptAnalyzer the one way this project runs it, and FAIL when it finds anything.
#
# THREE callers analyse this repo, not two: the lint step in ci.yml, the same check in
# publish.yml guarding the one irreversible action here, and code-scanning.yml, which uploads
# SARIF and is a REQUIRED check. They each spelled the
# invocation out inline and disagreed about both scope and severity -- ci.yml passed
# `-Severity Error, Warning` over four paths, code scanning passed no filter over everything.
#
# So an Information-severity finding was invisible to the gate that fails and visible to the
# gate that blocks: it passed lint locally and in CI, then surfaced where nobody was looking
# and held the merge. There is now one definition of how the analyzer is invoked, and both
# gates call it, so the class cannot come back by someone editing one workflow.
#
# Paths and the analyzer version come from .github/pins.env, read directly when the
# environment does not already carry them, so running this by hand is identical to running it
# in CI with no setup step.
[CmdletBinding()]
param(
    # Defaults to PSSA_PATHS. Override only to analyse a subset while iterating; the gates
    # must always run the full set.
    [string[]]$Path,

    # Defaults to PSSA_VERSION. The exact version matters: rules and their inference change
    # between releases, so an unpinned analyzer can report a finding CI does not, or miss one
    # it does.
    [string]$AnalyzerVersion,

    # Return the findings as data instead of failing on them. For the one caller that has its
    # own use for them -- code-scanning.yml converts them to SARIF, where an EMPTY set is a
    # meaningful upload that clears alerts for rules already fixed, so that consumer must never
    # be failed.
    #
    # Opt-out rather than opt-in, deliberately. The dangerous shape is a human running this and
    # reading exit 0 as a pass, so the safe behaviour has to be what you get without thinking
    # about it.
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseDecisions.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-PSCxPin {
    # One pinned value, preferring what the environment already holds.
    #
    # The workflows load pins.env into $env: after checkout, so in CI this reads the
    # environment. Run by hand there is no such step, and falling back to the file is what
    # stops a local run using a different analyzer, or a different path list, than the gate.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Name)

    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if ($fromEnv) { return $fromEnv }

    $pins = Join-Path -Path $repoRoot -ChildPath '.github/pins.env'
    $value = Get-PSCxPinValue -Line (Get-Content -LiteralPath $pins) -Name $Name
    if (-not $value) { throw "$Name is set neither in the environment nor in $pins." }
    return $value
}

if (-not $Path) { $Path = (Get-PSCxPin -Name 'PSSA_PATHS') -split ' ' | Where-Object { $_ } }
if (-not $AnalyzerVersion) { $AnalyzerVersion = Get-PSCxPin -Name 'PSSA_VERSION' }

# Refuse to analyse nothing. Without this an empty or misparsed PSSA_PATHS makes both gates
# report clean over zero files -- a lint gate that cannot fail, which looks exactly like a
# lint gate with nothing to say. The same failure the module itself shipped with.
if (@($Path).Count -eq 0) { throw 'No paths to analyse: PSSA_PATHS resolved to nothing.' }
foreach ($p in $Path) {
    if (-not (Test-Path -Path (Join-Path -Path $repoRoot -ChildPath $p))) {
        throw "PSSA_PATHS names '$p', which does not exist under $repoRoot."
    }
}

Import-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion

$settings = Join-Path -Path $repoRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'

# NO -Severity. Rules are excluded by name in the settings file, with a reason, which is a
# decision someone made; a severity filter mutes a whole band nobody decided about. One
# invocation, every rule, both gates.
#
# -Path takes a single item, so the loop is required rather than stylistic: passing the array
# fails with "Cannot convert 'System.Object[]' to the type 'System.String'".
# @() so a single finding is still a collection and callers can count it. No comma-wrap:
# callers pipe this, and `, $array` would enter the pipeline as one item.
$findings = [object[]]@($Path | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings })

if ($PassThru) { return $findings }

# Otherwise this script IS the gate, like Measure-PSCxCoverage.ps1 and Test-PSCxRelease.ps1
# beside it. It used to return findings and exit 0 whether or not it found any, so $? was not a
# verdict: a person who ran it by hand and checked the exit code got a confident wrong answer,
# and the verdict lived in THREE workflow steps instead -- ci.yml, publish.yml and nowhere at
# all for code scanning. Two of the three committed gate scripts failed loudly and this one did
# not, which is the inconsistency that made the trap invisible.
#
# Printed before the throw, because a gate that says how many findings there are without saying
# what they were sends the reader back to run it again.
. (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseDecisions.ps1')
$fault = Get-PSCxLintFault -FindingCount $findings.Count
if ($fault) {
    # Write-Output, not Write-Host: PSAvoidUsingWriteHost is NOT excluded in this repo and every
    # other script in tools/ prints this way. The sibling project excludes the rule and uses
    # Write-Host throughout, so this is the one line of that design that must not be copied
    # across -- and the gate this change creates caught it immediately, on itself.
    Write-Output ($findings | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize | Out-String)
    throw $fault
}
Write-Output 'Lint clean.'
