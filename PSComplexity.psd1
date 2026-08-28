@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.5.1'
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
            ReleaseNotes = '0.5.1: **The supported Pester range is now proven rather than asserted.** The manifest and README have always said Pester 5.0.0 or later; the gate that backs that claim ran exactly one version, 5.7.1, and had never once executed the floor. It now runs one leg per minor across the whole range -- **5.0.0, 5.1.1, 5.2.2, 5.3.3, 5.4.1, 5.5.0, 5.6.1, 5.7.1, 5.8.0, 5.9.1, 6.0.1, 6.1.0** -- and all twelve pass. Nothing about the module changed. What changed is that the number you are told is the number that gets exercised. **Pointed at the floor, the old gate reported the module broken.** It built its Pester configuration with `New-PesterConfiguration`, which did not exist until 5.1.0, so under 5.0.0 the command was not found, PowerShell autoloaded a newer Pester by name, and the two assemblies collided. The gate then blamed this module for an error that never mentioned it. If you ran it against 5.0.0 and believed the verdict, that is why. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
