# Cyclomatic complexity: 1 + decision points. Pinned against hand-counted fixtures.

$script:CyclomaticCases = @(
    @{ name = 'flat function = 1'; expected = 1; code = 'function T { param($x) $x + 1 }' }
    @{ name = 'single if = 2'; expected = 2; code = 'function T { param($a) if ($a) { 1 } }' }
    @{ name = 'if/elseif/else = 3 (else is not a clause)'; expected = 3; code = 'function T { param($a) if ($a -eq 1) { 1 } elseif ($a -eq 2) { 2 } else { 3 } }' }
    @{ name = 'while loop = 2'; expected = 2; code = 'function T { param($n) while ($n -gt 0) { $n-- } }' }
    @{ name = 'if with two -and = 4'; expected = 4; code = 'function T { param($a,$b,$c) if ($a -and $b -and $c) { 1 } }' }
    @{ name = 'foreach + if = 3'; expected = 3; code = 'function T { param($xs) foreach ($x in $xs) { if ($x) { 1 } } }' }
    # A ternary is one decision, like the if it stands in for. No case here used
    # one, so its increment could have been any number: a ternary scoring 2 would
    # inflate every unit that uses one, and PowerShell 7 code uses them freely.
    @{ name = 'ternary = 2'; expected = 2; code = 'function T { param($x) $x ? 1 : 2 }' }
    @{ name = 'ternary inside an if = 3'; expected = 3; code = 'function T { param($a,$x) if ($a) { $x ? 1 : 2 } }' }
    # PowerShell-specific flow. Every one of these scored as straight-line code before, so a
    # function branching only through them reported 1 -- the metric's own blind spot.
    @{ name = 'ForEach-Object is a loop'; expected = 3; code = 'function T { param($xs) $xs | ForEach-Object { if ($_) { 1 } } }' }
    @{ name = 'the foreach KEYWORD scores identically'; expected = 3; code = 'function T { param($xs) foreach ($x in $xs) { if ($x) { 1 } } }' }
    @{ name = 'Where-Object is a conditional'; expected = 2; code = 'function T { param($xs) $xs | Where-Object { $_ -gt 0 } }' }
    @{ name = 'the % alias counts too'; expected = 2; code = 'function T { param($xs) $xs | % { $_ } }' }
    @{ name = 'each && link is a decision'; expected = 3; code = 'function T { a && b && c }' }
    @{ name = 'null-coalescing = 2'; expected = 2; code = 'function T { param($a,$b) $x = $a ?? $b }' }
    @{ name = 'null-coalescing ASSIGNMENT = 2'; expected = 2; code = 'function T { param($a) $a ??= 1 }' }
    # Paired with the cases above: a command whose name a static walk cannot read must not
    # be treated as flow, and must not make the predicate throw either.
    @{ name = 'a command with no readable name is not flow'; expected = 1; code = 'function T { param($cmd) & $cmd arg }' }
    # Every remaining entry in the decision-point lists, pinned. Before these, five of the
    # seven type names in Cyclomatic.ps1 could be DELETED with the whole suite green at 100%
    # coverage -- and so could the entire switch block, which made a 12-case switch score 1
    # instead of 13. The mutation gate cannot see this: its operators are arithmetic and
    # boolean, and none deletes a statement or touches a type name.
    @{ name = 'switch scores one per clause'; expected = 13; code = 'function T { param($a) switch ($a) { 1 { "1" } 2 { "2" } 3 { "3" } 4 { "4" } 5 { "5" } 6 { "6" } 7 { "7" } 8 { "8" } 9 { "9" } 10 { "10" } 11 { "11" } 12 { "12" } } }' }
    # The pair that pins `default` NOT being a clause: same clause count, same score. Either
    # fixture alone passes against code that counts the default arm.
    @{ name = 'switch with a default'; expected = 3; code = 'function T { param($a) switch ($a) { 1 { "a" } 2 { "b" } default { "c" } } }' }
    @{ name = 'switch without a default scores the same'; expected = 3; code = 'function T { param($a) switch ($a) { 1 { "a" } 2 { "b" } } }' }
    @{ name = 'for loop = 2'; expected = 2; code = 'function T { for ($i = 0; $i -lt 3; $i++) { $i } }' }
    @{ name = 'do-while = 2'; expected = 2; code = 'function T { param($n) do { $n-- } while ($n -gt 0) }' }
    @{ name = 'do-until = 2'; expected = 2; code = 'function T { param($n) do { $n-- } until ($n -le 0) }' }
    @{ name = 'catch = 2'; expected = 2; code = 'function T { try { 1 } catch { 2 } }' }
    @{ name = 'trap = 2'; expected = 2; code = 'function T { trap { continue } 1 }' }
)

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }
    function script:Get-CyclomaticOf {
        param([string]$Code)
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "cxcyc-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $file $Code -Encoding utf8
        try { (Measure-PSComplexity -Path $file | Where-Object Unit -ne '<script-body>' | Select-Object -First 1).Cyclomatic }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Cyclomatic complexity - reference scores' {
    It 'cyclomatic of <name>' -ForEach $script:CyclomaticCases {
        Get-CyclomaticOf -Code $code | Should-Be $expected
    }
}

Describe 'every cyclomatic increment says which construct produced it' {
    # Same change as the cognitive side, and for the same reason: the amount was summed at
    # emission, so what caused it and where were gone before anything could report them.

    BeforeAll {
        $script:CycAttrFile = Join-Path ([System.IO.Path]::GetTempPath()) "cxcycattr-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $script:CycAttrFile @'
function T {
    param($a, $xs)
    foreach ($x in $xs) {
        if ($a) { 1 }
    }
}
'@ -Encoding utf8
        $script:CycAttrAst = [System.Management.Automation.Language.Parser]::ParseFile($script:CycAttrFile, [ref]$null, [ref]$null)
    }

    AfterAll { Remove-Item $script:CycAttrFile -Force -ErrorAction SilentlyContinue }

    It 'names the construct and the line on every row' {
        $rows = @(Get-PSCxCycClauseRow -Ast $script:CycAttrAst) + @(Get-PSCxCycBlockRow -Ast $script:CycAttrAst)
        @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Construct) }).Count | Should-Be 0
        @($rows | Where-Object { $_.Line -le 0 }).Count | Should-Be 0
    }

    It 'leaves the map a projection of the rows: base 1 plus their sum' {
        # Asserted as the relationship rather than as a number, because the number is what a
        # reference case already pins -- what THIS test protects is that widening the row did
        # not change how the map is derived from it. Summation happens once, in the fold.
        #
        # The base 1 lives in the MAP, not in Measure-PSComplexity: rows sum to 2 here and the
        # map reads 3. I had that backwards in the first version of this test, and the failure
        # is what corrected it.
        $rows = @(Get-PSCxCycClauseRow -Ast $script:CycAttrAst) + @(Get-PSCxCycBlockRow -Ast $script:CycAttrAst) +
                @(Get-PSCxCycFlowCommandRow -Ast $script:CycAttrAst) + @(Get-PSCxCycOperatorRow -Ast $script:CycAttrAst)
        $map = Get-PSCxCyclomaticMap -Ast $script:CycAttrAst -UnitTable (Get-PSCxUnitTable -Ast $script:CycAttrAst)
        $unit = @($map.Keys | Where-Object { $_ -notlike '<script-body>*' })[0]
        $unitRows = @($rows | Where-Object { $_.Key -eq $unit })
        $map[$unit] | Should-Be (1 + (($unitRows | Measure-Object Amount -Sum).Sum))
    }
}
