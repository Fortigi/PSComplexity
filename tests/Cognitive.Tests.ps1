# Cognitive complexity is only trustworthy if it reproduces known scores. These cases
# pin exact values -- the SonarSource reference examples plus PowerShell-specific ones
# (labelled jumps, do-until, nested ternary, lambda nesting). If the metric drifts,
# these fail with the exact unit and number.

$script:CognitiveCases = @(
    @{ spec = 'Cognitive Complexity spec, Appendix C -- sumOfPrimes'; name = 'prime sieve: nested loops + labelled continue'; expected = 7; code = @'
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
    @{ spec = 'spec B1 -- switch takes ONE increment regardless of case count, unlike cyclomatic'; name = 'switch scores 1 (not per-case)'; expected = 1; code = @'
function Get-Words { param($n) switch ($n) { 1 { 'one' } 2 { 'couple' } default { 'lots' } } }
'@ }
    @{ spec = 'spec B1 -- recursion is a structural increment; Appendix A fibonacci'; name = 'recursive fibonacci (if + 2 recursive calls)'; expected = 3; code = @'
function Get-Fib { param($n) if ($n -le 1) { return $n }; return (Get-Fib ($n - 1)) + (Get-Fib ($n - 2)) }
'@ }
    @{ spec = 'spec B1 -- a sequence of like operators is ONE increment'; name = 'a -and b -and c is one run'; expected = 2; code = 'function T { param($a,$b,$c) if ($a -and $b -and $c) { 1 } }' }
    @{ spec = 'spec B1 -- one increment per CHANGE of operator. The classic implementation error'; name = 'a -and b -or c is two runs'; expected = 3; code = 'function T { param($a,$b,$c) if ($a -and $b -or $c) { 1 } }' }
    @{ spec = 'spec B3 -- a nested if takes its own increment plus the nesting level'; name = 'nested if (structural + nesting)'; expected = 3; code = 'function T { param($a,$b) if ($a) { if ($b) { 1 } } }' }
    # Paired deliberately: only the LABELLED jump adds a point. A fixture with just the
    # labelled case passes equally well against a rule that counts every break.
    @{ spec = 'spec B1 -- an unlabelled jump takes no increment'; name = 'bare break adds nothing beyond its loop'; expected = 1; code = 'function T { foreach ($i in 1..3) { break } }' }
    @{ spec = 'spec B1 -- a LABELLED jump takes one, with no nesting bonus'; name = 'labelled break adds one'; expected = 2; code = 'function T { :outer foreach ($i in 1..3) { break outer } }' }
    @{ spec = 'spec B2 -- else/else-if are +1 flat. The second classic implementation error'; name = 'else and elseif each add 1, no nesting bonus'; expected = 3; code = 'function T { param($a) if ($a -eq 1) { 1 } elseif ($a -eq 2) { 2 } else { 3 } }' }
    @{ spec = 'spec B1/B3 -- labelled jump inside nested loops'; name = 'labelled break'; expected = 4; code = 'function T { param($n) :L for ($i = 0; $i -lt $n; $i++) { if ($i -eq 3) { break L } } }' }
    @{ spec = 'spec B1 -- a loop takes one increment'; name = 'do-until loop'; expected = 1; code = 'function T { param($n) $i = 0; do { $i++ } until ($i -ge $n) }' }
    @{ spec = 'EXTENSION -- the spec has no ternary; scored as the if it stands in for'; name = 'nested ternary'; expected = 3; code = 'function T { param($x, $y) $x ? ($y ? 1 : 2) : 3 }' }
    # 3, not 2: ForEach-Object is itself an increment now, on top of the nesting its block
    # already gave the if. The keyword form below must score the SAME, which is the whole
    # claim -- and is why the two are listed together rather than apart.
    @{ spec = 'EXTENSION -- PowerShell pipeline flow the spec does not cover'; name = 'if inside ForEach-Object'; expected = 3; code = 'function T { param($items) $items | ForEach-Object { if ($_) { 1 } } }' }
    @{ spec = 'EXTENSION -- the pipeline form must cost what the keyword form costs'; name = 'if inside foreach keyword scores identically'; expected = 3; code = 'function T { param($items) foreach ($i in $items) { if ($i) { 1 } } }' }
    @{ spec = 'EXTENSION -- PowerShell pipeline flow the spec does not cover'; name = 'Where-Object is a conditional'; expected = 1; code = 'function T { param($items) $items | Where-Object { $_ -gt 0 } }' }
    @{ spec = 'EXTENSION -- pipeline chains follow the spec B1 run rule'; name = '&& is one run, like -and'; expected = 1; code = 'function T { a && b && c }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = '&& then || is two runs'; expected = 2; code = 'function T { a && b || c }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'null-coalescing is a conditional'; expected = 1; code = 'function T { param($a, $b) $x = $a ?? $b }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'null-coalescing ASSIGNMENT is a conditional too'; expected = 1; code = 'function T { param($a) $a ??= 1 }' }
    # A command invoked through a variable has no name a static walk can read. The flow-command
    # test must answer "no" rather than dereference it -- paired with the ForEach-Object cases
    # above, which are the "yes" side of the same predicate.
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'a command with no readable name is not flow'; expected = 0; code = 'function T { param($cmd) & $cmd arg }' }
    # NESTED, deliberately. At nesting 0 the increment is 1 + 0, which is indistinguishable
    # from 1 - 0: the arithmetic itself is only pinned when the nesting term is non-zero.
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'ForEach-Object nested in an if pays the nesting'; expected = 3; code = 'function T { param($a, $xs) if ($a) { $xs | ForEach-Object { $_ } } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'null-coalescing nested in an if pays the nesting'; expected = 3; code = 'function T { param($a, $x, $y) if ($a) { $z = $x ?? $y } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'null-coalescing assignment nested in an if pays the nesting'; expected = 3; code = 'function T { param($a, $x) if ($a) { $x ??= 1 } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'flat function scores 0'; expected = 0; code = 'function T { param($x) $y = $x + 1; return $y }' }
    # Every remaining entry in the cognitive block list, flat. Four of the eight type names
    # could be DELETED with the whole suite green: tests/ contained no `catch` and no `trap`
    # at all, and a do-until but no do-while.
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'while = 1'; expected = 1; code = 'function T { param($n) while ($n -gt 0) { $n-- } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'do-while = 1'; expected = 1; code = 'function T { param($n) do { $n-- } while ($n -gt 0) }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'catch = 1'; expected = 1; code = 'function T { try { 1 } catch { 2 } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'trap = 1'; expected = 1; code = 'function T { trap { continue } 1 }' }

    # And every entry in $script:PSCxNestingTypes, which is a DIFFERENT list and needs a
    # different shape: an `if` INSIDE the construct. "X inside an if" pins IfStatementAst's
    # membership, not X's -- the nesting bonus belongs to whatever encloses. Each of these is
    # construct(1) + if(1 + 1 nesting) = 3, and drops to 2 the moment the construct stops
    # raising nesting.
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'while raises nesting'; expected = 3; code = 'function T { param($n,$a) while ($n -gt 0) { if ($a) { 1 } } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'for raises nesting'; expected = 3; code = 'function T { param($a) for ($i = 0; $i -lt 3; $i++) { if ($a) { 1 } } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'do-while raises nesting'; expected = 3; code = 'function T { param($n,$a) do { if ($a) { 1 } } while ($n -gt 0) }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'do-until raises nesting'; expected = 3; code = 'function T { param($n,$a) do { if ($a) { 1 } } until ($n -le 0) }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'switch raises nesting'; expected = 3; code = 'function T { param($a,$b) switch ($a) { 1 { if ($b) { 2 } } } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'catch raises nesting'; expected = 3; code = 'function T { param($a) try { 1 } catch { if ($a) { 2 } } }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'trap raises nesting'; expected = 3; code = 'function T { param($a) trap { if ($a) { continue } } 1 }' }
    @{ spec = 'VOCABULARY -- pins a construct-list entry, not a reference score'; name = 'foreach raises nesting'; expected = 3; code = 'function T { param($xs,$a) foreach ($x in $xs) { if ($a) { 1 } } }' }
)

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }
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

Describe 'Test-PSCxFlowCommand' {
    BeforeAll {
        function Get-Node { param([string]$Code, [string]$Type)
            # Two parameters that must each be USED where the analyzer can see it: $Type in
            # the function body rather than inside a script block, which
            # PSReviewUnusedParameter cannot see through; and the predicate's own $x, which
            # a constant `$true` would declare and ignore.
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
            foreach ($n in $ast.FindAll({ param($x) $null -ne $x }, $true)) {
                if ($n.GetType().Name -eq $Type) { return $n }
            }
        }
    }

    It 'is true for the cmdlet and for its alias' {
        Test-PSCxFlowCommand -Node (Get-Node '$c | ForEach-Object { 1 }' 'CommandAst') | Should-BeTrue
        Test-PSCxFlowCommand -Node (Get-Node '$c | % { 1 }' 'CommandAst') | Should-BeTrue
    }

    It 'is false for an ordinary command' {
        # Paired with the case above: a predicate that always answered true would satisfy
        # the first test on its own.
        Test-PSCxFlowCommand -Node (Get-Node 'Get-Item .' 'CommandAst') | Should-BeFalse
    }

    It 'returns $false -- not $null -- for a node that is not a command at all' {
        # Should-BeFalse is STRICT in Pester 6: $null is falsy but is not $false, so this
        # pins the return VALUE and not merely its truthiness. FindAll's predicate contract
        # is a boolean, and every caller here passes this straight to it.
        Test-PSCxFlowCommand -Node (Get-Node '$x = 1' 'VariableExpressionAst') | Should-BeFalse
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

# Counted at DISCOVERY, where the case table exists. Inside an It body $script:CognitiveCases
# is out of scope and evaluates to nothing -- which made the first version of the attribution
# test pass over an empty collection. A vacuous pass, in the test written to stop exactly that.
$script:SpecCases = @($script:CognitiveCases | Where-Object { $_.spec -like 'spec*' -or $_.spec -like 'Cognitive Complexity spec*' })
$script:ExtensionCases = @($script:CognitiveCases | Where-Object { $_.spec -like 'EXTENSION*' })
$script:ClassicErrorCases = @($script:CognitiveCases | Where-Object { $_.spec -match 'classic implementation error' })

Describe 'every reference score is attributed to something outside this project' {
    # The README claims these reproduce the SonarSource scores. The suite checked numbers the
    # project had chosen itself, so if an interpretation were wrong the suite would agree with
    # the bug -- and so would the mutation gate, because both only ever compare the code
    # against itself. An attribution does not make a number right; it makes the claim
    # CHECKABLE by someone holding the specification.

    It 'attributes <name>' -ForEach $script:CognitiveCases {
        # One test per case, so a new case added without attribution fails by name. Nobody can
        # add a number this project chose and have it sit among the reference scores looking
        # like one of them.
        [string]::IsNullOrWhiteSpace($spec) | Should-BeFalse
    }

    It 'carries <Count> cases taken from the specification itself' -ForEach @(@{ Count = 11; Actual = $script:SpecCases.Count }) {
        $Actual | Should-Be $Count
    }

    It 'keeps <Count> case(s) the spec calls a classic implementation error' -ForEach @(@{ Count = 2; Actual = $script:ClassicErrorCases.Count }) {
        # Named rather than counted alone: these two are where implementations are known to
        # disagree -- one increment per CHANGE of boolean operator, and else/else-if flat with
        # no nesting bonus. If either regressed the score would stay entirely plausible.
        $Actual | Should-Be $Count
    }

    It 'keeps the PowerShell extensions distinguishable from the spec cases' -ForEach @(@{ Actual = $script:ExtensionCases.Count }) {
        # The extensions are not reference scores and must not be mistaken for them: the spec
        # says nothing about ForEach-Object or ??, so a disagreement there is a decision this
        # project owns rather than a bug against an external standard.
        $Actual | Should-BeGreaterThan 0
    }
}

Describe 'every increment says which construct produced it' {
    # The amounts used to be summed at emission, so the construct that caused an increment and
    # where it was were gone at the moment the increment was created rather than at the
    # boundary. #3 asks the pipeline for information the pipeline destroyed two layers below
    # where the question is asked -- which makes it an architectural change, not an addition.
    #
    # The maps stay projections over these rows, so the published output does not change and
    # summation happens exactly once, in the fold.

    BeforeAll {
        $script:AttrFile = Join-Path ([System.IO.Path]::GetTempPath()) "cxattr-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $script:AttrFile @'
function T {
    param($a, $b, $xs)
    foreach ($x in $xs) {
        if ($a -and $b) { 1 }
    }
}
'@ -Encoding utf8
        $script:AttrAst = [System.Management.Automation.Language.Parser]::ParseFile($script:AttrFile, [ref]$null, [ref]$null)
    }

    AfterAll { Remove-Item $script:AttrFile -Force -ErrorAction SilentlyContinue }

    It 'names the construct on every row' {
        $rows = @(Get-PSCxCogIfRow -Ast $script:AttrAst) + @(Get-PSCxCogBlockRow -Ast $script:AttrAst) +
                @(Get-PSCxCogBooleanRow -Ast $script:AttrAst)
        $unnamed = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Construct) })
        $unnamed.Count | Should-Be 0
        # And the names are the ones a reader would expect, not a placeholder.
        (@($rows | ForEach-Object { $_.Construct } | Sort-Object -Unique) -join ',') |
            Should-Be 'block,boolean-run,if'
    }

    It 'points each row at the line the construct is on' {
        # The `if` is on line 4 of the fixture and the `foreach` on line 3. Without a line a
        # diagnostic can only point at a unit, which is what the SARIF half of #5 needs and
        # cannot get from a per-unit total.
        (@(Get-PSCxCogIfRow -Ast $script:AttrAst)[0]).Line | Should-Be 4
        (@(Get-PSCxCogBlockRow -Ast $script:AttrAst)[0]).Line | Should-Be 3
    }

    It 'groups every row under the unit that produced it' {
        # Three rows for one unit, deliberately: a map that starts a fresh list per row keeps
        # only the LAST one, and a fixture whose unit has a single increment cannot tell the
        # two apart. The full breakdown is asserted rather than the count, so a row landing
        # under the wrong key fails here too.
        $map = Get-PSCxContributionMap -Ast $script:AttrAst
        $unit = @($map.Keys | Where-Object { $_ -notlike '<script-body>*' })[0]
        (@($map[$unit] | ForEach-Object { "$($_.Construct)@$($_.Line)+$($_.Amount)" }) -join ' ') |
            Should-Be 'block@3+1 boolean-run@4+1 if@4+2'
    }

    It 'accounts for exactly the points the summed map reports' {
        # The two projections over the same rows have to agree. This is what a consumer relies
        # on when it reads a breakdown next to a score -- and it is the check that fails if the
        # grouping drops a row on the way, which the summed map would not notice.
        $map = Get-PSCxContributionMap -Ast $script:AttrAst
        $sums = Get-PSCxCognitiveMap -Ast $script:AttrAst -UnitTable (Get-PSCxUnitTable -Ast $script:AttrAst)
        $unit = @($sums.Keys | Where-Object { $_ -notlike '<script-body>*' })[0]
        (($map[$unit] | Measure-Object Amount -Sum).Sum) | Should-Be $sums[$unit]
    }

    It 'keeps a unit with no increments out of the map entirely' {
        # The decision-free unit is absent HERE and empty at the published boundary. Two
        # different jobs: this map answers "which rows exist", and Measure-PSComplexity turns
        # a missing key into an empty list so a consumer never has to tell absent from empty.
        $map = Get-PSCxContributionMap -Ast $script:AttrAst
        @($map.Keys | Where-Object { $_ -like '<script-body>*' }).Count | Should-Be 0
    }

    It 'leaves the summed map exactly as it was' {
        # The point of keeping the maps as projections: the published number must not move
        # because the intermediate representation grew a field.
        $map = Get-PSCxCognitiveMap -Ast $script:AttrAst -UnitTable (Get-PSCxUnitTable -Ast $script:AttrAst)
        $unit = @($map.Keys | Where-Object { $_ -notlike '<script-body>*' })[0]
        # foreach(1) + if(1 + 1 nesting) + boolean run(1) = 4
        $map[$unit] | Should-Be 4
    }
}

Describe 'the invariant the unit-boundary list leans on' {
    # FunctionMemberAst sits in $script:PSCxUnitBoundaryTypes and no test could be made to fail
    # by removing it -- the leave-one-out sweep pins 28 of 29 entries, and this was the one.
    #
    # The reason is a PowerShell invariant rather than luck: a class member's body is its own
    # FunctionDefinitionAst, nested inside the member, so every walk up the parent chain meets
    # the body first and never needs the member's own type. That makes the entry defence against
    # a shape the parser does not currently produce.
    #
    # This is what makes that negative checkable. If the invariant ever stops holding, these fail
    # and the entry becomes load-bearing -- rather than the module quietly attributing a method's
    # decisions to the script body, which is a wrong number in the output.

    It 'wraps every class member body in its own FunctionDefinitionAst' -ForEach @(
        @{ Shape = 'instance method'; Code = 'class C { [int] M() { return 1 } }' }
        @{ Shape = 'empty method'; Code = 'class C { [void] M() { } }' }
        @{ Shape = 'constructor'; Code = 'class C { C() { } }' }
        @{ Shape = 'static constructor'; Code = 'class C { static C() { } }' }
        @{ Shape = 'static method'; Code = 'class C { static [int] M() { return 1 } }' }
        @{ Shape = 'hidden method'; Code = 'class C { hidden [int] M() { return 1 } }' }
        @{ Shape = 'override'; Code = 'class B { [int] M() { return 1 } } class D : B { [int] M() { return 2 } }' }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
        $members = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.FunctionMemberAst] }, $true))
        $members.Count | Should-BeGreaterThan 0
        foreach ($m in $members) {
            @($m.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count |
                Should-BeGreaterThan 0 -Because "$Shape must carry its body as a FunctionDefinitionAst"
        }
    }

    It 'reaches the body before the member from anywhere a decision can sit' {
        # Not only inside the body. A parameter default and a ValidateScript attribute look like
        # they live on the member rather than in it -- both were candidates for the case that
        # would make the entry load-bearing, and PowerShell folds both into the body scriptblock.
        $codes = @(
            'class C { [int] M([int]$a) { if ($a) { return 1 } return 2 } }'
            'class C { [int] M([int]$a = ($true ? 1 : 2)) { return $a } }'
            'class C { [int] M([ValidateScript({ if ($_) { $true } else { $false } })][int]$a) { return $a } }'
        )
        foreach ($code in $codes) {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
            $nodes = @($ast.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.IfStatementAst] -or
                        $n -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true))
            $nodes.Count | Should-BeGreaterThan 0
            foreach ($n in $nodes) {
                $p = $n.Parent
                $first = '<none>'
                while ($p) {
                    $tn = $p.GetType().Name
                    if ($tn -in 'FunctionDefinitionAst', 'FunctionMemberAst', 'PropertyMemberAst') { $first = $tn; break }
                    $p = $p.Parent
                }
                $first | Should-Be 'FunctionDefinitionAst' -Because "reaching $first first would make the FunctionMemberAst entry load-bearing"
            }
        }
    }

    It 'still attributes a class method to the member, which is what the entry protects' {
        # The behaviour the invariant serves. A method's decisions belong to C.M, not to the
        # script body -- that is the answer that would silently change if the boundary handling
        # were wrong.
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "cxb-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $f 'class C { [int] M([int]$a) { if ($a) { return 1 } return 2 } }' -Encoding utf8
        try {
            $u = @(Measure-PSComplexity -Path $f | Where-Object Unit -eq 'C.M')
            $u.Count | Should-Be 1
            $u[0].Cyclomatic | Should-Be 2
        }
        finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}
