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
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.IfStatementAst] }, $true)) {
        $extra = ($n.Clauses.Count - 1) + [int][bool]$n.ElseClause
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 + (Get-PSCxNesting -Node $n) + $extra }
    }
}

function Get-PSCxCogBlockRow {
    # switch / loops / catch / trap: one increment + nesting (switch is not per-case).
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($tn in 'SwitchStatementAst', 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst') {
        foreach ($n in $Ast.FindAll({ param($x) $x.GetType().Name -eq $tn }.GetNewClosure(), $true)) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 + (Get-PSCxNesting -Node $n) }
        }
    }
}

function Get-PSCxCogTernaryRow {
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.TernaryExpressionAst] }, $true)) {
        [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 + (Get-PSCxNesting -Node $n) }
    }
}

function Get-PSCxCogBooleanRow {
    # +1 per maximal run of a logical operator; no nesting bonus.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        if (Test-PSCxLogicalRunStart -Node $n) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 } }
    }
}

function Get-PSCxCogJumpRow {
    # labelled break / continue: +1.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $isJump = { param($x) $x -is [System.Management.Automation.Language.BreakStatementAst] -or $x -is [System.Management.Automation.Language.ContinueStatementAst] }
    foreach ($n in $Ast.FindAll($isJump, $true)) {
        if ($n.Label) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 } }
    }
}

function Get-PSCxCogRecursionRow {
    # direct recursion: +1 per call to the enclosing function.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $fn = Get-PSCxEnclosingFunctionName -Node $n
        if ($fn -and $n.GetCommandName() -eq $fn) { [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 } }
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
    if ($expr -is [System.Management.Automation.Language.TypeExpressionAst]) {
        return $expr.TypeName.Name -eq $Method.Parent.Name
    }
    return $false
}

function Get-PSCxCogMethodRecursionRow {
    # direct recursion inside a class method: +1, same as the function case. A method
    # cannot recurse by bare command name, so Get-PSCxCogRecursionRow never sees it.
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    foreach ($n in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $method = Get-PSCxEnclosingMethod -Node $n
        if (-not $method) { continue }
        if ($n.Member.Value -ne $method.Name) { continue }
        if (Test-PSCxSelfInvocation -Node $n -Method $method) {
            [pscustomobject]@{ Key = Get-PSCxUnitKey -Node $n; Amount = 1 }
        }
    }
}

function Get-PSCxCognitiveMap {
    # unit key -> cognitive complexity (summed rows; decision-free unit = 0).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $rows = @(Get-PSCxCogIfRow -Ast $Ast) + @(Get-PSCxCogBlockRow -Ast $Ast) + @(Get-PSCxCogTernaryRow -Ast $Ast) +
            @(Get-PSCxCogBooleanRow -Ast $Ast) + @(Get-PSCxCogJumpRow -Ast $Ast) + @(Get-PSCxCogRecursionRow -Ast $Ast) +
            @(Get-PSCxCogMethodRecursionRow -Ast $Ast)
    $map = @{}
    foreach ($row in $rows) { $map[$row.Key] = [int]$map[$row.Key] + $row.Amount }
    $out = @{}
    foreach ($k in (Get-PSCxUnitTable -Ast $Ast).Keys) { $out[$k] = [int]$map[$k] }
    return $out
}
