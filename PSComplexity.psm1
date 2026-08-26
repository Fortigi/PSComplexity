# PSComplexity - cyclomatic + cognitive complexity for PowerShell.
# Dot-source the implementation (small, single-responsibility units) and export the
# public surface.
#
# The ORDER is a readable convention, not a constraint: every cross-file reference sits
# inside a function body and resolves at call time, so loading these four in reverse
# produces byte-identical output over this repo's own source. Verified, because this file
# used to claim Ast.ps1 had to load first and a reader could have refused a sensible change
# on the strength of it.

$src = Join-Path $PSScriptRoot 'src'
foreach ($file in @('Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Policy.ps1', 'Report.ps1', 'BaselineFile.ps1', 'Measure-PSComplexity.ps1')) {
    . (Join-Path $src $file)
}

Export-ModuleMember -Function @('Measure-PSComplexity', 'Test-PSComplexity')
