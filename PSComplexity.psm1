# PSComplexity - cyclomatic + cognitive complexity for PowerShell.
# Dot-source the implementation (small, single-responsibility units) and export the
# public surface.
#
# The ORDER is a readable convention, not a constraint: every cross-file reference sits
# inside a function body and resolves at call time, so loading these files in reverse
# produces byte-identical output over this repo's own source. tests/Layering.Tests.ps1 is
# what enforces the direction.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @(
        # What the code scores: the AST, the metrics, what a scan reads and gathers.
        'Ast.ps1'
        'Cyclomatic.ps1'
        'Cognitive.ps1'
        'Size.ps1'
        'InlineAccept.ps1'
        'Diff.ps1'
        'Scan.ps1'
        # What a run decides and writes: the policy, the reports, the files behind them.
        'Policy.ps1'
        'Report.ps1'
        'Markdown.ps1'
        'BaselineFile.ps1'
        'Config.ps1'
        'ConfigFile.ps1'
        # The entry points: the editor rule and the two public commands.
        'AnalyzerRule.ps1'
        'Measure-PSComplexity.ps1'
    )) {
    . (Join-Path $src $file)
}

Export-ModuleMember -Function @('Measure-PSComplexity', 'Test-PSComplexity')
