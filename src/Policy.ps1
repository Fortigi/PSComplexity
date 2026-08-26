# Policy: which units are excused from the ceilings, and on what terms.
#
# Two mechanisms, deliberately different in kind:
#
#   An ACCEPTANCE is a decision. It carries a written argument, excuses the unit outright, and
#   fails the run when it stops describing anything -- the unit was renamed away, or came back
#   under the ceilings and nobody deleted the note.
#
#   A BASELINE is a ratchet. It carries no argument, caps a unit at the score it already had,
#   and exists so the gate is adoptable on a codebase that is already red. A unit in it may stay
#   ugly; it may not get worse.
#
# Both are keyed by the same unit identity, which is why they share a file. Two key builders is
# the drift this arrangement exists to prevent: an acceptance and a baseline that disagree about
# what "the same unit" means would each be right on their own terms.
#
# Everything here is PURE. The file a baseline lives in is read and written by Report.ps1, which
# owns document I/O; this file decides what the contents mean.

# The baseline FILE format, versioned separately from the report and from the metric. Three
# things that change for different reasons: the metric version moves when a score would come out
# different, the report version when the published output changes, and this when the shape of a
# baseline entry does.
$script:PSCxBaselineSchemaVersion = 1

function Get-PSCxBaselineSchemaVersion {
    # A reader for the constant above, so no other file reaches into this one's module state. The
    # gate needs the number to compare a file against; it does not need to know where it is kept.
    [OutputType([int])]
    [CmdletBinding()]
    param()
    return $script:PSCxBaselineSchemaVersion
}

function Get-PSCxPolicyKey {
    # The identity a policy is written against. NOT Get-PSCxUnitKey in Ast.ps1, which keys an
    # AST node during a walk -- a different thing that happened to want the same name.
    #
    # Two fields, never one joined string: a File outside the measured root keeps its full path,
    # and on Windows that starts "C:", so any single-separator key is ambiguous the first time
    # somebody gates outside their repo.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$File,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Unit
    )
    return "$File`u{241F}$Unit"
}

function Get-PSCxAcceptanceFault {
    # Why ONE acceptance fails to describe this run, as text. Nothing when it holds.
    #
    # An acceptance is a CHECKABLE CLAIM and not a mute button. It carries a written argument,
    # and the run fails when the claim stops being true -- the unit was renamed away, or it came
    # back under the ceilings and nobody deleted the note. A declaration that silently stops
    # applying is indistinguishable from one nobody has read in a year, and a gate full of those
    # is the thing this module exists to find in other people's code.
    #
    # One acceptance at a time, over the pipeline, so the four rules sit at the top level of a
    # process block rather than inside a loop. Written as a foreach over the list they cost
    # their nesting depth each and the function scored 14 against a ceiling of 15 -- passing,
    # and one rule away from not passing, in the function most likely to grow another rule.
    #
    # There is deliberately NO ambiguity arm. A unit identity is unique within a file, so an
    # exact File+Unit match is one or none by construction -- and a rule that cannot fire looks
    # exactly like a rule that passes. If unit identity ever stops being unique, this is the
    # comment that has to change with it.
    #
    # Unique is not the same as STABLE, and the difference is why the baseline below refuses
    # what this accepts. Duplicate definitions are told apart by an ordinal -- Get-Thing#1, #2 --
    # which renumbers when a duplicate is inserted above them. An acceptance keyed that way is
    # re-read by whoever edits the file; a baseline is committed once and reviewed rarely.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] [AllowNull()] $Acceptance,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    process {
        $file = [string]$Acceptance.File
        $name = [string]$Acceptance.Unit
        $reason = [string]$Acceptance.Reason
        if (-not $file -or -not $name) {
            return "an acceptance needs both File and Unit, got File='$file' Unit='$name'"
        }
        if (-not $reason.Trim()) {
            return "$file $name is accepted with no reason -- an acceptance carries the argument for it, or it is a mute button"
        }
        $found = @($Unit | Where-Object { $_.File -eq $file -and $_.Unit -eq $name })
        if ($found.Count -eq 0) {
            return "$file $name is accepted but no such unit was measured -- it was renamed, moved, or is outside the path being gated"
        }
        if ($found[0].Cyclomatic -le $MaxCyclomatic -and $found[0].Cognitive -le $MaxCognitive) {
            return "$file $name is accepted but is within both ceilings -- delete the acceptance, it is no longer an argument about anything"
        }
    }
}

function Get-PSCxUnacceptedUnit {
    # The units that breach a ceiling and that no policy excuses. Separate from the gate because
    # the gate is a thin predicate and this is the whole of what it decides.
    #
    # BaselineMap is optional and defaults to empty, because two callers want different answers
    # from the same rule: the gate asks "what still fails", and the baseline writer asks "what
    # breaches at all" -- the second must not subtract what the current file already permits, or
    # regenerating would drop every entry it was about to rewrite.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        [AllowEmptyCollection()] [hashtable]$BaselineMap = @{}
    )
    $accepted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Accept) { [void]$accepted.Add((Get-PSCxPolicyKey -File ([string]$a.File) -Unit ([string]$a.Unit))) }
    # Emitted rather than returned as an array, so the declared OutputType describes what a
    # caller actually receives -- one record at a time. The gate wraps the result in @() and
    # gets an empty array when nothing breaches, which is the same answer either way.
    $Unit | Where-Object {
        ($_.Cyclomatic -gt $MaxCyclomatic -or $_.Cognitive -gt $MaxCognitive) -and
        -not $accepted.Contains((Get-PSCxPolicyKey -File $_.File -Unit $_.Unit)) -and
        -not (Test-PSCxWithinBaseline -Unit $_ -Map $BaselineMap)
    }
}

function Test-PSCxStableIdentity {
    # Whether a unit name identifies the same unit across an edit elsewhere in the file.
    #
    # Duplicate definitions in one file are told apart by an ORDINAL -- Get-Thing#1, #2, #3 --
    # and an ordinal renumbers when a duplicate is inserted above it. Measured: adding a third
    # Get-Thing at the top moves the unit that was #1 to #2, and #1 then names a function nobody
    # has seen before, so a recorded score would silently start capping it.
    #
    # A line number would be no better and is worse in the ordinary case, where it churns on
    # every edit above the unit. Nothing about the name is salvageable here, so the entry is
    # refused rather than approximated.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Unit
    )
    return -not $Unit.Contains('#')
}

function Get-PSCxBaselineMap {
    # Entries as a lookup keyed by unit identity, refusing a file that names one unit twice.
    #
    # Two entries for one unit is not a merge to resolve quietly: whichever wins decides what the
    # gate permits, and the loser reads as a recorded decision that is silently doing nothing.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Entry
    )
    $map = @{}
    foreach ($e in $Entry) {
        $key = Get-PSCxPolicyKey -File ([string]$e.file) -Unit ([string]$e.unit)
        if ($map.ContainsKey($key)) {
            throw ("The baseline names $($e.file) $($e.unit) twice. One of the two decides what " +
                'the gate permits and the other silently does nothing, so which one you meant ' +
                'cannot be read off the file.')
        }
        $map[$key] = $e
    }
    return $map
}

function Test-PSCxWithinEntry {
    # Whether this unit is at or under the scores one entry records. Named to parallel
    # Test-PSCxWithinBaseline below: same question, one against an entry and one against a map.
    #
    # Both metrics, and both must hold. A unit that traded cyclomatic for cognitive has not stayed
    # the same, and permitting it because one number fell is how a ratchet loosens.
    #
    # The ONE place the comparison lives, because two callers need it and they need the same
    # answer: the gate asks it to decide what to permit, and the fault check asks it to tell an
    # improvement from a regression. Two spellings would disagree exactly where a unit moved in
    # both directions at once -- the case neither author would have thought to test.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Unit,
        [Parameter(Mandatory)] $Entry
    )
    return ([int]$Unit.Cyclomatic -le [int]$Entry.cyclomatic -and
        [int]$Unit.Cognitive -le [int]$Entry.cognitive)
}

function Test-PSCxWithinBaseline {
    # Whether this unit is recorded and has not got worse. False when it is not recorded at all,
    # which is the answer that makes an un-baselined unit face the real ceilings.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Map
    )
    $key = Get-PSCxPolicyKey -File ([string]$Unit.File) -Unit ([string]$Unit.Unit)
    if (-not $Map.ContainsKey($key)) { return $false }
    return Test-PSCxWithinEntry -Unit $Unit -Entry $Map[$key]
}

function Get-PSCxBaselineScoreFault {
    # Why one entry's NUMBERS no longer describe the unit, as text. Nothing when they do.
    #
    # Split from the entry checks so neither function carries both kinds of rule: those are about
    # whether the entry points at anything, these about what it permits. Folded together the
    # single function sits over the complexity ceiling this module gates itself on.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Unit,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    if ($Unit.Cyclomatic -le $MaxCyclomatic -and $Unit.Cognitive -le $MaxCognitive) {
        return "$($Entry.file) $($Entry.unit) is recorded but is now within both ceilings (cyclomatic $($Unit.Cyclomatic), cognitive $($Unit.Cognitive)) -- delete the entry, the real bar covers it"
    }
    # Covered FIRST, then better. A unit can be both at once -- worse on cyclomatic, better on
    # cognitive -- and those two facts do not weigh the same: the regression is what the gate
    # exists to catch, and calling it an improvement sends somebody to lower an entry for a unit
    # that just got worse. Saying nothing here lets it fall through to the ordinary violation
    # path, which says the true thing.
    if (-not (Test-PSCxWithinEntry -Unit $Unit -Entry $Entry)) { return }
    if ($Unit.Cyclomatic -lt [int]$Entry.cyclomatic -or $Unit.Cognitive -lt [int]$Entry.cognitive) {
        return ("$($Entry.file) $($Entry.unit) improved to cyclomatic $($Unit.Cyclomatic), cognitive $($Unit.Cognitive) " +
            "from a recorded $($Entry.cyclomatic)/$($Entry.cognitive) -- lower the entry, or run " +
            'with -UpdateBaseline. A ratchet that keeps the old number stops being one')
    }
}

function Get-PSCxBaselineFault {
    # Why ONE baseline entry fails to describe this run, as text. Nothing when it holds.
    #
    # Same discipline as an acceptance, for the same reason: a recorded permission that has
    # stopped describing anything is indistinguishable from one nobody has read in a year. The
    # arms differ because a baseline says something narrower -- not "this is fine" but "this is
    # no worse than it was".
    #
    # One entry at a time over the pipeline, so each rule sits at the top level of a process
    # block rather than inside a loop, where it would cost its nesting depth against the ceiling
    # this module gates itself on.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] [AllowNull()] $Entry,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    process {
        $file = [string]$Entry.file
        $name = [string]$Entry.unit
        if (-not $file -or -not $name) {
            return "a baseline entry needs both file and unit, got file='$file' unit='$name'"
        }
        if (-not (Test-PSCxStableIdentity -Unit $name)) {
            return ("$file $name is recorded, but the ordinal in that name renumbers when a " +
                'duplicate definition is inserted above it, so this entry would start capping a ' +
                'different function. Rename one of the duplicates -- the later definition ' +
                'shadows the earlier at run time anyway')
        }
        if ($Accept | Where-Object { [string]$_.File -eq $file -and [string]$_.Unit -eq $name }) {
            return "$file $name is both accepted and recorded in the baseline -- the acceptance already excuses it, so the entry permits nothing"
        }
        $found = @($Unit | Where-Object { $_.File -eq $file -and $_.Unit -eq $name })
        if ($found.Count -eq 0) {
            return "$file $name is recorded but no such unit was measured -- it was renamed, moved, or is outside the path being gated"
        }
        return Get-PSCxBaselineScoreFault -Entry $Entry -Unit $found[0] `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive
    }
}

function Get-PSCxBaselineDocumentFault {
    # Why a baseline FILE cannot be compared against this run at all, as text. Nothing when it can.
    #
    # Separate from the per-entry rules because these refuse the whole document: once the numbers
    # are known to mean something else, there is no sensible verdict to reach entry by entry.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Document,
        [Parameter(Mandatory)] [int]$MetricVersion,
        [Parameter(Mandatory)] [int]$SchemaVersion
    )
    if ($null -eq $Document) { return 'the baseline file held no document' }
    # -ne rather than -lt: a file written by a NEWER PSComplexity is equally uncomparable, and
    # reading it as though it were current is the direction that fails silently.
    if ([int]$Document.schemaVersion -ne $SchemaVersion) {
        return ("the baseline is schemaVersion $($Document.schemaVersion) and this PSComplexity " +
            "writes $SchemaVersion -- regenerate it with -UpdateBaseline")
    }
    if ([int]$Document.metricVersion -ne $MetricVersion) {
        return ("the baseline was recorded against metric version $($Document.metricVersion) and " +
            "this run measures $MetricVersion -- the numbers are not comparable, so every entry " +
            'would be a guess. Regenerate it with -UpdateBaseline and review the diff')
    }
    if ($null -eq $Document.units) {
        return 'the baseline has no units array -- an empty baseline records an empty array, not nothing'
    }
}

function Get-PSCxBaselineRaise {
    # The units an update would have to record WORSE than the file already does.
    #
    # The one thing -UpdateBaseline must never do. A ratchet that absorbs a regression when you
    # re-run the tool is a suppression list with extra steps, and the regression it absorbs is
    # exactly the one the gate existed to catch.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Map
    )
    $Unit | Where-Object {
        $Map.ContainsKey((Get-PSCxPolicyKey -File ([string]$_.File) -Unit ([string]$_.Unit))) -and
        -not (Test-PSCxWithinBaseline -Unit $_ -Map $Map)
    }
}

function Get-PSCxBaselineDocument {
    # The baseline to write: every unit that breaches a ceiling and that nobody has accepted, at
    # the score it has now.
    #
    # Units are ordered by file then unit so a regenerated file has a readable diff. Left
    # unordered, enumeration reshuffles the whole document on every run and the one line that
    # changed is unfindable in review -- which is where a ratchet is actually enforced.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        [Parameter(Mandatory)] [int]$MetricVersion,
        [Parameter(Mandatory)] [int]$SchemaVersion,
        [Parameter(Mandatory)] [datetime]$GeneratedAt
    )
    $breaching = @(Get-PSCxUnacceptedUnit -Unit $Unit -Accept $Accept -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
    $entries = @($breaching | Sort-Object File, Unit | ForEach-Object {
            [pscustomobject]@{
                file       = $_.File
                unit       = $_.Unit
                cyclomatic = [int]$_.Cyclomatic
                cognitive  = [int]$_.Cognitive
            }
        })
    return [pscustomobject]@{
        schemaVersion = $SchemaVersion
        metricVersion = $MetricVersion
        generatedAt   = $GeneratedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        units         = $entries
    }
}
