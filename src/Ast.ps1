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
    # FunctionMemberAst is unreachable TODAY and kept on purpose. Every usage of this list walks
    # UP the parent chain, and PowerShell wraps a class member's body in its own
    # FunctionDefinitionAst -- verified across methods, constructors, static constructors, static
    # and hidden members, overrides, and an empty body. So the body is always met first, and
    # Resolve-PSCxUnitBoundary maps it back to the member without consulting this list at all.
    #
    # It stays because the failure modes are not symmetric. If PowerShell ever produced a member
    # without that inner node, keeping the entry costs nothing and removing it would silently
    # attribute the member's decisions to the script body -- a wrong number, which is the one
    # thing this module must not produce. The invariant it leans on is pinned by a test, so the
    # day it stops holding is a red suite rather than a quiet re-attribution.
    'FunctionDefinitionAst', 'FunctionMemberAst', 'PropertyMemberAst'
)

# Per-node answers, remembered for the file being measured.
#
# Get-PSCxUnitBoundary and Get-PSCxNesting each walk the ancestor chain from a node up to its
# enclosing unit, and between them they are called from twelve sites once per matched node. Where
# node count and depth grow together the total is quadratic: measured, a file nested 200 deep cost
# 1.84s of CPU for 3 KB of source, while 52 KB of ordinary code cost 3.0s.
#
# Keyed on the node OBJECT: two AST nodes with identical content are different nodes and must not
# collide, so entries from one parse can never answer a question about another.
#
# The default comparer already gives that, and passing one explicitly is what NOT to do here. Ast
# overrides neither Equals nor GetHashCode, so EqualityComparer<object>.Default is identity;
# naming ReferenceEqualityComparer to say so costs a .NET 5 type and raises this module's floor
# from PowerShell 7.0 to 7.1 in exchange for nothing. tests/Ast.Tests.ps1 pins the assumption with
# two structurally identical trees that must stay apart -- if Ast ever gains value equality, that
# test is what fails.
#
# Cleared per file by Clear-PSCxAstCache. Without that the tables grow for the life of the process,
# which for a gate over a large tree is every node of every file.
$script:PSCxBoundaryCache = [System.Collections.Generic.Dictionary[object, object]]::new()
$script:PSCxNestingCache = [System.Collections.Generic.Dictionary[object, object]]::new()

# Nodes bucketed by their runtime type, and the pre-order position of each node.
#
# The same pass that computes boundary and nesting already visits every node and already knows
# each one's type, so recording it costs one dictionary write. What it buys is every "find me the
# nodes of type X" question the metrics ask -- and they asked it 32 times per file, each time
# re-walking the whole tree and invoking a PowerShell predicate for every node. Measured on a
# 21k-node file: 32 x 21ms of traversal, for answers this pass already had.
#
# Keyed by [type] rather than by name so an assignability query can be answered without
# reconstructing types from strings; PSCxTypeNameCache holds the SAME lists under the exact type
# name, for the callers that mean GetType().Name -eq rather than -is. Two spellings of one
# question, kept apart on purpose: they differ the moment a construct gains a subclass, and
# InvokeMemberExpressionAst already has one.
#
# PSCxOrderCache exists only so a query spanning more than one bucket can put the union back into
# document order. FindAll returns pre-order, and the rows -Detailed publishes are read in that
# order, so a union that merged buckets end-to-end would reorder two increments on one line.
#
# The two node-keyed tables take the DEFAULT comparer, for the reason the boundary and nesting
# tables above do: Ast overrides neither Equals nor GetHashCode, so the default already is
# identity, and naming ReferenceEqualityComparer to say so costs a .NET 5 type and the module's
# floor. Every type named here predates .NET Core 3.1, which is what PowerShell 7.0 runs.
$script:PSCxTypeCache = [System.Collections.Generic.Dictionary[type, object]]::new()
$script:PSCxTypeNameCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$script:PSCxKindCache = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$script:PSCxOrderCache = [System.Collections.Generic.Dictionary[object, object]]::new()
$script:PSCxNameCache = [System.Collections.Generic.Dictionary[object, object]]::new()

# Which tree the caches describe, so the index is built once per file rather than once per ask.
# A reference, never a value: two parses of one file are different trees and must not share an
# index.
$script:PSCxIndexedRoot = $null

function Get-PSCxAstRoot {
    # The top of the tree a node belongs to.
    #
    # This is the one upward walk left, and it runs ONCE per file rather than once per node --
    # which is the whole difference between linear and quadratic here.
    [OutputType([System.Management.Automation.Language.Ast])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $r = $Node
    while ($r.Parent) { $r = $r.Parent }
    return $r
}

function Initialize-PSCxAstIndex {
    # Compute every node's enclosing unit and nesting depth in ONE pre-order pass.
    #
    # Both answers are defined against a node's PARENT:
    #
    #   boundary(n) = parent is a body owner ? resolve(parent) : boundary(parent)
    #   nesting(n)  = parent is a body owner ? 0 : nesting(parent) + (parent raises nesting ? 1 : 0)
    #
    # so knowing the parent's answers is enough to know the child's. FindAll walks in document
    # order and a parent always precedes its children, which is what lets this be a flat loop
    # rather than a recursion -- and a flat loop cannot exhaust the stack on a deeply nested file,
    # which is exactly the shape this exists for.
    #
    # It replaces walking up from every node. Twelve call sites asked for one or both of these
    # once per matched node, and where node count and depth grow together that is quadratic: a
    # file nested 200 deep cost 1.84s of CPU for 3 KB of source.
    #
    # It also records each node's TYPE and its position in the walk, which is what lets every
    # "find the nodes of type X" question be a dictionary read instead of another traversal. The
    # metrics asked that question 32 times per file, each time walking the whole tree and invoking
    # a PowerShell predicate per node.
    #
    # Unconditional: it REBUILDS. Confirm-PSCxAstIndex below is the idempotent entry point, and
    # the split is deliberate rather than tidy -- Get-PSCxUnitBoundary and Get-PSCxNesting call
    # this one on a cache miss, and their tests prove the memo hits by planting a value and
    # checking a rebuild would overwrite it. Guarding here made that rebuild an early return, so
    # the planted value survived and two mutants that used to die started living. Measured, on
    # the run that introduced it.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Root)
    # The type-keyed tables describe ONE tree and must be emptied before another is walked.
    # Boundary, nesting and name are keyed by node reference, so entries from two trees can sit
    # side by side and neither can answer for the other; a bucket keyed by TYPE has no such
    # protection, and appending a second tree's nodes to it hands back rows from a file the caller
    # never asked about. The suite caught exactly that -- an `if` reported at line 1 of the
    # previous fixture.
    $script:PSCxTypeCache.Clear()
    $script:PSCxTypeNameCache.Clear()
    $script:PSCxKindCache.Clear()
    $script:PSCxOrderCache.Clear()
    $script:PSCxBoundaryCache[$Root] = $null
    $script:PSCxNestingCache[$Root] = 0
    $position = 0
    foreach ($n in $Root.FindAll({ $true }, $true)) {
        # BEFORE the parent test below, which skips the root: FindAll returns the root itself, and
        # a bucket that silently omitted it would be a whole-tree query that is not one.
        Add-PSCxIndexedNode -Node $n -Position $position
        $position++
        $p = $n.Parent
        # The root itself comes back from FindAll and is already seeded; anything with no parent
        # is a root by definition.
        if ($null -eq $p) { continue }
        if ($p.GetType().Name -in $script:PSCxUnitBoundaryTypes) {
            $script:PSCxBoundaryCache[$n] = Resolve-PSCxUnitBoundary -Boundary $p
            $script:PSCxNestingCache[$n] = 0
            continue
        }
        $script:PSCxBoundaryCache[$n] = $script:PSCxBoundaryCache[$p]
        $raises = ($p.GetType().Name -in $script:PSCxNestingTypes) ? 1 : 0
        $script:PSCxNestingCache[$n] = [int]$script:PSCxNestingCache[$p] + $raises
    }
    # LAST, so a walk that throws part-way leaves the root unmarked and the next ask rebuilds it
    # rather than reading a half-filled index. Nothing in the loop throws today; the ordering costs
    # nothing and removes the question.
    $script:PSCxIndexedRoot = $Root
}

function Confirm-PSCxAstIndex {
    # Build the index for this tree unless it is already the one indexed.
    #
    # The idempotent half, kept apart from the rebuild above because the two are asked for by
    # different callers for different reasons. The bucket readers ask on EVERY query -- dozens per
    # file -- and an unguarded rebuild there would cost more than the traversals the index
    # replaced. The boundary and nesting readers ask only on a miss, which for one tree happens
    # once, and they want the rebuild.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Root)
    if ([object]::ReferenceEquals($script:PSCxIndexedRoot, $Root)) { return }
    Initialize-PSCxAstIndex -Root $Root
}

function Add-PSCxIndexedNode {
    # File one node into its type bucket and record where it sat in the walk.
    #
    # Split out of the loop above rather than inlined: the loop is the hot path of the whole
    # module and already carries two conditionals against the cognitive ceiling this module gates
    # itself on. It is also the one piece of the index whose contract -- buckets hold nodes in
    # document order -- is worth being able to test on its own.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [int]$Position
    )
    $script:PSCxOrderCache[$Node] = $Position
    $type = $Node.GetType()
    $bucket = $null
    if (-not $script:PSCxTypeCache.TryGetValue($type, [ref]$bucket)) {
        $bucket = [System.Collections.Generic.List[object]]::new()
        $script:PSCxTypeCache[$type] = $bucket
        # The same list under both keys, not a copy. An exact-name lookup and a type lookup are
        # two ways of asking for one bucket, and two lists would be two things to keep in step.
        $script:PSCxTypeNameCache[$type.Name] = $bucket
    }
    $bucket.Add($Node)
}

function Clear-PSCxAstCache {
    # Forget the per-node answers. Called once per file, before it is walked.
    #
    # Clear-, not Reset-: Reset is a state-changing verb, so PSUseShouldProcessForStateChangingFunctions
    # demands -WhatIf support that emptying an in-memory cache has no use for. Clear- says the same
    # thing and matches Get-PSCxUnitRecord's reason for not being New-.
    #
    # Correctness does not depend on this -- the keys are node references, so a stale entry can
    # never be found by a different parse. Memory does: without it the tables hold every node of
    # every file the process has seen.
    [OutputType([void])]
    [CmdletBinding()]
    param()
    $script:PSCxBoundaryCache.Clear()
    $script:PSCxNestingCache.Clear()
    $script:PSCxTypeCache.Clear()
    $script:PSCxTypeNameCache.Clear()
    $script:PSCxKindCache.Clear()
    $script:PSCxOrderCache.Clear()
    $script:PSCxNameCache.Clear()
    # The mark goes last and must go at all: leaving it set would let the next file read an index
    # that has just been emptied, and every metric would come back zero with nothing raised.
    $script:PSCxIndexedRoot = $null
}

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
    #
    # A read of the index, which is built on the first miss for a tree. There is deliberately no
    # second implementation that walks up: two ways to answer one question is how they come to
    # disagree, and the walk was the quadratic half.
    [OutputType([System.Management.Automation.Language.Ast])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $found = $null
    if ($script:PSCxBoundaryCache.TryGetValue($Node, [ref]$found)) { return $found }
    Initialize-PSCxAstIndex -Root (Get-PSCxAstRoot -Node $Node)
    [void]$script:PSCxBoundaryCache.TryGetValue($Node, [ref]$found)
    return $found
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
    # Memoised on the boundary NODE, because this is a pure function of it and the metrics ask for
    # the same handful of names thousands of times: measured on a 200-function file, 4200 calls
    # produced 200 distinct names. Every collector calls Get-PSCxUnitKey once per matched node,
    # and each of those rebuilds a list, walks to the root and formats a string to arrive back at
    # a name the last node in the same unit already produced.
    #
    # Reference-keyed and cleared per file, exactly like the boundary and nesting tables, so an
    # entry from one parse can never answer a question about another.
    $cachedName = $null
    if ($script:PSCxNameCache.TryGetValue($Boundary, [ref]$cachedName)) { return [string]$cachedName }
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
    $script:PSCxNameCache[$Boundary] = '{0}@{1}' -f ($parts -join '/'), $Boundary.Extent.StartOffset
    return [string]$script:PSCxNameCache[$Boundary]
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
    #
    # The same index, built by the same descent. Memoising the upward walk instead was tried and
    # is wrong in a way worth remembering: nesting answers along a chain are not equal the way
    # boundary answers are -- they decrease going up -- so caching them on the way up returns the
    # right number for the node asked about and the wrong one for every node cached en route. It
    # reported cognitive 200 where the answer was 20100, and all 558 tests passed.
    [OutputType([int])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Node)
    $found = $null
    if ($script:PSCxNestingCache.TryGetValue($Node, [ref]$found)) { return [int]$found }
    Initialize-PSCxAstIndex -Root (Get-PSCxAstRoot -Node $Node)
    [void]$script:PSCxNestingCache.TryGetValue($Node, [ref]$found)
    return [int]$found
}

function Get-PSCxNodeByTypeName {
    # Every node whose runtime type is EXACTLY this, in document order.
    #
    # The bucket is returned as it is stored, not copied: these are the hot reads of the whole
    # module and a copy per ask would give back the allocation the index exists to remove. No
    # caller mutates a bucket, and none has any reason to.
    #
    # Exact, because the caller said exact. This replaces `GetType().Name -eq $tn`, which is a
    # different question from `-is` the moment a construct gains a subclass -- and one already
    # has. Get-PSCxNodeByKind below is the other question, spelled separately so neither can
    # quietly answer for the other.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)] [string]$TypeName
    )
    Confirm-PSCxAstIndex -Root (Get-PSCxAstRoot -Node $Ast)
    $bucket = $null
    if ($script:PSCxTypeNameCache.TryGetValue($TypeName, [ref]$bucket)) { return $bucket }
    # A type the file contains no instance of. An empty result, never $null: every caller is a
    # foreach, and the difference between the two is a run that measures nothing while looking
    # like a run that found nothing.
    return @()
}

function Get-PSCxNodeByKind {
    # Every node ASSIGNABLE to one of these types -- the `-is` test -- in document order.
    #
    # Assignability is resolved against the types the file actually holds, not against a list
    # written here, so a subclass this module has never heard of is still matched. That is not
    # hypothetical: BaseCtorInvokeMemberExpressionAst derives from InvokeMemberExpressionAst, so
    # `-is` and `GetType().Name -eq` already disagree on `: base()` chaining, and a bucket lookup
    # that ignored the difference would silently drop a construct.
    #
    # Cached per tree by the set of types asked for, because the answer cannot change while the
    # index stands and the metrics ask the same handful of questions once each.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)] [type[]]$Type
    )
    Confirm-PSCxAstIndex -Root (Get-PSCxAstRoot -Node $Ast)
    $key = ($Type.FullName -join '|')
    $cached = $null
    if ($script:PSCxKindCache.TryGetValue($key, [ref]$cached)) { return $cached }
    $script:PSCxKindCache[$key] = Get-PSCxKindResult -Type $Type
    return $script:PSCxKindCache[$key]
}

function Get-PSCxKindResult {
    # The union of the buckets assignable to these types, in document order.
    #
    # Its own function so Get-PSCxNodeByKind stays a cache read, and so the ordering contract can
    # be tested without going through a cache that would answer the second call from memory.
    #
    # There is no shortcut for the single-bucket case, and that is a decision the mutation gate
    # forced. It looked free -- hand back the stored list untouched -- but a PowerShell function
    # UNROLLS a returned list into a fresh array anyway, so the caller cannot tell the two apart
    # by reference, by content or by order. A branch nothing can observe is one no test can
    # distinguish from its own absence, which is the shape this module refuses in other people's
    # code. The union is computed once per type per file and cached, so the copy costs a single
    # pass over one bucket.
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [type[]]$Type)
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $script:PSCxTypeCache.Keys) {
        if (Test-PSCxAssignable -Type $Type -Candidate $t) { $merged.AddRange([object[]]$script:PSCxTypeCache[$t]) }
    }
    # Back into document order. A dictionary enumerates its keys in no defined order, so a union
    # spanning two buckets would otherwise group every node of one type before every node of the
    # other -- reordering the rows -Detailed publishes, which a reader scans by line.
    #
    # Sorted on the recorded walk position rather than on an extent offset: a node and the node it
    # CONTAINS can start at the same offset, and pre-order puts the container first, which an
    # offset comparison has no way to know.
    #
    # [array]::Sort over a key array rather than Sort-Object, which invokes a PowerShell
    # scriptblock per comparison -- the exact cost this index exists to stop paying. The keys are
    # walk positions and so are unique, which is why an unstable sort is safe here.
    $nodes = $merged.ToArray()
    $keys = [int[]]@($nodes | ForEach-Object { $script:PSCxOrderCache[$_] })
    [array]::Sort($keys, $nodes)
    return $nodes
}

function Test-PSCxAssignable {
    # Whether a candidate type satisfies any of the types asked for.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [type[]]$Type,
        [Parameter(Mandatory)] [type]$Candidate
    )
    foreach ($t in $Type) {
        if ($t.IsAssignableFrom($Candidate)) { return $true }
    }
    return $false
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

