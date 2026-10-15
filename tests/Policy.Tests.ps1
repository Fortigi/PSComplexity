# The policy layer: which units are excused from the ceilings, and on what terms.
#
# This is the COVERING SUITE for src/Policy.ps1, and it is deliberately cheap. Everything here is
# a pure function over data, so nothing in this file parses a script, walks an AST, writes a
# temp file or runs a measurement. That matters for one specific reason: every mutant of
# Policy.ps1 re-runs its covering suite, and while that job belonged to Measure.Tests.ps1 -- which
# measures real files -- the 125 mutants of this one file cost 19 minutes on their own, against a
# CI job budget of 40 for everything.
#
# The end-to-end proofs did not move. tests/Measure.Tests.ps1 still drives all of this through
# Test-PSComplexity, because covering a predicate is not the same as covering its application and
# neither gate can tell the difference. This file exists so those proofs do not have to be paid
# for once per mutant.
#
# Boundary cases are here on purpose rather than by habit. A ceiling comparison tested at 4
# against 99 cannot tell -le from -lt, and a two-metric guard tested with both sides agreeing
# cannot tell -and from -or -- both survived as mutants until each got a case where the two
# operators disagree.

BeforeAll {
    # The comparison a real run makes on this platform's usual file system. Tests about case
    # pass both values explicitly instead (#151).
    $script:PathCmp = $IsLinux ? [System.StringComparison]::Ordinal : [System.StringComparison]::OrdinalIgnoreCase
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    function script:Unit {
        param([string]$File = 'src/A.ps1', [string]$Name = 'Invoke-Thing', [int]$Cyc = 20, [int]$Cog = 30)
        return [pscustomobject]@{ File = $File; Unit = $Name; Line = 1; Cyclomatic = $Cyc; Cognitive = $Cog }
    }
    function script:Entry {
        param([string]$File = 'src/A.ps1', [string]$Name = 'Invoke-Thing', [int]$Cyc = 20, [int]$Cog = 30)
        return [pscustomobject]@{ file = $File; unit = $Name; cyclomatic = $Cyc; cognitive = $Cog }
    }
    function script:Doc {
        param([int]$Schema = 1, [int]$Metric = 1, $Units = @())
        return [pscustomobject]@{ schemaVersion = $Schema; metricVersion = $Metric; units = $Units }
    }
}

Describe 'Get-PSCxPolicyKey' {
    It 'keeps file and unit apart even when one contains the other separator' {
        # A key joined on ':' is ambiguous the first time somebody gates a file outside their
        # repo, because on Windows the full path starts 'C:'. These two describe different units
        # and must not collide.
        (Get-PSCxPolicyKey -File 'C:/x/A.ps1' -Unit 'Go') |
            Should-NotBe (Get-PSCxPolicyKey -File 'C:/x' -Unit 'A.ps1:Go')
    }

    It 'gives the same key for the same pair' {
        (Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'Go') |
            Should-Be (Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'Go')
    }
}

Describe 'Get-PSCxBaselineSchemaVersion' {
    It 'reports the version this module writes' {
        # Read through the function rather than the variable, because no other file may reach
        # into this one's module state -- tests/Layering.Tests.ps1 asserts exactly that.
        Get-PSCxBaselineSchemaVersion | Should-Be 1
    }
}

Describe 'Test-PSCxStableIdentity' {
    It 'accepts an ordinary unit name' { Test-PSCxStableIdentity -Unit 'Invoke-Thing' | Should-BeTrue }
    It 'accepts a class method and a nested function' {
        Test-PSCxStableIdentity -Unit 'Widget.Render' | Should-BeTrue
        Test-PSCxStableIdentity -Unit 'Outer/Inner' | Should-BeTrue
    }
    It 'refuses a name carrying an ordinal' {
        # The paired half: without an accepted case above, a predicate that always returned
        # $false would pass this just as well.
        Test-PSCxStableIdentity -Unit 'Invoke-Twice#2' | Should-BeFalse
    }
}

Describe 'Test-PSCxWithinEntry' {
    It 'is true at the recorded score exactly' {
        # The boundary. Tested at 20 against 99 it cannot tell -le from -lt, and that mutant
        # survived until this case existed.
        Test-PSCxWithinEntry -Unit (Unit -Cyc 20 -Cog 30) -Entry (Entry -Cyc 20 -Cog 30) | Should-BeTrue
    }

    It 'is false one over on cyclomatic alone' {
        Test-PSCxWithinEntry -Unit (Unit -Cyc 21 -Cog 30) -Entry (Entry -Cyc 20 -Cog 30) | Should-BeFalse
    }

    It 'is false one over on cognitive alone' {
        # Both single-metric cases, because a check written with -or instead of -and passes
        # whichever one it happens to be tested with.
        Test-PSCxWithinEntry -Unit (Unit -Cyc 20 -Cog 31) -Entry (Entry -Cyc 20 -Cog 30) | Should-BeFalse
    }

    It 'is false when one metric improved and the other regressed' {
        # Trading one against the other is not staying the same. -or would call this within.
        Test-PSCxWithinEntry -Unit (Unit -Cyc 25 -Cog 10) -Entry (Entry -Cyc 20 -Cog 30) | Should-BeFalse
    }
}

Describe 'Test-PSCxWithinBaseline' {
    It 'returns exactly $false, not merely something falsy, for an unrecorded unit' {
        # Should-BeFalse is strict in Pester 6, so this fails against a $null. That matters
        # because the function declares [OutputType([bool])] and a caller may compare against
        # $false rather than test truthiness -- and a mutant returning $null survived every
        # truthiness-based assertion.
        Test-PSCxWithinBaseline -Unit (Unit) -Map @{} | Should-BeFalse
    }

    It 'finds a unit that is recorded' {
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry)
        Test-PSCxWithinBaseline -Unit (Unit) -Map $map | Should-BeTrue
    }

    It 'does not match a like-named unit in another file' {
        # The key is file AND unit. Keyed on the name alone this excuses every unit of that name
        # in the tree, which is how suppression lists usually leak.
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry -File 'src/B.ps1')
        Test-PSCxWithinBaseline -Unit (Unit -File 'src/A.ps1') -Map $map | Should-BeFalse
    }
}

Describe 'Get-PSCxBaselineMap' {
    It 'builds a lookup over the entries' {
        (Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @((Entry), (Entry -Name 'Other'))).Count | Should-Be 2
    }

    It 'is empty for no entries' {
        (Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @()).Count | Should-Be 0
    }

    It 'refuses a file naming one unit twice' {
        # Asserted on the TAIL of the message, past the last concatenation. Break the `+` that
        # builds it and PowerShell raises a conversion error QUOTING its left operand, which
        # contains every earlier phrase -- so an assertion on one of those matches the very
        # failure it exists to detect. Only text from after the break tells them apart.
        { Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @((Entry), (Entry)) } |
            Should-Throw -ExceptionMessage '*twice*cannot be read off the file*'
    }

    It 'refuses one unit named twice under two casings of its NAME, on every platform' {
        { Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @((Entry -Name 'Invoke-Thing'), (Entry -Name 'invoke-thing')) } |
            Should-Throw -ExceptionMessage '*twice*'
    }

    It 'keeps two files differing only in case apart when the run compares exactly (#151)' {
        $entries = @((Entry -File 'src/A.ps1'), (Entry -File 'src/a.ps1'))
        (Get-PSCxBaselineMap -PathComparison Ordinal -Entry $entries).Count | Should-Be 2
    }

    It 'refuses them as one unit named twice when the run ignores case' {
        $entries = @((Entry -File 'src/A.ps1'), (Entry -File 'src/a.ps1'))
        { Get-PSCxBaselineMap -PathComparison OrdinalIgnoreCase -Entry $entries } | Should-Throw -ExceptionMessage '*twice*'
    }
}

Describe 'Get-PSCxUnacceptedUnit' {
    It 'reports a unit over a ceiling that nothing excuses' {
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
    }

    It 'says nothing about a unit at the ceiling exactly' {
        # The boundary: -gt, not -ge. A unit AT the limit is within it.
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit -Cyc 15 -Cog 15) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'reports a unit over on cyclomatic alone, and on cognitive alone' {
        # Two single-metric cases, because the breach test is -or and a version written with
        # -and passes whichever one it is given.
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit -Cyc 16 -Cog 1) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit -Cyc 1 -Cog 16) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
    }

    It 'excuses an accepted unit' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'excuses a unit within its baseline, and only that unit' {
        # Paired: the recorded unit is excused and its neighbour is not, so a filter matching
        # on file alone fails here rather than passing quietly.
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry)
        $units = @((Unit), (Unit -Name 'Other'))
        $left = @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit $units -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -BaselineMap $map)
        $left.Count | Should-Be 1
        $left[0].Unit | Should-Be 'Other'
    }

    It 'still reports a recorded unit that got worse' {
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry -Cyc 20 -Cog 30)
        @(Get-PSCxUnacceptedUnit -PathComparison $script:PathCmp -Unit @(Unit -Cyc 21 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -BaselineMap $map).Count | Should-Be 1
    }
}

Describe 'Get-PSCxAcceptanceFault' {
    It 'says nothing about an acceptance that holds' {
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15).Count | Should-Be 0
    }

    It 'refuses an acceptance with no File or no Unit' {
        (@{ Unit = 'Invoke-Thing'; Reason = 'r' } | Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both File and Unit*'
        (@{ File = 'src/A.ps1'; Reason = 'r' } | Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both File and Unit*'
    }

    It 'refuses an acceptance whose reason is only whitespace' {
        (@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = '   ' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no reason*'
    }

    It 'refuses an acceptance naming a unit nobody measured' {
        (@{ File = 'src/A.ps1'; Unit = 'Ghost'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no such unit was measured*'
    }

    It 'refuses an acceptance for a unit within both ceilings, at the boundary' {
        # At the ceiling exactly, so -le and -lt disagree here.
        (@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit -Cyc 15 -Cog 15) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*within both ceilings*'
    }

    It 'keeps an acceptance for a unit over one ceiling only -- either one' {
        # The -and in that guard: over on one metric and under on the other is still a breach,
        # so the acceptance is still doing work and must not be called stale.
        #
        # BOTH directions, because each half of that guard reads a different score and only one
        # of the two is exercised by either case. Written with only the cyclomatic case, a mutant
        # that broke the cognitive read -- yielding $null, and $null -le 15 is $true -- survived
        # the whole suite.
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit -Cyc 16 -Cog 1) -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit @(Unit -Cyc 1 -Cog 16) -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }
}

Describe 'Get-PSCxBaselineScoreFault' {
    It 'says nothing when the unit is exactly at its recorded score and still over a ceiling' {
        Get-PSCxBaselineScoreFault -Entry (Entry) -Unit (Unit) -MaxCyclomatic 15 -MaxCognitive 15 |
            Should-BeNull
    }

    It 'reports a unit that came back within both ceilings, at the boundary exactly' {
        # Cyclomatic and cognitive both AT the ceiling. Tested at 4 against 99 this cannot tell
        # -le from -lt, and both of those mutants survived until this case existed.
        Get-PSCxBaselineScoreFault -Entry (Entry) -Unit (Unit -Cyc 15 -Cog 15) -MaxCyclomatic 15 -MaxCognitive 15 |
            Should-BeLikeString '*within both ceilings*'
    }

    It 'does NOT report a unit within one ceiling but over the other' {
        # The -and in that guard. With -or, a unit under cyclomatic but over cognitive would be
        # called fixed and its entry deleted -- removing the cap that was holding it.
        #
        # The unit sits at its recorded score exactly, so nothing here is an improvement either.
        # An earlier version of this fixture had the unit BELOW its record, which is a genuine
        # improvement: the function reported it, correctly, and the test was wrong rather than
        # the code.
        Get-PSCxBaselineScoreFault -Entry (Entry -Cyc 15 -Cog 30) -Unit (Unit -Cyc 15 -Cog 30) `
            -MaxCyclomatic 15 -MaxCognitive 15 | Should-BeNull
        Get-PSCxBaselineScoreFault -Entry (Entry -Cyc 20 -Cog 15) -Unit (Unit -Cyc 20 -Cog 15) `
            -MaxCyclomatic 15 -MaxCognitive 15 | Should-BeNull
    }

    It 'reports an improvement on cyclomatic alone' {
        Get-PSCxBaselineScoreFault -Entry (Entry -Cyc 20 -Cog 30) -Unit (Unit -Cyc 19 -Cog 30) `
            -MaxCyclomatic 15 -MaxCognitive 15 | Should-BeLikeString '*improved to cyclomatic 19*'
    }

    It 'reports an improvement on cognitive alone' {
        Get-PSCxBaselineScoreFault -Entry (Entry -Cyc 20 -Cog 30) -Unit (Unit -Cyc 20 -Cog 29) `
            -MaxCyclomatic 15 -MaxCognitive 15 | Should-BeLikeString '*cognitive 29*'
    }

    It 'calls a traded pair a regression, by saying nothing' {
        # Worse on cyclomatic, better on cognitive. Saying "improved" here would send somebody to
        # lower an entry for a unit that just got worse; saying nothing lets it fall through to
        # the ordinary violation path, which reports the regression.
        Get-PSCxBaselineScoreFault -Entry (Entry -Cyc 20 -Cog 30) -Unit (Unit -Cyc 21 -Cog 10) `
            -MaxCyclomatic 15 -MaxCognitive 15 | Should-BeNull
    }
}

Describe 'Get-PSCxBaselineFault' {
    It 'says nothing about an entry that holds' {
        @(Entry | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'refuses an entry with no file or no unit' {
        ([pscustomobject]@{ unit = 'Invoke-Thing'; cyclomatic = 20; cognitive = 30 } |
                Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both file and unit*'
        ([pscustomobject]@{ file = 'src/A.ps1'; cyclomatic = 20; cognitive = 30 } |
                Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both file and unit*'
    }

    It 'refuses an entry keyed by an ordinal name' {
        (Entry -Name 'Invoke-Twice#2' | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit -Name 'Invoke-Twice#2') `
                -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*renumbers when a duplicate*'
    }

    It 'refuses an entry for a unit that is also accepted' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        (Entry | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*both accepted and recorded*'
    }

    It 'does not treat an acceptance for a DIFFERENT unit in the same file as a clash' {
        # Both halves of the identity. Matching on the file alone, any acceptance anywhere in the
        # same file would count as excusing this unit, and its entry would be deleted as redundant.
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Something-Else'; Reason = 'r' })
        @(Entry | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'does not treat an acceptance for the same unit in ANOTHER file as a clash' {
        $acc = @(@{ File = 'src/B.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        @(Entry | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'refuses an entry naming a unit nobody measured' {
        (Entry -Name 'Ghost' | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no such unit was measured*'
    }

    It 'passes the score rules on to the score fault' {
        (Entry -Cyc 20 -Cog 30 | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit -Cyc 19 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15) | Should-BeLikeString '*improved to cyclomatic*'
    }
}

Describe 'Get-PSCxPolicyKey, and case' {
    # -ceq, because -eq ignores case and would pass whether or not the key folded anything.
    It 'folds the UNIT, whose name PowerShell never compares by case' {
        ((Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'Get-Thing') -ceq
            (Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'get-thing')) | Should-BeTrue
    }

    It 'keeps the FILE as written, leaving its case to the path comparer' {
        ((Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'u') -ceq
            (Get-PSCxPolicyKey -File 'src/a.ps1' -Unit 'u')) | Should-BeFalse
    }
}

Describe 'Get-PSCxPolicyLookup' {
    It 'finds a unit by file and unit, the unit ignoring case' {
        $lookup = Get-PSCxPolicyLookup -PathComparison $script:PathCmp -Record @((Unit), (Unit -Name 'Other' -Cyc 3))
        $found = $null
        $lookup.TryGetValue((Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'invoke-thing'), [ref]$found) | Should-BeTrue
        $found.Cyclomatic | Should-Be 20
        $lookup.Count | Should-Be 2
    }

    It 'matches the file by the run path comparison, both ways (#151)' {
        # Where the file system is case-sensitive, src/a.ps1 is a different file from src/A.ps1
        # and must not find its unit; where it is not, they are one file.
        $key = Get-PSCxPolicyKey -File 'SRC/a.ps1' -Unit 'Invoke-Thing'
        (Get-PSCxPolicyLookup -PathComparison Ordinal -Record @(Unit)).ContainsKey($key) | Should-BeFalse
        (Get-PSCxPolicyLookup -PathComparison OrdinalIgnoreCase -Record @(Unit)).ContainsKey($key) | Should-BeTrue
    }

    It 'keys an acceptance, which is a hashtable, the same way' {
        $lookup = Get-PSCxPolicyLookup -PathComparison $script:PathCmp -Record @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        $lookup.ContainsKey((Get-PSCxPolicyKey -File 'src/A.ps1' -Unit 'Invoke-Thing')) | Should-BeTrue
    }

    It 'is an empty lookup over no records, not nothing' {
        (Get-PSCxPolicyLookup -PathComparison $script:PathCmp -Record @()).Count | Should-Be 0
    }
}

Describe 'Policy checks over many entries' {
    # Each check pipes its entries one at a time, and the unit list is built into a lookup ONCE
    # in begin. Searched per entry instead it cost entries x units: a 2,000-entry baseline took
    # a gate from 9s to 31s (#153).

    It 'answers each piped entry against the same lookup' {
        # Two entries through one pipeline: the lookup built in begin must serve both, and each
        # gets its own answer rather than the first one's.
        $faults = @((Entry), (Entry -Name 'Ghost') |
                Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15)
        $faults.Count | Should-Be 1
        $faults[0] | Should-BeLikeString '*Ghost is recorded but no such unit*'
    }

    It 'takes time that does not grow with the number of units per entry' {
        # A RATIO rather than a time limit, so the machine's speed cancels out, and a ratio of the
        # PER-ENTRY cost: ten times the units, the same entries. A per-entry search reads ~18x
        # (planted and measured); the lookup reads 1.0-1.3x. 3 sits between the two.
        #
        # It read 3.0 on a Linux CI runner for correct code, as the plain ratio of two run times,
        # and two things in the fixture were adding to it -- both easy to reintroduce:
        #  - The entries named units 0..1999, so at the small size nine in ten MISSED and returned
        #    early. Every entry now names a unit present at both sizes, so each does the same work.
        #  - The lookup is built once per call, which is linear in units and correct. Each size is
        #    also timed with no entries and that subtracted, leaving only what each entry costs.
        #
        # The FASTEST of three runs of each, interleaved. Noise on a shared runner only ever adds
        # time, so the minimum is the closest reading of what the code costs.
        $entries = foreach ($i in 0..1999) { $j = $i % 220; Entry -File "src/F$($j % 200).ps1" -Name "Invoke-U$j" }
        $accept = foreach ($i in 0..1999) { $j = $i % 220; @{ File = "src/F$($j % 200).ps1"; Unit = "Invoke-U$j"; Reason = 'r' } }
        $small = foreach ($i in 0..219) { Unit -File "src/F$($i % 200).ps1" -Name "Invoke-U$i" }
        # The extra units go IN FRONT of the named ones: appended, a search that stops at its
        # match never reaches them, and a planted per-entry search passed this test.
        $large = @(foreach ($i in 0..1979) { Unit -File "src/F$($i % 200).ps1" -Name "Invoke-X$i" }) + $small
        # A stopwatch rather than Measure-Command: the analyzer cannot see a parameter used
        # inside a nested script block, and reports it unused.
        $time = {
            param($Unit, $Entry, $Accepted)
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $null = $Entry | Get-PSCxBaselineFault -PathComparison $script:PathCmp -Unit $Unit -Accept @() -MaxCyclomatic 15 -MaxCognitive 15
            $null = $Accepted | Get-PSCxAcceptanceFault -PathComparison $script:PathCmp -Unit $Unit -MaxCyclomatic 15 -MaxCognitive 15
            return $clock.Elapsed.TotalMilliseconds
        }
        $null = & $time $small $entries $accept  # warm-up, so neither side pays for compilation
        $ms = @{ LargeAll = [double]::MaxValue; LargeNone = [double]::MaxValue; SmallAll = [double]::MaxValue; SmallNone = [double]::MaxValue }
        foreach ($round in 1..3) {
            $ms.LargeAll = [Math]::Min($ms.LargeAll, (& $time $large $entries $accept))
            $ms.LargeNone = [Math]::Min($ms.LargeNone, (& $time $large @() @()))
            $ms.SmallAll = [Math]::Min($ms.SmallAll, (& $time $small $entries $accept))
            $ms.SmallNone = [Math]::Min($ms.SmallNone, (& $time $small @() @()))
        }
        ($ms.LargeAll - $ms.LargeNone) / ($ms.SmallAll - $ms.SmallNone) | Should-BeLessThan 3
    }
}

Describe 'Get-PSCxBaselineAddition' {
    BeforeAll {
        $script:recorded = Get-PSCxBaselineMap -PathComparison Ordinal -Entry @(Entry -Name 'Kept')
    }

    It 'names a breaching unit the baseline has never recorded (#152)' {
        $added = @(Get-PSCxBaselineAddition -Unit @((Unit -Name 'Kept'), (Unit -Name 'Fresh')) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -Map $script:recorded -PathComparison Ordinal)
        (($added | ForEach-Object Unit) -join ',') | Should-Be 'Fresh'
    }

    It 'leaves out a new unit within both ceilings, which the file would not record anyway' {
        @(Get-PSCxBaselineAddition -Unit @(Unit -Name 'Fresh' -Cyc 15 -Cog 15) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -Map $script:recorded -PathComparison Ordinal).Count | Should-Be 0
    }

    It 'leaves out an accepted unit, which the file never records' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Fresh'; Reason = 'r' })
        @(Get-PSCxBaselineAddition -Unit @(Unit -Name 'Fresh') -Accept $acc `
                -MaxCyclomatic 15 -MaxCognitive 15 -Map $script:recorded -PathComparison Ordinal).Count | Should-Be 0
    }

    It 'finds a recorded unit under any casing of its NAME' {
        @(Get-PSCxBaselineAddition -Unit @(Unit -Name 'KEPT') -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -Map $script:recorded -PathComparison Ordinal).Count | Should-Be 0
    }
}

Describe 'Get-PSCxBaselineUpdateFault' {
    It 'says nothing when nothing is raised or added' {
        Get-PSCxBaselineUpdateFault -Raised @() -Added @() | Should-BeNull
    }

    It 'refuses a raise, naming the unit and its scores' {
        Get-PSCxBaselineUpdateFault -Raised @(Unit -Cyc 21 -Cog 30) -Added @() |
            Should-BeLikeString '*src/A.ps1 Invoke-Thing is now cyclomatic 21, cognitive 30*worse than recorded*'
    }

    It 'refuses a raise even with -AllowNew' {
        Get-PSCxBaselineUpdateFault -Raised @(Unit) -Added @() -AllowNew | Should-BeLikeString '*worse than recorded*'
    }

    It 'refuses a SINGLE added unit too' {
        # One, not two: a guard that counted from the wrong place would pass any multi-unit case.
        Get-PSCxBaselineUpdateFault -Raised @() -Added @(Unit -Name 'Fresh') | Should-BeLikeString '*Fresh*not in the baseline*'
    }

    It 'refuses an addition, naming every unit, unless -AllowNew (#152)' {
        $added = @((Unit -Name 'A2' -Cyc 5 -Cog 10), (Unit -Name 'B' -Cyc 3 -Cog 3))
        Get-PSCxBaselineUpdateFault -Raised @() -Added $added |
            Should-BeLikeString '*src/A.ps1 A2 (cyclomatic 5, cognitive 10); src/A.ps1 B (cyclomatic 3, cognitive 3)*not in the baseline*-AllowNew*'
        Get-PSCxBaselineUpdateFault -Raised @() -Added $added -AllowNew | Should-BeNull
    }
}

Describe 'Get-PSCxBaselineDocumentFault' {
    It 'says nothing about a document this run can compare against' {
        Get-PSCxBaselineDocumentFault -Document (Doc) -MetricVersion 1 -SchemaVersion 1 | Should-BeNull
    }

    It 'refuses nothing at all' {
        Get-PSCxBaselineDocumentFault -Document $null -MetricVersion 1 -SchemaVersion 1 |
            Should-BeLikeString '*held no document*'
    }

    It 'refuses a NEWER schema version as well as an older one' {
        # -ne, not -lt. A file written by a newer PSComplexity is equally uncomparable, and
        # reading it as though it were current is the direction that fails silently.
        #
        # Asserted past the last concatenation, for the reason given in Get-PSCxBaselineMap above.
        Get-PSCxBaselineDocumentFault -Document (Doc -Schema 2) -MetricVersion 1 -SchemaVersion 1 |
            Should-BeLikeString '*schemaVersion 2*regenerate it with -UpdateBaseline*'
        Get-PSCxBaselineDocumentFault -Document (Doc -Schema 0) -MetricVersion 1 -SchemaVersion 1 |
            Should-BeLikeString '*schemaVersion 0*'
    }

    It 'refuses a NEWER metric version as well as an older one' {
        Get-PSCxBaselineDocumentFault -Document (Doc -Metric 2) -MetricVersion 1 -SchemaVersion 1 |
            Should-BeLikeString '*metric version 2*review the diff*'
        Get-PSCxBaselineDocumentFault -Document (Doc -Metric 0) -MetricVersion 1 -SchemaVersion 1 |
            Should-BeLikeString '*metric version 0*'
    }

    It 'refuses a document with no units array' {
        Get-PSCxBaselineDocumentFault -Document ([pscustomobject]@{ schemaVersion = 1; metricVersion = 1 }) `
            -MetricVersion 1 -SchemaVersion 1 | Should-BeLikeString '*no units array*'
    }

    It 'accepts an EMPTY units array' {
        # Paired with the case above: absent and empty are different answers, and a guard written
        # on truthiness rather than $null would refuse a legitimately empty baseline.
        Get-PSCxBaselineDocumentFault -Document (Doc -Units @()) -MetricVersion 1 -SchemaVersion 1 |
            Should-BeNull
    }
}

Describe 'Get-PSCxBaselineRaise' {
    It 'names a recorded unit that got worse' {
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry -Cyc 20 -Cog 30)
        @(Get-PSCxBaselineRaise -Unit @(Unit -Cyc 21 -Cog 30) -Map $map).Count | Should-Be 1
    }

    It 'says nothing about a unit at or under its record' {
        $map = Get-PSCxBaselineMap -PathComparison $script:PathCmp -Entry @(Entry -Cyc 20 -Cog 30)
        @(Get-PSCxBaselineRaise -Unit @((Unit -Cyc 20 -Cog 30), (Unit -Cyc 1 -Cog 1)) -Map $map).Count |
            Should-Be 0
    }

    It 'says nothing about a unit the baseline does not record' {
        # A new violation is not a raise. Reported as one, seeding a baseline would be impossible:
        # the first run would refuse to write anything.
        @(Get-PSCxBaselineRaise -Unit @(Unit) -Map @{}).Count | Should-Be 0
    }
}

Describe 'Get-PSCxBaselineDocument' {
    It 'records the breaching units and leaves the compliant ones out' {
        $doc = Get-PSCxBaselineDocument -PathComparison $script:PathCmp -Unit @((Unit), (Unit -Name 'Fine' -Cyc 1 -Cog 1)) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 1
        $doc.units[0].unit | Should-Be 'Invoke-Thing'
    }

    It 'leaves an accepted unit out' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        $doc = Get-PSCxBaselineDocument -PathComparison $script:PathCmp -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 0
    }

    It 'orders entries by file then unit' {
        # Joined and compared as a string, because Should-BeCollection ignores order and would
        # pass against the reshuffle this ordering exists to prevent.
        $units = @((Unit -File 'src/B.ps1' -Name 'Zeta'), (Unit -File 'src/A.ps1' -Name 'Beta'),
            (Unit -File 'src/A.ps1' -Name 'Alpha'))
        $doc = Get-PSCxBaselineDocument -PathComparison $script:PathCmp -Unit $units -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        (($doc.units | ForEach-Object { "$($_.file):$($_.unit)" }) -join ' ') |
            Should-Be 'src/A.ps1:Alpha src/A.ps1:Beta src/B.ps1:Zeta'
    }

    It 'stamps the versions and a UTC timestamp' {
        $doc = Get-PSCxBaselineDocument -PathComparison $script:PathCmp -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 7 -SchemaVersion 3 -GeneratedAt ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc))
        $doc.metricVersion | Should-Be 7
        $doc.schemaVersion | Should-Be 3
        $doc.generatedAt | Should-Be '2026-01-02T03:04:05Z'
    }

    It 'writes an empty units array when nothing breached' {
        $doc = Get-PSCxBaselineDocument -PathComparison $script:PathCmp -Unit @(Unit -Cyc 1 -Cog 1) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 0
    }
}
