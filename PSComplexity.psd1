@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.6.0'
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
            ReleaseNotes = '0.6.0: **The `.ForEach()` and `.Where()` methods now score as `ForEach-Object` and `Where-Object` do** (#159). The methods take a script block exactly as the cmdlets do, and branch exactly as much, but scored nothing: `$x | Where-Object { ... }` scored one more than the identical `$x.Where({ ... })`, so the method form was a cheaper spelling of the same logic. Each is now one decision for cyclomatic and one increment plus nesting for cognitive, the same as the cmdlet. Only instance calls count -- the intrinsics are never static, so `[Type]::Where()` is somebody else''s method. **Scores rise for any code that uses them, and the metric version is now 2.** A baseline recorded against version 1 is refused rather than compared; regenerate it with `-UpdateBaseline` and review the diff. Code that uses neither method scores exactly as before, and every SonarSource reference case is unchanged. **A large baseline no longer slows the gate down** (#153). Each baseline entry and each acceptance was checked by searching the whole list of measured units, so the check took entries x units: a 2,000-entry baseline over 2,200 units took a gate from 9 seconds to 31. The units are now indexed once per run and each entry is a single lookup -- measured on that size, 12.3 seconds of checking becomes 0.3. Matching is unchanged: file and unit, ignoring case. This one moves no score. **A path on a UNC share is measured, and named, like a local one** (#171). PowerShell writes a share path with a `Microsoft.PowerShell.Core\FileSystem::` prefix, and two places kept it. A FILE on a share -- `Measure-PSComplexity \\server\share\src\A.ps1`, or `./A.ps1` with the current location on a share -- was skipped as "could not be read", and the gate refused the run. Worse, quietly: with the current location on a share, a measured DIRECTORY named every file by its full path rather than relative to that location, so baseline and acceptance entries no longer matched, and a `-ChangedFile` list matched nothing -- which the gate reads as "no PowerShell changed" and passes. Paths are now resolved to the plain file-system form, so a share, or any path written provider-qualified, behaves exactly as a local path does. This one moves no score either. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
