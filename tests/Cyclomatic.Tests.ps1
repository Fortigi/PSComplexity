# Cyclomatic complexity: 1 + decision points. Pinned against hand-counted fixtures.

$script:CyclomaticCases = @(
    @{ name = 'flat function = 1'; expected = 1; code = 'function T { param($x) $x + 1 }' }
    @{ name = 'single if = 2'; expected = 2; code = 'function T { param($a) if ($a) { 1 } }' }
    @{ name = 'if/elseif/else = 3 (else is not a clause)'; expected = 3; code = 'function T { param($a) if ($a -eq 1) { 1 } elseif ($a -eq 2) { 2 } else { 3 } }' }
    @{ name = 'while loop = 2'; expected = 2; code = 'function T { param($n) while ($n -gt 0) { $n-- } }' }
    @{ name = 'if with two -and = 4'; expected = 4; code = 'function T { param($a,$b,$c) if ($a -and $b -and $c) { 1 } }' }
    @{ name = 'foreach + if = 3'; expected = 3; code = 'function T { param($xs) foreach ($x in $xs) { if ($x) { 1 } } }' }
    # A ternary is one decision, like the if it stands in for. No case here used
    # one, so its increment could have been any number: a ternary scoring 2 would
    # inflate every unit that uses one, and PowerShell 7 code uses them freely.
    @{ name = 'ternary = 2'; expected = 2; code = 'function T { param($x) $x ? 1 : 2 }' }
    @{ name = 'ternary inside an if = 3'; expected = 3; code = 'function T { param($a,$x) if ($a) { $x ? 1 : 2 } }' }
)

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1') { . (Join-Path $src $f) }
    function script:Get-CyclomaticOf {
        param([string]$Code)
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "cxcyc-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $file $Code -Encoding utf8
        try { (Measure-PSComplexity -Path $file | Where-Object Unit -ne '<script-body>' | Select-Object -First 1).Cyclomatic }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Cyclomatic complexity - reference scores' {
    It 'cyclomatic of <name>' -ForEach $script:CyclomaticCases {
        Get-CyclomaticOf -Code $code | Should-Be $expected
    }
}
