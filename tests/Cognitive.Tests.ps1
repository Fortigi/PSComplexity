# Cognitive complexity is only trustworthy if it reproduces known scores. These cases
# pin exact values -- the SonarSource reference examples plus PowerShell-specific ones
# (labelled jumps, do-until, nested ternary, lambda nesting). If the metric drifts,
# these fail with the exact unit and number.

$script:CognitiveCases = @(
    @{ name = 'prime sieve: nested loops + labelled continue'; expected = 7; code = @'
function Get-SumOfPrimes {
    param($max)
    $total = 0
    :OUT for ($i = 2; $i -le $max; $i++) {
        for ($j = 2; $j -lt $i; $j++) {
            if ($i % $j -eq 0) {
                continue OUT
            }
        }
        $total += $i
    }
    return $total
}
'@ }
    @{ name = 'switch scores 1 (not per-case)'; expected = 1; code = @'
function Get-Words { param($n) switch ($n) { 1 { 'one' } 2 { 'couple' } default { 'lots' } } }
'@ }
    @{ name = 'recursive fibonacci (if + 2 recursive calls)'; expected = 3; code = @'
function Get-Fib { param($n) if ($n -le 1) { return $n }; return (Get-Fib ($n - 1)) + (Get-Fib ($n - 2)) }
'@ }
    @{ name = 'a -and b -and c is one run'; expected = 2; code = 'function T { param($a,$b,$c) if ($a -and $b -and $c) { 1 } }' }
    @{ name = 'a -and b -or c is two runs'; expected = 3; code = 'function T { param($a,$b,$c) if ($a -and $b -or $c) { 1 } }' }
    @{ name = 'nested if (structural + nesting)'; expected = 3; code = 'function T { param($a,$b) if ($a) { if ($b) { 1 } } }' }
    @{ name = 'else and elseif each add 1, no nesting bonus'; expected = 3; code = 'function T { param($a) if ($a -eq 1) { 1 } elseif ($a -eq 2) { 2 } else { 3 } }' }
    @{ name = 'labelled break'; expected = 4; code = 'function T { param($n) :L for ($i = 0; $i -lt $n; $i++) { if ($i -eq 3) { break L } } }' }
    @{ name = 'do-until loop'; expected = 1; code = 'function T { param($n) $i = 0; do { $i++ } until ($i -ge $n) }' }
    @{ name = 'nested ternary'; expected = 3; code = 'function T { param($x, $y) $x ? ($y ? 1 : 2) : 3 }' }
    @{ name = 'lambda raises nesting (if inside ForEach-Object)'; expected = 2; code = 'function T { param($items) $items | ForEach-Object { if ($_) { 1 } } }' }
    @{ name = 'flat function scores 0'; expected = 0; code = 'function T { param($x) $y = $x + 1; return $y }' }
)

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1') { . (Join-Path $src $f) }
    function script:Get-CognitiveOf {
        param([string]$Code)
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "cxcog-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $file $Code -Encoding utf8
        try { (Measure-PSComplexity -Path $file | Where-Object Unit -ne '<script-body>' | Select-Object -First 1).Cognitive }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Cognitive complexity - reference scores' {
    It 'cognitive of <name> = <expected>' -ForEach $script:CognitiveCases {
        Get-CognitiveOf -Code $code | Should -Be $expected
    }
}

Describe 'Test-PSCxLogicalRunStart' {
    It 'flags the outer node of a same-operator chain as the single run start' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('$a -and $b -and $c', [ref]$null, [ref]$null)
        $bins = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
        @($bins | Where-Object { Test-PSCxLogicalRunStart -Node $_ }).Count | Should -Be 1
    }
    It 'is false for a non-logical operator' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('$a + $b', [ref]$null, [ref]$null)
        $bin = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)[0]
        Test-PSCxLogicalRunStart -Node $bin | Should -BeFalse
    }
}
