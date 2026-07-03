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

function Get-PSCxCyclomaticRow {
    # Emit {Key; Amount} decision-point rows across all types. Attributed per unit.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)

    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = $n.Clauses.Count }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = $n.Clauses.Count }
    }
    foreach ($tn in 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst') {
        foreach ($n in $Ast.FindAll({ param($x) $x.GetType().Name -eq $tn }.GetNewClosure(), $true)) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 }
        }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 }
    }
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        if ($n.Operator -in 'And', 'Or') { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 } }
    }
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
