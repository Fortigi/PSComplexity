<#
.SYNOPSIS
    Public API for PSComplexity: Measure-PSComplexity (data) and Test-PSComplexity (gate).
#>

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
    $gci = @{ File = $true; Recurse = [bool]$Recurse }
    if (Test-Path -LiteralPath $Path) { $gci.LiteralPath = $Path } else { $gci.Path = $Path }

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
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) }
    else { [System.IO.Path]::GetFullPath((Join-Path $Root $Path)) }
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
            SkipReason = "parse error: $($errors[0].Message)"
        }
    }

    $cyc = Get-PSCxCyclomaticMap -Ast $ast
    $cog = Get-PSCxCognitiveMap -Ast $ast
    $lines = Get-PSCxUnitTable -Ast $ast
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
    if ($Detailed) { $byUnit = Get-PSCxContributionMap -Ast $ast }
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
        [switch]$Recurse,
        [switch]$Detailed
    )
    foreach ($p in $Path) {
        foreach ($file in (Get-PSCxSourceFile -Path $p -Recurse:$Recurse)) {
            # OrdinalIgnoreCase: Windows and macOS resolve the same file under different
            # casing, and a case-sensitive check would let those through as two files.
            if (-not $Seen.Add($file)) { continue }
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
        [switch]$Recurse,
        [switch]$Detailed
    )
    $units = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -Recurse:$Recurse -Detailed:$Detailed)) {
        if ($fileScan.SkipReason) {
            $skipped.Add([pscustomobject]@{ File = $fileScan.File; Reason = $fileScan.SkipReason })
            continue
        }
        $units.AddRange([object[]]$fileScan.Units)
    }
    return [pscustomobject]@{
        Units         = @($units)
        Skipped       = @($skipped)
        Scope         = [pscustomobject]@{ Path = @($Path); Recurse = [bool]$Recurse; Root = (Get-Location).Path }
        MetricVersion = $script:PSCxMetricVersion
    }
}

function Measure-PSComplexity {
    <#
    .SYNOPSIS
        Measure cyclomatic and cognitive complexity of PowerShell code, per unit: each
        function and filter, each class method, constructor and initialised property, plus
        one <script-body> per file for top-level code.

    .DESCRIPTION
        Parses each .ps1/.psm1 file with the PowerShell AST and reports both metrics.
        Cognitive complexity implements the SonarSource metric in full (nesting-aware) and
        extends it for PowerShell constructs the specification does not cover:
        ForEach-Object and Where-Object score as the loop and conditional they stand in for,
        && and || as a boolean run, ?? and ??= as a ternary. Cyclomatic is the classic
        decision-point count, over the same set of constructs. A file that fails to parse is
        skipped and reported on the error stream, naming the file and the parse error;
        measurement continues over every other file rather than stopping.

    .PARAMETER Path
        One or more files or directories to measure.

    .PARAMETER Recurse
        Recurse into subdirectories when a directory is given.

    .PARAMETER Detailed
        Add a Contributions list to each record: one entry per cognitive increment, carrying
        the Line it sits on, the Construct that caused it and the Amount it added, in line
        order. The amounts sum to Cognitive.

        Read the amounts rather than the count. Anything above +1 is a structure plus the
        nesting charged for it, so four +1 rows and one +4 row reach the same total and mean
        different things -- points spread flat say the unit does too many things, points
        concentrated in one deep row say extract.

        A unit with no increments gets an empty list, not a missing property. Without the
        switch the record is exactly as documented below.

    .OUTPUTS
        [pscustomobject] with File, Unit, Line, Cyclomatic, Cognitive, MetricVersion -- one
        per unit, plus Contributions when -Detailed is given.

        These six names, their order and their types are the module's public contract
        alongside the two command names, and a test asserts them exactly: widening the
        record fails that test, so it is a decision rather than a side effect of an
        internal change. File and Unit are [string]; Line, Cyclomatic, Cognitive and
        MetricVersion are [int] -- Line as a string would silently turn a numeric sort into
        a lexical one.

        MetricVersion says which metric produced the numbers, and increments only when a
        score can change for source that did not. Anything that stores or compares scores
        should refuse to compare across two different values rather than mix them.

        Unit identifies one unit: a class member reads Class.Member, a nested function
        reads Outer/Inner, and units sharing a name in one scope carry an ordinal on every
        member of the group (Repo.Add#1, Repo.Add#2). File is relative to the working
        directory with forward slashes, so two machines produce the same key; a file outside
        that root keeps its full path.

        Line is NOT an identity. It moves whenever anything above a unit is edited, so it
        says where a unit currently starts, not which unit it is. Anything persisting or
        comparing records across commits needs something else.

    .EXAMPLE
        Measure-PSComplexity ./src -Recurse | Sort-Object Cognitive -Descending

    .EXAMPLE
        # Fail a build if anything is too complex:
        if (-not (Test-PSComplexity ./src -Recurse)) { exit 1 }
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)] [ValidateNotNullOrEmpty()] [string[]]$Path,
        [switch]$Recurse
        ,
        # Off by default because the DEFAULT SHAPE IS A CONTRACT: CI consumers parse these
        # records, and a field that appears unbidden is a breaking change dressed as a feature.
        [switch]$Detailed    )
    begin {
        # Resolved paths already emitted. Two inputs can name one file -- a directory and
        # something inside it, or a wildcard and a literal -- and measuring it twice put
        # duplicate rows in the output, doubling that file's contribution to anything that
        # counts. In `begin` rather than `process` so it also spans pipeline input, where
        # each item arrives as its own invocation of the block below.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    process {
        foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -Recurse:$Recurse -Detailed:$Detailed)) {
            # The projection: units to the output stream, a skip to the error stream.
            #
            # Write-Error rather than a warning: CI logs routinely swallow warnings, and this
            # is the module admitting it did not measure something it was asked to. It is a
            # RENDERING of $fileScan.SkipReason, not the only place that fact exists -- which
            # is what lets the gate read the reason as data instead of capturing this stream.
            if ($fileScan.SkipReason) {
                Write-Error "Skipped '$($fileScan.File)' -- $($fileScan.SkipReason)"
                continue
            }
            $fileScan.Units
        }
    }
}

function Get-PSCxAcceptanceKey {
    # The identity an acceptance is written against. Two fields, never one joined string: a
    # File outside the measured root keeps its full path, and on Windows that starts "C:", so
    # any single-separator key is ambiguous the first time somebody gates outside their repo.
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
    # The units that breach a ceiling and that nobody has argued for. Separate from the gate
    # because the gate is a thin predicate and this is the whole of what it decides.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    $accepted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Accept) { [void]$accepted.Add((Get-PSCxAcceptanceKey -File ([string]$a.File) -Unit ([string]$a.Unit))) }
    # Emitted rather than returned as an array, so the declared OutputType describes what a
    # caller actually receives -- one record at a time. The gate wraps the result in @() and
    # gets an empty array when nothing breaches, which is the same answer either way.
    $Unit | Where-Object {
        ($_.Cyclomatic -gt $MaxCyclomatic -or $_.Cognitive -gt $MaxCognitive) -and
        -not $accepted.Contains((Get-PSCxAcceptanceKey -File $_.File -Unit $_.Unit))
    }
}

function Test-PSComplexity {
    <#
    .SYNOPSIS
        Return $true if every unit is at or under the cyclomatic and cognitive ceilings;
        otherwise $false, writing a warning per offending unit. Intended as a CI gate.

    .PARAMETER Path
        One or more files or directories to check.

    .PARAMETER MaxCyclomatic
        Cyclomatic ceiling (default 15).

    .PARAMETER MaxCognitive
        Cognitive ceiling (default 15).

    .PARAMETER Recurse
        Recurse into subdirectories when a directory is given.

    .PARAMETER Accept
        Units that are allowed to exceed a ceiling, each carrying the argument for why. One
        entry per unit, with File, Unit and Reason -- for example
        @{ File = 'src/Parser.ps1'; Unit = 'Read-Token'; Reason = 'table-driven lexer; splitting it hides the table' }.

        An acceptance is a checkable claim, not a suppression. The gate THROWS, rather than
        quietly ignoring it, when one stops describing the run: no unit of that name was
        measured, the unit is now within both ceilings, or no reason was given. So a stale
        acceptance fails the build that relies on it instead of ageing silently into a mute
        button, which is what a plain suppression list becomes.

        File must match the record's File exactly -- relative to the working directory with
        forward slashes, or the full path for a file outside it.

    .OUTPUTS
        [bool]

    .EXAMPLE
        if (-not (Test-PSComplexity ./src -Recurse)) { throw 'Complexity gate failed' }
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)] [ValidateNotNullOrEmpty()] [string[]]$Path,
        [int]$MaxCyclomatic = 15,
        [int]$MaxCognitive = 15,
        [switch]$Recurse,
        # Empty is the normal case, and an empty array must bind rather than be rejected.
        [AllowEmptyCollection()] [object[]]$Accept = @()
    )
    # ValueFromPipeline needs begin/process/end, not a bare body. A bare body IS the `end`
    # block, so it would run once with $Path holding only the LAST item piped in -- and the
    # gate would return a confident verdict about one path while silently ignoring the rest.
    # Every path is collected first, then judged together, because the verdict is about the
    # whole selection.
    begin {
        $collected = [System.Collections.Generic.List[string]]::new()
    }
    process {
        $collected.AddRange([string[]]$Path)
    }
    end {
        $paths = $collected.ToArray()
        # The scan, not the record stream. What was skipped is a fact the measurement already
        # holds; reading it back off the error stream required -ErrorAction SilentlyContinue,
        # which swallowed every OTHER error into the same variable and then described it to
        # the caller as a file that did not parse.
        $scan = Get-PSCxScan -Path $paths -Recurse:$Recurse
        # Parse failures are refused rather than allowed past. A file the gate could not read
        # is a file it cannot vouch for, and "no unit exceeded a ceiling" is trivially true of
        # a file that produced no units -- the same shape as passing over an empty selection.
        if ($scan.Skipped.Count -gt 0) {
            throw ("Refusing to vouch for $($scan.Skipped.Count) file(s) that did not parse: " +
                (($scan.Skipped | ForEach-Object { "$($_.File) -- $($_.Reason)" }) -join '; ') +
                ". Fix the syntax, or exclude the file from the path you gate on.")
        }
        $units = $scan.Units

        # Refuse rather than pass. "No unit breached a ceiling" and "no unit was measured"
        # are the same $true, so a gate pointed at the wrong place reports clean -- which is
        # the failure this module exists to find in other people's code.
        if ($units.Count -eq 0) {
            $hint = if ($Recurse) { '' } else { ', or add -Recurse if they are in subdirectories' }
            throw ("Measured no units under: " + ($paths -join ', ') + ". Nothing was checked, " +
                "so a pass here would describe an empty set. Check the path exists and holds " +
                ".ps1 or .psm1 files" + $hint + '.')
        }

        # Checked BEFORE the verdict, and thrown rather than returned as $false. A stale
        # acceptance is a fault in the policy, not a complaint about the code -- reporting it
        # as a failing gate would send someone to refactor a unit that is fine.
        $faults = @($Accept | Get-PSCxAcceptanceFault -Unit $units `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
        if ($faults.Count -gt 0) {
            throw ("The acceptance list does not describe this run: " + ($faults -join '; ') +
                ". An acceptance that no longer applies is a mute button, so it fails here rather than ageing quietly.")
        }

        $violations = @(Get-PSCxUnacceptedUnit -Unit $units -Accept $Accept `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
        foreach ($v in $violations) {
            Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                    $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $MaxCyclomatic, $v.Cognitive, $MaxCognitive)
        }
        return $violations.Count -eq 0
    }
}
