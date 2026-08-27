<#
.SYNOPSIS
    Cyclomatic complexity per unit. Depends on Ast.ps1.

.DESCRIPTION
    Cyclomatic complexity = 1 + decision points, where a decision point is each
    if/elseif clause, each switch clause, each for/foreach/while/do loop, each
    catch/trap, each ternary, and each -and/-or in a boolean expression. This is the
    classic control-flow count (independent-path proxy); pairs with cognitive
    complexity, which weights nesting instead.
#>

function Get-PSCxCycClauseRow {
    # if / switch: one decision per CLAUSE. `else` is not a clause -- it is the absence of a
    # decision -- so Clauses.Count is the count, not Clauses.Count + 1.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.IfStatementAst]))) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'clause'; Line = $n.Extent.StartLineNumber; Amount = $n.Clauses.Count }
    }
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.SwitchStatementAst]))) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'clause'; Line = $n.Extent.StartLineNumber; Amount = $n.Clauses.Count }
    }
}

function Get-PSCxCycBlockRow {
    # Loops, catch and trap: one decision each.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    # One bucket read per type instead of one full traversal per type -- this loop alone walked
    # the whole tree seven times. The closure the predicate needed is gone with the predicate: a
    # bucket name is a value, not a variable resolved at call time.
    foreach ($tn in 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst') {
        foreach ($n in (Get-PSCxNodeByTypeName -Ast $Ast -TypeName $tn)) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'block'; Line = $n.Extent.StartLineNumber; Amount = 1 }
        }
    }
}

function Get-PSCxCycFlowCommandRow {
    # ForEach-Object / Where-Object and their aliases: one decision each, exactly as the
    # keyword loop and conditional they stand in for.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    # Test-PSCxFlowCommand answers False for anything that is not a CommandAst, so asking the
    # index for the CommandAst nodes and testing those is the same set in the same order -- at the
    # cost of the commands in the file rather than every node in it.
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.CommandAst]))) {
        if (-not (Test-PSCxFlowCommand -Node $n)) { continue }
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'flow-command'; Line = $n.Extent.StartLineNumber; Amount = 1 }
    }
}

function Get-PSCxCycOperatorRow {
    # Decisions expressed as operators rather than statements.
    #
    # && and || are control flow between pipelines, not boolean operators: `a && b` runs b
    # only if a succeeded, which is a decision exactly as `if ($?)` would be. ?? and ??= each
    # choose between two values on a null test.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.PipelineChainAst]))) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 }
    }
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.TernaryExpressionAst]))) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 }
    }
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.BinaryExpressionAst]))) {
        if ($n.Operator -in 'And', 'Or', 'QuestionQuestion') { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 } }
    }
    foreach ($n in (Get-PSCxNodeByKind -Ast $Ast -Type ([System.Management.Automation.Language.AssignmentStatementAst]))) {
        if ($n.Operator -eq 'QuestionQuestionEquals') { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 } }
    }
}

function Get-PSCxCyclomaticRow {
    # Every decision-point row, attributed per unit. Composed from one collector per KIND of
    # decision, mirroring Cognitive.ps1 -- adding a construct then means a new collector or a
    # new entry in one, never another loop in a function that already has eight.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    @(Get-PSCxCycClauseRow -Ast $Ast) + @(Get-PSCxCycBlockRow -Ast $Ast) +
    @(Get-PSCxCycFlowCommandRow -Ast $Ast) + @(Get-PSCxCycOperatorRow -Ast $Ast)
}

function Get-PSCxCyclomaticMap {
    # unit key -> cyclomatic complexity (1 + summed decision points).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        # The ROWS, collected once per file by the caller, rather than the Ast to collect them
        # from. "The map is a projection of the rows" is then structural rather than a claim
        # about a private local -- and the cognitive side needs the same rows twice, once for
        # the sum and once for the -Detailed contributions, which it cannot do while each map
        # collects its own.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Row,
        # The unit table, built ONCE per file by the caller. Mandatory rather than optional with
        # a fallback: Get-PSCxUnitTable is a full FindAll traversal invoking a PowerShell
        # predicate per node, and it was run three times against the same AST in one pass. A
        # fallback would leave a branch no test could ever distinguish from its own absence --
        # both arms produce identical output, which is exactly the mutant this repo refuses.
        [Parameter(Mandatory)] [hashtable]$UnitTable
    )
    $map = @{}
    foreach ($row in $Row) {
        $map[$row.Key] = [int]$map[$row.Key] + $row.Amount
    }
    $out = @{}
    foreach ($k in $UnitTable.Keys) { $out[$k] = 1 + [int]$map[$k] }
    return $out
}
