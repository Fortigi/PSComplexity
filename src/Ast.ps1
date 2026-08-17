<#
.SYNOPSIS
    Shared AST helpers for PSComplexity: unit discovery, nearest-unit attribution,
    and nesting-depth computation.

.DESCRIPTION
    A "unit" is anything that owns a body and is gated on its own:

      * a function/filter                -> 'name@line'
      * a class method or constructor    -> 'Class.Member@line'
      * an initialised class property    -> 'Class.Property@line'
      * one synthetic '<script-body>' per file, for top-level code

    Every increment is attributed to the nearest enclosing unit, so nested functions
    -- and methods of a class declared inside a function -- are measured independently.

    Class members are units because the gate is per-unit: folding a class's methods
    into the enclosing scope either hides a genuinely complex method inside a large
    total, or inflates a script body that is itself fine. A property INITIALISER is
    its own unit for the same reason and at the same granularity as a method: it is
    code that runs (at construction), it is not top-level code, and naming the
    property is what lets a gate point at the thing to fix. A property with no
    initialiser has no body and so is not a unit.

    Nesting depth (used by cognitive complexity) counts the flow-structuring ancestors
    between a node and its enclosing unit -- if/loops/switch/catch/trap/ternary AND
    nested script-block lambdas (e.g. a ForEach-Object body). That mirrors SonarSource's
    B3 nesting-level rule, where nested functions/lambdas raise the nesting level.
#>

# Ancestor types that raise the cognitive nesting level (B3).
$script:PSCxNestingTypes = @(
    'IfStatementAst', 'ForEachStatementAst', 'ForStatementAst', 'WhileStatementAst',
    'DoWhileStatementAst', 'DoUntilStatementAst', 'SwitchStatementAst',
    'CatchClauseAst', 'TrapStatementAst', 'TernaryExpressionAst', 'ScriptBlockExpressionAst'
)

# Ancestor types that OWN a body: the walk up stops here, both for attribution and
# for nesting. A method body bounds its contents exactly as a function body does.
$script:PSCxUnitBoundaryTypes = @(
    'FunctionDefinitionAst', 'FunctionMemberAst', 'PropertyMemberAst'
)

function Resolve-PSCxUnitBoundary {
    # A class method's body is itself a FunctionDefinitionAst, nested inside the
    # FunctionMemberAst. Both are body owners, so without this the same method is
    # discovered twice -- once unqualified. The MEMBER is the unit: it is the node
    # that knows the class name.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Boundary)
    if ($Boundary -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $Boundary.Parent -is [System.Management.Automation.Language.FunctionMemberAst]) {
        return $Boundary.Parent
    }
    return $Boundary
}

function Get-PSCxUnitBoundary {
    # Nearest enclosing body-owner, or $null for top-level code.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $p = $Node.Parent
    while ($p) {
        if ($p.GetType().Name -in $script:PSCxUnitBoundaryTypes) { return Resolve-PSCxUnitBoundary -Boundary $p }
        $p = $p.Parent
    }
    return $null
}

function Get-PSCxUnitName {
    # 'name@line' for a function; 'Class.Member@line' for a class member (whose
    # Parent is the TypeDefinitionAst carrying the class name). A constructor is
    # named after its class, so it reads 'Order.Order@line'.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Boundary)
    if ($Boundary -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        return '{0}@{1}' -f $Boundary.Name, $Boundary.Extent.StartLineNumber
    }
    return '{0}.{1}@{2}' -f $Boundary.Parent.Name, $Boundary.Name, $Boundary.Extent.StartLineNumber
}

function Get-PSCxUnitKey {
    # Nearest enclosing unit key, else '<script-body>'.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $boundary = Get-PSCxUnitBoundary -Node $Node
    if ($boundary) { return Get-PSCxUnitName -Boundary $boundary }
    return '<script-body>'
}

function Get-PSCxNesting {
    # Count of nesting-raising ancestors up to (not crossing) the enclosing unit.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $depth = 0
    $p = $Node.Parent
    while ($p -and $p.GetType().Name -notin $script:PSCxUnitBoundaryTypes) {
        if ($p.GetType().Name -in $script:PSCxNestingTypes) { $depth++ }
        $p = $p.Parent
    }
    return $depth
}

function Get-PSCxUnitTable {
    # Baseline unit -> start-line map: every function, every class method and
    # initialised property, plus the script body -- so a decision-free unit still
    # reports (cyclomatic 1 / cognitive 0).
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Ast)
    $units = @{ '<script-body>' = 1 }
    # No .GetNewClosure() here, unlike the per-type loops in Cyclomatic/Cognitive:
    # those capture a local loop variable and need one. This predicate captures
    # nothing, and a closure built INSIDE a function loses the module scope, so
    # $script:PSCxUnitBoundaryTypes would come back empty and match nothing.
    $isBodyOwner = {
        param($x)
        if ($x -is [System.Management.Automation.Language.PropertyMemberAst]) { return [bool]$x.InitialValue }
        return $x.GetType().Name -in $script:PSCxUnitBoundaryTypes
    }
    foreach ($node in $Ast.FindAll($isBodyOwner, $true)) {
        $unit = Resolve-PSCxUnitBoundary -Boundary $node
        $units[(Get-PSCxUnitName -Boundary $unit)] = $unit.Extent.StartLineNumber
    }
    return $units
}

function Get-PSCxEnclosingFunctionName {
    # Name of the nearest enclosing FUNCTION, for bare-command recursion detection.
    # $null when the nearest body-owner is a class member: a bare command inside a
    # method is a command lookup, never a call to the method, so walking past the
    # method to an outer function would attribute recursion to the wrong unit.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $boundary = Get-PSCxUnitBoundary -Node $Node
    if ($boundary -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $boundary.Name }
    return $null
}

function Get-PSCxEnclosingMethod {
    # Nearest enclosing class method/constructor, else $null. Method recursion goes
    # through a member invocation ($this.X()), not a command, so it needs the AST
    # node -- the class name on it is what tells a static self-call apart.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $boundary = Get-PSCxUnitBoundary -Node $Node
    if ($boundary -is [System.Management.Automation.Language.FunctionMemberAst]) { return $boundary }
    return $null
}
