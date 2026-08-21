@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.2.1'
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
            ReleaseNotes = '0.2.1: FIXED - Test-PSComplexity returned $true after measuring NOTHING, so a gate aimed at a path with no PowerShell under it gave the same answer as a gate over clean code; it now throws and names the path. Relatedly, a directory scanned without -Recurse measured NOTHING, and the gate passed over it. -Include is ignored for a directory unless -Recurse is also given, so Measure-PSComplexity ./src returned zero units for a folder full of code and Test-PSComplexity returned $true against units that all breached the ceiling. If you have been gating a flat directory, that gate has never measured anything. Also fixed: a path containing [ or ] matched nothing, because -Path reads brackets as a wildcard character class - so a directory named my[1]proj scored a confident, empty zero. An existing path is now resolved literally, and a pattern that names nothing on disk still falls through to wildcard matching. 0.2.0: PowerShell class members are measured as units. Methods and constructors report as Class.Member (previously a method appeared under its bare name, so two classes with the same method name -- or a class method and a function of that name -- collided in one row and in any per-unit baseline). An initialised class property is now its own unit instead of folding its decisions into the script body, and recursion through $this.Method() or [Class]::Method() counts as it does for functions. 0.1.0: initial release.'
        }
    }
}
