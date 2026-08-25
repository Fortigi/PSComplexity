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

function Get-PSCxFileRecord {
    # Every unit in ONE file, in source order. The caller owns which files and whether one
    # has been seen already; this owns what a file yields.
    #
    # Separate from the caller because the caller is two foreach levels deep before it does
    # anything: everything here would start at +3 inside it, and the parse-error guard and the
    # emit loop together are enough to put Measure-PSComplexity over the ceiling this module
    # gates itself on. Keeping it here is also what makes "measure one file" testable alone.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$File,
        [switch]$Detailed
    )
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors)
    if ($errors) {
        # Write-Error, not Write-Warning: non-terminating, so measuring a tree with one bad
        # file still returns every other file's units -- but it lands on a stream that
        # -ErrorVariable can capture and CI does not swallow. Test-PSComplexity captures
        # exactly this and refuses.
        Write-Error "Skipped '$File' -- parse error: $($errors[0].Message)"
        return
    }

    # Relative to where the caller is standing, which for a repo-scoped run is the repo.
    # Not a parameter: a root nobody passes is a root nobody gets wrong.
    $relative = Get-PSCxRelativePath -Path $File -Root (Get-Location).Path
    $cyc = Get-PSCxCyclomaticMap -Ast $ast
    $cog = Get-PSCxCognitiveMap -Ast $ast
    $lines = Get-PSCxUnitTable -Ast $ast
    # Source order, not hashtable order. .NET enumerates a hashtable by bucket layout, which
    # is neither insertion nor line order and is not required to be stable -- so two runs over
    # one unchanged file could emit the same rows in different sequences. Nothing noticed,
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
    foreach ($k in $ordered) {
        # Two traps stacked here, and the empty list has to survive BOTH.
        #
        # A decision-free unit has no entry, and @($byUnit[$k]) on a missing key gives an
        # array of ONE null rather than an empty one -- a contribution with no line, no
        # construct and no amount, which is worse than the absent property this exists to
        # avoid because it survives a count check.
        #
        # And the fix cannot be written as `$c = if (...) { ... } else { @() }`: an if used
        # as an expression yields its branch's OUTPUT, and emitting @() emits nothing, so
        # the variable lands back on $null. Assign first, then overwrite.
        $contrib = @()
        if ($byUnit.ContainsKey($k)) { $contrib = $byUnit[$k] }
        Get-PSCxUnitRecord -File $relative -Unit $display[$k] -Line $lines[$k] `
            -Cyclomatic $cyc[$k] -Cognitive $cog[$k] -MetricVersion $script:PSCxMetricVersion `
            -Contributions $contrib -Detailed:$Detailed
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
        decision-point count, over the same set of constructs. Files that fail to parse are
        skipped with a warning.

    .PARAMETER Path
        One or more files or directories to measure.

    .PARAMETER Recurse
        Recurse into subdirectories when a directory is given.

    .OUTPUTS
        [pscustomobject] with File, Unit, Line, Cyclomatic, Cognitive -- one per unit.

        These five names, their order and their types are the module's public contract
        alongside the two command names, and a test asserts them exactly: widening the
        record fails that test, so it is a decision rather than a side effect of an
        internal change. File and Unit are [string]; Line, Cyclomatic and Cognitive are
        [int] -- Line as a string would silently turn a numeric sort into a lexical one.

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
        foreach ($p in $Path) {
            foreach ($file in (Get-PSCxSourceFile -Path $p -Recurse:$Recurse)) {
                # OrdinalIgnoreCase: Windows and macOS resolve the same file under different
                # casing, and a case-sensitive check would let those through as two files.
                if (-not $seen.Add($file)) { continue }
                # BEFORE the parse, not after. A line written afterwards names files that are
                # already done, so a scan stuck on one file looks exactly like a scan that has
                # finished -- which is the whole complaint. Named here, the last line printed
                # IS the file being read.
                #
                # Verbose rather than a progress bar or a default-on line: this is the command
                # a CI gate calls, and a gate that chatters gets its output filtered, which
                # takes the parse errors with it.
                Write-Verbose "Measuring $file"
                Get-PSCxFileRecord -File $file -Detailed:$Detailed
            }
        }
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
        [switch]$Recurse
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
        # Parse failures are captured rather than allowed past. A file the gate could not
        # read is a file it cannot vouch for, and "no unit exceeded a ceiling" is trivially
        # true of a file that produced no units -- the same shape as passing over an empty
        # selection.
        $paths = $collected.ToArray()
        $units = @(Measure-PSComplexity -Path $paths -Recurse:$Recurse -ErrorVariable parseErrors -ErrorAction SilentlyContinue)
        if ($parseErrors.Count -gt 0) {
            throw ("Refusing to vouch for $($parseErrors.Count) file(s) that did not parse: " +
                (($parseErrors | ForEach-Object { $_.Exception.Message }) -join '; ') +
                ". Fix the syntax, or exclude the file from the path you gate on.")
        }

        # Refuse rather than pass. "No unit breached a ceiling" and "no unit was measured"
        # are the same $true, so a gate pointed at the wrong place reports clean -- which is
        # the failure this module exists to find in other people's code.
        if ($units.Count -eq 0) {
            $hint = if ($Recurse) { '' } else { ', or add -Recurse if they are in subdirectories' }
            throw ("Measured no units under: " + ($paths -join ', ') + ". Nothing was checked, " +
                "so a pass here would describe an empty set. Check the path exists and holds " +
                ".ps1 or .psm1 files" + $hint + '.')
        }

        $violations = @($units |
                Where-Object { $_.Cyclomatic -gt $MaxCyclomatic -or $_.Cognitive -gt $MaxCognitive })
        foreach ($v in $violations) {
            Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                    $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $MaxCyclomatic, $v.Cognitive, $MaxCognitive)
        }
        return $violations.Count -eq 0
    }
}
