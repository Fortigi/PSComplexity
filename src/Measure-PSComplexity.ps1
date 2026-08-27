# The public API: Measure-PSComplexity (data) and Test-PSComplexity (gate). The scan they both
# project over lives in Scan.ps1.
#
# A `#` header, not a <# #> block. A block comment immediately before `function` IS that
# function's comment-based help and SHADOWS the one inside the body -- so Get-Help would serve
# these two lines instead of the documentation written for users. It was harmless while an
# internal function sat first in the file; splitting the scan out moved a PUBLIC command into
# that position, and three tests failed on the same run.

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

    .PARAMETER ReportPath
        Also write a machine-readable JSON report to this path, described by
        schemas/v1/report.schema.json, which ships with the module.

        The record stream is unchanged -- the report is written alongside it, not instead of it.
        It carries the units, the scope that was asked for, the files that were skipped and why,
        a summary, and the metric version that produced the numbers.

        A report from this command reaches no verdict, because this command applies no
        thresholds. The published schema makes that unrepresentable rather than merely
        undocumented: a `passed` field is forbidden unless `thresholds` are present, so a
        measurement report cannot carry an answer nobody computed. Use Test-PSComplexity when
        the artefact needs a verdict.

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
        [switch]$Recurse,
        [string]$ReportPath,
        # Files a caller says changed, restricting the run to units in them. Omit it for a
        # whole-tree run; an EMPTY list is refused rather than treated as "nothing changed",
        # because that is what a diff command returns when it has failed.
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        # Off by default because the DEFAULT SHAPE IS A CONTRACT: CI consumers parse these
        # records, and a field that appears unbidden is a breaking change dressed as a feature.
        [switch]$Detailed
    )
    begin {
        # Resolved paths already emitted. Two inputs can name one file -- a directory and
        # something inside it, or a wildcard and a literal -- and measuring it twice put
        # duplicate rows in the output, doubling that file's contribution to anything that
        # counts. In `begin` rather than `process` so it also spans pipeline input, where
        # each item arrives as its own invocation of the block below.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        # Always collected, unguarded, because these are strings the caller already holds: the
        # cost is nil, and a guard here would be a branch nothing could observe. The report has
        # to say what the WHOLE run was asked for, and paths arrive one invocation at a time.
        $asked = [System.Collections.Generic.List[string]]::new()
        # Built ONCE, here, so both output paths filter identically. The streaming path below and
        # the single scan in `end` reach the same files by different routes, and a filter applied
        # to only one of them makes the answer depend on whether -ReportPath was given -- which is
        # exactly the bug this had while the two were wired separately.
        #
        # Validated here too, so an empty list is refused whichever route the run takes.
        $changedSet = $null
        if ($PSBoundParameters.ContainsKey('ChangedFile')) {
            Assert-PSCxChangedFile -ChangedFile $ChangedFile
            $changedSet = Get-PSCxChangedSet -ChangedFile $ChangedFile -Root (Get-Location).Path
        }
    }
    process {
        $asked.AddRange([string[]]$Path)
        # With a report, the whole run is emitted from `end` instead, out of a single scan.
        # Accumulating per file here would need three guards that only save memory -- and a
        # branch that changes no output cannot be told from its own absence by any test.
        if ($ReportPath) { return }
        foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -ChangedSet $changedSet -Recurse:$Recurse -Detailed:$Detailed)) {
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
    end {
        if (-not $ReportPath) { return }
        # One scan over everything the run was asked for, walking each file once exactly as the
        # streaming path does. What it gives up is emitting as it goes, which is the price of a
        # report that has to describe the whole run at once.
        $scanArgs = @{ Path = $asked.ToArray(); Recurse = $Recurse; Detailed = $Detailed }
        if ($PSBoundParameters.ContainsKey('ChangedFile')) {
            Assert-PSCxChangedFile -ChangedFile $ChangedFile
            $scanArgs.ChangedFile = $ChangedFile
        }
        $scan = Get-PSCxScan @scanArgs
        # The same projection the streaming path makes: units out, a skip to the error stream.
        # Rendered here too, so -ReportPath does not quietly silence the one thing the command
        # says when it could not read a file.
        foreach ($skip in $scan.Skipped) {
            Write-Error "Skipped '$($skip.File)' -- $($skip.Reason)"
        }
        $scan.Units
        Save-PSCxDocument -Path $ReportPath -Document (Get-PSCxReportDocument -Scan $scan `
                -ModuleVersion (Get-PSCxModuleVersion) -GeneratedAt (Get-Date))
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

    .PARAMETER ReportPath
        Also write a machine-readable JSON report to this path, described by
        schemas/v1/report.schema.json, which ships with the module.

        A gate report carries everything a measurement report does -- units, scope, skipped
        files, summary, metric version -- plus the ceilings that applied, the verdict, the units
        that breached, and every acceptance with its argument. That last part is deliberate: a
        report that said "passed" without saying what it excused would be the mute button the
        acceptance concept exists instead of.

        Written only when a verdict is reached. The refusals above -- a file that did not parse,
        nothing measured, an acceptance that no longer applies -- throw before a report exists,
        because each means the run cannot vouch for anything worth recording.

    .PARAMETER SarifPath
        Also write a SARIF 2.1.0 log to this path, for code scanning to render inline on a pull
        request. SARIF has its own published schema; this module writes it and validates nothing
        of its own.

        One result per breached ceiling, so a unit over both produces two, under two rule ids
        (PSCxCyclomatic, PSCxCognitive) that can be suppressed independently. An accepted or
        baselined unit produces no result at all: the gate excused it, and what it excused lives
        in the JSON report -- under `accepted` with its argument, or under `baselined` with the
        score it was held to -- rather than being repeated as a finding nobody should act on.

        Only the gate writes SARIF. Without ceilings there is no such thing as a finding, so a
        SARIF file from Measure-PSComplexity would be an empty results array claiming a clean
        bill of health.

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

    .PARAMETER BaselineFile
        A committed JSON file recording what each already-over-the-limit unit scored, so the gate
        is adoptable on a codebase that is already red. A unit in the baseline may not exceed its
        recorded score; a unit NOT in it must be under the ceilings, so new and touched code meets
        the real bar from day one.

        The answer to "we have forty violations" stops being "raise the threshold" -- which gates
        nothing -- and becomes "record them, then never add a forty-first".

        It is a ratchet rather than a suppression list, so the run THROWS when an entry stops
        describing it: the unit was renamed away, it came back under both ceilings, it is also in
        -Accept, or it IMPROVED and the recorded number is now larger than reality. That last one
        is the ratchet tightening; -UpdateBaseline is the one-command fix.

        An entry is keyed by file and unit, never by line, because a line number moves whenever
        anything above it is edited. A unit whose name carries an ordinal -- Get-Thing#2, how
        duplicate definitions in one file are told apart -- is refused outright: the ordinal
        renumbers when a duplicate is inserted above it, so the entry would silently begin capping
        a different function.

    .PARAMETER UpdateBaseline
        Write the file named by -BaselineFile, recording every breaching unaccepted unit at the
        score it has now, then return without gating.

        It only ever ratchets DOWN. When a unit is worse than the file already records, the write
        is refused and the units are named -- otherwise re-running the tool would absorb whatever
        regression the gate had just caught, and the baseline would become a suppression list that
        updates itself. Fix the regression, or accept the unit with an argument for it.

        The one exception is a baseline recorded against a different metric version, where the old
        numbers are answers to a different question rather than smaller or larger ones. That file
        is regenerated wholesale, and the diff is where it gets reviewed.

        No report and no SARIF are written by an update: the verdict they would record is one the
        call just manufactured.

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
        [string]$ReportPath,
        [string]$SarifPath,
        # Files a caller says changed, restricting the run to units in them. Omit it for a
        # whole-tree run; an EMPTY list is refused rather than treated as "nothing changed",
        # because that is what a diff command returns when it has failed.
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,

        # Empty is the normal case, and an empty array must bind rather than be rejected.
        [AllowEmptyCollection()] [object[]]$Accept = @(),
        [string]$BaselineFile,
        [switch]$UpdateBaseline
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
        # Before the scan, because the answer does not depend on it and a measurement run is the
        # expensive part. A -UpdateBaseline with nowhere to write would otherwise measure the
        # whole tree and then say it had no path.
        if ($UpdateBaseline -and -not $BaselineFile) {
            throw '-UpdateBaseline needs -BaselineFile: there is no default path for a baseline, because a file the gate reads without being told to is one nobody reviews.'
        }
        $paths = $collected.ToArray()
        # The scan, not the record stream. What was skipped is a fact the measurement already
        # holds; reading it back off the error stream required -ErrorAction SilentlyContinue,
        # which swallowed every OTHER error into the same variable and then described it to
        # the caller as a file that did not parse.
        $scanArgs = @{ Path = $paths; Recurse = $Recurse }
        if ($PSBoundParameters.ContainsKey('ChangedFile')) {
            Assert-PSCxChangedFile -ChangedFile $ChangedFile
            $scanArgs.ChangedFile = $ChangedFile
        }
        $scan = Get-PSCxScan @scanArgs
        # Parse failures are refused rather than allowed past. A file the gate could not read
        # is a file it cannot vouch for, and "no unit exceeded a ceiling" is trivially true of
        # a file that produced no units -- the same shape as passing over an empty selection.
        if ($scan.Skipped.Count -gt 0) {
            throw ("Refusing to vouch for $($scan.Skipped.Count) file(s) that did not parse: " +
                (($scan.Skipped | ForEach-Object { "$($_.File) -- $($_.Reason)" }) -join '; ') +
                ". Fix the syntax, or exclude the file from the path you gate on.")
        }
        $units = $scan.Units

        # Before the verdict, so it is on screen whether the run passes or fails. A pass is the
        # case that needs it: a failing gate already prints what breached.
        $notice = Get-PSCxSubsetNotice -Scan $scan
        if ($notice) { Write-Warning $notice }

        # The decision lives in Scan.ps1 beside the scan it judges: it is a rule about what a
        # measurement is worth, and this command is meant to stay a thin predicate.
        $emptyFault = Get-PSCxEmptyScanFault -UnitCount $units.Count -Path $paths `
            -Recurse:$Recurse -Filtered $PSBoundParameters.ContainsKey('ChangedFile')
        if ($emptyFault) { throw $emptyFault }

        # Checked BEFORE the verdict, and thrown rather than returned as $false. A stale
        # acceptance is a fault in the policy, not a complaint about the code -- reporting it
        # as a failing gate would send someone to refactor a unit that is fine.
        $faults = @($Accept | Get-PSCxAcceptanceFault -Unit $units `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
        if ($faults.Count -gt 0) {
            throw ("The acceptance list does not describe this run: " + ($faults -join '; ') +
                ". An acceptance that no longer applies is a mute button, so it fails here rather than ageing quietly.")
        }

        if ($UpdateBaseline) {
            Write-PSCxBaselineFile -Path $BaselineFile -Unit $units -Accept $Accept `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive `
                -MetricVersion (Get-PSCxMetricVersion)
            # No report and no SARIF from an update. The verdict they would record is one this
            # call just manufactured by recording every breach, and an artefact saying "passed"
            # about that is the mute button the whole policy layer exists instead of.
            return $true
        }

        $baselineMap = Get-PSCxBaselineState -Path $BaselineFile -Unit $units -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive `
            -MetricVersion (Get-PSCxMetricVersion)

        $violations = @(Get-PSCxUnacceptedUnit -Unit $units -Accept $Accept `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -BaselineMap $baselineMap)
        foreach ($v in $violations) {
            Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                    $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $MaxCyclomatic, $v.Cognitive, $MaxCognitive)
        }
        # Recomputed from the same two inputs the verdict used, rather than collected as a side
        # effect while deciding. A second pass is cheap; a list built inside the decision drifts
        # from it the first time either changes.
        $baselined = @($units | Where-Object { Test-PSCxWithinBaseline -Unit $_ -Map $baselineMap })
        $passed = $violations.Count -eq 0
        Write-PSCxGateArtifact -Scan $scan -Passed $passed -Violation $violations -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -Baselined $baselined `
            -ReportPath $ReportPath -SarifPath $SarifPath
        return $passed
    }
}
