# PSComplexity - cyclomatic + cognitive complexity for PowerShell.
# Dot-source the implementation (small, single-responsibility units) and export the
# public surface. Ast.ps1 provides the shared helpers the metric files depend on, so
# it loads first.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @('Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1')) {
    . (Join-Path $src $file)
}

Export-ModuleMember -Function @('Measure-PSComplexity', 'Test-PSComplexity')
