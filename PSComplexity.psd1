@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '961aa886-4f8e-40c0-9d25-68fd4c52e69f'
    Author               = 'Fortigi'
    CompanyName          = 'Fortigi'
    Copyright            = '(c) Fortigi. MIT licensed.'
    Description          = 'Cyclomatic and cognitive complexity for PowerShell. Cognitive complexity is a faithful port of the SonarSource metric (nesting-aware -- the better signal for "hard to understand"), validated against reference scores. Measures per unit (function/filter, class method/constructor, initialised class property, + script body) via the PowerShell AST; ships a Test-PSComplexity gate for CI.'
    PowerShellVersion    = '7.2'
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
            ReleaseNotes = '0.2.0: PowerShell class members are measured as units. Methods and constructors report as Class.Member (previously a method appeared under its bare name, so two classes with the same method name -- or a class method and a function of that name -- collided in one row and in any per-unit baseline). An initialised class property is now its own unit instead of folding its decisions into the script body, and recursion through $this.Method() or [Class]::Method() counts as it does for functions. 0.1.0: initial release.'
        }
    }
}
