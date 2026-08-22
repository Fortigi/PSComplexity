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
            ReleaseNotes = '0.2.1: FIXED - this release fixes two separate ways the gate reported success without measuring anything, and if either affected you, your builds have been passing on evidence that was never gathered. First: scanning a DIRECTORY without -Recurse resolved to zero files. -Include is ignored for a directory unless -Recurse is also given, so Measure-PSComplexity ./src returned nothing for a folder full of code, and Test-PSComplexity ./src -MaxCyclomatic 1 returned $true against units that all breached. Second: a path containing [ or ] matched nothing, because -Path reads brackets as a wildcard character class, so a real directory named my[1]proj scored a confident, empty zero. Discovery now filters on the file extension and resolves an existing path literally; a pattern that names nothing on disk still falls through to wildcard matching, so ./src/*.ps1 keeps working. AND, so that neither can be silent again, Test-PSComplexity now THROWS when it measured no units instead of returning $true - nothing breached a ceiling and nothing was measured must never be the same answer. WHAT TO DO: if you gate a flat directory, re-run before upgrading and compare. A run that starts failing after this upgrade is the honest one. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
