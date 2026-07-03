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
    $gci = @{ Path = $Path; Include = @('*.ps1', '*.psm1'); File = $true; Recurse = [bool]$Recurse }
    return [string[]]@(Get-ChildItem @gci | ForEach-Object { $_.FullName })
}

function Measure-PSComplexity {
    <#
    .SYNOPSIS
        Measure cyclomatic and cognitive complexity of PowerShell code, per unit
        (each function/filter, plus one <script-body> per file for top-level code).

    .DESCRIPTION
        Parses each .ps1/.psm1 file with the PowerShell AST and reports both metrics.
        Cognitive complexity is a faithful port of the SonarSource metric (nesting-aware);
        cyclomatic is the classic decision-point count. Files that fail to parse are
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
    process {
        foreach ($p in $Path) {
            foreach ($file in (Get-PSCxSourceFile -Path $p -Recurse:$Recurse)) {
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
                if ($errors) { Write-Warning "Skipped '$file' -- parse error: $($errors[0].Message)"; continue }

                $cyc = Get-PSCxCyclomaticMap -Ast $ast
                $cog = Get-PSCxCognitiveMap -Ast $ast
                $lines = Get-PSCxUnitTable -Ast $ast
                foreach ($k in $lines.Keys) {
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
    $violations = @(Measure-PSComplexity -Path $Path -Recurse:$Recurse |
        Where-Object { $_.Cyclomatic -gt $MaxCyclomatic -or $_.Cognitive -gt $MaxCognitive })
    foreach ($v in $violations) {
        Write-Warning ("{0}:{1} {2} -- cyclomatic {3} (max {4}), cognitive {5} (max {6})" -f `
                $v.File, $v.Line, $v.Unit, $v.Cyclomatic, $MaxCyclomatic, $v.Cognitive, $MaxCognitive)
    }
    return $violations.Count -eq 0
}
