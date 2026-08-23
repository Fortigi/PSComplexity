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
# Cmdlets that ARE control flow in PowerShell, with their aliases. ForEach-Object is the
# language's second loop and Where-Object its second conditional; a body written with them
# branches exactly as much as the keyword form, so scoring it lower rewards a rewrite that
# changes nothing a reader would call a decomposition.
#
# `foreach` and `where` appear here as ALIASES: the keyword forms parse to
# ForEachStatementAst and a filter script block, never to a CommandAst, so a CommandAst
# carrying those names can only be the alias.
$script:PSCxFlowCommands = @(
    'ForEach-Object', 'foreach', '%',
    'Where-Object', 'where', '?'
)

$script:PSCxUnitBoundaryTypes = @(
    'FunctionDefinitionAst', 'FunctionMemberAst', 'PropertyMemberAst'
)

function Resolve-PSCxUnitBoundary {
    # A class method's body is itself a FunctionDefinitionAst, nested inside the
    # FunctionMemberAst. Both are body owners, so without this the same method is
    # discovered twice -- once unqualified. The MEMBER is the unit: it is the node
    # that knows the class name.
    [OutputType([System.Management.Automation.Language.Ast])]
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
    [OutputType([System.Management.Automation.Language.Ast])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $p = $Node.Parent
    while ($p) {
        if ($p.GetType().Name -in $script:PSCxUnitBoundaryTypes) { return Resolve-PSCxUnitBoundary -Boundary $p }
        $p = $p.Parent
    }
    return $null
}

function Get-PSCxDisplayName {
    # Map ordered unit keys to the names a caller sees, disambiguating repeats.
    #
    # Qualification makes a nested unit distinct from one of the same name elsewhere, but it
    # cannot separate two units with the SAME name in the SAME scope -- two overloads, or a
    # function defined twice. Those still read alike, so a baseline keyed on the name merges
    # them. An ordinal is appended to every member of such a group, first one included: were
    # only the second suffixed, adding an overload would silently rename the first.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$OrderedKeys)
    $bare = @{}
    foreach ($k in $OrderedKeys) {
        $n = $k -replace '@\d+$', ''
        $bare[$k] = $n
    }
    $counts = @{}
    foreach ($k in $OrderedKeys) { $counts[$bare[$k]] = 1 + [int]$counts[$bare[$k]] }
    $seen = @{}
    $out = @{}
    foreach ($k in $OrderedKeys) {
        $n = $bare[$k]
        if ($counts[$n] -gt 1) {
            $seen[$n] = 1 + [int]$seen[$n]
            $out[$k] = '{0}#{1}' -f $n, $seen[$n]
        }
        else { $out[$k] = $n }
    }
    return $out
}

function Get-PSCxUnitOwnName {
    # A unit's own name, unqualified: 'Get-Thing' for a function, 'Class.Member' for a class
    # member (whose Parent is the TypeDefinitionAst carrying the class name). A constructor is
    # named after its class, so it reads 'Order.Order'.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Boundary)
    if ($Boundary -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        return $Boundary.Name
    }
    return '{0}.{1}' -f $Boundary.Parent.Name, $Boundary.Name
}

function Get-PSCxUnitName {
    # The qualified unit name plus the extent's start offset: 'Outer/Inner@412'.
    #
    # QUALIFIED, because a bare name is not unique. `Get-Inner` defined inside `Get-OuterA`
    # and again inside `Get-OuterB` produced two rows both reading `Get-Inner`, so anything
    # keying on the name -- a committed baseline, a per-file report -- silently merged two
    # different units. Class members were already qualified for exactly this reason; nested
    # functions were not, and the promise that the qualification extends to "any per-unit
    # baseline built from it" was true only for the half that had it.
    #
    # SUFFIXED WITH THE OFFSET, not the line, because a line is not unique either: two
    # overloads written on one physical line shared a key and had their scores ADDED, so the
    # file reported a single unit that exists nowhere in the source. An offset is unique per
    # node however the source is laid out. The reported Line is recorded separately and is
    # display data.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Boundary)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Get-PSCxUnitOwnName -Boundary $Boundary))
    # Walk out through every enclosing unit. Resolve each one first: a class method's body is
    # itself a FunctionDefinitionAst inside the FunctionMemberAst, so an unresolved walk
    # would name the same method twice.
    $seen = Resolve-PSCxUnitBoundary -Boundary $Boundary
    $p = $Boundary.Parent
    while ($p) {
        if ($p.GetType().Name -in $script:PSCxUnitBoundaryTypes) {
            $outer = Resolve-PSCxUnitBoundary -Boundary $p
            if (-not [object]::ReferenceEquals($outer, $seen)) {
                $parts.Insert(0, (Get-PSCxUnitOwnName -Boundary $outer))
                $seen = $outer
            }
        }
        $p = $p.Parent
    }
    return '{0}@{1}' -f ($parts -join '/'), $Boundary.Extent.StartOffset
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
        if ($x -is [System.Management.Automation.Language.PropertyMemberAst]) {
            # An ENUM member is a PropertyMemberAst too, and an initialised one -- `Red = 1`
            # -- would otherwise become a unit while a bare `Green` would not, making an
            # enum's complexity depend on whether anyone numbered its members. A label is
            # not code; there is nothing in it to measure.
            #
            # Folded into ONE returned expression rather than an early `return $false`: this
            # is a FindAll predicate, so $false and $null behave identically and a separate
            # return is unobservable -- it survived every mutant. The `-and` is observable,
            # because flipping it turns enum members back into units.
            $isEnumMember = $x.Parent -is [System.Management.Automation.Language.TypeDefinitionAst] -and $x.Parent.IsEnum
            return (-not $isEnumMember) -and [bool]$x.InitialValue
        }
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
    [OutputType([System.Management.Automation.Language.Ast])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $boundary = Get-PSCxUnitBoundary -Node $Node
    if ($boundary -is [System.Management.Automation.Language.FunctionMemberAst]) { return $boundary }
    return $null
}

function Test-PSCxFlowCommand {
    # True when a node is a call to a cmdlet that acts as control flow.
    #
    # Matched on the name as WRITTEN, because that is all a static walk has: `%` and
    # ForEach-Object are the same command at run time and different text here, so both
    # spellings are listed rather than resolved.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    if ($Node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
    # No guard for a null name: a command invoked through a variable (`& $cmd`) has none,
    # and -contains already answers False for it. A guard here would be unreachable by any
    # observation, which is how it was found -- both of its mutants survived.
    return $script:PSCxFlowCommands -contains $Node.GetCommandName()
}

