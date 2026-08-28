# The scan: turning paths into measured units, as DATA.
#
# Apart from Measure-PSComplexity.ps1, which holds the two public projections over this. The
# reason is measured rather than aesthetic: a covering suite is re-run once per mutant of the file
# it covers, and tests/Measure.Tests.ps1 takes 18 seconds because 134 tests each measure real
# source -- profiled, 16.7s of that is test bodies rather than fixture setup, so making the
# fixtures cheaper would not have helped. These 35 mutants were paying for it and need one small
# fixture instead.
#
# The split follows a seam the docstring already named: "the scan -- measurement as data -- and
# the two public projections over it". This is the first half.

function Get-PSCxSourceFile {
    # Resolve a path (file or directory) to the PowerShell source files to measure.
    #
    # [string[]] and not [string], unlike the streaming collectors: this RETURNS the whole
    # collection as one value rather than emitting items, so the array form is the accurate
    # declaration. The analyzer says so, which is how the distinction was found.
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path, [switch]$Recurse)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [string[]]@((Resolve-Path -LiteralPath $Path).Path) }

    # Take an existing path literally, and as a wildcard only when nothing is there. -Path
    # glob-parses '[', so a real directory named 'my[1]proj' matches nothing and the scan
    # reports a clean zero over code it never opened.
    #
    # A path that is neither returns an empty list HERE rather than reaching Get-ChildItem, which
    # would write a PathNotFound error of its own. That error was worse than useless: it named
    # this file and this line, it was attributed to Get-ChildItem rather than to the module, and
    # it did not reach the caller's -ErrorVariable -- so the only thing a consumer saw was zero
    # units. Get-PSCxPathScan records the empty result as a fact instead, and the gate refuses it.
    $gci = @{ File = $true; Recurse = [bool]$Recurse }
    if (Test-Path -LiteralPath $Path) { $gci.LiteralPath = $Path }
    elseif (Test-Path -Path $Path) { $gci.Path = $Path }
    else { return [string[]]@() }

    # Filter on the extension rather than with -Include, which a directory ignores unless
    # -Recurse is also present: a flat folder would resolve to zero files and every number
    # after it would describe the empty set.
    return [string[]]@(Get-ChildItem @gci |
            Where-Object { $_.Extension -in '.ps1', '.psm1' } |
            ForEach-Object { $_.FullName })
}

# Which metric produced a number. Two scores are comparable only if the same metric produced
# them, and this module's metric has already moved twice for unchanged source: 0.3.0 taught it
# PowerShell's own flow constructs, and 0.4.0 stopped merging two units written on one line.
# Both were correct, and both silently re-scored code nobody had touched.
#
# It increments whenever a score can change for source that did not, which is a narrower rule
# than the module version: a bug fix that only affects messages, or a new field on the record,
# leaves it alone. Anything persisting or comparing scores -- a committed baseline, a diffed
# report -- must refuse to compare across two different values rather than mix them.
#
# Starts at 1 with 0.4.0. Scores from earlier releases carry no version and are not comparable
# with these; that is a statement about what was never recorded, not a claim that they agree.
$script:PSCxMetricVersion = 1

function Get-PSCxRelativePath {
    # A path two machines can agree on.
    #
    # File used to be absolute and platform-separated, so the same source measured on the two
    # CI legs produced disjoint key sets -- C:\...\src\A.ps1 against /home/.../src/A.ps1 --
    # and anything comparing runs across them matched nothing while looking like it worked.
    # The README had rendered it relative all along, so the absolute form was not a decision
    # anyone recorded.
    #
    # Separators are normalised to '/' because that is the half that does not vary: a Windows
    # reader understands src/A.ps1, and a key containing a backslash cannot be matched by a
    # Linux run at all.
    #
    # The PLATFORM separator, not a literal backslash. On Linux a backslash is an ordinary
    # filename character, so replacing it there corrupts a legal path -- and the replacement
    # is a no-op on the one platform where the self-mutation gate runs, which is how a
    # hard-coded one survived every mutant while looking tested.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )
    # A RELATIVE Path resolves against Root, not against the working directory. GetFullPath
    # alone silently uses the CWD, so the function only gave the right answer while its one
    # caller happened to pass an absolute path AND a Root equal to the CWD -- two conditions
    # that both had to hold and neither of which was stated. The sibling project shipped the
    # same shape and it was a live hole there, because a config may name a file by full path.
    $full = [System.IO.Path]::IsPathRooted($Path) ?
        [System.IO.Path]::GetFullPath($Path) :
        [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }
    # Outside the root, keep the full path. A ../../ chain says less than the absolute path
    # does and is no more portable, so pretending would only hide where the file came from.
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Replace([System.IO.Path]::DirectorySeparatorChar, '/')
    }
    return $full.Substring($rootFull.Length).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
}

function Get-PSCxChangedSet {
    # The caller's changed-file list, normalised into a set the scan can compare against.
    #
    # Both sides have to be spelled the same way or the filter matches nothing and the run reports
    # a confident pass over zero units. A list comes from git as repo-relative with forward
    # slashes; a File on a record comes from Get-PSCxRelativePath. Putting both through the same
    # function is what makes 'src/A.ps1', './src/A.ps1', 'src\A.ps1' and an absolute path the same
    # entry.
    #
    # OrdinalIgnoreCase for the same reason the rest of this module uses it: a config that fails on
    # one platform and not the other is worse than one that fails on both.
    [OutputType([System.Collections.Generic.HashSet[string]])]
    [CmdletBinding()]
    param(
        # AllowEmptyString as well as AllowEmptyCollection: a Mandatory [string[]] rejects a
        # blank ENTRY, and `git diff --name-only` piped through PowerShell routinely yields one
        # as a trailing line. Without it the blank-skipping below is unreachable and the caller
        # gets a binding error instead.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        [Parameter(Mandatory)] [string]$Root
    )
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $ChangedFile) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        [void]$set.Add((Get-PSCxRelativePath -Path $f.Trim() -Root $Root))
    }
    # -NoEnumerate, because a HashSet is enumerable and PowerShell unrolls it on the way out: an
    # empty one becomes $null and a one-element one becomes the STRING it holds -- both of which
    # fail to bind several frames away from the return that caused them. The comma-wrap does the
    # same job and declares an object[], which is not what this returns.
    Write-Output -InputObject $set -NoEnumerate
}

function Get-PSCxUnmatchedPath {
    # One record for a requested path that produced no source file: what was asked for, why it
    # produced nothing, and whether the path is THERE at all.
    #
    # Both facts, because the two consumers need different ones. They are different situations:
    # a path that is not there is a typo or a wrong working directory, and nothing downstream can
    # be right; a path that IS there and holds no PowerShell is an ordinary outcome -- a docs
    # directory, a tree filtered down to nothing -- and a measurement command that treated it as
    # a fault would fail every legitimately empty run. The gate refuses both, because a ceiling
    # applied to nothing is not a gate; Measure-PSComplexity reports only the first.
    #
    # Its own function rather than a conditional inside the walk: Get-PSCxPathScan already carries
    # its loop's nesting against the ceiling this module gates itself on.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    # Both spellings, matching Get-PSCxSourceFile: a directory named 'my[1]proj' is real and only
    # -LiteralPath sees it, while a wildcard is real and only -Path resolves it.
    $exists = (Test-Path -LiteralPath $Path) -or (Test-Path -Path $Path)
    $reason = 'no such path'
    if ($exists) { $reason = 'holds no .ps1 or .psm1 file' }
    return [pscustomobject]@{ Path = $Path; Reason = $reason; Exists = $exists }
}

function Get-PSCxUnmatchedPathFault {
    # Why the paths this run was asked for do not describe it, as text. Nothing when they all
    # matched something.
    #
    # The mixed case is the one this exists for, and it is the failure the whole module is about
    # aimed inward: Get-PSCxEmptyScanFault below fires only when the run measured NOTHING, so a
    # single valid path masked any number of mistyped ones. Measured, before this existed:
    # Test-PSComplexity @('./src/Ast.ps1', '/nope') returned $true -- a green gate over a path
    # that does not exist.
    #
    # Separate from the empty-scan fault rather than folded into it, because both are reachable
    # and they say different things: every path wrong is "you measured nothing", some paths wrong
    # is "you measured less than you asked for". A run where every path is wrong measures nothing
    # and is refused by the other rule first.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unmatched)
    if ($Unmatched.Count -eq 0) { return $null }
    return ('Refusing to vouch for a run that could not read ' + $Unmatched.Count +
        ' of the path(s) it was given: ' +
        (($Unmatched | ForEach-Object { "$($_.Path) -- $($_.Reason)" }) -join '; ') +
        '. A gate that skips what it cannot find reports a pass over the part it did reach, ' +
        'which reads as a stronger claim than it is. Fix the path, or stop naming it.')
}

function Get-PSCxEmptyScanFault {
    # Why a run that measured nothing cannot be believed, or $null when it can.
    #
    # "No unit breached a ceiling" and "no unit was measured" are the same $true, so a gate
    # pointed at the wrong place reports clean -- the failure this module exists to find in other
    # people's code.
    #
    # NOT for a diff-scoped run. There, measuring nothing is an ordinary outcome -- a pull request
    # touching only markdown -- and refusing it would fail every such build. What keeps that
    # honest is the subset notice below, not a refusal; and the empty changed-file LIST, which is
    # the case that actually indicates a broken diff command, is refused separately.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$UnitCount,
        [Parameter(Mandatory)] [bool]$Filtered,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Path,
        [Parameter(Mandatory)] [bool]$Recurse
    )
    if ($UnitCount -gt 0 -or $Filtered) { return $null }
    $hint = $Recurse ? '' : ', or add -Recurse if they are in subdirectories'
    return ('Measured no units under: ' + ($Path -join ', ') + '. Nothing was checked, so a pass ' +
        'here would describe an empty set. Check the path exists and holds .ps1 or .psm1 files' +
        $hint + '.')
}

function Get-PSCxSubsetNotice {
    # What a diff-scoped run must say out loud, or $null for a whole-tree run.
    #
    # A filtered pass reported as a whole-tree pass is worse than no gate: it reads as a stronger
    # claim than it is, and the reader has no way to tell. The gate prints nothing at all when it
    # passes, so without this a run over two files and a run over the repository are the same
    # silence.
    #
    # Text rather than a Write-Warning here, so the sentence is a value a test can compare and the
    # caller decides which stream it belongs on.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Scan)
    if ($null -eq $Scan.Scope.ChangedFile) { return $null }
    $files = @($Scan.Scope.ChangedFile).Count
    $units = @($Scan.Units).Count
    return ("Measured $units unit(s) from $files changed file(s), not the whole tree. This verdict " +
        'covers only what -ChangedFile named; it is not a statement about the rest of the code.')
}

function Get-PSCxScanFault {
    # Why this measurement cannot be gated on at all, as text. Nothing when it can.
    #
    # Both scan-level refusals in ONE place, in the order they have to fire, because that order is
    # a decision rather than a detail. Every path wrong measures nothing and is answered by the
    # count rule, which carries the -Recurse hint; SOME paths wrong measures plenty and is
    # answered by the path rule. Reversed, the count rule could never fire -- and a rule that
    # cannot fire looks exactly like a rule that keeps passing.
    #
    # Written here rather than as two consecutive ifs in Test-PSComplexity for the reason that
    # command keeps every other decision out of itself: it is a thin predicate, and the ordering
    # is now something a test can hold rather than something a reader has to infer from statement
    # order.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$Path,
        [Parameter(Mandatory)] [bool]$Filtered,
        [switch]$Recurse
    )
    $empty = Get-PSCxEmptyScanFault -UnitCount @($Scan.Units).Count -Path $Path `
        -Recurse:$Recurse -Filtered $Filtered
    if ($empty) { return $empty }
    return Get-PSCxUnmatchedPathFault -Unmatched @($Scan.Unmatched)
}

function Assert-PSCxChangedFile {
    # Refuse a changed-file list that is empty, naming why.
    #
    # An empty list means "nothing changed", and taken at face value it produces a confident pass
    # over zero units -- the vacuous score this module exists to find in other people's code,
    # aimed inward. It is also the single most likely thing a caller passes by accident: a git
    # command that failed, matched nothing, or ran against a shallow clone where the base ref does
    # not exist prints nothing and exits 0.
    #
    # A caller who genuinely has no changed files wants to SKIP the gate, and that is a decision
    # only they can make -- so it is theirs to make, in their own script, where it is visible.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        # AllowEmptyString for the same reason as Get-PSCxChangedSet: a blank entry is what a
        # diff emits as a trailing line, and rejecting it at the binder turns the refusal this
        # function exists to make into a message about parameter binding.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [AllowEmptyString()] [string[]]$ChangedFile
    )
    if (@($ChangedFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { return }
    throw ('-ChangedFile was given no files. An empty list would restrict the run to nothing and ' +
        'report a pass over zero units, which is the failure this module exists to find -- and it ' +
        'is what a diff command prints when it fails, matches nothing, or runs against a shallow ' +
        'clone whose base ref is missing. If nothing changed, skip the gate rather than asking it ' +
        'to measure an empty set.')
}

function Write-PSCxUnmatchedPath {
    # Render each path that produced no source file to the error stream.
    #
    # Write-Error, matching how a skipped file is reported, and for the same reason: this is the
    # module admitting it did not measure something it was asked to, and CI logs routinely swallow
    # warnings. It is a RENDERING of a fact the scan already holds, never the only place that fact
    # exists -- which is what lets the gate refuse the same paths as data.
    #
    # Its own function because both of Measure-PSComplexity's routes need it and neither owns it.
    [OutputType([void])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unmatched)
    foreach ($u in $Unmatched) {
        # A path that exists and holds no PowerShell is an ordinary empty measurement, not a
        # fault: this command applies no thresholds and reaches no verdict, so refusing one would
        # turn measurement into judgement -- and under ErrorActionPreference = Stop it would
        # terminate a run over a directory the caller knows is empty. The gate refuses it there,
        # where a ceiling applied to nothing genuinely is a broken gate.
        if ($u.Exists) { continue }
        Write-Error "Measured nothing under '$($u.Path)' -- $($u.Reason)"
    }
}

function Get-PSCxUnitRecord {
    # Shape one output record. The only place the published shape is decided.
    #
    # A function rather than inline, because the caller sits inside a per-unit loop and a
    # conditional there costs its nesting depth rather than one point. Folded back into that
    # loop, the -Detailed branch alone puts Measure-PSComplexity over the cognitive ceiling
    # this module gates itself on.
    #
    # Get-, not New-, although it builds something: New- is a state-changing verb, so
    # PSUseShouldProcessForStateChangingFunctions demands -WhatIf support this has no use for.
    # It also matches the Get-PSCx*Row composers, which build rows the same way.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$File,
        [Parameter(Mandatory)] [string]$Unit,
        [Parameter(Mandatory)] [int]$Line,
        [Parameter(Mandatory)] [int]$Cyclomatic,
        [Parameter(Mandatory)] [int]$Cognitive,
        [Parameter(Mandatory)] [int]$MetricVersion,
        [AllowEmptyCollection()] [object[]]$Contributions,
        [switch]$Detailed
    )
    $record = [pscustomobject]@{
        File          = $File
        Unit          = $Unit
        Line          = $Line
        Cyclomatic    = $Cyclomatic
        Cognitive     = $Cognitive
        MetricVersion = $MetricVersion
    }
    # Absent and empty are different answers, and a consumer iterating this should not have to
    # tell them apart -- so -Detailed always adds the property, even for a decision-free unit.
    if ($Detailed) { $record | Add-Member -NotePropertyName Contributions -NotePropertyValue @($Contributions) }
    return $record
}

function Get-PSCxSkipReason {
    # Why a file produced no units, as text, told apart by what actually went wrong.
    #
    # Parser::ParseFile reports an I/O failure through the SAME out-parameter as a syntax error --
    # a missing file, a directory, a permission denial and a deleted-mid-scan file all arrive as a
    # ParseError. Calling every one of them a "parse error" sent the reader to inspect syntax that
    # was perfectly correct, and the gate's own advice compounded it by saying "fix the syntax".
    #
    # Discriminated on ErrorId rather than on the message text, which is prose and may be
    # localised. FileReadError is what the parser raises when it could not read the bytes at all.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ParseError)
    if ($ParseError.ErrorId -eq 'FileReadError') { return "could not be read: $($ParseError.Message)" }
    return "parse error: $($ParseError.Message)"
}

function Get-PSCxFileScan {
    # One file's measurement AS DATA: the units it produced, or the reason it produced none.
    #
    # Nothing is written to the error stream here, and that is the point. A skip that exists
    # only as an error is a fact the caller has to rebuild by capturing the stream and reading
    # message text -- which is what the gate did, with -ErrorAction SilentlyContinue, so any
    # unrelated failure reached the user described as a parse error.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [switch]$Detailed
    )
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors)
    # The per-node answer tables are for THIS file. Keyed by node reference they can never answer
    # wrongly across parses, so this is about memory rather than correctness: without it a gate
    # over a large tree holds every node of every file it has seen.
    Clear-PSCxAstCache
    # Relative to where the caller is standing, which for a repo-scoped run is the repo. Not a
    # parameter: a root nobody passes is a root nobody gets wrong. Resolved for BOTH arms, so a
    # skipped file is named the same way a measured one is.
    $relative = Get-PSCxRelativePath -Path $File -Root (Get-Location).Path
    if ($errors) {
        # The FIRST error. Later ones are usually cascade from it, and a skip that does not say
        # why is the one thing the reason string exists to prevent.
        return [pscustomobject]@{
            File       = $relative
            Units      = @()
            SkipReason = Get-PSCxSkipReason -ParseError $errors[0]
        }
    }

    # ONE traversal, shared. Get-PSCxUnitTable is a full FindAll walk that invokes a PowerShell
    # predicate for every node, and it used to run three times against the same AST in a single
    # pass -- once here for the line numbers, and once inside each metric map.
    $lines = Get-PSCxUnitTable -Ast $ast
    # Each row set collected ONCE, here, and projected into whatever the run needs. The cognitive
    # rows are needed twice -- summed into the map, and grouped per unit for -Detailed -- and
    # collecting them inside each map meant -Detailed walked the tree a second time for rows that
    # already existed.
    $cyc = Get-PSCxCyclomaticMap -Row @(Get-PSCxCyclomaticRow -Ast $ast) -UnitTable $lines
    $cogRows = @(Get-PSCxCognitiveRow -Ast $ast)
    $cog = Get-PSCxCognitiveMap -Row $cogRows -UnitTable $lines
    # Source order, not hashtable order. .NET enumerates a hashtable by bucket layout, which is
    # neither insertion nor line order and is not required to be stable -- so two runs over one
    # unchanged file could emit the same rows in different sequences. Nothing here noticed,
    # because the gate takes a max and a human reads a table; a committed baseline or a diffed
    # report would have.
    #
    # Line first, then unit name: two units CAN start on the same line
    # (`function A { } function B { }`), and a tie left unbroken puts the nondeterminism
    # straight back.
    $ordered = @($lines.Keys | Sort-Object @{ Expression = { $lines[$_] } }, @{ Expression = { $_ } })
    # Names computed over the whole file, because disambiguating a repeat needs to know there
    # IS a repeat. Done per row, the first of a pair could not be told apart from a unit that
    # never had a twin.
    $display = Get-PSCxDisplayName -OrderedKeys $ordered
    # Once per file rather than per unit: the rows are one walk, and asking for them per unit
    # would re-walk the tree for every function in the file.
    $byUnit = @{}
    if ($Detailed) { $byUnit = Get-PSCxContributionMap -Row $cogRows }
    $units = foreach ($k in $ordered) {
        # Two traps stacked here, and the empty list has to survive BOTH.
        #
        # A decision-free unit has no entry, and @($byUnit[$k]) on a missing key gives an array
        # of ONE null rather than an empty one -- a contribution with no line, no construct and
        # no amount, which is worse than the absent property this exists to avoid because it
        # survives a count check.
        #
        # And the fix cannot be written as `$c = if (...) { ... } else { @() }`: an if used as
        # an expression yields its branch's OUTPUT, and emitting @() emits nothing, so the
        # variable lands back on $null. Assign first, then overwrite.
        $contrib = @()
        if ($byUnit.ContainsKey($k)) { $contrib = $byUnit[$k] }
        Get-PSCxUnitRecord -File $relative -Unit $display[$k] -Line $lines[$k] `
            -Cyclomatic $cyc[$k] -Cognitive $cog[$k] -MetricVersion $script:PSCxMetricVersion `
            -Contributions $contrib -Detailed:$Detailed
    }
    return [pscustomobject]@{ File = $relative; Units = @($units); SkipReason = $null }
}

function Get-PSCxPathScan {
    # Every file under Path, measured, ONE per-file scan at a time.
    #
    # Streaming on purpose. Measure-PSComplexity emits units as it walks, and the aggregate
    # below is a fold over this -- so both public commands share one walk without forcing the
    # streaming one to buffer a whole tree to get it.
    #
    # -Seen belongs to the caller, because dedup has to span pipeline input: paths arrive one
    # invocation at a time, and a set created here would forget the previous one.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Path,
        # AllowEmptyCollection, because an empty set is the NORMAL starting point and
        # Mandatory alone rejects it. Without this the binding failure surfaces wherever the
        # caller happens to report errors -- the gate described it as a file that did not
        # parse, which is the same class of misdiagnosis this scan exists to end.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]]$Seen,
        # Paths that resolved to no source file at all. Caller-owned for the same reason -Seen is:
        # paths arrive one invocation at a time down the pipeline, and a list created here would
        # forget the previous one -- so the run could not say afterwards what it never read.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Unmatched,
        # $null means no filter. An EMPTY set would be ambiguous -- "nothing changed" and "no
        # filter was asked for" are different answers -- so the public commands refuse an empty
        # list rather than passing one down.
        [System.Collections.Generic.HashSet[string]]$ChangedSet,
        [switch]$Recurse,
        [switch]$Detailed
    )
    $root = (Get-Location).Path
    foreach ($p in $Path) {
        $files = @(Get-PSCxSourceFile -Path $p -Recurse:$Recurse)
        # Recorded BEFORE the changed-file filter, because "this path is not there" and "nothing in
        # this path changed" are different answers and only the first one is a mistake.
        if ($files.Count -eq 0) {
            $Unmatched.Add((Get-PSCxUnmatchedPath -Path $p))
            continue
        }
        foreach ($file in $files) {
            # OrdinalIgnoreCase: Windows and macOS resolve the same file under different
            # casing, and a case-sensitive check would let those through as two files.
            if (-not $Seen.Add($file)) { continue }
            # BEFORE the parse, so a diff-scoped run over a large tree does not read every file
            # only to throw most of them away. The verdict is identical either way; the cost is
            # not, and cost is most of why anyone asks for a diff-scoped run.
            if ($null -ne $ChangedSet -and
                -not $ChangedSet.Contains((Get-PSCxRelativePath -Path $file -Root $root))) { continue }
            # BEFORE the parse, not after. A line written afterwards names files that are
            # already done, so a scan stuck on one file looks exactly like a scan that has
            # finished -- which is the whole complaint. Named here, the last line printed IS
            # the file being read.
            #
            # Verbose rather than a progress bar or a default-on line: this is the command a
            # CI gate calls, and a gate that chatters gets its output filtered, which takes
            # the parse errors with it.
            Write-Verbose "Measuring $file"
            Get-PSCxFileScan -File $file -Detailed:$Detailed
        }
    }
}

function Get-PSCxScan {
    # The complete measurement: what was asked for, what was measured, and what was not.
    #
    # The record stream Measure-PSComplexity publishes is a PROJECTION of this -- the same
    # relationship a cognitive map has to its rows. Facts about the RUN, which files were
    # skipped and why and what was in scope, have nowhere else to live: without this they are
    # destroyed at emission and every consumer rebuilds them from whatever leaked out.
    #
    # Internal deliberately. This is the shape a report, a changed-files run and a committed
    # baseline all need, and settling it in one place is what stops each inventing a private
    # version and the first one shipped becoming the contract by accident.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Path,
        # The files a caller says changed, or the parameter omitted for a whole-tree scan. It is
        # recorded in Scope, because a number over a subset that cannot say WHICH subset is worse
        # than no number: it reads as a stronger claim than it is.
        [AllowEmptyCollection()] [string[]]$ChangedFile,
        [switch]$Recurse,
        [switch]$Detailed
    )
    $units = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $unmatched = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $root = (Get-Location).Path
    # $null when no filter was asked for, which is what tells the walk to read everything. Built
    # from $PSBoundParameters rather than from the value, so an explicitly empty list is
    # distinguishable from an absent one -- the public commands refuse the first.
    $changedSet = $null
    if ($PSBoundParameters.ContainsKey('ChangedFile')) {
        $changedSet = Get-PSCxChangedSet -ChangedFile $ChangedFile -Root $root
    }
    foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -Unmatched $unmatched -ChangedSet $changedSet -Recurse:$Recurse -Detailed:$Detailed)) {
        if ($fileScan.SkipReason) {
            $skipped.Add([pscustomobject]@{ File = $fileScan.File; Reason = $fileScan.SkipReason })
            continue
        }
        $units.AddRange([object[]]$fileScan.Units)
    }
    # Assigned OUT of the hashtable literal, and typed. A $( ) subexpression UNROLLS a
    # one-element array to the element, so a run filtered to a single file recorded a bare string
    # where every consumer expects a list -- and the report then serialised it as one, which the
    # published schema rejects. Same trap as returning an empty HashSet.
    $changed = $null
    if ($null -ne $changedSet) { $changed = [string[]]@($changedSet | Sort-Object) }
    return [pscustomobject]@{
        Units         = @($units)
        Skipped       = @($skipped)
        # Paths that produced no source file. Beside Skipped rather than folded into it: a file
        # found and not measured and a path never found at all are answered by different fixes,
        # and an aggregate that cannot say which it hit is the shape this project distrusts.
        Unmatched     = @($unmatched)
        Scope         = [pscustomobject]@{
            Path        = @($Path)
            Recurse     = [bool]$Recurse
            Root        = $root
            # $null, not @(), when no filter was asked for. Absent and empty are different
            # answers here: a consumer has to be able to tell a whole-tree run from one filtered
            # down to nothing, and only one of those may be read as a full measurement.
            ChangedFile = $changed
        }
        MetricVersion = $script:PSCxMetricVersion
    }
}

function Get-PSCxMetricVersion {
    # A reader for the constant above, so no other file reaches into this one's module state. The
    # gate needs the number to stamp a baseline with; it does not need to know where it is kept.
    [OutputType([int])]
    [CmdletBinding()]
    param()
    return $script:PSCxMetricVersion
}
