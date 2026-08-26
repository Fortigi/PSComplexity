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

function Get-PSCxMetricVersion {
    # A reader for the constant above, so no other file reaches into this one's module state. The
    # gate needs the number to stamp a baseline with; it does not need to know where it is kept.
    [OutputType([int])]
    [CmdletBinding()]
    param()
    return $script:PSCxMetricVersion
}
