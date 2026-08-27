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
            ReleaseNotes = '0.5.0: **The minimum PowerShell version is now 7.0, down from 7.2.** The old floor was set in the first commit and never justified; nothing in the module needed it. The real constraint is 7.0, and it is a hard one: the metric scores `&&`, `||`, `??`, `??=` and the ternary, the AST types for those arrived with the operators themselves in 7.0, and their type names are referenced directly -- an unresolvable type literal is a parse-time failure, so an older host cannot load the module at all rather than degrading quietly. **The floor is still a claim rather than a checked fact**, and that is worth saying plainly: no CI leg runs on 7.0. `PSUseCompatibleTypes` was tried as a proof and rejected -- against a 7.0 profile it reports clean on `[System.DateOnly]`, `[System.Half]` and `Get-Error` alike, so a clean result from it means nothing at all. **BEHAVIOUR CHANGE -- the gate now refuses a path it could not read.** `Test-PSComplexity` given a good path and a mistyped one used to return `$true`: the empty-scan guard counts UNITS, so one valid path masked any number of missing ones, and the error behind it never reached your `-ErrorVariable`. A green gate over a path that does not exist is the failure this module exists to find in other people''s code. It now throws, naming each path and whether it is missing or simply holds no PowerShell. If a build of yours goes red on upgrading, the gate was measuring less than you thought it was. `Measure-PSComplexity` reports a path that is NOT THERE on the error stream; a path that is there and simply holds no PowerShell stays an ordinary empty measurement, because that command applies no thresholds. The JSON report gains an `unmatched` array beside `skipped`; it is not required by the schema, so a v1 report written before this field existed is still valid v1. **A file that could not be READ is no longer called a parse error.** A missing file, a directory, a permission denial and a file deleted mid-scan all arrived labelled `parse error:`, and the gate advised "Fix the syntax" for a file that was merely gone. Skips now read `could not be read:` or `parse error:`, and the gate says "could not measure" and "Fix the fault named". **Paths now bind by property name.** `Get-ChildItem | Measure-PSComplexity` worked only by coercion; anything carrying its path as a property -- what `Select-Object` and `Where-Object` hand you -- measured NOTHING, silently. Both commands accept `-Path` by value and by property name, with `FullName` aliased onto it. `PSPath` is deliberately not aliased: it is provider-qualified, and normalising one would undo the portable `File` identity 0.4.0 introduced. **Measurement is about 2.6x faster and no score moves.** The metrics made 34 full AST traversals per file, 52 with `-Detailed`; the pass that already computes each unit and its nesting now records the type of each node, and the collectors read that index instead -- 2 traversals. `-Detailed` now costs essentially nothing over a plain run, where it used to add about 12%. Output is byte-identical over 384 unit records including the `-Detailed` contributions, and `metricVersion` stays 1. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
