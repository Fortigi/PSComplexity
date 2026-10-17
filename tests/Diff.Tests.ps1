# Changed lines from a unified diff (#168): reading the headers, and which units own the lines.
#
# The COVERING SUITE for src/Diff.ps1, and cheap: every diff is a string and every span table is
# built by hand or from source parsed in memory. Applying it -- the scan, the gate, the report -- is
# tests/Scan.Tests.ps1 and tests/Measure.Tests.ps1.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    function script:Diff {
        param([string[]]$Line)
        return Get-PSCxUnifiedDiff -Text $Line
    }
    function script:Hunks {
        # One file's hunks as 'start,count' strings, in order.
        param($Result, [string]$File)
        return @($Result.Files[$File] | ForEach-Object { "$($_.Start),$($_.Count)" })
    }
    function script:Span {
        # A unit spanning StartLine..EndLine, with offsets that nest the way the lines do.
        param([int]$StartLine, [int]$EndLine)
        return [pscustomobject]@{ Start = $StartLine * 100; End = $EndLine * 100 + 99; StartLine = $StartLine; EndLine = $EndLine }
    }
    function script:Changed {
        param([hashtable]$Span, [object[]]$Hunk)
        return (@(Get-PSCxChangedUnit -Span $Span -Hunk $Hunk) | Sort-Object) -join ','
    }
    function script:Hunk {
        param([int]$Start, [int]$Count)
        return [pscustomobject]@{ Start = $Start; Count = $Count }
    }
}

Describe 'Get-PSCxDiffPath' {
    It 'reads <Header> as <Expected>' -ForEach @(
        @{ Header = '+++ b/src/a.ps1'; Expected = 'b/src/a.ps1' }
        @{ Header = "+++ src/a.ps1`t2026-10-17 10:00:00"; Expected = 'src/a.ps1' }
        @{ Header = '+++ "b/my \"x\" \\y.ps1"'; Expected = 'b/my "x" \y.ps1' }
        @{ Header = '--- "a"'; Expected = 'a' }
        @{ Header = '--- "'; Expected = '"' }
        @{ Header = '--- ""'; Expected = '' }
    ) {
        Get-PSCxDiffPath -Header $Header | Should-Be $Expected
    }

    It 'reads /dev/null as no file' {
        Get-PSCxDiffPath -Header '+++ /dev/null' | Should-BeNull
        Get-PSCxDiffPath -Header "--- /dev/null`t1970-01-01" | Should-BeNull
    }
}

Describe 'Get-PSCxUnifiedDiff' {

    It 'reads each file and its new-side hunks from git diff --unified=0' {
        $r = Diff @(
            'diff --git a/src/a.ps1 b/src/a.ps1'
            'index 1111111..2222222 100644'
            '--- a/src/a.ps1'
            '+++ b/src/a.ps1'
            '@@ -3 +3 @@ function A {'
            '-    1'
            '+    2'
            '@@ -10,0 +11,2 @@'
            '+x'
            '+y'
            'diff --git a/src/b.ps1 b/src/b.ps1'
            '--- a/src/b.ps1'
            '+++ b/src/b.ps1'
            '@@ -5,2 +4,0 @@'
            '-gone'
            '-gone too'
        )
        $r.Fault | Should-BeNull
        @($r.Files.Keys) | Should-BeCollection @('src/a.ps1', 'src/b.ps1')
        Hunks $r 'src/a.ps1' | Should-BeCollection @('3,1', '11,2')
        Hunks $r 'src/b.ps1' | Should-BeCollection @('4,0')
    }

    It 'takes the prefixes off a new file, and keeps them without the a/ that shows they are prefixes' {
        $r = Diff @('--- /dev/null', '+++ b/new.ps1', '@@ -0,0 +1 @@', '+1', '--- b/x.ps1', '+++ b/x.ps1', '@@ -1 +1 @@', '-1', '+2', '--- src/y.ps1', '+++ src/y.ps1', '@@ -1 +1 @@', '-1', '+2')
        @($r.Files.Keys) | Should-BeCollection @('new.ps1', 'b/x.ps1', 'src/y.ps1')
    }

    It 'leaves a deleted file out, and its hunk with it' {
        $r = Diff @('--- a/old.ps1', '+++ /dev/null', '@@ -1,2 +0,0 @@', '-1', '-2', '--- a/k.ps1', '+++ b/k.ps1', '@@ -1 +1 @@', '-1', '+2')
        @($r.Files.Keys) | Should-BeCollection @('k.ps1')
        Hunks $r 'k.ps1' | Should-BeCollection @('1,1')
    }

    It 'skips the body by the counts, so a changed line that looks like a header is not one' {
        $r = Diff @('--- a/k.ps1', '+++ b/k.ps1', '@@ -1,2 +1,2 @@', '--- x', '-- y', '+++ z', '++ w', '@@ -9 +9 @@', '-a', '+b')
        @($r.Files.Keys) | Should-BeCollection @('k.ps1')
        Hunks $r 'k.ps1' | Should-BeCollection @('1,2', '9,1')
    }

    It 'skips a body line that looks like a header: <Why>' -ForEach @(
        # Each would be read as `--- y` or `+++ q` if the count ran out early, and either changes
        # what the next file header means.
        @{ Why = 'a removed line under an omitted old count'; Body = @('@@ -1 +0,0 @@', '--- y') }
        @{ Why = 'a removed line after an added one'; Body = @('@@ -1 +1 @@', '+a', '--- y') }
        @{ Why = 'a removed line after an added empty one'; Body = @('@@ -1,2 +1,1 @@', '+', '-a', '--- y') }
        @{ Why = 'an added line'; Body = @('@@ -0,0 +1 @@', '+++ q') }
    ) {
        $r = Diff (@('--- a/k.ps1', '+++ b/k.ps1') + $Body + @('+++ b/z.ps1', '@@ -1 +1 @@', '-1', '+2'))
        $r.Fault | Should-BeNull
        @($r.Files.Keys) | Should-BeCollection @('k.ps1', 'z.ps1')
    }

    It 'counts a context line on both sides, and a no-newline marker on neither' {
        $r = Diff @('--- a/k.ps1', '+++ b/k.ps1', '@@ -1,3 +1,3 @@', ' keep', '-old', '\ No newline at end of file', '+new', '\ No newline at end of file', '', '@@ -20 +20 @@', '-a', '+b')
        Hunks $r 'k.ps1' | Should-BeCollection @('1,3', '20,1')
    }

    It 'lists a file changed without a hunk -- a rename -- with none' {
        $r = Diff @('diff --git a/a.ps1 b/c.ps1', 'similarity index 100%', 'rename from a.ps1', 'rename to c.ps1')
        $r.Fault | Should-BeNull
        $r.Files.Count | Should-Be 0
        $r = Diff @('--- a/a.ps1', '+++ b/c.ps1')
        @($r.Files.Keys) | Should-BeCollection @('c.ps1')
        @($r.Files['c.ps1']).Count | Should-Be 0
    }

    It 'pools the hunks of a file named twice' {
        $r = Diff @('--- a/k.ps1', '+++ b/k.ps1', '@@ -1 +1 @@', '-1', '+2', '--- a/k.ps1', '+++ b/k.ps1', '@@ -5 +5 @@', '-1', '+2')
        Hunks $r 'k.ps1' | Should-BeCollection @('1,1', '5,1')
    }

    It 'reads one string holding the whole diff, with either line ending' {
        $r = Diff @("--- a/k.ps1`r`n+++ b/k.ps1`r`n@@ -1 +1,4 @@`r`n-1`r`n+2`n+3`n+4`n+5`n")
        Hunks $r 'k.ps1' | Should-BeCollection @('1,4')
    }

    It 'refuses <Why>' -ForEach @(
        @{ Why = 'nothing'; Text = $null; Like = '-ChangedDiff was given an empty diff*skip the gate*' }
        @{ Why = 'an empty list'; Text = @(); Like = '-ChangedDiff was given an empty diff*' }
        @{ Why = 'blank lines'; Text = @('', '  ', "`t"); Like = '-ChangedDiff was given an empty diff*' }
        @{ Why = 'a list of file names'; Text = @('src/a.ps1', 'src/b.ps1'); Like = '*no file header*not a unified diff*-ChangedFile takes.' }
        @{ Why = 'a hunk header it cannot read'; Text = @('--- a/k.ps1', '+++ b/k.ps1', '@@ nonsense @@'); Like = "-ChangedDiff line 3 is not a hunk header ('@@ nonsense @@')*" }
        @{ Why = 'a hunk before any file header'; Text = @('diff --git a/k.ps1 b/k.ps1', '@@ -1 +1 @@'); Like = '-ChangedDiff line 2 starts a hunk before any*cut or malformed.' }
        @{ Why = 'a hunk with no header at all'; Text = @('@@ -1 +1 @@', '-a', '+b'); Like = '-ChangedDiff line 1 starts a hunk before any*' }
    ) {
        $r = Get-PSCxUnifiedDiff -Text $Text
        $r.Fault | Should-BeLikeString $Like
        $r.Files.Count | Should-Be 0
    }

    It 'refuses a hunk after a file header was read but a new file began without one' {
        $r = Diff @('--- a/k.ps1', '+++ b/k.ps1', '@@ -1 +1 @@', '-1', '+2', 'diff --git a/m.ps1 b/m.ps1', '@@ -1 +1 @@')
        $r.Fault | Should-BeLikeString '-ChangedDiff line 7 starts a hunk*'
    }
}

Describe 'Get-PSCxLineOwner' {

    It 'gives each line its innermost unit, and no unit outside them all' {
        $owner = Get-PSCxLineOwner -Span @{ Outer = (Span 2 8); Inner = (Span 4 5) }
        $owner.Count | Should-Be 9
        $owner[1] | Should-BeNull
        @($owner[3]) | Should-BeCollection @('Outer')
        @($owner[4]) | Should-BeCollection @('Inner')
        @($owner[5]) | Should-BeCollection @('Inner')
        @($owner[6]) | Should-BeCollection @('Outer')
        @($owner[8]) | Should-BeCollection @('Outer')
    }

    It 'gives a line two siblings share to both, and takes their parent off it' {
        # `} function B {` -- A ends and B starts on line 5, both inside P.
        $owner = Get-PSCxLineOwner -Span @{ P = (Span 1 9); A = [pscustomobject]@{ Start = 200; End = 510; StartLine = 2; EndLine = 5 }; B = [pscustomobject]@{ Start = 520; End = 899; StartLine = 5; EndLine = 8 } }
        (@($owner[5]) | Sort-Object) -join ',' | Should-Be 'A,B'
        @($owner[9]) | Should-BeCollection @('P')
    }

    It 'keeps both siblings whose text touches, painted in either order' {
        # A ends exactly where B starts. Painted longer first, so each order is tried.
        foreach ($longer in 'A', 'B') {
            $a = [pscustomobject]@{ Start = 100; End = 300; StartLine = 1; EndLine = 3 }
            $b = [pscustomobject]@{ Start = 300; End = 500; StartLine = 3; EndLine = 5 }
            if ($longer -eq 'A') { $a.Start = 50 } else { $b.End = 550 }
            $owner = Get-PSCxLineOwner -Span @{ A = $a; B = $b }
            (@($owner[3]) | Sort-Object) -join ',' | Should-Be 'A,B'
        }
    }

    It 'is one empty entry for a file with no units' {
        $owner = Get-PSCxLineOwner -Span @{}
        $owner.Count | Should-Be 1
    }
}

Describe 'Get-PSCxChangedUnit' {
    BeforeAll {
        $script:spans = @{ Outer = (Span 2 8); Inner = (Span 4 5); Next = (Span 10 12) }
    }

    It 'gives a changed line to its innermost unit only: <Why>' -ForEach @(
        @{ Why = 'inside the inner function'; Hunk = @(@{ Start = 4; Count = 1 }); Expected = 'Inner' }
        @{ Why = 'in the outer function, outside the inner one'; Hunk = @(@{ Start = 6; Count = 1 }); Expected = 'Outer' }
        @{ Why = 'a range across both'; Hunk = @(@{ Start = 5; Count = 2 }); Expected = 'Inner,Outer' }
        @{ Why = 'outside every unit'; Hunk = @(@{ Start = 9; Count = 1 }); Expected = '<script-body>' }
        @{ Why = 'past the last unit'; Hunk = @(@{ Start = 13; Count = 2 }); Expected = '<script-body>' }
        @{ Why = 'the first and last lines of a range'; Hunk = @(@{ Start = 1; Count = 2 }); Expected = '<script-body>,Outer' }
        @{ Why = 'the last line of a range only'; Hunk = @(@{ Start = 8; Count = 3 }); Expected = '<script-body>,Next,Outer' }
        @{ Why = 'two hunks'; Hunk = @(@{ Start = 4; Count = 1 }, @{ Start = 11; Count = 1 }); Expected = 'Inner,Next' }
    ) {
        Changed $script:spans @($Hunk | ForEach-Object { Hunk $_.Start $_.Count }) | Should-Be $Expected
    }

    It 'gives a deletion to the innermost unit holding both lines around it: <Why>' -ForEach @(
        @{ Why = 'inside the inner function'; After = 4; Expected = 'Inner' }
        @{ Why = 'inside the outer function'; After = 6; Expected = 'Outer' }
        @{ Why = 'where the inner function ends'; After = 5; Expected = 'Outer' }
        @{ Why = 'between two functions'; After = 8; Expected = '<script-body>' }
        @{ Why = 'at the top of the file'; After = 0; Expected = '<script-body>' }
        @{ Why = 'on the first line of a function'; After = 2; Expected = 'Outer' }
        @{ Why = 'on the line before a function'; After = 1; Expected = '<script-body>' }
        @{ Why = 'on the line before its last'; After = 11; Expected = 'Next' }
        @{ Why = 'on its last line'; After = 12; Expected = '<script-body>' }
    ) {
        Changed $script:spans @(Hunk $After 0) | Should-Be $Expected
    }

    It 'gives nothing for a file changed without a hunk' {
        Changed $script:spans @() | Should-Be ''
    }

    It 'finds the units of real source by their keys' {
        $code = "function Outer {`n  function Inner {`n    1`n  }`n  2`n}`n`$x = 1"
        $spans = Get-PSCxUnitSpan -Ast ([System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null))
        $inner = @($spans.Keys | Where-Object { $_ -like '*Inner*' })[0]
        @(Get-PSCxChangedUnit -Span $spans -Hunk @(Hunk 3 1)) | Should-BeCollection @($inner)
        @(Get-PSCxChangedUnit -Span $spans -Hunk @(Hunk 7 1)) | Should-BeCollection @('<script-body>')
    }
}

Describe 'Get-PSCxDeletionOwner' {
    It 'picks the smallest of the units holding both lines, whatever order they are listed in' {
        foreach ($order in @(@('A', 'B', 'C'), @('C', 'B', 'A'))) {
            $spans = [ordered]@{}
            $all = @{ A = (Span 1 20); B = (Span 3 15); C = (Span 5 10) }
            foreach ($k in $order) { $spans[$k] = $all[$k] }
            Get-PSCxDeletionOwner -Span ([hashtable]$spans) -After 6 | Should-Be 'C'
            Get-PSCxDeletionOwner -Span ([hashtable]$spans) -After 12 | Should-Be 'B'
        }
    }

    It 'measures a unit by its length, not by where it sits' {
        # The inner unit starts late and ends late, so start plus end would pick the outer one.
        $spans = @{
            Outer = [pscustomobject]@{ Start = 100; End = 1999; StartLine = 1; EndLine = 20 }
            Inner = [pscustomobject]@{ Start = 1500; End = 1900; StartLine = 15; EndLine = 19 }
        }
        Get-PSCxDeletionOwner -Span $spans -After 16 | Should-Be 'Inner'
    }
}
