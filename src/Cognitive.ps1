<#
.SYNOPSIS
    Cognitive complexity per unit -- a faithful PowerShell port of the SonarSource
    "Cognitive Complexity" metric. Depends on Ast.ps1.

.DESCRIPTION
    Cognitive complexity measures how hard code is to UNDERSTAND (not to test). It
    rewards flat code and penalises nesting. Rules implemented:

      B1 (structural increment, +1 each): if, else-if, else, switch, for, foreach,
         while, do-while/do-until, catch, trap, ternary, a labelled break/continue,
         each maximal run of a binary logical operator (-and / -or), and each direct
         recursive call to the enclosing function.
      B2 (nesting increment, +nesting): added to if (the leading clause), switch,
         loops, catch/trap and ternary -- NOT to else/else-if, boolean runs, labelled
         jumps or recursion.
      B3 (nesting level): raised by if/loops/switch/catch/trap/ternary and by nested
         script-block lambdas (see Get-PSCxNesting in Ast.ps1).

    Reference scores this reproduces (see tests/Cognitive.Tests.ps1): a two-nested-loop
    prime sieve with a labelled continue = 7; a plain switch = 1; recursive fibonacci
    = 3; `if (a -and b -or c)` = 3. The row collectors are split into small functions so
    this metric clears its own gate.
#>

function Test-PSCxLogicalRunStart {
    # True if this -and/-or node begins a new operator run (Sonar counts one per run).
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    if ($Node.Operator -notin 'And', 'Or') { return $false }
    $p = $Node.Parent
    $continues = ($p -is [System.Management.Automation.Language.BinaryExpressionAst]) -and ($p.Operator -eq $Node.Operator)
    return -not $continues
}

function Get-PSCxCogIfRow {
    # if leading clause: 1 + nesting; each else-if and the else: +1 (no nesting bonus).
    #
    # One row per CLAUSE, each at its own line (#157), so -Detailed can say which branch cost
    # what. An elseif sits at its condition's line; the else at its block's, since the AST keeps no
    # extent for the `else` keyword itself -- and `} else {` puts the two on one line.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'IfStatementAst')) {
        $key = Get-PSCxUnitKey -Node $n
        [pscustomobject]@{ Key = $key; Construct = 'if'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
        # Clauses[0] is the if itself.
        for ($i = 1; $i -lt $n.Clauses.Count; $i++) {
            [pscustomobject]@{ Key = $key; Construct = 'elseif'; Line = $n.Clauses[$i].Item1.Extent.StartLineNumber; Column = $n.Clauses[$i].Item1.Extent.StartColumnNumber; Amount = 1 }
        }
        if ($n.ElseClause) {
            [pscustomobject]@{ Key = $key; Construct = 'else'; Line = $n.ElseClause.Extent.StartLineNumber; Column = $n.ElseClause.Extent.StartColumnNumber; Amount = 1 }
        }
    }
}

function Get-PSCxCogBlockRow {
    # switch / loops / catch / trap: one increment + nesting (switch is not per-case).
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    # Eight bucket reads where there were eight whole-tree traversals -- the single largest
    # repeated walk in the module.
    foreach ($tn in 'SwitchStatementAst', 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst') {
        foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName $tn)) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'block'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
        }
    }
}

function Get-PSCxCogTernaryRow {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'TernaryExpressionAst')) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'ternary'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
    }
}

function Get-PSCxCogFlowCommandRow {
    # ForEach-Object / Where-Object and the .ForEach() / .Where() methods: one increment +
    # nesting, exactly as the keyword loop and conditional get. Their script block is a
    # ScriptBlockExpressionAst, which already raises nesting for anything inside, so a body
    # written this way now costs the same as the keyword form rather than less.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst], [System.Management.Automation.Language.InvokeMemberExpressionAst]))) {
        if (-not (Test-PSCxFlowCommand -Node $n)) { continue }
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'flow-command'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
    }
}

function Get-PSCxCogNullCoalesceRow {
    # ?? and ??= choose between two values on a null test, so they are scored as the
    # conditional shorthand they are -- the same treatment the ternary already gets.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'BinaryExpressionAst')) {
        if ($n.Operator -eq 'QuestionQuestion') {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'null-coalesce'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
        }
    }
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'AssignmentStatementAst')) {
        if ($n.Operator -eq 'QuestionQuestionEquals') {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'null-coalesce'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 + (Get-PSCxNesting -Node $n) }
        }
    }
}

function Get-PSCxCogPipelineChainRow {
    # && and || follow the BOOLEAN-RUN rule rather than the structural one: a run of like
    # operators is one increment, so `a && b && c` costs the same as `$a -and $b -and $c`.
    # Scoring each link separately would make the shell idiom dearer than the expression it
    # mirrors, which is the inverse of the bug this exists to fix.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'PipelineChainAst')) {
        if ($n.Parent -isnot [System.Management.Automation.Language.PipelineChainAst] -or
            $n.Parent.Operator -ne $n.Operator) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'pipeline-chain'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 }
        }
    }
}

function Get-PSCxCogBooleanRow {
    # +1 per maximal run of a logical operator; no nesting bonus.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'BinaryExpressionAst')) {
        if (Test-PSCxLogicalRunStart -Node $n) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'boolean-run'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 } }
    }
}

function Get-PSCxCogJumpRow {
    # labelled break / continue: +1.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    # ONE query over both types, not two loops: the original was a single FindAll and returned
    # break and continue interleaved in document order. Two bucket reads end-to-end would group
    # them by type, which -Detailed publishes and a reader reads top to bottom.
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.BreakStatementAst], [System.Management.Automation.Language.ContinueStatementAst]))) {
        if ($n.Label) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'labelled-jump'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 } }
    }
}

function Get-PSCxCogRecursionRow {
    # direct recursion: +1 per call to the enclosing function.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName 'CommandAst')) {
        if (Test-PSCxSelfCall -Node $n) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'recursion'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 } }
    }
}

function Test-PSCxSelfInvocation {
    # True if a member call targets the enclosing class itself: $this.X() for an
    # instance method, [ClassName]::X() for a static one. $other.X() from inside X
    # is a call to a DIFFERENT object and is not recursion.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node, [Parameter(Mandatory)] $Method)
    $expr = $Node.Expression
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return $expr.VariablePath.UserPath -eq 'this'
    }
    return ($expr -is [System.Management.Automation.Language.TypeExpressionAst]) -and
        ($expr.TypeName.Name -eq $Method.Parent.Name)
}

function Get-PSCxCogMethodRecursionRow {
    # direct recursion inside a class method: +1, same as the function case. A method
    # cannot recurse by bare command name, so Get-PSCxCogRecursionRow never sees it.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    # ByKind, not an exact-name lookup: BaseCtorInvokeMemberExpressionAst derives from this type,
    # so `: base()` chaining reaches the original -is test and must keep reaching this one.
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.InvokeMemberExpressionAst]))) {
        $method = Get-PSCxEnclosingMethod -Node $n
        if (-not $method) { continue }
        if ($n.Member.Value -ne $method.Name) { continue }
        if (Test-PSCxSelfInvocation -Node $n -Method $method) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'recursion'; Line = $n.Extent.StartLineNumber; Column = $n.Extent.StartColumnNumber; Amount = 1 }
        }
    }
}

function Get-PSCxCognitiveRow {
    # Every cognitive increment, attributed per unit. Composed from one collector per KIND of
    # increment, mirroring Cyclomatic.ps1 -- and separate from the map so that "the map is a
    # projection of the rows" is structural rather than a claim about a private local.
    #
    # The rows are what -Detailed publishes: a total of 23 is correct and unactionable, because
    # nothing in it says whether that is one deeply-nested loop or twenty flat guards, and those
    # call for opposite fixes.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    @(Get-PSCxCogIfRow -Ast $Ast) + @(Get-PSCxCogBlockRow -Ast $Ast) + @(Get-PSCxCogTernaryRow -Ast $Ast) +
    @(Get-PSCxCogFlowCommandRow -Ast $Ast) + @(Get-PSCxCogNullCoalesceRow -Ast $Ast) +
    @(Get-PSCxCogPipelineChainRow -Ast $Ast) + @(Get-PSCxCogBooleanRow -Ast $Ast) +
    @(Get-PSCxCogJumpRow -Ast $Ast) + @(Get-PSCxCogRecursionRow -Ast $Ast) +
    @(Get-PSCxCogMethodRecursionRow -Ast $Ast)
}

function Get-PSCxContributionMap {
    # unit key -> the increments that produced its cognitive score, in line order.
    #
    # Its own function because the caller is already a nested walk over files and units, where
    # this loop would carry that nesting on top of its own and put the caller over the cognitive
    # ceiling this module gates itself on. Grouping rows by unit is also a separable question
    # with its own test, which is what keeps the split from being a branch hidden to buy a
    # number.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        # The same rows Get-PSCxCognitiveMap sums. Collected once per file by the caller and
        # handed to both: collecting them here too would be eighteen more traversals of the tree
        # for rows the sum has just built.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Row
    )
    $byUnit = @{}
    foreach ($row in $Row) {
        if (-not $byUnit.ContainsKey($row.Key)) {
            $byUnit[$row.Key] = [System.Collections.Generic.List[object]]::new()
        }
        $byUnit[$row.Key].Add([pscustomobject]@{ Line = $row.Line; Column = $row.Column; Construct = $row.Construct; Amount = $row.Amount })
    }
    # Sorted here rather than at the call site: the question this answers is "where did 23 come
    # from", and a reader scans a unit top to bottom -- and, within a line, left to right (#186).
    # By line alone the tie fell to the construct NAME, so a one-line chain read `else, elseif,
    # if`. The column is a sort key and nothing more: the published row stays Line, Construct,
    # Amount. Two rows can start at one column -- a ternary whose condition is a boolean run --
    # and the name still decides those, so the order never depends on which collector ran first.
    $out = @{}
    foreach ($k in $byUnit.Keys) {
        $out[$k] = @(foreach ($r in ($byUnit[$k] | Sort-Object Line, Column, Construct)) {
                [pscustomobject]@{ Line = $r.Line; Construct = $r.Construct; Amount = $r.Amount }
            })
    }
    return $out
}

function Get-PSCxCognitiveMap {
    # unit key -> cognitive complexity (summed rows; decision-free unit = 0).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        # The rows, collected once per file by the caller -- see Get-PSCxCyclomaticMap for why
        # the maps take rows rather than an Ast.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Row,
        # The unit table, built ONCE per file by the caller. Mandatory rather than optional with
        # a fallback: it was once run three times against the same AST in one pass, each a full
        # FindAll invoking a PowerShell predicate per node. It reads the index's buckets now
        # (#155), but a fallback would still leave a branch no test could ever distinguish from
        # its own absence -- both arms produce identical output, the mutant this repo refuses.
        [Parameter(Mandatory)] [hashtable]$UnitTable
    )
    $map = @{}
    foreach ($row in $Row) { $map[$row.Key] = [int]$map[$row.Key] + $row.Amount }
    $out = @{}
    foreach ($k in $UnitTable.Keys) { $out[$k] = [int]$map[$k] }
    return $out
}
