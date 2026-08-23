@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.4.0'
    GUID                 = '961aa886-4f8e-40c0-9d25-68fd4c52e69f'
    Author               = 'Fortigi'
    CompanyName          = 'Fortigi'
    Copyright            = '(c) Fortigi. MIT licensed.'
    Description          = 'Cyclomatic and cognitive complexity for PowerShell. Cognitive complexity implements the SonarSource metric in full (nesting-aware -- the better signal for "hard to understand"), scoring every reference example exactly as published, and extends it for PowerShell constructs the specification does not cover: ForEach-Object and Where-Object, the && and || pipeline chains, and ?? and ??=. Measures per unit (function/filter, class method/constructor, initialised class property, + script body) via the PowerShell AST; ships a Test-PSComplexity gate for CI.'
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
            ReleaseNotes = '0.4.0: BEHAVIOUR CHANGE -- two published values change shape, and anything that stored them will not match. Read this before upgrading a pipeline that keeps records. `Unit` and `File` were neither unique within a file nor stable across machines, and both are fixed together because a half-fixed identity is still not one. **`Unit` is now qualified and disambiguated.** A function nested in another reads `Get-OuterA/Get-Inner` rather than `Get-Inner` -- two such units in one file used to be indistinguishable, and they score differently. Two units sharing a name in the same scope -- overloads, or a function defined twice -- get an ordinal on **every** member of the group: `Repo.Add#1`, `Repo.Add#2`. Both, not just the second, because suffixing only the later one would silently rename the first the day an overload is added. Class members were already qualified; this extends the same rule to the half that lacked it. **`File` is now relative to the working directory, with forward slashes.** It was absolute and platform-separated, so identical source measured on two CI legs produced disjoint key sets -- `C:\...\src\A.ps1` against `/home/.../src/A.ps1` -- and anything comparing runs across them matched nothing while appearing to work. A file outside the root keeps its full path, because a `../../` chain is no more portable and says less. The README had rendered this relative all along. If you have a stored baseline, it will not match after upgrading. That is the point: the keys it holds could not distinguish units the tool could. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
