# Measure line coverage over src/ and fail below the required figure.
#
# A committed script rather than a few lines inside ci.yml, so that measuring by hand and
# measuring in CI cannot drift. This project's coverage figure was folklore for exactly that
# reason: CLAUDE.md claimed 100% and nothing measured it, while CHANGELOG.md quoted a command
# count that had been wrong for two releases.
#
# UseBreakpoints is set as a HEDGE, not a fix. In another repository it is load-bearing --
# Pester 6 moved coverage to the Profiler tracer, and a nested Pester run tears that tracer
# down, so every file discovered afterwards reports a plausible near-zero. Measured here both
# ways on the same suite, the two agree exactly, because nothing in tests/ starts a nested
# run. The setting costs a little speed and means a future test that does start one cannot
# quietly halve the number.
[CmdletBinding()]
param(
    # Percentage the run must reach. 100 because this module gates other people's code on a
    # number, so its own numbers are the product.
    [double]$Minimum = 100
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
# Match the gates: the classic `Should -Be` form is an error here too, so coverage cannot be
# measured over a suite that would fail the lint of its own assertions.
$cfg.Should.DisableV5 = $true
$cfg.CodeCoverage.Enabled = $true
$cfg.CodeCoverage.UseBreakpoints = $true
$cfg.CodeCoverage.Path = (Get-ChildItem (Join-Path $root 'src') -Filter *.ps1).FullName
# Steer the XML to temp: Pester's default would drop a coverage.xml in the working tree on
# every local run.
$cfg.CodeCoverage.OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-coverage-$PID.xml"

$result = Invoke-Pester -Configuration $cfg
. (Join-Path $PSScriptRoot 'ReleaseDecisions.ps1')
$fault = Get-PSCxTestRunFault -FailedCount $result.FailedCount `
    -ContainerResult @($result.Containers | ForEach-Object { [string]$_.Result }) `
    -ContainerName @($result.Containers | ForEach-Object { Split-Path $_.Item -Leaf })
if ($fault) { throw "$fault Coverage over a suite that did not fully run means nothing." }

$covered = $result.CodeCoverage.CommandsExecuted
$missed = $result.CodeCoverage.CommandsMissed
$total = @($covered).Count + @($missed).Count

# Refuse to report on nothing. An empty src/, or a Path that resolved to no files, would
# otherwise divide by zero or report a clean 0/0 -- the same shape of failure this module
# shipped with, where a gate that measured nothing reported success.
if ($total -eq 0) { throw 'No commands were analysed: src/ resolved to no measurable files.' }

@($covered) + @($missed) | Group-Object { Split-Path $_.File -Leaf } | Sort-Object Name |
    ForEach-Object {
        $hit = @($_.Group | Where-Object { $_.HitCount -gt 0 }).Count
        Write-Output ('  {0,-30} {1,4}/{2,-5} {3,6:N1}%' -f $_.Name, $hit, $_.Count, (100 * $hit / $_.Count))
    }
@($missed) | Sort-Object File, Line | ForEach-Object {
    Write-Output ('  UNCOVERED {0}:{1}  {2}' -f (Split-Path $_.File -Leaf), $_.Line, $_.Command)
}

$percent = 100 * @($covered).Count / $total
Write-Output ("Coverage: {0:N2}% over {1} commands in src/" -f $percent, $total)
if ($percent -lt $Minimum) {
    throw ("Coverage {0:N2}% is below the required {1}%." -f $percent, $Minimum)
}
