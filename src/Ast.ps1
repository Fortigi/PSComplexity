<#
.SYNOPSIS
    Shared AST helpers for PSComplexity: unit discovery, nearest-function
    attribution, and nesting-depth computation.

.DESCRIPTION
    A "unit" is a function/filter body, plus one synthetic '<script-body>' per file for
    top-level code. Every increment is attributed to the nearest enclosing function, so
    nested functions are measured independently.

    Nesting depth (used by cognitive complexity) counts the flow-structuring ancestors
    between a node and its enclosing function -- if/loops/switch/catch/trap/ternary AND
    nested script-block lambdas (e.g. a ForEach-Object body). That mirrors SonarSource's
    B3 nesting-level rule, where nested functions/lambdas raise the nesting level.
#>

# Ancestor types that raise the cognitive nesting level (B3).
$script:PSCxNestingTypes = @(
    'IfStatementAst', 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst',
    'DoWhileStatementAst', 'DoUntilStatementAst', 'SwitchStatementAst',
    'CatchClauseAst', 'TrapStatementAst', 'TernaryExpressionAst', 'ScriptBlockExpressionAst'
)

function Get-PSCxUnitKey {
    # Nearest enclosing function 'name@line', else '<script-body>'.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return '{0}@{1}' -f $p.Name, $p.Extent.StartLineNumber
        }
        $p = $p.Parent
    }
    return '<script-body>'
}

function Get-PSCxNesting {
    # Count of nesting-raising ancestors up to (not crossing) the enclosing function.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $depth = 0
    $p = $Node.Parent
    while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
        if ($p.GetType().Name -in $script:PSCxNestingTypes) { $depth++ }
        $p = $p.Parent
    }
    return $depth
}

function Get-PSCxUnitTable {
    # Baseline unit -> start-line map: every function + the script body, so a
    # decision-free unit still reports (cyclomatic 1 / cognitive 0).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $units = @{ '<script-body>' = 1 }
    foreach ($fn in $Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $units['{0}@{1}' -f $fn.Name, $fn.Extent.StartLineNumber] = $fn.Extent.StartLineNumber
    }
    return $units
}

function Get-PSCxEnclosingFunctionName {
    # Name of the nearest enclosing function (for recursion detection), else $null.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }
        $p = $p.Parent
    }
    return $null
}
