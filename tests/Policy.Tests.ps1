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
        $map = Get-PSCxBaselineMap -Entry @(Entry)
        Test-PSCxWithinBaseline -Unit (Unit) -Map $map | Should-BeTrue
    }

    It 'does not match a like-named unit in another file' {
        # The key is file AND unit. Keyed on the name alone this excuses every unit of that name
        # in the tree, which is how suppression lists usually leak.
        $map = Get-PSCxBaselineMap -Entry @(Entry -File 'src/B.ps1')
        Test-PSCxWithinBaseline -Unit (Unit -File 'src/A.ps1') -Map $map | Should-BeFalse
    }
}

Describe 'Get-PSCxBaselineMap' {
    It 'builds a lookup over the entries' {
        (Get-PSCxBaselineMap -Entry @((Entry), (Entry -Name 'Other'))).Count | Should-Be 2
    }

    It 'is empty for no entries' {
        (Get-PSCxBaselineMap -Entry @()).Count | Should-Be 0
    }

    It 'refuses a file naming one unit twice' {
        # Asserted on the TAIL of the message, past the last concatenation. Break the `+` that
        # builds it and PowerShell raises a conversion error QUOTING its left operand, which
        # contains every earlier phrase -- so an assertion on one of those matches the very
        # failure it exists to detect. Only text from after the break tells them apart.
        { Get-PSCxBaselineMap -Entry @((Entry), (Entry)) } |
            Should-Throw -ExceptionMessage '*twice*cannot be read off the file*'
    }
}

Describe 'Get-PSCxUnacceptedUnit' {
    It 'reports a unit over a ceiling that nothing excuses' {
        @(Get-PSCxUnacceptedUnit -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
    }

    It 'says nothing about a unit at the ceiling exactly' {
        # The boundary: -gt, not -ge. A unit AT the limit is within it.
        @(Get-PSCxUnacceptedUnit -Unit @(Unit -Cyc 15 -Cog 15) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'reports a unit over on cyclomatic alone, and on cognitive alone' {
        # Two single-metric cases, because the breach test is -or and a version written with
        # -and passes whichever one it is given.
        @(Get-PSCxUnacceptedUnit -Unit @(Unit -Cyc 16 -Cog 1) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
        @(Get-PSCxUnacceptedUnit -Unit @(Unit -Cyc 1 -Cog 16) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 1
    }

    It 'excuses an accepted unit' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        @(Get-PSCxUnacceptedUnit -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'excuses a unit within its baseline, and only that unit' {
        # Paired: the recorded unit is excused and its neighbour is not, so a filter matching
        # on file alone fails here rather than passing quietly.
        $map = Get-PSCxBaselineMap -Entry @(Entry)
        $units = @((Unit), (Unit -Name 'Other'))
        $left = @(Get-PSCxUnacceptedUnit -Unit $units -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -BaselineMap $map)
        $left.Count | Should-Be 1
        $left[0].Unit | Should-Be 'Other'
    }

    It 'still reports a recorded unit that got worse' {
        $map = Get-PSCxBaselineMap -Entry @(Entry -Cyc 20 -Cog 30)
        @(Get-PSCxUnacceptedUnit -Unit @(Unit -Cyc 21 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -BaselineMap $map).Count | Should-Be 1
    }
}

Describe 'Get-PSCxAcceptanceFault' {
    It 'says nothing about an acceptance that holds' {
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15).Count | Should-Be 0
    }

    It 'refuses an acceptance with no File or no Unit' {
        (@{ Unit = 'Invoke-Thing'; Reason = 'r' } | Get-PSCxAcceptanceFault -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both File and Unit*'
        (@{ File = 'src/A.ps1'; Reason = 'r' } | Get-PSCxAcceptanceFault -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both File and Unit*'
    }

    It 'refuses an acceptance whose reason is only whitespace' {
        (@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = '   ' } |
                Get-PSCxAcceptanceFault -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no reason*'
    }

    It 'refuses an acceptance naming a unit nobody measured' {
        (@{ File = 'src/A.ps1'; Unit = 'Ghost'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -Unit @(Unit) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no such unit was measured*'
    }

    It 'refuses an acceptance for a unit within both ceilings, at the boundary' {
        # At the ceiling exactly, so -le and -lt disagree here.
        (@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -Unit @(Unit -Cyc 15 -Cog 15) -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*within both ceilings*'
    }

    It 'keeps an acceptance for a unit over one ceiling only -- either one' {
        # The -and in that guard: over on one metric and under on the other is still a breach,
        # so the acceptance is still doing work and must not be called stale.
        #
        # BOTH directions, because each half of that guard reads a different index into the
        # matched units and only one of the two is exercised by either case. Written with only
        # the cyclomatic case, a mutant that replaced the cognitive lookup with an out-of-range
        # index -- which yields $null, and $null -le 15 is $true -- survived the whole suite.
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -Unit @(Unit -Cyc 16 -Cog 1) -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
        @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' } |
                Get-PSCxAcceptanceFault -Unit @(Unit -Cyc 1 -Cog 16) -MaxCyclomatic 15 -MaxCognitive 15).Count |
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
        @(Entry | Get-PSCxBaselineFault -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'refuses an entry with no file or no unit' {
        ([pscustomobject]@{ unit = 'Invoke-Thing'; cyclomatic = 20; cognitive = 30 } |
                Get-PSCxBaselineFault -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both file and unit*'
        ([pscustomobject]@{ file = 'src/A.ps1'; cyclomatic = 20; cognitive = 30 } |
                Get-PSCxBaselineFault -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*needs both file and unit*'
    }

    It 'refuses an entry keyed by an ordinal name' {
        (Entry -Name 'Invoke-Twice#2' | Get-PSCxBaselineFault -Unit @(Unit -Name 'Invoke-Twice#2') `
                -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*renumbers when a duplicate*'
    }

    It 'refuses an entry for a unit that is also accepted' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        (Entry | Get-PSCxBaselineFault -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*both accepted and recorded*'
    }

    It 'does not treat an acceptance for a DIFFERENT unit in the same file as a clash' {
        # The -and in that lookup. With -or, any acceptance anywhere in the same file would count
        # as excusing this unit, and its entry would be deleted as redundant.
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Something-Else'; Reason = 'r' })
        @(Entry | Get-PSCxBaselineFault -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'does not treat an acceptance for the same unit in ANOTHER file as a clash' {
        $acc = @(@{ File = 'src/B.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        @(Entry | Get-PSCxBaselineFault -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15).Count |
            Should-Be 0
    }

    It 'refuses an entry naming a unit nobody measured' {
        (Entry -Name 'Ghost' | Get-PSCxBaselineFault -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15) |
            Should-BeLikeString '*no such unit was measured*'
    }

    It 'passes the score rules on to the score fault' {
        (Entry -Cyc 20 -Cog 30 | Get-PSCxBaselineFault -Unit @(Unit -Cyc 19 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15) | Should-BeLikeString '*improved to cyclomatic*'
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
        $map = Get-PSCxBaselineMap -Entry @(Entry -Cyc 20 -Cog 30)
        @(Get-PSCxBaselineRaise -Unit @(Unit -Cyc 21 -Cog 30) -Map $map).Count | Should-Be 1
    }

    It 'says nothing about a unit at or under its record' {
        $map = Get-PSCxBaselineMap -Entry @(Entry -Cyc 20 -Cog 30)
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
        $doc = Get-PSCxBaselineDocument -Unit @((Unit), (Unit -Name 'Fine' -Cyc 1 -Cog 1)) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 1
        $doc.units[0].unit | Should-Be 'Invoke-Thing'
    }

    It 'leaves an accepted unit out' {
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        $doc = Get-PSCxBaselineDocument -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 0
    }

    It 'orders entries by file then unit' {
        # Joined and compared as a string, because Should-BeCollection ignores order and would
        # pass against the reshuffle this ordering exists to prevent.
        $units = @((Unit -File 'src/B.ps1' -Name 'Zeta'), (Unit -File 'src/A.ps1' -Name 'Beta'),
            (Unit -File 'src/A.ps1' -Name 'Alpha'))
        $doc = Get-PSCxBaselineDocument -Unit $units -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        (($doc.units | ForEach-Object { "$($_.file):$($_.unit)" }) -join ' ') |
            Should-Be 'src/A.ps1:Alpha src/A.ps1:Beta src/B.ps1:Zeta'
    }

    It 'stamps the versions and a UTC timestamp' {
        $doc = Get-PSCxBaselineDocument -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 7 -SchemaVersion 3 -GeneratedAt ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc))
        $doc.metricVersion | Should-Be 7
        $doc.schemaVersion | Should-Be 3
        $doc.generatedAt | Should-Be '2026-01-02T03:04:05Z'
    }

    It 'writes an empty units array when nothing breached' {
        $doc = Get-PSCxBaselineDocument -Unit @(Unit -Cyc 1 -Cog 1) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 `
            -MetricVersion 1 -SchemaVersion 1 -GeneratedAt ([datetime]'2026-01-02T03:04:05Z')
        @($doc.units).Count | Should-Be 0
    }
}
