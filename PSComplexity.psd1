@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.5.0'
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
            ReleaseNotes = '0.5.0: **The minimum PowerShell version is now 7.0, down from 7.2.** The old floor was set in the first commit and never justified; nothing in the module needed it. The real constraint is 7.0, and it is a hard one: the metric scores `&&`, `||`, `??`, `??=` and the ternary, the AST types for those arrived with the operators themselves in 7.0, and their type names are referenced directly -- an unresolvable type literal is a parse-time failure, so an older host cannot load the module at all rather than degrading quietly. Nothing else changes. If you are already on 7.2 or newer, this release is identical to 0.4.0 in behaviour. **The floor is still a claim rather than a checked fact**, and that is worth saying plainly: no CI leg runs on 7.0. `PSUseCompatibleTypes` was tried as a proof and rejected -- against a 7.0 profile it reports clean on `[System.DateOnly]`, `[System.Half]` and `Get-Error` alike, so a clean result from it means nothing at all. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
