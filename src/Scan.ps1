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
    #
    # Comma-wrapped, so an empty result reaches the caller as an empty array rather than as $null,
    # and a single file as an array of one. Callers ASSIGN the result: wrapped in @( ) it would be
    # an array holding the array. Both types declared, because `, $x` is statically an Object[].
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path, [switch]$Recurse)
    # ProviderPath, not Path: for a UNC path, or any path written provider-qualified, Path keeps
    # the 'Microsoft.PowerShell.Core\FileSystem::' prefix, and the parser then reads that as a file
    # name and fails (#171). Get-ChildItem's FullName below is already the plain form.
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return , [string[]]@((Resolve-Path -LiteralPath $Path).ProviderPath) }

    # Take an existing path literally, and as a wildcard only when nothing is there. -Path
    # glob-parses '[', so a real directory named 'my[1]proj' matches nothing and the scan
    # reports a clean zero over code it never opened.
    #
    # A path that is neither returns an empty list HERE rather than reaching Get-ChildItem, which
    # would write a PathNotFound error of its own. That error was worse than useless: it named
    # this file and this line, it was attributed to Get-ChildItem rather than to the module, and
    # it did not reach the caller's -ErrorVariable -- so the only thing a consumer saw was zero
    # units. Get-PSCxPathScan records the empty result as a fact instead, and the gate refuses it.
    # -Force so hidden entries are walked on every OS (#161). Without it the same tree measured
    # differently per platform: Linux treats a dot-name as hidden and skipped `.github/x.ps1`
    # silently, while Windows hides by attribute and measured it. Code is code wherever it lives,
    # and a gate that skips some of it without a word passes over what it never read.
    $gci = @{ File = $true; Recurse = [bool]$Recurse; Force = $true }
    if (Test-Path -LiteralPath $Path) { $gci.LiteralPath = $Path }
    elseif (Test-Path -Path $Path) { $gci.Path = $Path }
    else { return , [string[]]@() }

    # Filter on the extension rather than with -Include, which a directory ignores unless
    # -Recurse is also present: a flat folder would resolve to zero files and every number
    # after it would describe the empty set.
    return , [string[]]@(Get-ChildItem @gci |
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
# 2: the .ForEach() and .Where() methods score as the cmdlets do (#159).
#    Unreleased with it: recursion through ${function:Name}, $MyInvocation, and a script calling
#    itself (#182).
$script:PSCxMetricVersion = 2

function Get-PSCxWorkingRoot {
    # Where the caller is standing, as a FILE-SYSTEM path: the root every File is made relative to.
    #
    # (Get-Location).Path is the PowerShell path, and on a UNC share -- or after Set-Location to a
    # provider-qualified path -- it carries the 'Microsoft.PowerShell.Core\FileSystem::' prefix.
    # Handed to [System.IO.Path] as a root, that turned every relative path under it into a file
    # nobody could open (#171). One reader, so the next caller cannot pick the wrong property.
    [OutputType([string])]
    [CmdletBinding()]
    param()
    return (Get-Location).ProviderPath
}

function Get-PSCxPathComparison {
    # How to compare two file paths: exactly, or ignoring case. Pure; the question of WHICH is
    # answered by the file system, in Get-PSCxRunPathComparison below.
    [OutputType([System.StringComparison])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [bool]$CaseSensitive)
    if ($CaseSensitive) { return [System.StringComparison]::Ordinal }
    return [System.StringComparison]::OrdinalIgnoreCase
}

function Test-PSCxExactEntry {
    # Whether a directory holds an entry spelled exactly so. Not Test-Path: on a case-insensitive
    # directory that answers yes for any casing, which is the question being asked, not the answer.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter(Mandatory)] [string]$Name
    )
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($Directory)) {
        if ([System.IO.Path]::GetFileName($entry) -ceq $Name) { return $true }
    }
    return $false
}

function Test-PSCxEntryExist {
    # Whether a name resolves to anything, file or directory, by the file system's own lookup.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    return [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
}

function Test-PSCxCaseSensitiveDirectory {
    # Whether this directory tells names apart by case: $true, $false, or $null when nothing in it
    # can answer. Asked of the FILE SYSTEM, not the platform (#151): Windows PowerShell reaching a
    # WSL project through \\wsl.localhost is on Windows and on a case-sensitive file system, and
    # Windows can mark any directory case-sensitive -- a clone made inside one inherits it.
    #
    # One existing name, looked up with its case flipped; nothing is written. Not found: the
    # directory is case-sensitive. Found: it is not -- unless the flipped spelling is an entry of
    # its own, which only a case-sensitive directory can hold.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($Path)) {
        $name = [System.IO.Path]::GetFileName($entry)
        $flipped = $name.ToUpperInvariant()
        if ($flipped -ceq $name) { $flipped = $name.ToLowerInvariant() }
        # A name with no cased letter in it (123.ps1) cannot be flipped; try the next one.
        if ($flipped -ceq $name) { continue }
        return (-not (Test-PSCxEntryExist -Path (Join-Path $Path $flipped))) -or
            (Test-PSCxExactEntry -Directory $Path -Name $flipped)
    }
    return $null
}

function Get-PSCxRunPathComparison {
    # How THIS run compares file paths: as the working directory's file system does. Every File
    # is relative to it and every baseline, acceptance and -ChangedFile list describes it, so one
    # answer serves the whole run and every identity in it agrees.
    #
    # The platform only when the directory cannot say (nothing in it has a cased letter) -- the
    # assumption .NET makes: Linux case-sensitive, Windows and macOS not. A parameter rather than
    # $IsLinux in the body, so both answers are testable on the one platform the self-mutation
    # gate runs on.
    [OutputType([System.StringComparison])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Root,
        [bool]$Fallback = $IsLinux
    )
    $probed = Test-PSCxCaseSensitiveDirectory -Path $Root
    $caseSensitive = ($null -eq $probed) ? $Fallback : $probed
    return Get-PSCxPathComparison -CaseSensitive $caseSensitive
}

function Test-PSCxSameEntry {
    # Whether two paths that differ only in case reach the same file. Asked of each directory on
    # the way down, not of the run: a case-sensitive folder can sit inside a case-insensitive
    # tree, and only that folder knows it holds two entries where the run sees one name.
    #
    # Different exactly where some directory holds BOTH spellings as entries of their own. A
    # spelling that is not an entry is the other one reached by a case-insensitive lookup.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Other
    )
    # The root (C:\, \\server\share, /) is not a directory entry, and on every file system that
    # has letters in it, it ignores case.
    $parent = [System.IO.Path]::GetPathRoot($Path)
    $mine = $Path.Substring($parent.Length).Split([System.IO.Path]::DirectorySeparatorChar)
    $theirs = $Other.Substring([System.IO.Path]::GetPathRoot($Other).Length).Split([System.IO.Path]::DirectorySeparatorChar)
    for ($i = 0; $i -lt $mine.Count; $i++) {
        if ($mine[$i] -cne $theirs[$i] -and (Test-PSCxExactEntry -Directory $parent -Name $mine[$i]) -and
            (Test-PSCxExactEntry -Directory $parent -Name $theirs[$i])) { return $false }
        $parent = Join-Path $parent $mine[$i]
    }
    return $true
}

function Get-PSCxCaseTwinScan {
    # A file the seen set refused: nothing when it is a file already measured, a SKIP when it is a
    # different file whose name differs only in case.
    #
    # That second case is a case-sensitive folder inside a run that compares ignoring case. Both
    # are real, but every identity in the run -- baseline, acceptance, -ChangedFile -- would key
    # them as one, so measuring both would be as wrong as dropping one. Dropping one silently is
    # how a gate passed over code it never read (#151); a skip is refused by the gate and says
    # what to do.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [System.Collections.Generic.HashSet[string]]$Seen,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $stored = $null
    [void]$Seen.TryGetValue($File, [ref]$stored)
    if ($stored -ceq $File -or (Test-PSCxSameEntry -Path $File -Other $stored)) { return }
    $root = Get-PSCxWorkingRoot
    $twin = Get-PSCxRelativePath -Path $stored -Root $root -PathComparison $PathComparison
    return [pscustomobject]@{
        File       = Get-PSCxRelativePath -Path $File -Root $root -PathComparison $PathComparison
        Units      = @()
        SkipReason = ("differs only in case from $twin. Both are files -- their folder is " +
            'case-sensitive -- but the working directory is not, so a baseline, an acceptance ' +
            'or -ChangedFile could not tell them apart. Rename one, or run from a ' +
            'case-sensitive directory')
    }
}

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
        [Parameter(Mandatory)] [string]$Root,
        # Whether a path is under Root is a question about the file system's names: on a
        # case-sensitive one /REPO is not /repo (#151).
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    # A RELATIVE Path resolves against Root, not against the working directory. GetFullPath
    # alone silently uses the CWD, so the function only gave the right answer while its one
    # caller happened to pass an absolute path AND a Root equal to the CWD -- two conditions
    # that both had to hold and neither of which was stated. The another project shipped the
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
    if (-not $full.StartsWith($rootFull, $PathComparison)) {
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
    # Compared as the run's file system compares names: where it is case-sensitive 'src/a.ps1' is
    # not 'src/A.ps1', and a list naming one must not select the other (#151).
    [OutputType([System.Collections.Generic.HashSet[string]])]
    [CmdletBinding()]
    param(
        # AllowEmptyString as well as AllowEmptyCollection: a Mandatory [string[]] rejects a
        # blank ENTRY, and `git diff --name-only` piped through PowerShell routinely yields one
        # as a trailing line. Without it the blank-skipping below is unreachable and the caller
        # gets a binding error instead.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ChangedFile,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::FromComparison($PathComparison))
    foreach ($f in $ChangedFile) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        [void]$set.Add((Get-PSCxRelativePath -Path $f.Trim() -Root $Root -PathComparison $PathComparison))
    }
    # -NoEnumerate, because a HashSet is enumerable and PowerShell unrolls it on the way out: an
    # empty one becomes $null and a one-element one becomes the STRING it holds -- both of which
    # fail to bind several frames away from the return that caused them. The comma-wrap does the
    # same job and declares an object[], which is not what this returns.
    Write-Output -InputObject $set -NoEnumerate
}

function Get-PSCxChangedLine {
    # -ChangedDiff's hunks keyed by File as a record spells it, so the walk can look a file up the
    # way the changed set does. Two spellings of one file in a diff -- which git does not write --
    # pool their hunks rather than one hiding the other.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'The literal @{} ignores case; the run path comparison decides instead (#151).')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary]$Diff,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $lines = [hashtable]::new([System.StringComparer]::FromComparison($PathComparison))
    foreach ($file in $Diff.Keys) {
        $relative = Get-PSCxRelativePath -Path $file -Root $Root -PathComparison $PathComparison
        if (-not $lines.ContainsKey($relative)) { $lines[$relative] = [System.Collections.Generic.List[object]]::new() }
        $lines[$relative].AddRange([object[]]@($Diff[$file]))
    }
    return $lines
}

function Get-PSCxChangeScope {
    # What a command's -ChangedFile or -ChangedDiff restricts the run to, checked: the changed set
    # the walk filters files by, the hunks per file for a diff, and the diff as read. Each $null
    # when not given, which is what tells the walk to read everything.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # The command's $PSBoundParameters.
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $scope = [pscustomobject]@{ Set = $null; Line = $null; Diff = $null }
    if ($Bound.ContainsKey('ChangedDiff')) {
        $scope.Diff = Read-PSCxChangedDiff -Bound $Bound
        $scope.Line = Get-PSCxChangedLine -Diff $scope.Diff -Root $Root -PathComparison $PathComparison
        $scope.Set = Get-PSCxChangedSet -ChangedFile @($scope.Line.Keys) -Root $Root -PathComparison $PathComparison
    }
    elseif ($Bound.ContainsKey('ChangedFile')) {
        Assert-PSCxChangedFile -ChangedFile $Bound['ChangedFile']
        $scope.Set = Get-PSCxChangedSet -ChangedFile $Bound['ChangedFile'] -Root $Root -PathComparison $PathComparison
    }
    return $scope
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
    if ($null -ne $Scan.Scope.ChangedLines) {
        return ("Gated $units unit(s) owning lines changed in $files file(s), not the whole tree. This verdict " +
            'covers only what -ChangedDiff changed; it is not a statement about the rest of the code.')
    }
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
    # Refuse a changed-file list that is empty, or that names PowerShell files not there, naming why.
    #
    # An empty list means "nothing changed", and taken at face value it produces a confident pass
    # over zero units -- the vacuous score this module exists to find in other people's code,
    # aimed inward. It is also the single most likely thing a caller passes by accident: a git
    # command that failed, matched nothing, or ran against a shallow clone where the base ref does
    # not exist prints nothing and exits 0.
    #
    # A caller who genuinely has no changed files wants to SKIP the gate, and that is a decision
    # only they can make -- so it is theirs to make, in their own script, where it is visible.
    #
    # A listed .ps1 or .psm1 that does not exist is refused too (#160). The list is resolved
    # against the current directory and git prints it relative to the repository root, so a gate
    # run from a subdirectory matched nothing, measured 0 units and PASSED -- a filtered run that
    # measures nothing is ordinary, so nothing downstream could object. Only PowerShell entries are
    # checked: a missing README changes no answer. Checked here, before any route scans, so
    # Measure-PSComplexity refuses the list too: its scope would name files it never read.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        # AllowEmptyString for the same reason as Get-PSCxChangedSet: a blank entry is what a
        # diff emits as a trailing line, and rejecting it at the binder turns the refusal this
        # function exists to make into a message about parameter binding.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [AllowEmptyString()] [string[]]$ChangedFile
    )
    $listed = @($ChangedFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object Trim)
    if ($listed.Count -eq 0) {
        throw ('-ChangedFile was given no files. An empty list would restrict the run to nothing and ' +
            'report a pass over zero units, which is the failure this module exists to find -- and it ' +
            'is what a diff command prints when it fails, matches nothing, or runs against a shallow ' +
            'clone whose base ref is missing. If nothing changed, skip the gate rather than asking it ' +
            'to measure an empty set.')
    }
    $fault = Get-PSCxMissingChangeFault -File $listed -Parameter '-ChangedFile'
    if ($fault) { throw ($fault + ' A file the change deleted has nothing left to measure: list changes with ' +
            '`git diff --name-only --diff-filter=d`.') }
}

function Get-PSCxMissingChangeFault {
    # Why the PowerShell files a change names are not all there, as text, or nothing when they are.
    # Only .ps1 and .psm1 are checked: a missing README changes no answer.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]]$File,
        [Parameter(Mandatory)] [string]$Parameter
    )
    $missing = @($File | Where-Object {
            [System.IO.Path]::GetExtension($_) -in '.ps1', '.psm1' -and -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -eq 0) { return }
    return ("$Parameter names $($missing.Count) PowerShell file(s) that do not exist from " +
        "'$(Get-PSCxWorkingRoot)': " + ($missing -join ', ') + '. The list is resolved against the ' +
        'current directory, and git prints paths relative to the repository root -- run from the ' +
        'root.')
}

function Read-PSCxChangedDiff {
    # -ChangedDiff's text as files and hunks, refusing a diff that cannot be read, one naming
    # PowerShell files not there, and -ChangedFile beside it. Checked before any route scans, like
    # -ChangedFile, so Measure-PSComplexity refuses it too.
    #
    # A diff naming no PowerShell file at all -- a docs-only change -- is not refused: like a
    # -ChangedFile list holding only a README, it measures nothing and the run says so.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        # The command's $PSBoundParameters.
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Bound
    )
    if ($Bound.ContainsKey('ChangedFile')) {
        throw '-ChangedFile and -ChangedDiff cannot be combined: one gates every unit in the files it names and the other only the units a diff changed. Pass one.'
    }
    $diff = Get-PSCxUnifiedDiff -Text $Bound['ChangedDiff']
    if ($diff.Fault) { throw $diff.Fault }
    # A deleted file never reaches the list, so unlike -ChangedFile there is no filter to suggest.
    $fault = Get-PSCxMissingChangeFault -File @($diff.Files.Keys) -Parameter '-ChangedDiff'
    if ($fault) { throw $fault }
    return $diff.Files
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
        # SonarQube's ncloc for this unit (#166); published with -Detailed only.
        [int]$LinesOfCode,
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
    if ($Detailed) {
        $record | Add-Member -NotePropertyName Contributions -NotePropertyValue @($Contributions)
        $record | Add-Member -NotePropertyName LinesOfCode -NotePropertyValue $LinesOfCode
    }
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
    #
    # Two more are not syntax either, and fail only where the HOST cannot parse them (#161): a
    # `workflow`, which PowerShell 7 does not parse at all, and a DSC `Configuration` on a host
    # without the DSC schema store -- Linux, by default. Calling those "parse error" sent the
    # reader to fix syntax that is fine on Windows PowerShell. Only the first line of the message
    # is kept: the DSC one carries the .NET exception and its whole stack trace.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ParseError,
        # The file's tokens, for the DSC case, which has no ErrorId of its own.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token
    )
    $message = ($ParseError.Message -split '\r?\n')[0]
    if ($ParseError.ErrorId -eq 'FileReadError') { return "could not be read: $message" }
    if ($ParseError.ErrorId -eq 'WorkflowNotSupportedInPowerShellCore') { return "a workflow, which PowerShell 7 cannot parse: $message" }
    if (Test-PSCxDscSchemaFault -ParseError $ParseError -Token $Token) {
        return "a DSC Configuration, which this host cannot parse without the DSC schema store: $message"
    }
    return "parse error: $message"
}

function Test-PSCxDscSchemaFault {
    # True when a parse error is the parser failing to load DSC resources for a `Configuration`,
    # rather than a fault in the source.
    #
    # By POSITION, not message: that error has the generic ErrorId 'ParserError', and its text is
    # a .NET exception message that may be localised. It always sits on the token straight after
    # the `Configuration` keyword -- the configuration's name, where the parser goes to look the
    # resources up. A real syntax error later in the same file is not there, and keeps its name.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ParseError,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token
    )
    if ($ParseError.ErrorId -ne 'ParserError') { return $false }
    # PSMutant-Equivalent: 1 -> 0: Token[-1] is the EndOfInput token the parser always ends with, which is never the Configuration keyword.
    for ($i = 1; $i -lt $Token.Count; $i++) {
        if ($Token[$i - 1].Kind -eq 'Configuration' -and
            $Token[$i].Extent.StartOffset -eq $ParseError.Extent.StartOffset) { return $true }
    }
    return $false
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
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison,
        # The file's changed lines from -ChangedDiff, as Get-PSCxUnifiedDiff gives them, or $null to
        # gate every unit in it.
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Hunk,
        [switch]$Detailed
    )
    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    # The per-node answer tables are for THIS file. Keyed by node reference they can never answer
    # wrongly across parses, so this is about memory rather than correctness: without it a gate
    # over a large tree holds every node of every file it has seen.
    Clear-PSCxAstCache
    # Relative to where the caller is standing, which for a repo-scoped run is the repo. Not a
    # parameter: a root nobody passes is a root nobody gets wrong. Resolved for BOTH arms, so a
    # skipped file is named the same way a measured one is.
    $relative = Get-PSCxRelativePath -Path $File -Root (Get-PSCxWorkingRoot) -PathComparison $PathComparison
    if ($errors) {
        # The FIRST error. Later ones are usually cascade from it, and a skip that does not say
        # why is the one thing the reason string exists to prevent.
        return [pscustomobject]@{
            File         = $relative
            Units        = @()
            SkipReason   = Get-PSCxSkipReason -ParseError $errors[0] -Token $tokens
            Measured     = @()
            InlineAccept = @()
            InlineStray  = @()
        }
    }
    return Get-PSCxParsedScan -Ast $ast -Token @($tokens) -File $relative -Hunk $Hunk -Detailed:$Detailed
}

function Get-PSCxParsedScan {
    # One parsed file's measurement: the units, the ones a diff changed, and the acceptances its
    # code declares. Apart from the parse so the editor rule (#163) measures a buffer that is not on
    # disk exactly as the gate measures a file -- the two cannot disagree about a score.
    #
    # The caller has cleared the per-node caches for this tree, as Get-PSCxFileScan does.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        # The file as a record names it.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$File,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Hunk,
        [switch]$Detailed
    )

    # ONCE, shared. Get-PSCxUnitTable used to run three times against the same AST in a single
    # pass -- once here for the line numbers, and once inside each metric map -- each a full
    # FindAll with a PowerShell predicate per node. It reads the index's buckets now (#155).
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
    $loc = @{}
    if ($Detailed) {
        $byUnit = Get-PSCxContributionMap -Row $cogRows
        # Information only, and only when asked for (#166): one pass over the tokens the parse
        # already produced, attributed to the same units the scores are.
        $loc = Get-PSCxLinesOfCodeMap -Token $Token -Span (Get-PSCxUnitSpan -Ast $ast)
    }
    # The units a diff changed (#168): every unit is still measured, because the policy checks
    # acceptances and baseline entries against the whole file, but only these are gated.
    $changed = $null
    # Wrapped, because no unit changed is an empty answer and unrolled it would read as no filter.
    if ($null -ne $Hunk) { $changed = @(Get-PSCxChangedUnit -Span (Get-PSCxUnitSpan -Ast $ast) -Hunk $Hunk) }
    $selected = [System.Collections.Generic.List[object]]::new()
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
        $record = Get-PSCxUnitRecord -File $File -Unit $display[$k] -Line $lines[$k] `
            -Cyclomatic $cyc[$k] -Cognitive $cog[$k] -MetricVersion $script:PSCxMetricVersion `
            -Contributions $contrib -LinesOfCode ([int]$loc[$k]) -Detailed:$Detailed
        if ($null -eq $changed -or $k -in $changed) { $selected.Add($record) }
        $record
    }
    # Acceptances written in the code (#165), read here because only here are the text, the
    # tokens and the unit lines all at hand. Collected on every run and applied only by the gate:
    # Measure-PSComplexity measures every unit whatever a comment argues.
    $inline = Get-PSCxInlineAccept -Text $ast.Extent.Text -Token $Token -UnitLine $lines -Display $display -File $File
    return [pscustomobject]@{
        File         = $File
        Units        = @($selected)
        Measured     = @($units)
        SkipReason   = $null
        InlineAccept = $inline.Accept
        InlineStray  = $inline.Stray
    }
}

function Test-PSCxSelectedFile {
    # Whether the walk measures this file: named by -ChangedFile when a list was given, and not
    # excluded by the config (#164). An excluded file is recorded, because a report has to be able
    # to say what it left out -- and only one the run would otherwise have measured, so the list
    # does not fill up with files a diff-scoped run was never going to read.
    #
    # Out of the walk's loop for the ceiling this module gates itself on: two filters nested two
    # loops deep cost the walk its nesting twice.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison,
        [System.Collections.Generic.HashSet[string]]$ChangedSet,
        # The resolved config's Exclude -- Base, Pattern, Regex -- or $null for none.
        $Exclude,
        [System.Collections.Generic.List[string]]$Excluded
    )
    $relative = Get-PSCxRelativePath -Path $File -Root $Root -PathComparison $PathComparison
    if ($null -ne $ChangedSet -and -not $ChangedSet.Contains($relative)) { return $false }
    if ($null -eq $Exclude) { return $true }
    # Matched relative to the CONFIG's directory, which is what its patterns are written against. A
    # file outside that directory comes back as a full path, and is never excluded: `**` would
    # otherwise match it, and a config cannot speak for a tree it does not sit in.
    $underConfig = Get-PSCxRelativePath -Path $File -Root $Exclude.Base -PathComparison $PathComparison
    if ([System.IO.Path]::IsPathRooted($underConfig)) { return $true }
    foreach ($regex in $Exclude.Regex) {
        if ($regex.IsMatch($underConfig)) {
            $Excluded.Add($relative)
            return $false
        }
    }
    return $true
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
        # -ChangedDiff's hunks: File -> hunks, keyed as ChangedSet is, or $null to gate whole files.
        [hashtable]$ChangedLine,
        # The config's excludes and the list the files they matched go into; both $null without one.
        $Exclude,
        [System.Collections.Generic.List[string]]$Excluded,
        # The run's, and the one -Seen was built with -- the caller holds both.
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison,
        [switch]$Recurse,
        [switch]$Detailed
    )
    $root = Get-PSCxWorkingRoot
    foreach ($p in $Path) {
        $files = Get-PSCxSourceFile -Path $p -Recurse:$Recurse
        # Recorded BEFORE the changed-file filter, because "this path is not there" and "nothing in
        # this path changed" are different answers and only the first one is a mistake.
        if ($files.Count -eq 0) {
            $Unmatched.Add((Get-PSCxUnmatchedPath -Path $p))
            continue
        }
        foreach ($file in $files) {
            # Compared as the run's file system compares names: where it ignores case, one file
            # reached under two casings counts once. A refusal is not dropped unexamined, though
            # -- skipping it without a word let a gate pass over code it never read (#151).
            if (-not $Seen.Add($file)) {
                Get-PSCxCaseTwinScan -File $file -Seen $Seen -PathComparison $PathComparison
                continue
            }
            # BEFORE the parse, so a diff-scoped run over a large tree does not read every file
            # only to throw most of them away. The verdict is identical either way; the cost is
            # not, and cost is most of why anyone asks for a diff-scoped run.
            if (-not (Test-PSCxSelectedFile -File $file -Root $root -PathComparison $PathComparison `
                        -ChangedSet $ChangedSet -Exclude $Exclude -Excluded $Excluded)) { continue }
            # BEFORE the parse, not after. A line written afterwards names files that are
            # already done, so a scan stuck on one file looks exactly like a scan that has
            # finished -- which is the whole complaint. Named here, the last line printed IS
            # the file being read.
            #
            # Verbose rather than a progress bar or a default-on line: this is the command a
            # CI gate calls, and a gate that chatters gets its output filtered, which takes
            # the parse errors with it.
            Write-Verbose "Measuring $file"
            $hunk = $null
            if ($null -ne $ChangedLine) { $hunk = $ChangedLine[(Get-PSCxRelativePath -Path $file -Root $root -PathComparison $PathComparison)] }
            Get-PSCxFileScan -File $file -PathComparison $PathComparison -Hunk $hunk -Detailed:$Detailed
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
        # -ChangedDiff's files and hunks, as Get-PSCxUnifiedDiff gives them, or omitted. Restricts the
        # run to the units owning a changed line, and is recorded in Scope like ChangedFile.
        [System.Collections.IDictionary]$ChangedDiff,
        # The resolved config's Exclude, or $null. Recorded in Scope beside the files it matched.
        $Exclude,
        [switch]$Recurse,
        [switch]$Detailed
    )
    $units = [System.Collections.Generic.List[object]]::new()
    $measured = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[string]]::new()
    $inlineAccept = [System.Collections.Generic.List[object]]::new()
    $inlineStray = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $unmatched = [System.Collections.Generic.List[object]]::new()
    $root = Get-PSCxWorkingRoot
    # Read once from the working directory's file system and recorded below, so the gate keys
    # its baseline and acceptances by the same rule the scan used to tell files apart.
    $pathComparison = Get-PSCxRunPathComparison -Root $root
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::FromComparison($pathComparison))
    # $null when no filter was asked for, which is what tells the walk to read everything. Built
    # from $PSBoundParameters rather than from the value, so an explicitly empty list is
    # distinguishable from an absent one -- the public commands refuse the first.
    $changedSet = $null
    if ($PSBoundParameters.ContainsKey('ChangedFile')) {
        $changedSet = Get-PSCxChangedSet -ChangedFile $ChangedFile -Root $root -PathComparison $pathComparison
    }
    $changedLine = $null
    if ($PSBoundParameters.ContainsKey('ChangedDiff')) {
        $changedLine = Get-PSCxChangedLine -Diff $ChangedDiff -Root $root -PathComparison $pathComparison
        $changedSet = Get-PSCxChangedSet -ChangedFile @($changedLine.Keys) -Root $root -PathComparison $pathComparison
    }
    foreach ($fileScan in (Get-PSCxPathScan -Path $Path -Seen $seen -Unmatched $unmatched -ChangedSet $changedSet -ChangedLine $changedLine -Exclude $Exclude -Excluded $excluded -PathComparison $pathComparison -Recurse:$Recurse -Detailed:$Detailed)) {
        if ($fileScan.SkipReason) {
            $skipped.Add([pscustomobject]@{ File = $fileScan.File; Reason = $fileScan.SkipReason })
            continue
        }
        $units.AddRange([object[]]$fileScan.Units)
        $measured.AddRange([object[]]$fileScan.Measured)
        $inlineAccept.AddRange([object[]]$fileScan.InlineAccept)
        $inlineStray.AddRange([object[]]$fileScan.InlineStray)
    }
    # Assigned OUT of the hashtable literal, and typed. A $( ) subexpression UNROLLS a
    # one-element array to the element, so a run filtered to a single file recorded a bare string
    # where every consumer expects a list -- and the report then serialised it as one, which the
    # published schema rejects. Same trap as returning an empty HashSet.
    $changed = $null
    if ($null -ne $changedSet) { $changed = [string[]]@($changedSet | Sort-Object) }
    # Sorted by file for the report, each file's hunks as the diff gave them.
    $lineScope = $null
    if ($null -ne $changedLine) {
        $lineScope = [ordered]@{}
        foreach ($f in @($changedLine.Keys | Sort-Object)) { $lineScope[$f] = @($changedLine[$f]) }
    }
    return [pscustomobject]@{
        Units         = @($units)
        # Every unit of every file read, the gated ones among them. The same as Units unless
        # -ChangedDiff picked some out: the policy is checked against these, so an acceptance for a
        # unit the diff did not touch is still judged rather than mistaken for a renamed one.
        Measured      = @($measured)
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
            # -ChangedDiff's hunks per file, or $null when the run gated whole files.
            ChangedLines = $lineScope
            # What the config excluded: its patterns, and the files they kept out of this run.
            # Both empty without a config, which is the true answer rather than an absent one.
            Exclude     = [string[]]@($Exclude.Pattern | Where-Object { $null -ne $_ })
            Excluded    = [string[]]@($excluded | Sort-Object)
        }
        MetricVersion = $script:PSCxMetricVersion
        # Acceptances the measured files declare in their code, and declarations that excuse no
        # unit (#165). Facts about the files, so they live in the scan; the gate decides.
        InlineAccept  = @($inlineAccept)
        InlineStray   = @($inlineStray)
        # How this run compared file paths. A fact about the run, read by the gate: a baseline keyed
        # by a different rule than the scan used would match the wrong units or none.
        PathComparison = $pathComparison
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
