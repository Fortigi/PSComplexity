# Dogfood: PSComplexity measures its own source and gates itself at <= 15 on both
# metrics -- the same bar it exists to enforce for others.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1') { . (Join-Path $src $f) }
    $script:units = @(Measure-PSComplexity -Path $src -Recurse)
}

Describe 'Self complexity gate' {
    It 'measured its own units' {
        $script:units.Count | Should -BeGreaterThan 0
    }
    It 'has no unit over cyclomatic 15' {
        $over = @($script:units | Where-Object Cyclomatic -gt 15)
        $detail = ($over | ForEach-Object { "$($_.Unit)=$($_.Cyclomatic)" }) -join ', '
        $over.Count | Should -Be 0 -Because "over cyclomatic 15: $detail"
    }
    It 'has no unit over cognitive 15' {
        $over = @($script:units | Where-Object Cognitive -gt 15)
        $detail = ($over | ForEach-Object { "$($_.Unit)=$($_.Cognitive)" }) -join ', '
        $over.Count | Should -Be 0 -Because "over cognitive 15: $detail"
    }
}
