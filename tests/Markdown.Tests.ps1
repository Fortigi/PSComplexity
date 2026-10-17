# The Markdown summary (#167): what it lists, in what order, and what it says it left out.
#
# The COVERING SUITE for src/Markdown.ps1, and cheap: a scan is an ordinary object here and
# nothing is measured. The two commands writing it end to end are in tests/Measure.Tests.ps1.

BeforeAll {
    $script:PathCmp = $IsLinux ? [System.StringComparison]::Ordinal : [System.StringComparison]::OrdinalIgnoreCase
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "cxmd-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:work -Force | Out-Null

    function script:Unit {
        param([string]$File = 'src/A.ps1', [string]$Name = 'Get-A', [int]$Cyc = 1, [int]$Cog = 0, [int]$Line = 1)
        return [pscustomobject]@{ File = $File; Unit = $Name; Line = $Line; Cyclomatic = $Cyc; Cognitive = $Cog; MetricVersion = 3 }
    }
    function script:Scan {
        param([object[]]$Units = @(), $ChangedFile = $null, [string[]]$Excluded = @(), [object[]]$Skipped = @(), $ChangedLines = $null)
        return [pscustomobject]@{
            Units = @($Units); Skipped = @($Skipped); Unmatched = @(); MetricVersion = 3; PathComparison = $script:PathCmp
            Scope = [pscustomobject]@{ Path = @('.'); Recurse = $true; Root = '/r'; ChangedFile = $ChangedFile; ChangedLines = $ChangedLines; Exclude = @(); Excluded = $Excluded }
        }
    }
    function script:Gate {
        param([bool]$Passed = $true, [object[]]$Violations = @(), [object[]]$Overrides = @(), [hashtable]$FileCeiling = @{},
            [string]$Config = '', [object[]]$Accepted = @(), [object[]]$Baselined = @())
        return [pscustomobject]@{
            Passed = $Passed; Violations = $Violations; MaxCyclomatic = 15; MaxCognitive = 14; Overrides = $Overrides
            FileCeiling = $FileCeiling; Config = $Config; Accepted = $Accepted; Baselined = $Baselined
        }
    }
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'a table cell' {
    It 'escapes a pipe and folds a line break' {
        ConvertTo-PSCxMarkdownCell -Text "a|b`r`nc" | Should-Be 'a\|b c'
        ConvertTo-PSCxMarkdownCell -Text $null | Should-Be ''
    }

    It 'makes a header, a separator and a row per entry' {
        $t = Get-PSCxMarkdownTable -Header 'A', 'B' -Row @(, @('x|y', 2))
        $t | Should-BeCollection @('| A | B |', '| --- | --- |', '| x\|y | 2 |')
        $empty = Get-PSCxMarkdownTable -Header 'A' -Row @()
        $empty | Should-BeCollection @('| A |', '| --- |')
    }
}

Describe 'the hotspots' {
    It 'are the top N by cognitive, then cyclomatic, then file and unit' {
        $units = @(
            (Unit -Name 'Low' -Cog 1 -Cyc 9), (Unit -Name 'TieB' -Cog 5 -Cyc 2), (Unit -Name 'High' -Cog 9 -Cyc 1),
            (Unit -Name 'TieA' -Cog 5 -Cyc 2), (Unit -Name 'TieCyc' -Cog 5 -Cyc 3), (Unit -File 'src/0.ps1' -Name 'TieB' -Cog 5 -Cyc 2)
        )
        @((Get-PSCxHotspot -Unit $units -Top 5).Unit) | Should-BeCollection @('High', 'TieCyc', 'TieB', 'TieA', 'TieB')
        (Get-PSCxHotspot -Unit $units -Top 5)[2].File | Should-Be 'src/0.ps1'
        @(Get-PSCxHotspot -Unit $units -Top 1).Count | Should-Be 1
        @(Get-PSCxHotspot -Unit @() -Top 3).Count | Should-Be 0
    }
}

Describe 'the per-file totals' {
    It 'count, sum and take the maxima per file, the biggest sum first' {
        $t = Get-PSCxFileTotal -Unit @((Unit 'a.ps1' -Cog 2 -Cyc 3), (Unit 'a.ps1' -Cog 4 -Cyc 1), (Unit 'b.ps1' -Cog 7 -Cyc 2), (Unit 'c.ps1' -Cog 6 -Cyc 1))
        @($t.File) | Should-BeCollection @('b.ps1', 'a.ps1', 'c.ps1')
        $t[1].Units | Should-Be 2
        $t[1].Cognitive | Should-Be 6
        $t[1].MaxCognitive | Should-Be 4
        $t[1].MaxCyclomatic | Should-Be 3
        @(Get-PSCxFileTotal -Unit @()).Count | Should-Be 0
    }

    It 'breaks a tie by file name' {
        @((Get-PSCxFileTotal -Unit @((Unit 'b.ps1' -Cog 2), (Unit 'a.ps1' -Cog 2))).File) | Should-BeCollection @('a.ps1', 'b.ps1')
    }
}

Describe 'comparing with a previous report' {
    It 'refuses a document that is not a report, and one from another metric version' {
        Get-PSCxCompareFault -Document $null -MetricVersion 3 | Should-BeLikeString '*not a PSComplexity JSON report*'
        Get-PSCxCompareFault -Document ([pscustomobject]@{ generatedFrom = 'Other'; units = @() }) -MetricVersion 3 | Should-BeLikeString '*not a PSComplexity*'
        Get-PSCxCompareFault -Document ([pscustomobject]@{ generatedFrom = 'PSComplexity'; metricVersion = 3 }) -MetricVersion 3 | Should-BeLikeString '*not a PSComplexity*'
        Get-PSCxCompareFault -Document ([pscustomobject]@{ generatedFrom = 'PSComplexity'; metricVersion = 2; units = @() }) -MetricVersion 3 |
            Should-Be 'it was measured with metric version 2 and this run with 3, so its numbers are not comparable'
        Get-PSCxCompareFault -Document ([pscustomobject]@{ generatedFrom = 'PSComplexity'; metricVersion = 3; units = @() }) -MetricVersion 3 | Should-BeNull
    }

    It 'sorts units into new, worse and better, by file and unit, ignoring unchanged ones' {
        $base = @((Unit -Name 'Same' -Cyc 2 -Cog 2), (Unit -Name 'UpCyc' -Cyc 2 -Cog 2), (Unit -Name 'UpCog' -Cyc 2 -Cog 2),
            (Unit -Name 'Down' -Cyc 2 -Cog 2), (Unit -Name 'Mixed' -Cyc 2 -Cog 2), (Unit -Name 'DownCog' -Cyc 2 -Cog 2), (Unit -Name 'Gone'))
        $now = @((Unit -Name 'SAME' -Cyc 2 -Cog 2), (Unit -Name 'UpCyc' -Cyc 3 -Cog 2), (Unit -Name 'UpCog' -Cyc 2 -Cog 3),
            (Unit -Name 'Down' -Cyc 1 -Cog 2), (Unit -Name 'Mixed' -Cyc 1 -Cog 3), (Unit -Name 'DownCog' -Cyc 2 -Cog 1), (Unit -Name 'Fresh'),
            (Unit -File 'src/B.ps1' -Name 'Same'))
        $c = Get-PSCxComparison -Unit $now -BaseUnit $base -PathComparison $script:PathCmp
        @($c.New.Unit) | Should-BeCollection @('Fresh', 'Same')
        $c.New[1].File | Should-Be 'src/B.ps1'
        @($c.Worse.Unit.Unit) | Should-BeCollection @('UpCyc', 'UpCog', 'Mixed')
        @($c.Better.Unit.Unit) | Should-BeCollection @('Down', 'DownCog')
        $c.Worse[0].Before.Cyclomatic | Should-Be 2
    }
}

Describe 'the headline' {
    It 'says what was measured, for a measurement' {
        Get-PSCxMarkdownHeadline -Scan (Scan @((Unit 'a.ps1'), (Unit 'a.ps1'), (Unit 'b.ps1'))) -Gate $null |
            Should-Be '**Measured 3 unit(s) in 2 file(s)**, metric version 3.'
    }

    It 'gives the verdict and its terms, for a gate' {
        Get-PSCxMarkdownHeadline -Scan (Scan @(Unit)) -Gate (Gate) |
            Should-Be '**Gate passed**. Measured 1 unit(s) in 1 file(s) against cyclomatic 15 and cognitive 14.'
        Get-PSCxMarkdownHeadline -Scan (Scan @(Unit)) -Gate (Gate -Passed $false -Violations @((Unit), (Unit)) -Overrides @(1)) |
            Should-Be '**Gate failed** -- 2 unit(s) over a ceiling. Measured 1 unit(s) in 1 file(s) against cyclomatic 15 and cognitive 14, with 1 per-path override(s).'
    }
}

Describe 'what the summary says it did not cover' {
    It 'is nothing for a whole-tree measurement' {
        (Get-PSCxMarkdownScopeLine -Scan (Scan) -Gate $null).Count | Should-Be 0
    }

    It 'names a diff scope, exclusions, skips, the config, acceptances and baselined units' {
        $scan = Scan -ChangedFile @('a.ps1', 'b.ps1') -Excluded @('g.ps1') -Skipped @([pscustomobject]@{ File = 'x'; Reason = 'y' })
        # One of each, so "more than none" cannot pass as "more than one".
        $notes = Get-PSCxMarkdownScopeLine -Scan $scan -Gate (Gate -Config '.pscomplexity.json' -Accepted @(1) -Baselined @(1))
        $notes | Should-BeCollection @(
            'Only the 2 changed file(s) were measured, not the whole tree.'
            '1 file(s) excluded by the config.'
            '1 file(s) could not be measured.'
            'Policy from `.pscomplexity.json`.'
            '1 unit(s) accepted with a written reason.'
            '1 unit(s) held to a baseline.'
        )
    }

    It 'names the changed lines of a diff scope instead (#168)' {
        $scan = Scan -ChangedFile @('a.ps1', 'b.ps1') -ChangedLines ([ordered]@{ 'a.ps1' = @(); 'b.ps1' = @() })
        Get-PSCxMarkdownScopeLine -Scan $scan -Gate $null | Should-BeCollection @('Only the units owning lines changed in 2 file(s) were gated, not the whole tree.')
    }
}

Describe 'the breaches' {
    It 'puts a single breach on one row' {
        $lines = Get-PSCxMarkdownBreach -Gate (Gate -Violations @(Unit 'a.ps1' -Name 'A' -Cyc 20 -Line 4))
        $lines[-1] | Should-Be '| A | a.ps1:4 | 20 / 15 | 0 / 14 |'
        $lines.Count | Should-Be 6
    }

    It 'lists every one with the ceiling its file faced' {
        $v = @((Unit 'a.ps1' -Name 'A' -Cyc 20 -Cog 3 -Line 4), (Unit 'b.ps1' -Name 'B' -Cyc 2 -Cog 30 -Line 9))
        $lines = Get-PSCxMarkdownBreach -Gate (Gate -Violations $v -FileCeiling @{ 'b.ps1' = [pscustomobject]@{ Cyclomatic = 5; Cognitive = 25 } })
        $lines | Should-BeCollection @(
            '', '### Over a ceiling', ''
            '| Unit | Where | Cyclomatic / max | Cognitive / max |', '| --- | --- | --- | --- |'
            '| A | a.ps1:4 | 20 / 15 | 3 / 14 |'
            '| B | b.ps1:9 | 2 / 5 | 30 / 25 |'
        )
    }
}

Describe 'the comparison section' {
    It 'counts all three, and tables only the non-empty ones' {
        $c = [pscustomobject]@{
            New    = @(Unit -Name 'N' -Cyc 3 -Cog 4 -Line 2)
            Worse  = @([pscustomobject]@{ Unit = (Unit -Name 'W' -Cyc 5 -Cog 6 -Line 7); Before = (Unit -Cyc 1 -Cog 2) })
            Better = @()
        }
        $lines = Get-PSCxMarkdownComparisonPart -Comparison $c -BaseName 'main.json'
        $lines | Should-BeCollection @(
            '', '### Compared with `main.json`', ''
            '1 new, 1 worse, 0 better.'
            '', '**New**', ''
            '| Unit | Where | Cyclomatic | Cognitive |', '| --- | --- | --- | --- |', '| N | src/A.ps1:2 | 3 | 4 |'
            '', '**Worse**', ''
            '| Unit | Where | Cyclomatic | Cognitive |', '| --- | --- | --- | --- |', '| W | src/A.ps1:7 | 1 -> 5 | 2 -> 6 |'
        )
    }

    It 'says so when nothing changed' {
        $c = [pscustomobject]@{ New = @(); Worse = @(); Better = @([pscustomobject]@{ Unit = (Unit -Name 'B' -Cyc 1 -Line 3); Before = (Unit -Cyc 2) }) }
        $lines = Get-PSCxMarkdownComparisonPart -Comparison $c -BaseName 'b'
        $lines[3] | Should-Be '0 new, 0 worse, 1 better.'
        $lines | Should-ContainCollection @('**Better**', '| B | src/A.ps1:3 | 2 -> 1 | 0 -> 0 |')
        # One at a time: a collection assertion over both passes when only one is missing.
        ($lines -contains '**New**') | Should-BeFalse
        ($lines -contains '**Worse**') | Should-BeFalse
    }
}

Describe 'the whole summary' {
    It 'is the headline, the hotspots and the per-file totals, for a measurement' {
        $md = Get-PSCxMarkdownDocument -Scan (Scan @((Unit 'a.ps1' -Name 'A' -Cog 2 -Cyc 3))) -Top 10 -Gate $null -Comparison $null -BaseName ''
        $md | Should-Be ((@(
                    '## PSComplexity', '', '**Measured 1 unit(s) in 1 file(s)**, metric version 3.'
                    '', '### Most complex units (top 10)', ''
                    '| Unit | Where | Cognitive | Cyclomatic |', '| --- | --- | --- | --- |', '| A | a.ps1:1 | 2 | 3 |'
                    '', '### Per file', ''
                    '| File | Units | Cognitive total | Max cognitive | Max cyclomatic |', '| --- | --- | --- | --- | --- |', '| a.ps1 | 1 | 2 | 2 | 3 |'
                ) -join "`n") + "`n")
    }

    It 'adds the scope notes, the breaches and the comparison when there are any' {
        $v = Unit 'a.ps1' -Name 'Big' -Cyc 20
        $c = [pscustomobject]@{ New = @(); Worse = @(); Better = @() }
        $md = Get-PSCxMarkdownDocument -Scan (Scan @($v) -Excluded @('g.ps1')) -Top 3 -Gate (Gate -Passed $false -Violations @($v)) -Comparison $c -BaseName 'b.json'
        $md | Should-BeLikeString "*`n`n1 file(s) excluded by the config.`n*"
        # ? for the backticks: in a -like pattern a backtick is the escape character.
        $md | Should-BeLikeString '*### Over a ceiling*### Most complex units (top 3)*### Per file*### Compared with ?b.json?*'
    }

    It 'has no breach section for a passing gate' {
        (Get-PSCxMarkdownDocument -Scan (Scan @(Unit)) -Top 3 -Gate (Gate) -Comparison $null -BaseName '') | Should-NotBeLikeString '*Over a ceiling*'
    }
}

Describe 'the previous report a run compares with' {
    BeforeAll {
        $script:base = Join-Path $script:work 'base.json'
        Set-Content -LiteralPath $script:base -Value '{"generatedFrom":"PSComplexity","metricVersion":3,"units":[]}' -Encoding utf8
        $script:old = Join-Path $script:work 'old.json'
        Set-Content -LiteralPath $script:old -Value '{"generatedFrom":"PSComplexity","metricVersion":1,"units":[]}' -Encoding utf8
    }

    It 'is nothing without -CompareTo' {
        Read-PSCxCompareBase -Bound @{ MarkdownPath = 'x.md' } -MetricVersion 3 | Should-BeNull
        Read-PSCxCompareBase -Bound @{} -MetricVersion 3 | Should-BeNull
    }

    It 'is the report -CompareTo names' {
        (Read-PSCxCompareBase -Bound @{ MarkdownPath = 'x.md'; CompareTo = $script:base } -MetricVersion 3).metricVersion | Should-Be 3
    }

    It 'refuses one from another metric version, naming the file' {
        { Read-PSCxCompareBase -Bound @{ MarkdownPath = 'x.md'; CompareTo = $script:old } -MetricVersion 3 } |
            Should-Throw -ExceptionMessage "Cannot compare with $($script:old) : it was measured with metric version 1*."
    }

    It 'refuses -MarkdownTop or -CompareTo without -MarkdownPath' -ForEach @(@{ Key = 'MarkdownTop'; Value = 3 }, @{ Key = 'CompareTo'; Value = 'x' }) {
        { Read-PSCxCompareBase -Bound @{ $Key = $Value } -MetricVersion 3 } | Should-Throw -ExceptionMessage '-MarkdownTop and -CompareTo only apply with -MarkdownPath*'
        { Read-PSCxCompareBase -Bound @{ $Key = $Value; MarkdownPath = '' } -MetricVersion 3 } | Should-Throw -ExceptionMessage '-MarkdownTop and -CompareTo only*'
    }
}

Describe 'writing the summary' {
    It 'writes the rendered text, comparing when given a base' {
        $p = Join-Path $script:work "w-$([System.Guid]::NewGuid().ToString('N'))/s.md"
        $base = [pscustomobject]@{ units = @(Unit -Name 'Get-A' -Cyc 1 -Cog 0) }
        Write-PSCxMarkdown -Path $p -Scan (Scan @(Unit -Name 'Get-A' -Cyc 2)) -Top 5 -Gate $null -Base $base -BaseName 'b.json'
        $text = [System.IO.File]::ReadAllText($p)
        $text | Should-BeLikeString '## PSComplexity*0 new, 1 worse, 0 better.*'
        $text.EndsWith("`n") | Should-BeTrue
    }

    It 'has no comparison without a base' {
        $p = Join-Path $script:work "w-$([System.Guid]::NewGuid().ToString('N')).md"
        Write-PSCxMarkdown -Path $p -Scan (Scan @(Unit)) -Top 5 -Gate $null -Base $null -BaseName ''
        [System.IO.File]::ReadAllText($p) | Should-NotBeLikeString '*Compared with*'
    }
}
