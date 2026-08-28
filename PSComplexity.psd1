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
            ReleaseNotes = '0.5.1: **Scanning is about 30% faster, and no score moves.** Measured over a 235-file repository holding 259,144 AST nodes: **9,737ms to 6,809ms wall, 12,723ms to 8,875ms CPU**, interleaved over three pairs each time. Output is byte-identical -- 1,317 units, every `-Detailed` contribution row included -- and the mutant surface the self-gate measures is unchanged at 572 candidates, which is the check that makes "no score moves" mean something rather than sound reassuring. Nearly all of it was one line. Building the per-file AST index called a PowerShell function **once per node**, and a function with `[CmdletBinding()]` and mandatory parameters costs about 9us to invoke: 2,437ms against 62ms for the same work written inline, a factor of 39. That single call site was 62% of a scan. Two smaller things came with it: the collectors now ask for a type EXACTLY where that type has no subclass, instead of taking a path that sweeps every type in the file, unions and sorts; and the recursion check no longer walks up from every command in the file, because a command naming nothing defined in that file cannot be a call to its own enclosing function -- seven commands in eight. If you gate large repositories in CI, this is time back on every run. If you gate a handful of files, you will not notice it. **The declared PowerShell floor is now executed, not just declared.** The manifest says `PowerShellVersion = ''7.0''`; CI runs whatever the runners ship, which is 7.6.x, so that number had never been run. A new gate proves the module on one PowerShell per supported minor -- **7.0.13, 7.1.7, 7.2.24, 7.3.12, 7.4.19, 7.5.10** -- and all six pass. Each leg downloads the official release, imports the module under it, and requires the measured scores to match the host''s **row for row**, plus a ceiling below the fixture returning `$false`. So the claim is now that this module computes the same answers on 7.0 as on 7.6, rather than that somebody once believed it would. Nothing about the module changed. **The supported Pester range is now proven rather than asserted.** The manifest and README have always said Pester 5.0.0 or later; the gate that backs that claim ran exactly one version, 5.7.1, and had never once executed the floor. It now runs one leg per minor across the whole range -- **5.0.4, 5.1.1, 5.2.2, 5.3.3, 5.4.1, 5.5.0, 5.6.1, 5.7.1, 5.8.0, 5.9.1, 6.0.1, 6.1.0** -- and all twelve pass. Nothing about the module changed. What changed is that the number you are told is the number that gets exercised. **Pointed at the floor, the old gate reported the module broken.** It built its Pester configuration with `New-PesterConfiguration`, which did not exist until 5.1.0, so under 5.0.0 the command was not found, PowerShell autoloaded a newer Pester by name, and the two assemblies collided. The gate then blamed this module for an error that never mentioned it. If you ran it against 5.0.0 and believed the verdict, that is why. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
