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
        ForEach-Object and Where-Object, and the .ForEach() and .Where() methods, score as the
        loop and conditional they stand in for, && and || as a boolean run, ?? and ??= as a
        ternary. Cyclomatic is the classic
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

    .PARAMETER MarkdownPath
        Also write a Markdown summary to this path, for a CI step summary or a pull request
        comment: the most complex units, per-file totals and, with -CompareTo, what is new, worse
        or better than a previous report. Rendered from the same scan as everything else, so it
        holds no number the records do not.

        The file is replaced, not appended to. On GitHub Actions, -MarkdownPath
        $env:GITHUB_STEP_SUMMARY works because each step gets its own summary file.

    .PARAMETER MarkdownTop
        How many of the most complex units the Markdown summary lists, by cognitive and then
        cyclomatic. Default 10. Only with -MarkdownPath.

    .PARAMETER CompareTo
        A previous JSON report (-ReportPath) to compare this run with, for example one saved from
        the main branch. The summary then lists the units that are new, worse or better than in
        it, matched by file and unit name. A report measured with another metric version is
        refused, because its numbers answer a different question. Only with -MarkdownPath.

    .PARAMETER ChangedFile
        The files a change touched, for example from `git diff --name-only --diff-filter=d`. Only
        the units in those files are measured; every unit of a named file is. An empty list is
        refused, because a failed diff command prints nothing. Paths are resolved against the
        current directory, so run from the repository root.

    .PARAMETER ChangedDiff
        A unified diff, for example the output of `git diff --unified=0 origin/main...HEAD`. Only
        the units owning a changed line are measured: the innermost unit holding the line, so editing
        a nested function does not drag in its parent, and for a pure deletion the unit it was
        deleted from. Lines outside every function belong to the script body.

        Only the `+++` and `@@` headers are read. With context lines in the diff, those count as
        changed too, so pass --unified=0. An empty diff is refused for the reason an empty
        -ChangedFile is, and so is text that is not a diff. It cannot be combined with
        -ChangedFile.

    .PARAMETER Detailed
        Add Contributions and LinesOfCode to each record. Contributions holds one entry per
        cognitive increment -- its Line, Construct and Amount, in source order -- summing to
        Cognitive. LinesOfCode is SonarQube's ncloc: lines holding code, not blank or comment.

        Read the amounts rather than the count. Anything above +1 is a structure plus the
        nesting charged for it, so four +1 rows and one +4 row reach the same total and mean
        different things -- points spread flat say the unit does too many things, points
        concentrated in one deep row say extract.

        A unit with no increments gets an empty list, not a missing property. Without the
        switch the record is exactly as documented below.

    .INPUTS
        [string[]] -- one or more file or directory paths, by value or by property name.

        A path may be piped as a string, or taken from a Path or FullName property, so
        `Get-ChildItem ./src -Filter *.ps1 | Measure-PSComplexity` and
        `$paths | Measure-PSComplexity` both work. Script blocks and AST objects are NOT
        accepted: this command measures files on disk, and anything else is reported as a path
        that matched nothing.

    .OUTPUTS
        [pscustomobject] with File, Unit, Line, Cyclomatic, Cognitive, MetricVersion -- one
        per unit, plus Contributions and LinesOfCode when -Detailed is given.

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

    .EXAMPLE
        # Measure only what a pull request touched, and keep the machine-readable record:
        $changed = git diff --name-only --diff-filter=d origin/main...HEAD
        Measure-PSComplexity ./src -Recurse -ChangedFile $changed -ReportPath ./reports/complexity.json

    .LINK
        https://github.com/Fortigi/PSComplexity

    .LINK
        Test-PSComplexity
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # ValueFromPipelineByPropertyName as well as ByValue, with FullName aliased onto it.
        #
        # `Get-ChildItem | Measure-PSComplexity` already appeared to work, but only by coercion: a
        # FileInfo has no Path property, so it bound ByValue through ToString(). Anything carrying
        # its path as a PROPERTY -- the ordinary shape for an object a caller builds, selects or
        # filters -- bound to nothing and measured NOTHING, silently. This makes the working case
        # work by contract and the failing case work at all.
        #
        # FullName only, NOT PSPath: every FileInfo/DirectoryInfo carries both, so PSPath would be a
        # second route for input that already binds. (The old reason, that a provider-qualified
        # path could not be resolved, stopped being true with #171.)
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string[]]$Path,
        [switch]$Recurse,
        [string]$ReportPath,
        [string]$MarkdownPath,
        # Default 10. A parameter default is fine here, unlike the ceilings: nothing else can set it.
        [ValidateRange(1, [int]::MaxValue)] [int]$MarkdownTop = 10,
        [string]$CompareTo,
        # Files a caller says changed, restricting the run to units in them. Omit it for a
        # whole-tree run; an EMPTY list is refused rather than treated as "nothing changed",
        # because that is what a diff command returns when it has failed.
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        # A unified diff, restricting the run to the units owning a changed line (#168). Refused
        # when empty, for the reason an empty -ChangedFile is, and beside -ChangedFile.
        [AllowNull()] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedDiff,
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
        # Compared as this run's file system compares names, read once from the working directory.
        $pathComparison = Get-PSCxRunPathComparison -Root (Get-PSCxWorkingRoot)
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::FromComparison($pathComparison))
        # Paths that produced no source file, collected across the whole run for the same reason
        # $seen is: each piped path arrives as its own invocation of the process block.
        $unmatched = [System.Collections.Generic.List[object]]::new()
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
        $change = Get-PSCxChangeScope -Bound $PSBoundParameters -Root (Get-PSCxWorkingRoot) -PathComparison $pathComparison
        # Read and checked before anything is measured, so a wrong -CompareTo costs nothing.
        $compareBase = Read-PSCxCompareBase -Bound $PSBoundParameters -MetricVersion (Get-PSCxMetricVersion)
    }
    process {
        $asked.AddRange([string[]]$Path)
        # With a report, the whole run is emitted from `end` instead, out of a single scan.
        # Accumulating per file here would need three guards that only save memory -- and a
        # branch that changes no output cannot be told from its own absence by any test.
        if ($ReportPath -or $MarkdownPath) { return }
        foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -Unmatched $unmatched -ChangedSet $change.Set -ChangedLine $change.Line -PathComparison $pathComparison -Recurse:$Recurse -Detailed:$Detailed)) {
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
        if (-not ($ReportPath -or $MarkdownPath)) {
            # The streaming route's own projection of the discovery faults. Written here rather
            # than in `process` because a path is only known to have matched nothing once its
            # invocation is done, and because this command reports a fact per path, not per item.
            Write-PSCxUnmatchedPath -Unmatched $unmatched
            return
        }
        # One scan over everything the run was asked for, walking each file once exactly as the
        # streaming path does. What it gives up is emitting as it goes, which is the price of a
        # report that has to describe the whole run at once.
        $scanArgs = @{ Path = $asked.ToArray(); Recurse = $Recurse; Detailed = $Detailed }
        # Checked in `begin`, so whichever route the run takes refuses the same input.
        if ($PSBoundParameters.ContainsKey('ChangedFile')) { $scanArgs.ChangedFile = $ChangedFile }
        if ($PSBoundParameters.ContainsKey('ChangedDiff')) { $scanArgs.ChangedDiff = $change.Diff }
        $scan = Get-PSCxScan @scanArgs
        # The same projection the streaming path makes: units out, a skip to the error stream.
        # Rendered here too, so -ReportPath does not quietly silence the one thing the command
        # says when it could not read a file.
        foreach ($skip in $scan.Skipped) {
            Write-Error "Skipped '$($skip.File)' -- $($skip.Reason)"
        }
        Write-PSCxUnmatchedPath -Unmatched $scan.Unmatched
        $scan.Units
        if ($ReportPath) {
            Save-PSCxDocument -Path $ReportPath -Document (Get-PSCxReportDocument -Scan $scan `
                    -ModuleVersion (Get-PSCxModuleVersion) -GeneratedAt (Get-Date))
        }
        if ($MarkdownPath) {
            Write-PSCxMarkdown -Path $MarkdownPath -Scan $scan -Top $MarkdownTop -Gate $null -Base $compareBase -BaseName $CompareTo
        }
    }
}

function Test-PSComplexity {
    <#
    .SYNOPSIS
        Return $true if every unit is at or under the cyclomatic and cognitive ceilings;
        otherwise $false, writing a warning per offending unit. Intended as a CI gate.

    .DESCRIPTION
        Measures every unit under Path -- each function and filter, each class method,
        constructor and initialised property, plus one <script-body> per file -- and compares
        both scores against the ceilings. Returns $true when every unit is within them, and
        $false after writing one warning per unit that is not.

        The verdict is about the whole selection, so every path is collected before any of them
        is judged; piping paths in is safe.

        It REFUSES rather than answering, and the refusals are the point: a gate that quietly
        measures less than it was asked to is worse than no gate, because a pass reads as a
        stronger claim than it is. The run throws -- rather than returning $false -- when

          * a path matched no PowerShell file, even if other paths did;
          * nothing at all was measured;
          * a file could not be read or did not parse;
          * an acceptance or a baseline entry no longer describes the run.

        The last of those is a fault in the policy rather than a complaint about the code, so
        reporting it as a failing gate would send somebody to refactor a unit that is fine.

        The policy can live in a committed .pscomplexity.json instead of on the command line --
        see -ConfigFile. Whatever the command line says still wins.

        Two mechanisms let an already-red codebase adopt the gate without weakening it.
        -Accept excuses a named unit outright and carries the written argument for it;
        -BaselineFile caps each already-breaching unit at what it already scored, so old code
        cannot get worse and new code meets the real bar. Neither is a suppression list: both
        fail the build when they stop describing the run.

    .PARAMETER Path
        One or more files or directories to check.

    .PARAMETER MaxCyclomatic
        Cyclomatic ceiling. Without it, the config's maxCyclomatic, or 15. Given, it applies to
        every unit, overriding the config's per-path overrides too.

    .PARAMETER MaxCognitive
        Cognitive ceiling. Without it, the config's maxCognitive, or 15. Given, it applies to
        every unit, overriding the config's per-path overrides too.

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

    .PARAMETER MarkdownPath
        Also write a Markdown summary to this path, for a CI step summary or a pull request
        comment: the verdict and every unit over a ceiling, then the most complex units, per-file
        totals and, with -CompareTo, what is new, worse or better than a previous report. Like
        the JSON report, it is written only when a verdict is reached, and not by -UpdateBaseline. Rendered from the same scan as everything else, so it
        holds no number the records do not.

        The file is replaced, not appended to. On GitHub Actions, -MarkdownPath
        $env:GITHUB_STEP_SUMMARY works because each step gets its own summary file.

    .PARAMETER MarkdownTop
        How many of the most complex units the Markdown summary lists, by cognitive and then
        cyclomatic. Default 10. Only with -MarkdownPath.

    .PARAMETER CompareTo
        A previous JSON report (-ReportPath) to compare this run with, for example one saved from
        the main branch. The summary then lists the units that are new, worse or better than in
        it, matched by file and unit name. A report measured with another metric version is
        refused, because its numbers answer a different question. Only with -MarkdownPath.

    .PARAMETER ChangedFile
        The files a change touched, for example from `git diff --name-only --diff-filter=d`. Only
        the units in those files are gated; every unit of a named file is. An empty list is
        refused, because a failed diff command prints nothing. Paths are resolved against the
        current directory, so run from the repository root.

    .PARAMETER ChangedDiff
        A unified diff, for example the output of `git diff --unified=0 origin/main...HEAD`. Only
        the units owning a changed line are gated: the innermost unit holding the line, so editing
        a nested function does not drag in its parent, and for a pure deletion the unit it was
        deleted from. Lines outside every function belong to the script body.

        Only the `+++` and `@@` headers are read. With context lines in the diff, those count as
        changed too, so pass --unified=0. An empty diff is refused for the reason an empty
        -ChangedFile is, and so is text that is not a diff. It cannot be combined with
        -ChangedFile.

        Acceptances and baseline entries are still checked against every unit of the changed
        files, so one that has gone stale fails the run as it would on the whole tree.

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

    .PARAMETER ConfigFile
        A .pscomplexity.json holding the gate's policy: default ceilings, per-path overrides,
        excludes, acceptances with their reasons, and the baseline file. It is described by
        schemas/v1/config.schema.json, which ships with the module, and every path in it is
        relative to the config file's own directory.

        Without -ConfigFile the gate looks for one: the nearest .pscomplexity.json from each -Path
        up to the repository root, and none at all outside a repository. Every path of one run
        must fall under the same config, or the run is refused. The file used is printed and
        recorded in the report.

        The command line wins wherever it says something: -MaxCyclomatic and -MaxCognitive replace
        the config's ceilings everywhere, -Accept replaces its acceptances, -BaselineFile its
        baseline. A config that is not valid is refused, naming every fault in it.

        Only this command reads a config. Measure-PSComplexity measures what it is pointed at.

    .PARAMETER NoConfig
        Apply no config: do not look for one. The ceilings are then the command line's or 15.

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

        Nor does it add a unit the file has never recorded, unless -AllowNew says to: see below.

    .PARAMETER AllowNew
        With -UpdateBaseline, also record breaching units the existing baseline has never seen.

        Without it such an update is refused, naming each unit. A unit new to the baseline is new
        code, which should meet the ceilings, or a renamed one -- and a rename that also got worse
        is exactly the regression the ratchet exists to catch, which an unconditional update would
        absorb. With it, each added unit is still named in a warning, so the log says what the
        diff says.

        Not needed to seed a baseline, or to regenerate one across a metric version change: there
        is nothing to add to.

        No report and no SARIF are written by an update: the verdict they would record is one the
        call just manufactured.

    .INPUTS
        [string[]] -- one or more file or directory paths, by value or by property name, the
        same shapes Measure-PSComplexity accepts. Every piped path is collected before the
        verdict is reached, because the verdict is about the whole selection.

    .OUTPUTS
        [bool]

    .EXAMPLE
        if (-not (Test-PSComplexity ./src -Recurse)) { throw 'Complexity gate failed' }

    .EXAMPLE
        # Adopt the gate on a codebase that is already over the line, then hold the ratchet:
        Test-PSComplexity ./src -Recurse -BaselineFile ./complexity-baseline.json -UpdateBaseline
        Test-PSComplexity ./src -Recurse -BaselineFile ./complexity-baseline.json

    .EXAMPLE
        # Gate only the functions a pull request changed, not every function in the files it touched:
        $diff = git diff --unified=0 origin/main...HEAD
        Test-PSComplexity ./src -Recurse -ChangedDiff $diff

    .EXAMPLE
        # Gate a pull request on what it changed, and render findings inline:
        $changed = git diff --name-only --diff-filter=d origin/main...HEAD
        Test-PSComplexity ./src -Recurse -ChangedFile $changed -SarifPath ./reports/complexity.sarif

    .LINK
        https://github.com/Fortigi/PSComplexity

    .LINK
        Measure-PSComplexity
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        # Bound exactly as Measure-PSComplexity's is, and for the reason recorded there. The gate
        # and the measurement must accept the same input, or a pipeline that measures cleanly
        # fails to gate.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string[]]$Path,
        # No defaults here: 15 applies only when neither this nor a config sets a ceiling, and a
        # parameter default cannot tell "not given" from "given as 15". See Get-PSCxGatePolicy.
        [int]$MaxCyclomatic,
        [int]$MaxCognitive,
        [switch]$Recurse,
        [string]$ReportPath,
        [string]$SarifPath,
        [string]$MarkdownPath,
        # Default 10. A parameter default is fine here, unlike the ceilings: nothing else can set it.
        [ValidateRange(1, [int]::MaxValue)] [int]$MarkdownTop = 10,
        [string]$CompareTo,
        # Files a caller says changed, restricting the run to units in them. Omit it for a
        # whole-tree run; an EMPTY list is refused rather than treated as "nothing changed",
        # because that is what a diff command returns when it has failed.
        [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        # A unified diff, restricting the run to the units owning a changed line (#168).
        [AllowNull()] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedDiff,

        # Empty is the normal case, and an empty array must bind rather than be rejected.
        [AllowEmptyCollection()] [object[]]$Accept,
        [string]$BaselineFile,
        [switch]$UpdateBaseline,
        [switch]$AllowNew,
        [ValidateNotNullOrEmpty()] [string]$ConfigFile,
        [switch]$NoConfig
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
        # The config, the command line and the defaults, settled into what this run applies --
        # including the two refusals about -UpdateBaseline, which now depend on the config.
        $policy = Resolve-PSCxGatePolicy -Bound $PSBoundParameters -Path $paths
        $compareBase = Read-PSCxCompareBase -Bound $PSBoundParameters -MetricVersion (Get-PSCxMetricVersion)
        $MaxCyclomatic = $policy.MaxCyclomatic
        $MaxCognitive = $policy.MaxCognitive
        $Accept = $policy.Accept
        # The scan, not the record stream. What was skipped is a fact the measurement already
        # holds; reading it back off the error stream required -ErrorAction SilentlyContinue,
        # which swallowed every OTHER error into the same variable and then described it to
        # the caller as a file that did not parse.
        $scanArgs = @{ Path = $paths; Recurse = $Recurse; Exclude = $policy.Exclude }
        $change = Get-PSCxChangeScope -Bound $PSBoundParameters -Root (Get-PSCxWorkingRoot) -PathComparison (Get-PSCxRunPathComparison -Root (Get-PSCxWorkingRoot))
        if ($PSBoundParameters.ContainsKey('ChangedFile')) { $scanArgs.ChangedFile = $ChangedFile }
        if ($null -ne $change.Diff) { $scanArgs.ChangedDiff = $change.Diff }
        $scan = Get-PSCxScan @scanArgs
        # Parse failures are refused rather than allowed past. A file the gate could not read
        # is a file it cannot vouch for, and "no unit exceeded a ceiling" is trivially true of
        # a file that produced no units -- the same shape as passing over an empty selection.
        if ($scan.Skipped.Count -gt 0) {
            # "could not measure", not "did not parse", and the advice no longer names syntax. A
            # file that was deleted mid-scan or cannot be read arrives here too, and telling
            # somebody to fix the syntax of a file that is merely gone is the same misdiagnosis
            # this command's own scan was built to end. Each reason says which it was.
            throw ("Refusing to vouch for $($scan.Skipped.Count) file(s) it could not measure: " +
                (($scan.Skipped | ForEach-Object { "$($_.File) -- $($_.Reason)" }) -join '; ') +
                ". Fix the fault named, or exclude the file from the path you gate on.")
        }
        $units = $scan.Units
        # Every unit of the files read, the gated ones among them: what the policy is checked against.
        $measured = $scan.Measured
        $fileCeiling = Get-PSCxFileCeiling -Unit $measured -Override $policy.Overrides -MaxCyclomatic $MaxCyclomatic `
            -MaxCognitive $MaxCognitive -Root $scan.Scope.Root -PathComparison $scan.PathComparison

        # Before the verdict, so it is on screen whether the run passes or fails. A pass is the
        # case that needs it: a failing gate already prints what breached.
        $notice = Get-PSCxSubsetNotice -Scan $scan
        if ($notice) { Write-Warning $notice }

        # The decision lives in Scan.ps1 beside the scan it judges: it is a rule about what a
        # measurement is worth, and this command is meant to stay a thin predicate. Both
        # scan-level refusals are sequenced there, because which one fires first is itself a
        # decision -- see Get-PSCxScanFault.
        $scanFault = Get-PSCxScanFault -Scan $scan -Path $paths `
            -Recurse:$Recurse -Filtered ($null -ne $scan.Scope.ChangedFile)
        if ($scanFault) { throw $scanFault }

        # Checked BEFORE the verdict, and thrown rather than returned as $false. A stale
        # acceptance is a fault in the policy, not a complaint about the code -- reporting it
        # as a failing gate would send someone to refactor a unit that is fine.
        # The code's own acceptances join the list's (#165), after the two are checked against each
        # other, and from here on face exactly the checks a listed one does.
        # A run filtered to changed files checks only the listed acceptances for files it read
        # (#203): one for a file it never opened cannot be judged either way.
        $filtered = $null -ne $scan.Scope.ChangedFile
        $Accept = @(Select-PSCxScopedEntry -Entry @($Accept) -Unit $measured -Filtered $filtered -PathComparison $scan.PathComparison)
        $faults = @(Get-PSCxInlineAcceptFault -Inline $scan.InlineAccept -Stray $scan.InlineStray `
                -Listed $Accept -PathComparison $scan.PathComparison)
        $Accept = @($Accept) + @($scan.InlineAccept)
        $faults += @($Accept | Get-PSCxAcceptanceFault -Unit $measured `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -PathComparison $scan.PathComparison `
                -FileCeiling $fileCeiling)
        if ($faults.Count -gt 0) {
            throw ("The acceptance list does not describe this run: " + ($faults -join '; ') +
                ". An acceptance that no longer applies is a mute button, so it fails here rather than ageing quietly.")
        }

        if ($UpdateBaseline) {
            Write-PSCxBaselineFile -Path $policy.BaselineFile -Unit $units -Accept $Accept `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -FileCeiling $fileCeiling `
                -MetricVersion (Get-PSCxMetricVersion) -PathComparison $scan.PathComparison -AllowNew:$AllowNew
            # No report and no SARIF from an update. The verdict they would record is one this
            # call just manufactured by recording every breach, and an artefact saying "passed"
            # about that is the mute button the whole policy layer exists instead of.
            return $true
        }

        $baselineMap = Get-PSCxBaselineState -Path $policy.BaselineFile -Unit $measured -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -FileCeiling $fileCeiling `
            -MetricVersion (Get-PSCxMetricVersion) -PathComparison $scan.PathComparison -Filtered $filtered

        $violations = @(Get-PSCxUnacceptedUnit -Unit $units -Accept $Accept `
                -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -BaselineMap $baselineMap `
                -PathComparison $scan.PathComparison -FileCeiling $fileCeiling)
        foreach ($v in $violations) {
            # The ceilings THIS unit faced, which a per-path override may have moved.
            $ceiling = Get-PSCxUnitCeiling -File $v.File -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -FileCeiling $fileCeiling
            Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                    $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $ceiling.Cyclomatic, $v.Cognitive, $ceiling.Cognitive)
        }
        # Recomputed from the same two inputs the verdict used, rather than collected as a side
        # effect while deciding. A second pass is cheap; a list built inside the decision drifts
        # from it the first time either changes.
        $baselined = @($units | Where-Object { Test-PSCxWithinBaseline -Unit $_ -Map $baselineMap })
        $passed = $violations.Count -eq 0
        Write-PSCxGateArtifact -Scan $scan -Passed $passed -Violation $violations -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive -Baselined $baselined `
            -Override $policy.Overrides -FileCeiling $fileCeiling -Config ([string]$policy.Config.Display) `
            -ReportPath $ReportPath -SarifPath $SarifPath
        if ($MarkdownPath) {
            $gate = [pscustomobject]@{
                Passed = $passed; Violations = $violations; MaxCyclomatic = $MaxCyclomatic; MaxCognitive = $MaxCognitive
                Overrides = $policy.Overrides; FileCeiling = $fileCeiling; Config = [string]$policy.Config.Display
                Accepted = $Accept; Baselined = $baselined
            }
            Write-PSCxMarkdown -Path $MarkdownPath -Scan $scan -Top $MarkdownTop -Gate $gate -Base $compareBase -BaseName $CompareTo
        }
        return $passed
    }
}
