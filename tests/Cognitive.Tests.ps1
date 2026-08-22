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
    # Paired deliberately: only the LABELLED jump adds a point. A fixture with just the
    # labelled case passes equally well against a rule that counts every break.
    @{ name = 'bare break adds nothing beyond its loop'; expected = 1; code = 'function T { foreach ($i in 1..3) { break } }' }
    @{ name = 'labelled break adds one'; expected = 2; code = 'function T { :outer foreach ($i in 1..3) { break outer } }' }
    @{ name = 'else and elseif each add 1, no nesting bonus'; expected = 3; code = 'function T { param($a) if ($a -eq 1) { 1 } elseif ($a -eq 2) { 2 } else { 3 } }' }
    @{ name = 'labelled break'; expected = 4; code = 'function T { param($n) :L for ($i = 0; $i -lt $n; $i++) { if ($i -eq 3) { break L } } }' }
    @{ name = 'do-until loop'; expected = 1; code = 'function T { param($n) $i = 0; do { $i++ } until ($i -ge $n) }' }
    @{ name = 'nested ternary'; expected = 3; code = 'function T { param($x, $y) $x ? ($y ? 1 : 2) : 3 }' }
    # 3, not 2: ForEach-Object is itself an increment now, on top of the nesting its block
    # already gave the if. The keyword form below must score the SAME, which is the whole
    # claim -- and is why the two are listed together rather than apart.
    @{ name = 'if inside ForEach-Object'; expected = 3; code = 'function T { param($items) $items | ForEach-Object { if ($_) { 1 } } }' }
    @{ name = 'if inside foreach keyword scores identically'; expected = 3; code = 'function T { param($items) foreach ($i in $items) { if ($i) { 1 } } }' }
    @{ name = 'Where-Object is a conditional'; expected = 1; code = 'function T { param($items) $items | Where-Object { $_ -gt 0 } }' }
    @{ name = '&& is one run, like -and'; expected = 1; code = 'function T { a && b && c }' }
    @{ name = '&& then || is two runs'; expected = 2; code = 'function T { a && b || c }' }
    @{ name = 'null-coalescing is a conditional'; expected = 1; code = 'function T { param($a, $b) $x = $a ?? $b }' }
    @{ name = 'null-coalescing ASSIGNMENT is a conditional too'; expected = 1; code = 'function T { param($a) $a ??= 1 }' }
    # A command invoked through a variable has no name a static walk can read. The flow-command
    # test must answer "no" rather than dereference it -- paired with the ForEach-Object cases
    # above, which are the "yes" side of the same predicate.
    @{ name = 'a command with no readable name is not flow'; expected = 0; code = 'function T { param($cmd) & $cmd arg }' }
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
        Get-CognitiveOf -Code $code | Should-Be $expected
    }
}

Describe 'Cognitive complexity - class members' {
    BeforeAll {
        function script:Get-UnitCognitive {
            param([string]$Code, [string]$Unit)
            $file = Join-Path ([System.IO.Path]::GetTempPath()) "cxcls-$([System.Guid]::NewGuid().ToString('N')).ps1"
            Set-Content $file $Code -Encoding utf8
            try { (Measure-PSComplexity -Path $file | Where-Object Unit -eq $Unit).Cognitive }
            finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'counts an instance method calling itself through $this as recursion' {
        # A method cannot recurse by bare command name, so the function-recursion
        # collector never sees this. Without the member-invocation rule the if is
        # the only increment and the score is 1.
        $code = 'class C { [int] Walk($o) { if ($o) { return $this.Walk($o.Next) } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Walk' | Should-Be 2
    }

    It 'counts a static method calling itself through the class name' {
        $code = 'class C { static [int] Helper($o) { if ($o) { return [C]::Helper($o.Next) } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Helper' | Should-Be 2
    }

    It 'does not count a call to the SAME method name on another object' {
        # $other.Walk() is a different object's method. Only the if counts.
        $code = 'class C { [int] Walk($o) { if ($o) { return $o.Walk(1) } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Walk' | Should-Be 1
    }

    It 'does not count a call to a DIFFERENT method on $this' {
        $code = 'class C { [int] Walk($o) { if ($o) { return $this.Other(1) } return 0 } [int] Other($x) { return 1 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Walk' | Should-Be 1
    }

    It 'does not count a same-named static method on a DIFFERENT class' {
        $code = 'class D { static [int] Helper($x) { return 1 } }
class C { static [int] Helper($o) { if ($o) { return [D]::Helper(1) } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Helper' | Should-Be 1
    }

    It 'does not count a same-named call on the result of an expression' {
        # The target is neither $this nor a type name, so it cannot be known to be
        # this object -- (...).Walk() is a call on whatever that expression returned.
        $code = 'class C { [int] Walk($o) { if ($o) { return (Get-Item .).Walk(1) } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Walk' | Should-Be 1
    }

    It 'does not treat a plain function as the enclosing method' {
        # The enclosing-method lookup must return $null for a FUNCTION boundary. If it
        # returns the function instead, `$this.Walk()` inside a function named Walk is
        # read as method recursion and scores 1 where it should score 0.
        $code = 'function Walk { $this.Walk() }'
        Get-UnitCognitive -Code $code -Unit 'Walk' | Should-Be 0
    }

    It 'ignores a DYNAMIC member name outside any class' {
        # $this.$m() has no literal member name, so the name comparison below the guard
        # cannot reject it -- only the "no enclosing method" guard can. Without that
        # guard this scores 1.
        $code = 'function Outer { $this.$m() }'
        Get-UnitCognitive -Code $code -Unit 'Outer' | Should-Be 0
    }

    It 'ignores a member invocation outside any class' {
        # Guards the "no enclosing method" path: without it the rule dereferences
        # $null looking for a method name.
        $code = '$o = Get-Item .; $o.Refresh()'
        Get-UnitCognitive -Code $code -Unit '<script-body>' | Should-Be 0
    }

    It 'does not treat a bare command matching the method name as recursion' {
        # Inside a method, `Walk` is a command lookup, never a call to the method.
        # The method body is itself a FunctionDefinitionAst named Walk, so reading
        # the enclosing FUNCTION name here would score a phantom recursive call.
        $code = 'class C { [int] Walk($o) { if ($o) { Walk } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Walk' | Should-Be 1
    }

    It 'still counts recursion for a plain function of the same shape' {
        $code = 'function Walk { param($o) if ($o) { return (Walk $o.Next) } return 0 }'
        Get-UnitCognitive -Code $code -Unit 'Walk' | Should-Be 2
    }

    It 'measures nesting inside a method from the method boundary, not the class' {
        # if(+1) > if(+2) > foreach(+3) > if(+4) = 10, exactly as the same body
        # scores in a plain function.
        $code = 'class C { [int] Process($o) { if ($o.A) { if ($o.B) { foreach ($x in $o.C) { if ($x) { return 1 } } } } return 0 } }'
        Get-UnitCognitive -Code $code -Unit 'C.Process' | Should-Be 10
    }

    It 'attributes a property initialiser to the property, not the script body' {
        $code = 'class C { [int] $Threshold = $(if ($env:X) { 5 } else { 1 }) }'
        Get-UnitCognitive -Code $code -Unit 'C.Threshold'  | Should-Be 2
        Get-UnitCognitive -Code $code -Unit '<script-body>' | Should-Be 0
    }
}

Describe 'Test-PSCxLogicalRunStart' {
    It 'flags the outer node of a same-operator chain as the single run start' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('$a -and $b -and $c', [ref]$null, [ref]$null)
        $bins = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
        @($bins | Where-Object { Test-PSCxLogicalRunStart -Node $_ }).Count | Should-Be 1
    }
    It 'is false for a non-logical operator' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('$a + $b', [ref]$null, [ref]$null)
        $bin = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)[0]
        Test-PSCxLogicalRunStart -Node $bin | Should-BeFalse
    }
}
