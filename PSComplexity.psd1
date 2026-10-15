@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.5.3'
    GUID                 = '961aa886-4f8e-40c0-9d25-68fd4c52e69f'
    Author               = 'Fortigi'
    CompanyName          = 'Fortigi'
    Copyright            = '(c) Fortigi. MIT licensed.'
    Description          = 'Cyclomatic and cognitive complexity for PowerShell. Cognitive complexity implements the SonarSource metric in full (nesting-aware -- the better signal for "hard to understand"), scoring every reference example exactly as published, and extends it for PowerShell constructs the specification does not cover: ForEach-Object and Where-Object, the && and || pipeline chains, and ?? and ??=. Measures per unit (function/filter, class method/constructor, initialised class property, + script body) via the PowerShell AST; ships a Test-PSComplexity gate for CI.'
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
            ReleaseNotes = '0.5.3: **A large baseline no longer slows the gate down.** Each baseline entry and each acceptance was checked by searching the whole list of measured units, so the check took entries x units: a 2,000-entry baseline over 2,200 units took a gate from 9 seconds to 31. The units are now indexed once per run and each entry is a single lookup -- measured on that size, 12.3 seconds of checking becomes 0.3. Matching is unchanged: file and unit, ignoring case. No score moves and no command changed. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
