@{
    RootModule           = 'PSComplexity.psm1'
    ModuleVersion        = '0.5.2'
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
            ReleaseNotes = '0.5.2: **The SARIF log is now accepted by GitHub Advanced Security for Azure DevOps, and the README shows how to run the gate on Azure Pipelines.** Checked with the SARIF validator''s Azure DevOps and GitHub Advanced Security rule sets, the log failed two rules and now passes them: the tool carries a `fullName` (name and version), which Azure DevOps requires, and each rule carries a `help` text, which GitHub Advanced Security requires. Nothing else in the log changed -- same rules, same results, same fingerprints -- so existing alerts are not reopened. One rule is left failing on purpose: the log carries no `automationDetails`, i.e. no category. On GitHub a category in the file overrides the one the upload step names, so writing one would make two PSComplexity uploads in one repository replace each other. **On Azure DevOps, set `Category` on `AdvancedSecurity-Publish@1`**; that is where it comes from. New in the README, with a complete `examples/azure-pipelines.yml`: the gate on Azure Pipelines, publishing the SARIF to Advanced Security or -- without it -- to the *SARIF SAST Scans Tab* extension, why the publishing step needs `condition: succeededOrFailed()`, and how to gate a pull request on the files it changed when Azure Pipelines checks out shallow and detached. **Three internal lookups return an empty array rather than `$null`.** PowerShell unrolls a returned collection, so an empty result reached the caller as `$null` and a single result as a bare item, although one of them documented the opposite. Every caller iterated with `foreach`, which forgives both, so no measurement was ever wrong; a future caller using a pipeline would have run its body once over `$null`. No score moves and no command changed. Full changelog: https://github.com/Fortigi/PSComplexity/blob/main/CHANGELOG.md'
        }
    }
}
