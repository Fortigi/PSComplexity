# The Markdown summary (#167): the same run, rendered for a person -- a CI step summary, a pull
# request comment. Not a second source of numbers: every figure here is read off the scan and the
# gate's verdict, exactly as the JSON report's are.
#
# Three parts, always in this order: the hotspots (the top N units by cognitive, then cyclomatic),
# per-file totals, and -- when given a previous JSON report -- what is new, worse or better than it.
# The gate's version adds its verdict and lists EVERY breach, whatever N is: a summary that showed
# ten of twelve breaches would be the partial number this project exists to distrust.

function ConvertTo-PSCxMarkdownCell {
    # Text that is safe inside a table cell: a pipe would end the cell, and a line break the row.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] $Text)
    return ([string]$Text).Replace('|', '\|').Replace("`r", '').Replace("`n", ' ')
}

function Get-PSCxMarkdownTable {
    # A Markdown table: one header row, the separator, one row per entry. Every cell escaped.
    # Both, for the comma-wrap that keeps the array whole: `, $x` is statically an Object[].
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Header,
        # Each row an array of cells, in header order.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Row
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| ' + ($Header -join ' | ') + ' |')
    $lines.Add('|' + (@($Header | ForEach-Object { ' --- ' }) -join '|') + '|')
    foreach ($r in $Row) {
        $lines.Add('| ' + (@($r | ForEach-Object { ConvertTo-PSCxMarkdownCell -Text $_ }) -join ' | ') + ' |')
    }
    return , [string[]]$lines.ToArray()
}

function Get-PSCxHotspot {
    # The Top units by cognitive, then cyclomatic, with file and unit breaking ties so the same
    # run always lists the same units in the same order.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [int]$Top
    )
    # Emitted, not comma-wrapped: callers collect with @(), and a wrapped empty list would come
    # back to them as a list holding one empty list.
    $Unit | Sort-Object @{ Expression = 'Cognitive'; Descending = $true }, @{ Expression = 'Cyclomatic'; Descending = $true }, File, Unit |
        Select-Object -First $Top
}

function Get-PSCxFileTotal {
    # Per file: how many units, the summed cognitive score, and the highest of each metric --
    # ordered by the sum, so the file with the most to read comes first.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit)
    $totals = foreach ($group in ($Unit | Group-Object File)) {
        [pscustomobject]@{
            File          = $group.Name
            Units         = $group.Count
            Cognitive     = [int]($group.Group | Measure-Object Cognitive -Sum).Sum
            MaxCognitive  = [int]($group.Group | Measure-Object Cognitive -Maximum).Maximum
            MaxCyclomatic = [int]($group.Group | Measure-Object Cyclomatic -Maximum).Maximum
        }
    }
    $totals | Sort-Object @{ Expression = 'Cognitive'; Descending = $true }, File
}

function Get-PSCxCompareFault {
    # Why a previous report cannot be compared with this run, as text. Nothing when it can.
    #
    # A report from another metric version is refused, as a baseline is: its numbers answer a
    # different question, so "worse" and "better" against it would be guesses.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Document,
        [Parameter(Mandatory)] [int]$MetricVersion
    )
    if ($Document.generatedFrom -ne 'PSComplexity' -or $null -eq $Document.units) {
        return 'it is not a PSComplexity JSON report -- write one with -ReportPath'
    }
    if ([int]$Document.metricVersion -ne $MetricVersion) {
        return "it was measured with metric version $($Document.metricVersion) and this run with $MetricVersion, so its numbers are not comparable"
    }
}

function Get-PSCxComparison {
    # This run's units against a previous report's: new (no unit of that file and name before),
    # worse (either metric up) and better (neither up, at least one down). Units that only
    # disappeared are not listed; a unit gone is not a hotspot.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$BaseUnit,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $before = Get-PSCxPolicyLookup -Record $BaseUnit -PathComparison $PathComparison
    $new = [System.Collections.Generic.List[object]]::new()
    $worse = [System.Collections.Generic.List[object]]::new()
    $better = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $Unit) {
        $b = $null
        if (-not $before.TryGetValue((Get-PSCxPolicyKey -File ([string]$u.File) -Unit ([string]$u.Unit)), [ref]$b)) { $new.Add($u); continue }
        $pair = [pscustomobject]@{ Unit = $u; Before = $b }
        if ($u.Cyclomatic -gt [int]$b.Cyclomatic -or $u.Cognitive -gt [int]$b.Cognitive) { $worse.Add($pair); continue }
        if ($u.Cyclomatic -lt [int]$b.Cyclomatic -or $u.Cognitive -lt [int]$b.Cognitive) { $better.Add($pair) }
    }
    return [pscustomobject]@{ New = @($new); Worse = @($worse); Better = @($better) }
}

function Get-PSCxMarkdownHeadline {
    # The one line a reader takes away: the verdict and its terms, or what was measured.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [AllowNull()] $Gate
    )
    $units = @($Scan.Units)
    $files = @($units | ForEach-Object { $_.File } | Select-Object -Unique).Count
    $measured = "$($units.Count) unit(s) in $files file(s)"
    if ($null -eq $Gate) { return "**Measured $measured**, metric version $($Scan.MetricVersion)." }
    $verdict = $Gate.Passed ? '**Gate passed**' : "**Gate failed** -- $(@($Gate.Violations).Count) unit(s) over a ceiling"
    return "$verdict. Measured $measured against cyclomatic $($Gate.MaxCyclomatic) and cognitive $($Gate.MaxCognitive)" +
        "$((@($Gate.Overrides).Count -gt 0) ? ", with $(@($Gate.Overrides).Count) per-path override(s)" : '')."
}

function Get-PSCxMarkdownScopeLine {
    # What the numbers do NOT cover, said beside them: a diff-scoped run, excluded files, files
    # that could not be measured, and what the gate excused. Nothing when there is nothing to say.
    # Both, for the comma-wrap that keeps the array whole: `, $x` is statically an Object[].
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [AllowNull()] $Gate
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Scan.Scope.ChangedFile) { $notes.Add("Only the $(@($Scan.Scope.ChangedFile).Count) changed file(s) were measured, not the whole tree.") }
    if (@($Scan.Scope.Excluded).Count -gt 0) { $notes.Add("$(@($Scan.Scope.Excluded).Count) file(s) excluded by the config.") }
    if (@($Scan.Skipped).Count -gt 0) { $notes.Add("$(@($Scan.Skipped).Count) file(s) could not be measured.") }
    # Filtered, never @($Gate.X) alone: for a measurement there is no gate, and @() around $null
    # is a list of ONE, which would report an acceptance nobody made.
    $accepted = @($Gate.Accepted | Where-Object { $null -ne $_ }).Count
    $baselined = @($Gate.Baselined | Where-Object { $null -ne $_ }).Count
    if ($Gate.Config) { $notes.Add("Policy from ``$($Gate.Config)``.") }
    if ($accepted -gt 0) { $notes.Add("$accepted unit(s) accepted with a written reason.") }
    if ($baselined -gt 0) { $notes.Add("$baselined unit(s) held to a baseline.") }
    return , [string[]]$notes.ToArray()
}

function Get-PSCxMarkdownBreach {
    # The gate's breaches, every one, with the ceilings each unit faced -- an override's where one
    # reached it, read from the gate's file ceilings rather than resolved again here.
    # Both, for the comma-wrap that keeps the array whole: `, $x` is statically an Object[].
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Gate)
    # @( ) around the loop: assigned bare, a single breach's row would arrive as its four cells.
    $rows = @(foreach ($v in @($Gate.Violations)) {
        $ceiling = $Gate.FileCeiling[[string]$v.File]
        , @($v.Unit, "$($v.File):$($v.Line)",
            "$($v.Cyclomatic) / $($ceiling.Cyclomatic ?? $Gate.MaxCyclomatic)",
            "$($v.Cognitive) / $($ceiling.Cognitive ?? $Gate.MaxCognitive)")
        })
    return , [string[]](@('', '### Over a ceiling', '') +
        (Get-PSCxMarkdownTable -Header 'Unit', 'Where', 'Cyclomatic / max', 'Cognitive / max' -Row $rows))
}

function Get-PSCxMarkdownComparisonPart {
    # The comparison section: new, worse and better units, each a table, or a line saying none.
    # Both, for the comma-wrap that keeps the array whole: `, $x` is statically an Object[].
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Comparison,
        [Parameter(Mandatory)] [string]$BaseName
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@('', "### Compared with ``$BaseName``", ''))
    $lines.Add("$($Comparison.New.Count) new, $($Comparison.Worse.Count) worse, $($Comparison.Better.Count) better.")
    if ($Comparison.New.Count -gt 0) {
        $lines.AddRange([string[]]@('', '**New**', ''))
        $lines.AddRange((Get-PSCxMarkdownTable -Header 'Unit', 'Where', 'Cyclomatic', 'Cognitive' -Row @(
                    $Comparison.New | ForEach-Object { , @($_.Unit, "$($_.File):$($_.Line)", $_.Cyclomatic, $_.Cognitive) })))
    }
    foreach ($part in @(@('Worse', $Comparison.Worse), @('Better', $Comparison.Better))) {
        if ($part[1].Count -eq 0) { continue }
        $lines.AddRange([string[]]@('', "**$($part[0])**", ''))
        $lines.AddRange((Get-PSCxMarkdownTable -Header 'Unit', 'Where', 'Cyclomatic', 'Cognitive' -Row @(
                    $part[1] | ForEach-Object {
                        , @($_.Unit.Unit, "$($_.Unit.File):$($_.Unit.Line)", "$($_.Before.Cyclomatic) -> $($_.Unit.Cyclomatic)", "$($_.Before.Cognitive) -> $($_.Unit.Cognitive)")
                    })))
    }
    return , [string[]]$lines.ToArray()
}

function Get-PSCxMarkdownDocument {
    # The whole summary as text. Pure: the previous report arrives already read.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [Parameter(Mandatory)] [int]$Top,
        # The gate's verdict and terms, or $null for a measurement.
        [AllowNull()] $Gate,
        # The previous report's comparison, or $null for none.
        [AllowNull()] $Comparison,
        [AllowEmptyString()] [string]$BaseName
    )
    $units = @($Scan.Units)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@('## PSComplexity', '', (Get-PSCxMarkdownHeadline -Scan $Scan -Gate $Gate)))
    $scope = Get-PSCxMarkdownScopeLine -Scan $Scan -Gate $Gate
    if ($scope.Count -gt 0) { $lines.AddRange([string[]]@('', ($scope -join ' '))) }
    if (@($Gate.Violations | Where-Object { $null -ne $_ }).Count -gt 0) { $lines.AddRange((Get-PSCxMarkdownBreach -Gate $Gate)) }
    $hot = @(Get-PSCxHotspot -Unit $units -Top $Top)
    $lines.AddRange([string[]]@('', "### Most complex units (top $Top)", ''))
    $lines.AddRange((Get-PSCxMarkdownTable -Header 'Unit', 'Where', 'Cognitive', 'Cyclomatic' -Row @(
                $hot | ForEach-Object { , @($_.Unit, "$($_.File):$($_.Line)", $_.Cognitive, $_.Cyclomatic) })))
    $lines.AddRange([string[]]@('', '### Per file', ''))
    $lines.AddRange((Get-PSCxMarkdownTable -Header 'File', 'Units', 'Cognitive total', 'Max cognitive', 'Max cyclomatic' -Row @(
                @(Get-PSCxFileTotal -Unit $units) | ForEach-Object { , @($_.File, $_.Units, $_.Cognitive, $_.MaxCognitive, $_.MaxCyclomatic) })))
    if ($null -ne $Comparison) { $lines.AddRange((Get-PSCxMarkdownComparisonPart -Comparison $Comparison -BaseName $BaseName)) }
    return ($lines -join "`n") + "`n"
}

function Read-PSCxCompareBase {
    # The previous report to compare against, or $null when none was asked for -- read and checked
    # BEFORE the scan, so a wrong path is refused before the expensive part rather than after it.
    [OutputType([object])]
    [CmdletBinding()]
    param(
        # The command's $PSBoundParameters.
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory)] [int]$MetricVersion
    )
    # Refused rather than ignored, as -AllowNew without -UpdateBaseline is: a run carrying these
    # believes it asked for something, and without a summary to put it in it asked for nothing.
    if (-not $Bound['MarkdownPath'] -and ($Bound.ContainsKey('MarkdownTop') -or $Bound.ContainsKey('CompareTo'))) {
        throw '-MarkdownTop and -CompareTo only apply with -MarkdownPath: they shape the Markdown summary, and without one there is nothing for them to shape.'
    }
    $path = [string]$Bound['CompareTo']
    if (-not $path) { return $null }
    $document = Read-PSCxDocument -Path $path
    $fault = Get-PSCxCompareFault -Document $document -MetricVersion $MetricVersion
    if ($fault) { throw "Cannot compare with $path : $fault." }
    return $document
}

function Write-PSCxMarkdown {
    # Render the summary and write it. The previous report, if any, was read by
    # Read-PSCxCompareBase before the scan.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Scan,
        [Parameter(Mandatory)] [int]$Top,
        [AllowNull()] $Gate,
        [AllowNull()] $Base,
        [AllowEmptyString()] [string]$BaseName
    )
    $comparison = ($null -eq $Base) ? $null :
        (Get-PSCxComparison -Unit @($Scan.Units) -BaseUnit @($Base.units) -PathComparison $Scan.PathComparison)
    Save-PSCxText -Path $Path -Text (Get-PSCxMarkdownDocument -Scan $Scan -Top $Top -Gate $Gate -Comparison $comparison -BaseName $BaseName)
}
