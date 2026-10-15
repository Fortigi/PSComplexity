# Reading, refusing and writing the baseline file.
#
# The COVERING SUITE for src/BaselineFile.ps1, and cheap on purpose. Nothing here measures a
# script: a unit record is an ordinary object and a baseline is a small JSON file, so the whole
# file runs in about a second. That is the entire reason these two functions live apart from
# Measure-PSComplexity.ps1 -- against its 18-second measuring suite, their 28 mutants cost about
# eight minutes of every gate run to prove things that need no measurement at all.
#
# The end-to-end proofs are in tests/Measure.Tests.ps1, driving the same code through
# Test-PSComplexity -BaselineFile. Covering a function is not covering its application, and
# neither the coverage gate nor the mutation gate can tell the difference.

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

    $script:blWork = Join-Path ([System.IO.Path]::GetTempPath()) "cxblfile-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:blWork -Force | Out-Null

    function script:Unit {
        param([string]$File = 'src/A.ps1', [string]$Name = 'Invoke-Thing', [int]$Cyc = 20, [int]$Cog = 30)
        return [pscustomobject]@{ File = $File; Unit = $Name; Line = 1; Cyclomatic = $Cyc; Cognitive = $Cog }
    }
    function script:Baseline {
        param($Units = @(), [int]$Schema = 1, [int]$Metric = 1)
        $p = Join-Path $script:blWork "bl-$([System.Guid]::NewGuid().ToString('N')).json"
        [pscustomobject]@{ schemaVersion = $Schema; metricVersion = $Metric; generatedAt = '2026-01-01T00:00:00Z'; units = @($Units) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
        return $p
    }
    function script:Entry {
        param([string]$File = 'src/A.ps1', [string]$Name = 'Invoke-Thing', [int]$Cyc = 20, [int]$Cog = 30)
        return [pscustomobject]@{ file = $File; unit = $Name; cyclomatic = $Cyc; cognitive = $Cog }
    }
    function script:NewPath { return Join-Path $script:blWork "out-$([System.Guid]::NewGuid().ToString('N')).json" }
}

AfterAll { Remove-Item $script:blWork -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-PSCxBaselineState' {
    It 'is an empty MAP when no baseline was asked for, not a null' {
        # The type is the claim, not just the count: $null.Count is also 0, so a count assertion
        # alone passes against a null return -- and that mutant survived until this line existed.
        # It matters because the result is handed to a [hashtable] parameter that rejects null,
        # so a null here fails the ordinary no-baseline run rather than this test.
        $m = Get-PSCxBaselineState -PathComparison $script:PathCmp -Path '' -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        ($m -is [hashtable]) | Should-BeTrue
        $m.Count | Should-Be 0
    }

    It 'returns a lookup over a baseline that describes the run' {
        $p = Baseline -Units @(Entry)
        $m = Get-PSCxBaselineState -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        $m.Count | Should-Be 1
    }

    It 'names the file and the reason when the document cannot be compared' {
        # Asserted past the last concatenation. Break the `+` and PowerShell raises a conversion
        # error quoting its left operand, which contains every earlier phrase -- so an assertion
        # on one of those matches the very failure it exists to detect.
        $p = Baseline -Units @() -Metric 99
        { Get-PSCxBaselineState -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 } |
            Should-Throw -ExceptionMessage '*Cannot use the baseline*metric version 99*review the diff*'
    }

    It 'throws rather than failing the gate when an entry stops describing the run' {
        # A stale entry is a fault in the policy, not a complaint about the code. Returned as a
        # failing gate it would send somebody to refactor a unit that is fine.
        $p = Baseline -Units @(Entry -Name 'Ghost')
        { Get-PSCxBaselineState -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 } |
            Should-Throw -ExceptionMessage '*no such unit was measured*ageing quietly*'
    }

    It 'reports every fault at once, not just the first' {
        # Fixing a stale baseline should cost one round trip rather than one per entry.
        $p = Baseline -Units @((Entry -Name 'Ghost'), (Entry -Name 'Phantom'))
        { Get-PSCxBaselineState -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 } |
            Should-Throw -ExceptionMessage '*Ghost*Phantom*'
    }

    It 'accepts a baseline with no entries at all' {
        # Paired with the refusals above: an empty baseline is a legitimate state -- everything
        # was fixed -- and refusing it would make the last cleanup fail the build.
        (Get-PSCxBaselineState -PathComparison $script:PathCmp -Path (Baseline -Units @()) -Unit @(Unit) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1).Count | Should-Be 0
    }
}

Describe 'Write-PSCxBaselineFile' {
    It 'seeds a file that did not exist' {
        # The ordinary first run. Treating absence as an error would make the switch unusable for
        # the one job it exists to do.
        $p = NewPath
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        $doc = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        @($doc.units).Count | Should-Be 1
        $doc.units[0].unit | Should-Be 'Invoke-Thing'
        $doc.metricVersion | Should-Be 1
    }

    It 'lowers an entry whose unit improved' {
        $p = Baseline -Units @(Entry -Cyc 40 -Cog 50)
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 20 -Cog 30) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        $doc = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $doc.units[0].cyclomatic | Should-Be 20
        $doc.units[0].cognitive | Should-Be 30
    }

    It 'refuses to record a unit worse than the file already does' {
        # The whole ratchet, and the paired half of the case above: down is allowed, up is not.
        $p = Baseline -Units @(Entry -Cyc 20 -Cog 30)
        { Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 21 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 } |
            Should-Throw -ExceptionMessage '*worse than recorded*only ever ratchets down*'
    }

    It 'leaves the existing file untouched when it refuses' {
        # A refusal that had already written half a document would leave the ratchet loosened by
        # the very call that declined to loosen it.
        $p = Baseline -Units @(Entry -Cyc 20 -Cog 30)
        $before = Get-Content -LiteralPath $p -Raw
        try {
            Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 21 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        }
        catch { $null = $_ }
        (Get-Content -LiteralPath $p -Raw) | Should-Be $before
    }

    It 'regenerates wholesale across a metric version change' {
        # The one case where the ratchet cannot be enforced: the recorded numbers answer a
        # different question, so they are neither larger nor smaller. Refusing would leave no way
        # forward at all.
        $p = Baseline -Units @(Entry -Cyc 1 -Cog 1) -Metric 99
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 20 -Cog 30) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        $doc = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $doc.metricVersion | Should-Be 1
        $doc.units[0].cyclomatic | Should-Be 20
    }

    It 'regenerates wholesale across a schema version change' {
        $p = Baseline -Units @(Entry -Cyc 1 -Cog 1) -Schema 99
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 20 -Cog 30) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).schemaVersion | Should-Be 1
    }

    It 'leaves an accepted unit out of the file' {
        # An entry for an accepted unit permits nothing, and would fail the very next run.
        $p = NewPath
        $acc = @(@{ File = 'src/A.ps1'; Unit = 'Invoke-Thing'; Reason = 'r' })
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit) -Accept $acc -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        @((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).units).Count | Should-Be 0
    }

    It 'leaves a compliant unit out of the file' {
        $p = NewPath
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 1 -Cog 1) -Accept @() -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1
        @((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).units).Count | Should-Be 0
    }

    It 'refuses to add a unit the baseline has never recorded, naming it (#152)' {
        # This test used to assert the opposite -- that an update records a new unit without being
        # asked. A new unit is new code or a renamed one, and a rename that also got worse is
        # the regression the ratchet exists to refuse; an unconditional update absorbed it.
        $p = Baseline -Units @(Entry -Name 'Other' -Cyc 20 -Cog 30)
        $before = Get-Content -LiteralPath $p -Raw
        { Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @((Unit -Name 'Other'), (Unit -Name 'Fresh')) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 } |
            Should-Throw -ExceptionMessage '*src/A.ps1 Fresh (cyclomatic 20, cognitive 30)*not in the baseline*-AllowNew*'
        (Get-Content -LiteralPath $p -Raw) | Should-Be $before
    }

    It 'records it with -AllowNew, and still says so' {
        $p = Baseline -Units @(Entry -Name 'Other' -Cyc 20 -Cog 30)
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @((Unit -Name 'Other'), (Unit -Name 'Fresh')) -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -AllowNew -WarningVariable warned 3>$null
        $doc = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        (($doc.units.unit | Sort-Object) -join ',') | Should-Be 'Fresh,Other'
        # One warning, for the ADDED unit only: the one already recorded is not news.
        @($warned).Count | Should-Be 1
        [string]$warned[0] | Should-BeLikeString '*src/A.ps1 Fresh at cyclomatic 20, cognitive 30*new to the baseline*'
    }

    It 'still refuses a unit worse than recorded, even with -AllowNew' {
        # -AllowNew is about units the file has never seen; it cannot make a recorded one worse.
        $p = Baseline -Units @(Entry -Cyc 20 -Cog 30)
        { Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $p -Unit @(Unit -Cyc 21 -Cog 30) -Accept @() `
                -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -AllowNew } |
            Should-Throw -ExceptionMessage '*worse than recorded*'
    }

    It 'needs no -AllowNew to seed, or to regenerate across a metric change, and warns about neither' {
        # Nothing to add TO: every unit is new to an absent file, and an incomparable one is
        # regenerated wholesale and reviewed as a diff.
        $seed = NewPath
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $seed -Unit @(Unit -Name 'Fresh') -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -WarningVariable seedWarned 3>$null
        $regen = Baseline -Units @(Entry -Name 'Other') -Metric 99
        Write-PSCxBaselineFile -PathComparison $script:PathCmp -Path $regen -Unit @(Unit -Name 'Fresh') -Accept @() `
            -MaxCyclomatic 15 -MaxCognitive 15 -MetricVersion 1 -WarningVariable regenWarned 3>$null
        (Get-Content -LiteralPath $seed -Raw | ConvertFrom-Json).units[0].unit | Should-Be 'Fresh'
        (Get-Content -LiteralPath $regen -Raw | ConvertFrom-Json).units[0].unit | Should-Be 'Fresh'
        @($seedWarned).Count + @($regenWarned).Count | Should-Be 0
    }
}
