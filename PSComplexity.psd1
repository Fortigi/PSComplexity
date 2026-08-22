@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.3.0'
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
            ReleaseNotes = '0.3.0: BEHAVIOUR CHANGE - a gate that passed for you may now fail, in two unrelated ways, and both are the point of the release. Read this before upgrading a pipeline you cannot watch. FIRST, SCORES RISE for code that branches through PowerShell''s own flow constructs. ForEach-Object, Where-Object and their aliases, the && and || pipeline chains, and ?? and ??= were all measured as straight-line code, so a function branching only through them reported cyclomatic 1 and cognitive 0. They are now scored as the loop, conditional, boolean run and ternary they stand in for, and a pipeline body costs exactly what the keyword form costs. Every SonarSource reference example still scores as published; the additions are listed in the README with the rule each follows. If a unit sat just under your ceiling, it may not any more. SECOND, THE GATE NO LONGER REPORTS SUCCESS WITHOUT MEASURING ANYTHING, in three ways it previously could. Scanning a directory without -Recurse resolved to zero files, so Measure-PSComplexity ./src returned nothing for a folder full of code and Test-PSComplexity ./src -MaxCyclomatic 1 returned $true against units that all breached. A path containing [ or ] matched nothing, because -Path reads brackets as a wildcard character class, so a directory named my[1]proj scored a confident, empty zero. And a file that failed to PARSE was skipped with a warning and contributed no units, so a broken file passed the gate. Discovery now filters on the file extension and resolves an existing path literally, Test-PSComplexity throws rather than vouching for an empty selection, and it refuses a verdict when any file could not be read. A pattern that names nothing on disk still falls through to wildcard matching, so ./src/*.ps1 keeps working. ALSO FIXED: naming one file by two inputs measured it twice and emitted every unit twice; enum members with initialisers were reported as units, so an enum''s complexity depended on whether anyone numbered it; rows came back in hashtable order rather than source order, so two runs over one unchanged file could differ; and Test-PSComplexity now accepts paths from the pipeline, judging all of them rather than binding nothing. WHAT TO DO: re-run against your codebase before upgrading and compare. A run that starts failing after this upgrade is the honest one -- either it is measuring code it never opened before, or it is scoring branches it could not previously see. Pin 0.2.0 if you need the previous numbers exactly; every score here is greater than or equal to the one it produced. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
