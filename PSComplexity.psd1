@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.7.0'
    GUID                 = '961aa886-4f8e-40c0-9d25-68fd4c52e69f'
    Author               = 'Fortigi'
    CompanyName          = 'Fortigi'
    Copyright            = '(c) Fortigi. MIT licensed.'
    Description          = 'Cyclomatic and cognitive complexity for PowerShell. Cognitive complexity implements the SonarSource metric in full (nesting-aware -- the better signal for "hard to understand"), scoring every reference example exactly as published, and extends it for PowerShell constructs the specification does not cover: ForEach-Object and Where-Object, the .ForEach() and .Where() methods, the && and || pipeline chains, and ?? and ??=. Measures per unit (function/filter, class method/constructor, initialised class property, + script body) via the PowerShell AST; ships a Test-PSComplexity gate for CI.'
    PowerShellVersion    = '7.0'
    CompatiblePSEditions = @('Core')

    FunctionsToExport    = @('Measure-PSComplexity', 'Test-PSComplexity')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('complexity', 'cyclomatic', 'cognitive', 'code-quality', 'ast', 'metrics', 'maintainability', 'lint', 'ci')
            LicenseUri   = 'https://github.com/Fortigi/PSComplexity/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Fortigi/PSComplexity'
            ReleaseNotes = '0.7.0: **`-Detailed` reports each unit''s lines of code.** Complexity says nothing about size -- a long function of straight-line code scores 1 and 0 -- so `-Detailed` now adds `LinesOfCode`, counted exactly as SonarQube counts `ncloc`: a physical line holding at least one character that is neither whitespace nor part of a comment. A brace on its own line, each line of a continued statement and the non-blank lines of a here-string count; blank lines, comments and comment-based help do not. Each line belongs to the innermost unit, so a nested function''s lines are not its parent''s. It is information only, with no threshold, and a run without `-Detailed` is unchanged. The JSON report carries it for a `-Detailed` run, as an optional field of each unit. **The gate''s policy can live in a committed `.pscomplexity.json`.** Ceilings, per-path overrides, excludes, acceptances with their reasons and the baseline file, in one place for CI and for a run by hand. `Test-PSComplexity` takes `-ConfigFile`, or finds the nearest `.pscomplexity.json` from each path up to the repository root -- never above it, and not at all outside a repository -- and `-NoConfig` turns that off. The file used is printed and recorded in the JSON report as `config`, beside `scope.exclude`, `scope.excluded` and `thresholds.overrides`. The command line wins wherever it says something. A config that is not valid is refused, naming every fault, and its format ships as `schemas/v1/config.schema.json`. Without a config nothing changes: the ceilings are still 15 and 15. Measure-PSComplexity reads no config. **An acceptance can be written in the code.** A `# PSCx-Accept: <reason>` line comment directly above a function, method or constructor excuses that unit, with exactly the checks `-Accept` has: the gate fails when the unit is back within its ceilings or the reason is empty. The argument then moves with the code instead of going stale in a `File` + `Unit` list. A declaration that excuses nothing -- separated by a blank line, sharing a line with code, or above something that is not a unit -- is refused rather than ignored, and so is a unit accepted both in its code and in a list. Whole units only. The report''s `accepted` entries now say where each argument is written, as `source` (`inline` or `list`) and the `line` of an inline one. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
