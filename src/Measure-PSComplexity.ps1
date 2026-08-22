<#
.SYNOPSIS
    Public API for PSComplexity: Measure-PSComplexity (data) and Test-PSComplexity (gate).
#>

function Get-PSCxSourceFile {
    # Resolve a path (file or directory) to the PowerShell source files to measure.
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

function Measure-PSComplexity {
    <#
    .SYNOPSIS
        Measure cyclomatic and cognitive complexity of PowerShell code, per unit
        (each function/filter, plus one <script-body> per file for top-level code).

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

    .EXAMPLE
        Measure-PSComplexity ./src -Recurse | Sort-Object Cognitive -Descending

    .EXAMPLE
        # Fail a build if anything is too complex:
        if (-not (Test-PSComplexity ./src -Recurse)) { exit 1 }
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)] [ValidateNotNullOrEmpty()] [string[]]$Path,
        [switch]$Recurse
    )
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
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
                if ($errors) {
                    # Write-Error, not Write-Warning: non-terminating, so measuring a tree
                    # with one bad file still returns every other file's units -- but it
                    # lands on a stream that -ErrorVariable can capture and CI does not
                    # swallow. Test-PSComplexity captures exactly this and refuses.
                    Write-Error "Skipped '$file' -- parse error: $($errors[0].Message)"
                    continue
                }

                $cyc = Get-PSCxCyclomaticMap -Ast $ast
                $cog = Get-PSCxCognitiveMap -Ast $ast
                $lines = Get-PSCxUnitTable -Ast $ast
                # Source order, not hashtable order. .NET enumerates a hashtable by bucket
                # layout, which is neither insertion nor line order and is not required to
                # be stable -- so two runs over one unchanged file could emit the same rows
                # in different sequences. Nothing here noticed, because the gate takes a
                # max and a human reads a table; a committed baseline or a diffed report
                # would have.
                #
                # Line first, then unit name: two units CAN start on the same line
                # (`function A { } function B { }`), and a tie left unbroken puts the
                # nondeterminism straight back.
                $ordered = $lines.Keys | Sort-Object @{ Expression = { $lines[$_] } }, @{ Expression = { $_ } }
                foreach ($k in $ordered) {
                    [pscustomobject]@{
                        File       = $file
                        Unit       = ($k -replace '@\d+$', '')
                        Line       = $lines[$k]
                        Cyclomatic = $cyc[$k]
                        Cognitive  = $cog[$k]
                    }
                }
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
        [Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string[]]$Path,
        [int]$MaxCyclomatic = 15,
        [int]$MaxCognitive = 15,
        [switch]$Recurse
    )
    # Parse failures are captured rather than allowed past. A file the gate could not read
    # is a file it cannot vouch for, and "no unit exceeded a ceiling" is trivially true of a
    # file that produced no units -- the same shape as passing over an empty selection.
    $units = @(Measure-PSComplexity -Path $Path -Recurse:$Recurse -ErrorVariable parseErrors -ErrorAction SilentlyContinue)
    if ($parseErrors.Count -gt 0) {
        throw ("Refusing to vouch for $($parseErrors.Count) file(s) that did not parse: " +
            (($parseErrors | ForEach-Object { $_.Exception.Message }) -join '; ') +
            ". Fix the syntax, or exclude the file from the path you gate on.")
    }

    # Refuse rather than pass. "No unit breached a ceiling" and "no unit was measured" are
    # the same $true, so a gate pointed at the wrong place reports clean -- which is the
    # failure this module exists to find in other people's code.
    if ($units.Count -eq 0) {
        $hint = if ($Recurse) { '' } else { ', or add -Recurse if they are in subdirectories' }
        throw ("Measured no units under: " + ($Path -join ', ') + ". Nothing was checked, so " +
            "a pass here would describe an empty set. Check the path exists and holds .ps1 " +
            "or .psm1 files" + $hint + '.')
    }

    $violations = @($units |
            Where-Object { $_.Cyclomatic -gt $MaxCyclomatic -or $_.Cognitive -gt $MaxCognitive })
    foreach ($v in $violations) {
        Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $MaxCyclomatic, $v.Cognitive, $MaxCognitive)
    }
    return $violations.Count -eq 0
}
