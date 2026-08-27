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
            ReleaseNotes = '0.5.0: **The minimum PowerShell version is now 7.0, down from 7.2.** The old floor was set in the first commit and never justified; nothing in the module needed it. The real constraint is 7.0, and it is a hard one: the metric scores `&&`, `||`, `??`, `??=` and the ternary, the AST types for those arrived with the operators themselves in 7.0, and their type names are referenced directly -- an unresolvable type literal is a parse-time failure, so an older host cannot load the module at all rather than degrading quietly. **The gate no longer passes over a path it could not read.** a gate given a good path and a mistyped one returned `$true`: the empty-scan guard counts UNITS, so one valid path masked any number of missing ones, and the underlying Get-ChildItem error never reached -ErrorVariable in the calling scope. The scan now records every requested path that produced no source file, and the gate refuses the run naming each one. `Measure-PSComplexity` reports a path that is NOT THERE on the error stream; a path that exists and simply holds no PowerShell stays an ordinary empty measurement, because that command applies no thresholds. The JSON report gains an `unmatched` array beside `skipped` -- not required in the schema, so a v1 report written before it is still valid v1. **An unreadable file is no longer called a parse error.** ParseFile reports a missing file, a directory, a permission denial and a file deleted mid-scan through the same out-parameter as a syntax error; all of them read `parse error:` and the gate advised "Fix the syntax" for a file that was merely gone. Skips are now discriminated on ErrorId and read `could not be read:` or `parse error:`. **Paths now bind by property name.** `Get-ChildItem | Measure-PSComplexity` worked only by coercion through ToString(); anything carrying its path as a property measured NOTHING, silently. Both commands declare ValueFromPipelineByPropertyName with FullName aliased onto -Path. PSPath is deliberately not aliased -- it is provider-qualified, and normalising one would reintroduce the identity bug 0.4.0 fixed. **Measurement is about 2.6x faster, and no score moves.** The metrics made 34 full AST traversals per file (52 with -Detailed), each invoking a PowerShell predicate per node; the pre-order pass that already computes unit and nesting now records the type of each node, and the collectors read buckets -- 2 traversals. Interleaved A/B against 0.5.0 over the same corpus: 1.73s to 0.70s CPU, and with -Detailed 1.95s to 0.69s -- -Detailed now costs essentially nothing over a plain run. Output is byte-identical over 384 unit records including the -Detailed contributions, and metricVersion stays 1. **Documentation:** Test-PSComplexity gained the .DESCRIPTION it never had, and both commands gained .INPUTS, .LINK and further examples. Otherwise, for the floor change specifically: If you are already on 7.2 or newer, this release is identical to 0.4.0 in behaviour. **The floor is still a claim rather than a checked fact**, and that is worth saying plainly: no CI leg runs on 7.0. `PSUseCompatibleTypes` was tried as a proof and rejected -- against a 7.0 profile it reports clean on `[System.DateOnly]`, `[System.Half]` and `Get-Error` alike, so a clean result from it means nothing at all. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
