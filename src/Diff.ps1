# Changed lines from a unified diff (#168): which lines of which files a change touched, and which
# units own them.
#
# The caller produces the diff -- `git diff --unified=0 origin/main...HEAD`, or any tool that writes
# the format -- so the module stays free of git, for the reasons recorded beside -ChangedFile. Only
# the headers are read: `+++` names a file on the new side, and `@@` gives a hunk's new-side line
# range. The lines in between are skipped by the counts the header gives, never interpreted, so an
# added line that happens to start `++` cannot be mistaken for a header. With context lines in the
# diff, those count as changed too: `--unified=0` gives exactly the changed lines.
#
# Pure: text in, data out. The scan applies it.

$script:PSCxHunkHeader = [regex]::new('^@@ -\d+(?:,(?<oldCount>\d+))? \+(?<start>\d+)(?:,(?<count>\d+))? @@')

function Get-PSCxDiffPath {
    # The file one `---` or `+++` header names, as the diff spelt it, or $null for /dev/null -- the
    # side of a file that was created or deleted.
    #
    # git quotes a path holding unusual characters ("b/my \"x\".ps1") and other tools append a tab
    # and a timestamp; both are taken off. The a/ and b/ prefixes are left on: only the pair of
    # headers can say whether they are prefixes or a directory, and Get-PSCxUnifiedDiff decides.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Header)
    $path = $Header.Substring(4).Split("`t")[0]
    if ($path.Length -ge 2 -and $path.StartsWith('"') -and $path.EndsWith('"')) {
        $path = $path.Substring(1, $path.Length - 2) -replace '\\(["\\])', '$1'
    }
    if ($path -eq '/dev/null') { return $null }
    return $path
}

function Get-PSCxUnifiedDiff {
    # The new-side hunks of every file a unified diff changes: [pscustomobject]@{ Files; Fault }.
    # Files maps each file, as the diff names it, to its hunks -- Start and Count on the new side,
    # Count 0 for a pure deletion, which sits after line Start. Fault says why the text cannot be
    # read as a diff, and Files is then empty.
    #
    # A deleted file is left out: nothing of it is left to measure. A file whose change has no hunk
    # -- a rename, a mode change, a new empty file -- is listed with none.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # Lines, or one string holding them, as a pipe or Get-Content -Raw gives it.
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Text
    )
    $lines = @(($Text -join "`n") -split '\r?\n')
    if (-not ($lines -match '\S')) {
        return [pscustomobject]@{ Files = [ordered]@{}; Fault = '-ChangedDiff was given an empty diff. An empty diff would restrict the run to nothing and report a pass over zero units, which is the failure this module exists to find -- and it is what a diff command prints when it fails, matches nothing, or runs against a shallow clone whose base ref is missing. If nothing changed, skip the gate rather than asking it to measure an empty set.' }
    }
    # Minus: the last `---` path. Current: the file hunks go to, $null inside a deleted one.
    # Old, New: body lines still to skip on each side after the last hunk header.
    $state = [pscustomobject]@{ Files = [ordered]@{}; Minus = $null; Current = $null; InFile = $false; SawFile = $false; Old = 0; New = 0 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $fault = Read-PSCxDiffLine -State $state -Line $lines[$i] -Number ($i + 1)
        if ($fault) { return [pscustomobject]@{ Files = [ordered]@{}; Fault = $fault } }
    }
    if (-not $state.SawFile) {
        return [pscustomobject]@{ Files = $state.Files; Fault = '-ChangedDiff was given text with no file header (`diff` or `+++`), so it is not a unified diff. Pass the output of `git diff --unified=0 <base>...HEAD`, not a list of file names: that is what -ChangedFile takes.' }
    }
    return [pscustomobject]@{ Files = $state.Files; Fault = $null }
}

function Read-PSCxDiffLine {
    # Read one line of a diff into the state Get-PSCxUnifiedDiff keeps, returning why it cannot be
    # read, or nothing.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Line,
        [Parameter(Mandatory)] [int]$Number
    )
    # A body line, skipped by the counts and never read: it may begin with anything.
    # A context line counts on both sides, an added or removed one on its own, and git's
    # `\ No newline at end of file` on neither.
    if ($State.Old -gt 0 -or $State.New -gt 0) {
        $note = $Line.StartsWith('\')
        if (-not $Line.StartsWith('+') -and -not $note) { $State.Old-- }
        if (-not $Line.StartsWith('-') -and -not $note) { $State.New-- }
        return
    }
    if ($Line.StartsWith('diff ')) {
        $State.InFile = $false
        $State.Current = $null
        $State.SawFile = $true
        return
    }
    if ($Line.StartsWith('--- ')) { $State.Minus = Get-PSCxDiffPath -Header $Line; return }
    if ($Line.StartsWith('+++ ')) { Read-PSCxDiffFileHeader -State $State -Line $Line; return }
    if ($Line.StartsWith('@@')) { return Read-PSCxDiffHunk -State $State -Line $Line -Number $Number }
}

function Read-PSCxDiffFileHeader {
    # A `+++` header: the file the hunks after it belong to.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string]$Line
    )
    $current = Get-PSCxDiffPath -Header $Line
    # git's prefixes, taken off only when the old side shows them too -- `--no-prefix` writes
    # neither, and a top-level directory named b/ must keep its name there.
    if ($current -and $current.StartsWith('b/') -and ($null -eq $State.Minus -or $State.Minus.StartsWith('a/'))) {
        $current = $current.Substring(2)
    }
    if ($current -and -not $State.Files.Contains($current)) { $State.Files[$current] = [System.Collections.Generic.List[object]]::new() }
    $State.Current = $current
    $State.InFile = $true
    $State.SawFile = $true
}

function Read-PSCxDiffHunk {
    # A `@@` header: one hunk of the current file, and the body lines to skip after it. Returns why
    # it cannot be read, or nothing.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string]$Line,
        [Parameter(Mandatory)] [int]$Number
    )
    $match = $script:PSCxHunkHeader.Match($Line)
    $fault = Get-PSCxHunkFault -Line $Line -Number $Number -Match $match -InFile $State.InFile
    if ($fault) { return $fault }
    # A count left out is one line, as the format defines it.
    $count = $match.Groups['count'].Success ? [int]$match.Groups['count'].Value : 1
    $State.Old = $match.Groups['oldCount'].Success ? [int]$match.Groups['oldCount'].Value : 1
    $State.New = $count
    if ($State.Current) { $State.Files[$State.Current].Add([pscustomobject]@{ Start = [int]$match.Groups['start'].Value; Count = $count }) }
}

function Get-PSCxHunkFault {
    # Why one `@@` line cannot be read, as text, or nothing when it can.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Line,
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [System.Text.RegularExpressions.Match]$Match,
        [Parameter(Mandatory)] [bool]$InFile
    )
    if (-not $Match.Success) { return "-ChangedDiff line $Number is not a hunk header ('$Line'): expected '@@ -<old> +<start>[,<count>] @@'." }
    if (-not $InFile) { return "-ChangedDiff line $Number starts a hunk before any '+++' header names its file, so the diff is cut or malformed." }
}

function Get-PSCxLineOwner {
    # For each line of a file, the innermost units holding it: an array indexed by line number, each
    # entry the unit keys or $null where no unit is (the script body's lines).
    #
    # Painted outer to inner, so an inner unit replaces its parent on its own lines. A unit sharing
    # a line with a sibling -- `} function Next {` -- does not replace it: both own the line, as
    # both count it as a line of code. One pass per unit over its own lines, so a large new file
    # costs its length times its nesting, not its length times its unit count.
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        # Get-PSCxUnitSpan: unit key -> Start, End (offsets), StartLine, EndLine.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Span
    )
    # Measure-Object over no units gives no maximum, which [int] makes 0.
    $last = [int]($Span.Values.EndLine | Measure-Object -Maximum).Maximum
    $owner = [object[]]::new($last + 1)
    $order = @($Span.Keys | Sort-Object @{ Expression = { $Span[$_].End - $Span[$_].Start }; Descending = $true }, @{ Expression = { $_ } })
    foreach ($key in $order) {
        $unit = $Span[$key]
        for ($line = $unit.StartLine; $line -le $unit.EndLine; $line++) {
            # Keep a sibling sharing the line, whose text does not overlap this unit's. Anything
            # painted earlier that does overlap is longer, so it is the parent, and it goes.
            $kept = @(foreach ($k in @($owner[$line])) {
                    if ($null -ne $k -and ($Span[$k].End -le $unit.Start -or $unit.End -le $Span[$k].Start)) { $k }
                })
            $owner[$line] = $kept + $key
        }
    }
    return , $owner
}

function Get-PSCxChangedUnit {
    # The keys of the units a file's hunks change, '<script-body>' among them for a line no unit
    # holds.
    #
    # A changed line belongs to the innermost unit holding it, as its line of code does: editing a
    # nested function does not change its parent. A pure deletion between two lines belongs to the
    # innermost unit holding both -- removing a branch changes the unit it was removed from -- and
    # to the script body when no unit holds both, or at the top of the file.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Span,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Hunk
    )
    $owner = Get-PSCxLineOwner -Span $Span
    $changed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($h in $Hunk) {
        if ($h.Count -eq 0) {
            [void]$changed.Add((Get-PSCxDeletionOwner -Span $Span -After $h.Start))
            continue
        }
        for ($line = $h.Start; $line -lt $h.Start + $h.Count; $line++) {
            # Past the last unit's end the array has no entry -- an index past the end reads
            # $null -- and the line is the script body's.
            $keys = $owner[$line]
            if ($null -eq $keys) { [void]$changed.Add('<script-body>'); continue }
            foreach ($k in $keys) { [void]$changed.Add($k) }
        }
    }
    return [string[]]@($changed)
}

function Get-PSCxDeletionOwner {
    # The innermost unit holding both lines a deletion sits between -- After and the line below it
    # -- or the script body when none does.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Span,
        [Parameter(Mandatory)] [int]$After
    )
    # The units holding both lines nest, so the shortest of them is the innermost.
    $holding = @($Span.Keys | Where-Object { $Span[$_].StartLine -le $After -and $After + 1 -le $Span[$_].EndLine } |
            Sort-Object { $Span[$_].End - $Span[$_].Start })
    if ($holding.Count -eq 0) { return '<script-body>' }
    return $holding[0]
}
