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
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'clause'; Line = $n.Extent.StartLineNumber; Amount = $n.Clauses.Count }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'clause'; Line = $n.Extent.StartLineNumber; Amount = $n.Clauses.Count }
    }
}

function Get-PSCxCycBlockRow {
    # Loops, catch and trap: one decision each.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($tn in 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst') {
        # The closure is required: without it $tn resolves at CALL time, when the loop has
        # already finished, and every type matches the last name in the list.
        foreach ($n in $Ast.FindAll({ param($x) $x.GetType().Name -eq $tn }.GetNewClosure(), $true)) {
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
    foreach ($n in $Ast.FindAll({ param($x) Test-PSCxFlowCommand -Node $x }, $true)) {
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
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.PipelineChainAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        if ($n.Operator -in 'And', 'Or', 'QuestionQuestion') { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Construct = 'operator'; Line = $n.Extent.StartLineNumber; Amount = 1 } }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
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
    param([Parameter(Mandatory)] $Ast)
    $map = @{}
    foreach ($row in Get-PSCxCyclomaticRow -Ast $Ast) {
        $map[$row.Key] = [int]$map[$row.Key] + $row.Amount
    }
    $out = @{}
    foreach ($k in (Get-PSCxUnitTable -Ast $Ast).Keys) { $out[$k] = 1 + [int]$map[$k] }
    return $out
}
