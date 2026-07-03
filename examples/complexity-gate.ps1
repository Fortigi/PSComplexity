# Example: use PSComplexity as a build gate and to inspect the numbers.
#
#   Install-Module PSComplexity
#   ./examples/complexity-gate.ps1

Import-Module PSComplexity

# 1. Inspect: the most complex units first.
Measure-PSComplexity -Path ./src -Recurse |
    Sort-Object Cognitive, Cyclomatic -Descending |
    Format-Table File, Unit, Line, Cyclomatic, Cognitive

# 2. Gate: fail the build if anything is over the ceilings (default 15/15).
if (-not (Test-PSComplexity -Path ./src -Recurse -MaxCyclomatic 15 -MaxCognitive 15)) {
    throw 'Complexity gate failed - see the warnings above.'
}
Write-Information 'Complexity gate passed.' -InformationAction Continue
