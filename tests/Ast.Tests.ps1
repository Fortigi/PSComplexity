# The AST walk: what a unit is, what it is called, and how deep a node sits inside it.
#
# The COVERING SUITE for src/Ast.ps1, and cheap on purpose -- everything here parses a string and
# calls a function. Nothing writes a file or measures a directory.
#
# That is the whole reason it exists. Ast.ps1 was mapped to Cognitive.Tests.ps1 AND
# Measure.Tests.ps1 and paid for both on every one of its 57 mutants, at roughly 22s a mutant --
# 39% of the entire gate, for a file whose functions never touch a disk. Measured, not assumed.
#
# Dropping the second suite instead was tried first and is provably wrong: with Cognitive.Tests
# alone the score falls to 84% AND the mutant set shrinks from 57 to 50, because coveredLinesOnly
# sees fewer covered lines. A smaller set scoring the same is exactly the failure this project
# exists to find. So the eight mutants only the expensive suite killed are covered HERE instead,
# directly -- all eight are in the naming and identity functions, which Cognitive.Tests never
# exercised because it tests scores rather than names.
#
# The end-to-end proofs did not move: tests/Measure.Tests.ps1 still drives all of this through
# Measure-PSComplexity. Covering a function is not covering its application.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    function script:Tree { param([string]$Code)
        return [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
    }
    function script:Nodes { param($Ast, [string]$TypeName)
        # Collect everything, then filter. The obvious form puts $TypeName inside the FindAll
        # predicate and needs .GetNewClosure() to bind it -- which the analyzer cannot see
        # through, so it reports the parameter as unused. Filtering outside the predicate keeps
        # the reference where both PowerShell and PSScriptAnalyzer can find it.
        return @($Ast.FindAll({ param($n) $null -ne $n }, $true) |
                Where-Object { $_.GetType().Name -eq $TypeName })
    }
    function script:FirstNode { param($Ast, [string]$TypeName) return (Nodes $Ast $TypeName)[0] }
    # Unit names carry an @offset suffix, which is deliberate and unstable across fixtures.
    function script:Bare { param([string]$Name) return ($Name -replace '@\d+$', '') }
}

Describe 'Resolve-PSCxUnitBoundary' {
    It 'returns a plain function unchanged' {
        $fn = FirstNode (Tree 'function Get-Thing { 1 }') 'FunctionDefinitionAst'
        [object]::ReferenceEquals((Resolve-PSCxUnitBoundary -Boundary $fn), $fn) | Should-BeTrue
    }

    It 'resolves a method body up to the MEMBER that knows the class name' {
        # A class method's body is itself a FunctionDefinitionAst nested inside the
        # FunctionMemberAst. Both own a body, so without this the same method is discovered
        # twice, once unqualified.
        $t = Tree 'class Widget { [int] Render() { return 1 } }'
        $body = FirstNode $t 'FunctionDefinitionAst'
        (Resolve-PSCxUnitBoundary -Boundary $body).GetType().Name | Should-Be 'FunctionMemberAst'
    }
}

Describe 'Get-PSCxUnitBoundary' {
    It 'finds the nearest enclosing function' {
        $t = Tree 'function Get-Thing { if ($x) { 1 } }'
        (Get-PSCxUnitBoundary -Node (FirstNode $t 'IfStatementAst')).Name | Should-Be 'Get-Thing'
    }

    It 'returns nothing for code at file scope' {
        # Paired with the case above: top-level code has no owner, and that is what makes
        # <script-body> a unit rather than an error.
        $t = Tree 'if ($x) { 1 }'
        Get-PSCxUnitBoundary -Node (FirstNode $t 'IfStatementAst') | Should-BeNull
    }

    It 'stops at the NEAREST owner, not the outermost' {
        $t = Tree 'function Outer { function Inner { if ($x) { 1 } } }'
        (Get-PSCxUnitBoundary -Node (FirstNode $t 'IfStatementAst')).Name | Should-Be 'Inner'
    }
}

Describe 'Get-PSCxDisplayName' {
    # Where the gate's most expensive coverage gap was. Three of the eight mutants that only
    # Measure.Tests.ps1 killed live in this function, and all three are about the ORDINAL that
    # disambiguates same-named units.

    It 'leaves a unique name alone' {
        $out = Get-PSCxDisplayName -OrderedKeys @('Get-A@0', 'Get-B@10')
        $out['Get-A@0'] | Should-Be 'Get-A'
        $out['Get-B@10'] | Should-Be 'Get-B'
    }

    It 'suffixes EVERY member of a duplicate group, the first one included' {
        # Were only the second suffixed, adding an overload would silently rename the first --
        # and a baseline keyed on the name would then describe a different unit.
        $out = Get-PSCxDisplayName -OrderedKeys @('Get-A@0', 'Get-A@10')
        $out['Get-A@0'] | Should-Be 'Get-A#1'
        $out['Get-A@10'] | Should-Be 'Get-A#2'
    }

    It 'numbers a group of two, which is the boundary' {
        # The count test is -gt 1. Written -gt 2 a PAIR gets no ordinal at all and the two units
        # merge under one name; that mutant survives any fixture with three or more duplicates,
        # so the discriminating group size is exactly two.
        $out = Get-PSCxDisplayName -OrderedKeys @('Dup@0', 'Dup@5')
        @($out.Values | Sort-Object) -join ',' | Should-Be 'Dup#1,Dup#2'
    }

    It 'counts UP, so a group of three numbers 1, 2, 3' {
        # The running count is `1 + [int]$counts[...]`. Flip that + to - and the counts go
        # negative, -gt 1 is never true, and no group is ever numbered.
        $out = Get-PSCxDisplayName -OrderedKeys @('Dup@0', 'Dup@5', 'Dup@9')
        @($out.Values | Sort-Object) -join ',' | Should-Be 'Dup#1,Dup#2,Dup#3'
    }

    It 'groups on the bare name, ignoring the offset suffix' {
        # The keys differ (@0, @5) and the names do not. Strip the wrong thing and nothing is
        # ever a duplicate.
        (Get-PSCxDisplayName -OrderedKeys @('Same@0', 'Same@5')).Values |
            Should-NotContainCollection 'Same'
    }

    It 'keeps distinct names distinct even when one group repeats' {
        $out = Get-PSCxDisplayName -OrderedKeys @('Dup@0', 'Dup@5', 'Solo@9')
        $out['Solo@9'] | Should-Be 'Solo'
    }

    It 'returns an empty map for no keys' {
        (Get-PSCxDisplayName -OrderedKeys @()).Count | Should-Be 0
    }
}

Describe 'Get-PSCxUnitOwnName' {
    It 'names a function by its own name' {
        $fn = FirstNode (Tree 'function Get-Thing { 1 }') 'FunctionDefinitionAst'
        Get-PSCxUnitOwnName -Boundary $fn | Should-Be 'Get-Thing'
    }

    It 'qualifies a class member with its class' {
        $m = FirstNode (Tree 'class Widget { [int] Render() { return 1 } }') 'FunctionMemberAst'
        Get-PSCxUnitOwnName -Boundary $m | Should-Be 'Widget.Render'
    }

    It 'names a constructor after its class, twice' {
        $m = FirstNode (Tree 'class Order { Order() { $this.X = 1 } }') 'FunctionMemberAst'
        Get-PSCxUnitOwnName -Boundary $m | Should-Be 'Order.Order'
    }
}

Describe 'Get-PSCxUnitName' {
    It 'qualifies a nested function with the one enclosing it' {
        # A bare name is not unique: Get-Inner defined inside two different outer functions
        # produced two rows reading the same, so anything keyed on the name merged them.
        $t = Tree 'function Outer { function Inner { 1 } }'
        $inner = @(Nodes $t 'FunctionDefinitionAst' | Where-Object Name -eq 'Inner')[0]
        Bare (Get-PSCxUnitName -Boundary $inner) | Should-Be 'Outer/Inner'
    }

    It 'does not qualify a top-level function with anything' {
        $fn = FirstNode (Tree 'function Solo { 1 }') 'FunctionDefinitionAst'
        Bare (Get-PSCxUnitName -Boundary $fn) | Should-Be 'Solo'
    }

    It 'never names a class method twice, although its body is a unit owner too' {
        # The walk resolves each enclosing owner before comparing, so the member and its own
        # body do not both contribute. Unresolved, this reads 'Widget.Render/Widget.Render'.
        $m = FirstNode (Tree 'class Widget { [int] Render() { return 1 } }') 'FunctionMemberAst'
        Bare (Get-PSCxUnitName -Boundary $m) | Should-Be 'Widget.Render'
    }

    It 'qualifies a function nested inside a class method' {
        $t = Tree 'class Widget { [int] Render() { function Helper { 1 } ; return 1 } }'
        $h = @(Nodes $t 'FunctionDefinitionAst' | Where-Object Name -eq 'Helper')[0]
        Bare (Get-PSCxUnitName -Boundary $h) | Should-Be 'Widget.Render/Helper'
    }

    It 'suffixes the START OFFSET, so two units on ONE line stay distinct' {
        # A line is not unique. Two functions written on one physical line shared a key and had
        # their scores ADDED, so the file reported a unit that exists nowhere in the source.
        $t = Tree 'function A { 1 } ; function B { 2 }'
        $names = @(Nodes $t 'FunctionDefinitionAst' | ForEach-Object { Get-PSCxUnitName -Boundary $_ })
        @($names | Sort-Object -Unique).Count | Should-Be 2
        $names[0] | Should-MatchString '@\d+$'
    }
}

Describe 'Get-PSCxUnitKey' {
    It 'is the unit name inside a function' {
        $t = Tree 'function Get-Thing { if ($x) { 1 } }'
        Bare (Get-PSCxUnitKey -Node (FirstNode $t 'IfStatementAst')) | Should-Be 'Get-Thing'
    }

    It 'is the script-body key for code outside any unit' {
        # The name avoids angle brackets on purpose: Pester 6 reads <...> in a test name as a
        # -ForEach placeholder and fails to build the block.
        # The paired half, and the one that matters: forcing the boundary test true means no
        # node is ever attributed to the script body, so top-level decisions land on whichever
        # unit happens to be nearby.
        $t = Tree 'if ($x) { 1 }'
        Get-PSCxUnitKey -Node (FirstNode $t 'IfStatementAst') | Should-Be '<script-body>'
    }
}

Describe 'Get-PSCxNesting' {
    It 'is zero for a decision directly inside a unit' {
        $t = Tree 'function F { if ($x) { 1 } }'
        Get-PSCxNesting -Node (FirstNode $t 'IfStatementAst') | Should-Be 0
    }

    It 'counts each nesting-raising ancestor' {
        $t = Tree 'function F { if ($a) { if ($b) { if ($c) { 1 } } } }'
        $inner = @(Nodes $t 'IfStatementAst')[-1]
        Get-PSCxNesting -Node $inner | Should-Be 2
    }

    It 'stops at the unit boundary rather than counting through it' {
        # A function declared inside three ifs starts its own count at zero. Walking past the
        # boundary would charge a nested helper for the nesting of the code around it.
        $t = Tree 'if ($a) { if ($b) { function F { if ($c) { 1 } } } }'
        $inner = @(Nodes $t 'IfStatementAst')[-1]
        Get-PSCxNesting -Node $inner | Should-Be 0
    }
}

Describe 'Get-PSCxUnitTable' {
    It 'always contains the script body, at line 1' {
        # The line is a literal 1. A decision-free file must still report a unit, and it must
        # report it at the top of the file rather than wherever the first node happens to sit.
        $t = Get-PSCxUnitTable -Ast (Tree '$x = 1')
        $t['<script-body>'] | Should-Be 1
    }

    It 'lists every function with its start line' {
        $code = "function A { 1 }`nfunction B { 2 }"
        $t = Get-PSCxUnitTable -Ast (Tree $code)
        $lines = @($t.GetEnumerator() | Where-Object { (Bare $_.Key) -eq 'B' } | ForEach-Object Value)
        $lines[0] | Should-Be 2
    }

    It 'lists a class method once, qualified' {
        $t = Get-PSCxUnitTable -Ast (Tree 'class Widget { [int] Render() { return 1 } }')
        @($t.Keys | ForEach-Object { Bare $_ } | Where-Object { $_ -eq 'Widget.Render' }).Count |
            Should-Be 1
    }

    It 'counts an INITIALISED property as a unit' {
        # There is code in an initialiser, so there is something to measure.
        $t = Get-PSCxUnitTable -Ast (Tree 'class Widget { [int] $Size = 3 }')
        @($t.Keys | ForEach-Object { Bare $_ }) | Should-ContainCollection 'Widget.Size'
    }

    It 'does NOT count an uninitialised property' {
        $t = Get-PSCxUnitTable -Ast (Tree 'class Widget { [int] $Size }')
        @($t.Keys | ForEach-Object { Bare $_ }) | Should-NotContainCollection 'Widget.Size'
    }

    It 'does NOT count an enum member, however it is written' {
        # An enum member is a PropertyMemberAst too, and an initialised one would otherwise
        # become a unit while a bare one would not -- making an enum's complexity depend on
        # whether anyone numbered its members. A label is not code.
        #
        # BOTH members, because the guard is `(-not $isEnumMember) -and [bool]$x.InitialValue`:
        # flip that -and to -or and the numbered member comes back as a unit while the bare one
        # still does not, so a fixture with only one of the two cannot tell them apart.
        $t = Get-PSCxUnitTable -Ast (Tree 'enum Colour { Red = 1 ; Green }')
        $names = @($t.Keys | ForEach-Object { Bare $_ })
        $names | Should-NotContainCollection 'Colour.Red'
        $names | Should-NotContainCollection 'Colour.Green'
        # And the paired half: an ordinary class property with the same shape IS a unit, so
        # this is not passing because nothing is ever counted.
        $c = Get-PSCxUnitTable -Ast (Tree 'class Palette { [int] $Red = 1 }')
        @($c.Keys | ForEach-Object { Bare $_ }) | Should-ContainCollection 'Palette.Red'
    }

    It 'keeps two same-named units apart by offset' {
        $t = Get-PSCxUnitTable -Ast (Tree 'function Dup { 1 } ; function Dup { 2 }')
        @($t.Keys | Where-Object { (Bare $_) -eq 'Dup' }).Count | Should-Be 2
    }
}

Describe 'Get-PSCxEnclosingFunctionName' {
    It 'names the nearest enclosing function' {
        $t = Tree 'function Get-Thing { Get-Thing }'
        Get-PSCxEnclosingFunctionName -Node (FirstNode $t 'CommandAst') | Should-Be 'Get-Thing'
    }

    It 'is null inside a class method, so recursion is not attributed to an outer function' {
        # A bare command inside a method is a command lookup, never a call to the method.
        $t = Tree 'function Outer { class W { [int] M() { Outer ; return 1 } } }'
        Get-PSCxEnclosingFunctionName -Node (FirstNode $t 'CommandAst') | Should-BeNull
    }

    It 'is null at file scope' {
        Get-PSCxEnclosingFunctionName -Node (FirstNode (Tree 'Get-Thing') 'CommandAst') |
            Should-BeNull
    }
}

Describe 'Get-PSCxEnclosingMethod' {
    It 'returns the member for a node inside a class method' {
        $t = Tree 'class W { [int] M() { if ($x) { return 1 } return 0 } }'
        (Get-PSCxEnclosingMethod -Node (FirstNode $t 'IfStatementAst')).Name | Should-Be 'M'
    }

    It 'is null inside an ordinary function' {
        $t = Tree 'function F { if ($x) { 1 } }'
        Get-PSCxEnclosingMethod -Node (FirstNode $t 'IfStatementAst') | Should-BeNull
    }
}

Describe 'Test-PSCxFlowCommand' {
    It 'is true for a control-flow cmdlet' {
        Test-PSCxFlowCommand -Node (FirstNode (Tree 'Where-Object { $_ }') 'CommandAst') |
            Should-BeTrue
    }

    It 'is true for the alias spelling too' {
        # Matched on the name as WRITTEN: % and ForEach-Object are one command at run time and
        # different text to a static walk.
        Test-PSCxFlowCommand -Node (FirstNode (Tree '1..3 | % { $_ }') 'CommandAst') |
            Should-BeTrue
    }

    It 'is false for an ordinary command' {
        Test-PSCxFlowCommand -Node (FirstNode (Tree 'Get-Item x') 'CommandAst') | Should-BeFalse
    }

    It 'is false for a node that is not a command at all' {
        Test-PSCxFlowCommand -Node (FirstNode (Tree 'if ($x) { 1 }') 'IfStatementAst') |
            Should-BeFalse
    }

    It 'is false for a command invoked through a variable, which has no name' {
        # `& $cmd` has no command name. There is deliberately no null guard for it -- -contains
        # already answers false -- and a guard would be unreachable by any observation.
        Test-PSCxFlowCommand -Node (FirstNode (Tree '& $cmd 1') 'CommandAst') | Should-BeFalse
    }
}
