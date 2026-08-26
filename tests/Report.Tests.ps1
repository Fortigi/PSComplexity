# The two published formats: our own report, defined by schemas/v1/report.schema.json, and
# SARIF 2.1.0. Both leave the process, so both are contracts.
#
# The schema is validated against reports a REAL run just wrote, not against hand-built
# documents. A schema that has drifted from the writer is worse than none: it invites a consumer
# to code against a shape they will not receive.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:schemaText = Get-Content (Join-Path $script:repo 'schemas/v1/report.schema.json') -Raw

    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "cxreport-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:work -Force | Out-Null
    # One unit over both ceilings, one clean, one file that will not parse. All three matter:
    # the report has to carry units, a verdict and a skip, and a fixture missing any of them
    # leaves that part of the document untested.
    Set-Content (Join-Path $script:work 'hot.ps1') @'
function Invoke-Hot {
    param($a, $b, $c)
    if ($a) { if ($b) { if ($c) { 1 } } }
}
function Get-Cool { param($x) $x }
'@ -Encoding utf8

    $script:out = Join-Path $script:work 'out'
    New-Item -ItemType Directory -Path $script:out -Force | Out-Null

    # Written once by real runs, then asserted against. Both shapes, because they travel
    # different call paths and a field wired into one writer and not the other is invisible
    # until somebody opens the file.
    $script:measurePath = Join-Path $script:out 'measure.json'
    Measure-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -ReportPath $script:measurePath | Out-Null

    $script:gatePath = Join-Path $script:out 'gate.json'
    $script:sarifPath = Join-Path $script:out 'gate.sarif'
    Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 1 -MaxCognitive 1 `
        -ReportPath $script:gatePath -SarifPath $script:sarifPath -WarningAction SilentlyContinue | Out-Null

    # Read as TEXT. ConvertFrom-Json recognises the ISO-8601 generatedAt and hands back a
    # [datetime], so a round-tripped object no longer holds the string the schema describes.
    # The file is the contract.
    $script:measureText = [System.IO.File]::ReadAllText($script:measurePath)
    $script:gateText = [System.IO.File]::ReadAllText($script:gatePath)

    function Test-AgainstSchema {
        param([string]$Json)
        try { Test-Json -Json $Json -Schema $script:schemaText -ErrorAction Stop | Out-Null; return $true }
        catch { return $false }
    }

    function Get-NestedDocument {
        # A document nested exactly $Levels deep, for the two depth assertions below.
        #
        # Get-, not New-, although it builds something: New- is a state-changing verb, so
        # PSUseShouldProcessForStateChangingFunctions asks for -WhatIf support a test helper has
        # no use for. Same reason Get-PSCxUnitRecord is spelled that way.
        param([int]$Levels)
        $root = [ordered]@{ a = $null }
        $node = $root
        foreach ($i in 1..$Levels) {
            $child = [ordered]@{ a = $null }
            $node['a'] = $child
            $node = $child
        }
        return $root
    }
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'the published report schema' {

    It 'accepts the measurement report a real run just wrote' {
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:measureText)
    }

    It 'accepts the gate report a real run just wrote' {
        Should-BeTrue -Actual (Test-AgainstSchema -Json $script:gateText)
    }

    It 'refuses a measurement report that carries a verdict' {
        # The safety property, and the reason this schema is worth shipping rather than merely
        # writing down. Measure-PSComplexity applies no thresholds, so a `passed` beside its
        # numbers is an answer nobody computed. Making it unrepresentable beats a caveat.
        #
        # Written as a boolean-false property schema, because Test-Json silently IGNORES `not`
        # -- the obvious spelling of this rule is a clause that can never fire, which looks
        # exactly like one that passes.
        $tampered = $script:measureText -replace '("mode"\s*:\s*"Measure")', '$1, "passed": true'
        # Asserted first: a -replace that matched nothing leaves the document untouched, and
        # this test would then pass while proving nothing about the schema.
        $tampered | Should-NotBe $script:measureText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $tampered)
    }

    It 'refuses a report with no metricVersion' {
        # Required on purpose. The metric has moved twice for source that did not change, so a
        # stored number that cannot be checked for comparability is a trend chart waiting to
        # mislead.
        $stripped = $script:measureText -replace '"metricVersion"\s*:\s*[0-9]+,', ''
        $stripped | Should-NotBe $script:measureText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $stripped)
    }

    It 'refuses a report whose summary cannot say what it excluded' {
        # scope and skipped are required BESIDE the summary. An aggregate that cannot say what
        # it covered is the failure this project exists to find in other people's code.
        $stripped = $script:measureText -replace '"skipped"\s*:\s*\[[^\]]*\],', ''
        $stripped | Should-NotBe $script:measureText
        Should-BeFalse -Actual (Test-AgainstSchema -Json $stripped)
    }

    It 'still accepts a report carrying a field it has never seen' {
        # The additive promise, in the other direction: schemaVersion changes when a field
        # changes meaning or disappears, NEVER when one is added. So the schema must permit
        # extra properties, or every consumer validating against it breaks on the next release
        # that records one more thing.
        $widened = $script:measureText -replace '("generatedFrom"\s*:\s*"PSComplexity")', '$1, "somethingAddedLater": 42'
        $widened | Should-NotBe $script:measureText
        Should-BeTrue -Actual (Test-AgainstSchema -Json $widened)
    }

    It 'ships the schema the module validates against' {
        # A schema left behind in the repo is no use to the consumer it exists for, and that
        # failure is invisible from inside the repo. The package smoke test asserts it travels;
        # this asserts it is here and parses.
        $path = Join-Path $script:repo 'schemas/v1/report.schema.json'
        Should-BeTrue -Actual (Test-Path -LiteralPath $path)
        # Parsed and identified, not merely present. There is no Should-NotThrow in Pester 6
        # and that is deliberate -- an unhandled exception fails the test on its own, so the
        # assertion worth making is about what the document IS.
        ($script:schemaText | ConvertFrom-Json).title | Should-Be 'PSComplexity report'
    }
}

Describe 'what a report says' {

    It 'stamps the schema version the shipped schema describes' {
        # Nothing else pins this. A consumer branches on it, so a bump nobody meant is a silent
        # promise that a field changed meaning.
        $d = Get-Content $script:measurePath -Raw | ConvertFrom-Json
        $d.schemaVersion | Should-Be 1
    }

    It 'says which command produced it' {
        # mode is what a consumer reads to know whether a verdict was even possible. The
        # conditional in the schema keys on `thresholds`, so a wrong mode still validates --
        # only an assertion catches it.
        (Get-Content $script:measurePath -Raw | ConvertFrom-Json).mode | Should-Be 'Measure'
        (Get-Content $script:gatePath -Raw | ConvertFrom-Json).mode | Should-Be 'Gate'
    }

    It 'rounds an average to two decimals, not to one and not to none' {
        # Needs a fixture whose average does NOT divide evenly, or every precision agrees and
        # the assertion passes whatever the code does. Three units scoring 0, 1 and 2 average
        # 1, which proves nothing; these four average 1.75, where two decimals, one decimal and
        # a whole number are three different published answers.
        # THREE units, and totals not divisible by three, so both averages are 2.333... A
        # fixture averaging 1.75 is no good: it is exact at two decimals, so rounding to three
        # gives the same answer and the assertion passes against either. The denominator has to
        # be a number that does not divide the total.
        $p = Join-Path $script:work 'round.ps1'
        Set-Content $p @'
function Get-R1 { param($a) if ($a) { 1 } }
function Get-R2 { param($a, $b, $c) if ($a) { if ($b) { if ($c) { 1 } } } }
'@ -Encoding utf8
        $out = Join-Path $script:out 'round.json'
        Measure-PSComplexity -Path $p -ReportPath $out | Out-Null
        $d = Get-Content $out -Raw | ConvertFrom-Json
        # Both averages, because they are two separate roundings and a change to one is
        # invisible in the other.
        foreach ($metric in 'Cyclomatic', 'Cognitive') {
            $values = @($d.units | ForEach-Object { $_.$metric })
            $exact = ($values | Measure-Object -Average).Average
            # The fixture has to discriminate, asserted out loud rather than hoped for: an
            # average that terminates at two decimals rounds identically at three, and the
            # test then passes whatever precision the code uses.
            [math]::Round($exact, 2) | Should-NotBe ([math]::Round($exact, 3))
            $d.summary."average$metric" | Should-Be ([math]::Round($exact, 2))
        }
    }

    It 'names the exact top-level fields of a measurement report' {
        # The schema states the guaranteed MINIMUM and permits more. This pins the actual list,
        # so widening it stays a decision rather than a side effect of an internal rename. Two
        # assertions, two different claims.
        $d = Get-Content $script:measurePath -Raw | ConvertFrom-Json
        ($d.PSObject.Properties.Name -join ',') |
            Should-Be 'generatedFrom,schemaVersion,producedBy,generatedAt,mode,metricVersion,scope,skipped,summary,units'
    }

    It 'adds exactly the gate fields to a gate report' {
        $d = Get-Content $script:gatePath -Raw | ConvertFrom-Json
        ($d.PSObject.Properties.Name -join ',') |
            Should-Be 'generatedFrom,schemaVersion,producedBy,generatedAt,mode,metricVersion,scope,skipped,summary,units,thresholds,passed,violations,accepted,baselined'
    }

    It 'reconciles its summary against the units it carries' {
        # Every aggregate is checkable against the array in the same document. A summary that is
        # the only place a fact lives has to be taken on trust, which is the opposite of what
        # this report is for.
        $d = Get-Content $script:measurePath -Raw | ConvertFrom-Json
        $d.summary.unitCount | Should-Be $d.units.Count
        $d.summary.maxCyclomatic | Should-Be (@($d.units | ForEach-Object { $_.Cyclomatic }) | Measure-Object -Maximum).Maximum
        $d.summary.maxCognitive | Should-Be (@($d.units | ForEach-Object { $_.Cognitive }) | Measure-Object -Maximum).Maximum
    }

    It 'records a skipped file with its reason' {
        # A report that omits what it could not read describes a smaller job than the one it was
        # asked to do, and nothing in the numbers says so.
        $broken = Join-Path $script:work 'broken'
        New-Item -ItemType Directory -Path $broken -Force | Out-Null
        Set-Content (Join-Path $broken 'bad.ps1') 'function Oops { param(' -Encoding utf8
        Set-Content (Join-Path $broken 'fine.ps1') 'function Get-Fine { 1 }' -Encoding utf8
        $p = Join-Path $script:out 'skip.json'
        Measure-PSComplexity -Path $broken -ReportPath $p -ErrorAction SilentlyContinue | Out-Null
        $d = Get-Content $p -Raw | ConvertFrom-Json
        # Both halves: one file skipped AND one measured, so this cannot pass against a run that
        # skipped everything or recorded nothing.
        $d.skipped.Count | Should-Be 1
        $d.skipped[0].reason | Should-BeLikeString '*parse error*'
        @($d.units | Where-Object Unit -eq 'Get-Fine').Count | Should-Be 1
    }

    It 'records what the run was asked for, not only what it found' {
        $d = Get-Content $script:measurePath -Raw | ConvertFrom-Json
        $d.scope.path.Count | Should-Be 1
        $d.scope.recurse | Should-BeFalse
    }

    It 'carries every acceptance with its argument' {
        # A gate report that said "passed" without saying what it excused would be the mute
        # button the acceptance concept exists instead of.
        $p = Join-Path $script:out 'accepted.json'
        $hot = Measure-PSComplexity -Path (Join-Path $script:work 'hot.ps1') | Where-Object Unit -eq 'Invoke-Hot'
        $ok = @(@{ File = $hot.File; Unit = 'Invoke-Hot'; Reason = 'a deliberately nested fixture' })
        Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 1 -MaxCognitive 1 `
            -Accept $ok -ReportPath $p -WarningAction SilentlyContinue | Out-Null
        $d = Get-Content $p -Raw | ConvertFrom-Json
        $d.passed | Should-BeTrue
        $d.accepted.Count | Should-Be 1
        $d.accepted[0].reason | Should-Be 'a deliberately nested fixture'
        # And the excused unit is NOT reported as a violation, which is the pair to the above.
        $d.violations.Count | Should-Be 0
    }

    It 'carries every unit the baseline excused, with the score it was held to' {
        # Same argument as the acceptance above, and it matters more here: a baseline routinely
        # excuses far more units than an acceptance ever will, so a report recording one and not
        # the other would say "passed" over a set it never named. The SCORE is carried, not just
        # the name -- "excused" without a number does not say how much room was left.
        $p = Join-Path $script:out 'baselined.json'
        $src = Join-Path $script:work 'hot.ps1'
        $hot = Measure-PSComplexity -Path $src | Where-Object Unit -eq 'Invoke-Hot'
        $bl = Join-Path $script:out 'bl.json'
        [pscustomobject]@{
            schemaVersion = 1
            metricVersion = 1
            generatedAt   = '2026-01-01T00:00:00Z'
            units         = @([pscustomobject]@{
                    file = $hot.File; unit = 'Invoke-Hot'
                    cyclomatic = $hot.Cyclomatic; cognitive = $hot.Cognitive
                })
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $bl -Encoding utf8

        Test-PSComplexity -Path $src -MaxCyclomatic 1 -MaxCognitive 1 `
            -BaselineFile $bl -ReportPath $p -WarningAction SilentlyContinue | Out-Null
        $d = Get-Content $p -Raw | ConvertFrom-Json
        $d.passed | Should-BeTrue
        $d.baselined.Count | Should-Be 1
        $d.baselined[0].unit | Should-Be 'Invoke-Hot'
        $d.baselined[0].cyclomatic | Should-Be $hot.Cyclomatic
        $d.baselined[0].cognitive | Should-Be $hot.Cognitive
        # The pair: the excused unit is not also reported as a violation.
        $d.violations.Count | Should-Be 0
        Should-BeTrue -Actual (Test-AgainstSchema -Json ([System.IO.File]::ReadAllText($p)))
    }

    It 'records an EMPTY baselined list when no baseline was used' {
        # Absent and empty are different answers, and the schema requires the key on every gate
        # report. A consumer iterating it should not have to tell a run with no baseline from a
        # release that stopped recording one.
        $p = Join-Path $script:out 'nobaseline.json'
        Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 99 -MaxCognitive 99 `
            -ReportPath $p -WarningAction SilentlyContinue | Out-Null
        $d = Get-Content $p -Raw | ConvertFrom-Json
        ($d.PSObject.Properties.Name -contains 'baselined') | Should-BeTrue
        @($d.baselined).Count | Should-Be 0
    }

    It 'reports zero rather than nothing when it measured no units' {
        # A path that matched no PowerShell is a real outcome for Measure-PSComplexity, which
        # does not refuse it the way the gate does. Measure-Object over an empty set yields
        # $null, and a null maximum in the file reads as "zero complexity" rather than as
        # "nothing measured" -- the counts beside it are what tell those apart.
        $empty = Join-Path $script:work 'nosource'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Set-Content (Join-Path $empty 'notes.txt') 'not powershell' -Encoding utf8
        $p = Join-Path $script:out 'empty.json'
        Measure-PSComplexity -Path $empty -ReportPath $p | Out-Null
        $d = Get-Content $p -Raw | ConvertFrom-Json
        $d.summary.unitCount | Should-Be 0
        $d.summary.maxCognitive | Should-Be 0
        Should-BeTrue -Actual (Test-AgainstSchema -Json ([System.IO.File]::ReadAllText($p)))
    }

    It 'writes no report when none was asked for' {
        # The switch has to be the only thing that creates a file. A command that writes an
        # artefact unbidden litters every consumer's working tree.
        $before = @(Get-ChildItem $script:out -File).Count
        Measure-PSComplexity -Path (Join-Path $script:work 'hot.ps1') | Out-Null
        @(Get-ChildItem $script:out -File).Count | Should-Be $before
    }
}

Describe 'the SARIF log' {

    BeforeAll {
        $script:sarif = Get-Content $script:sarifPath -Raw | ConvertFrom-Json
    }

    It 'is a SARIF 2.1.0 log naming this tool' {
        $script:sarif.version | Should-Be '2.1.0'
        $script:sarif.runs[0].tool.driver.name | Should-Be 'PSComplexity'
    }

    It 'declares one rule per metric so they suppress independently' {
        # A single rule would mean silencing cyclomatic silences cognitive, which is not a
        # decision anyone asked to make.
        (@($script:sarif.runs[0].tool.driver.rules | ForEach-Object { $_.id }) -join ',') |
            Should-Be 'PSCxCyclomatic,PSCxCognitive'
    }

    It 'raises one result per breached ceiling, so a unit over both appears twice' {
        # Invoke-Hot is over both ceilings at 1/1. One result would render against one metric
        # and silently drop the other.
        @($script:sarif.runs[0].results | Where-Object {
                $_.partialFingerprints.psComplexityUnit -like '*Invoke-Hot'
            }).Count | Should-Be 2
    }

    It 'raises nothing for a unit that is within its ceilings' {
        # The kept half. Without it, the count above passes just as well against a log that
        # reports every unit it measured.
        @($script:sarif.runs[0].results | Where-Object {
                $_.partialFingerprints.psComplexityUnit -like '*Get-Cool'
            }).Count | Should-Be 0
    }

    It 'raises nothing for an accepted unit' {
        # The gate excused it, and repeating it as a finding asks a reviewer to act on something
        # already argued. The argument is not lost: the JSON report carries it under `accepted`.
        $p = Join-Path $script:out 'accepted.sarif'
        $hot = Measure-PSComplexity -Path (Join-Path $script:work 'hot.ps1') | Where-Object Unit -eq 'Invoke-Hot'
        $ok = @(@{ File = $hot.File; Unit = 'Invoke-Hot'; Reason = 'r' })
        Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 1 -MaxCognitive 1 `
            -Accept $ok -SarifPath $p -WarningAction SilentlyContinue | Out-Null
        (Get-Content $p -Raw | ConvertFrom-Json).runs[0].results.Count | Should-Be 0
    }

    It 'keeps every result pointing at the rule it names' {
        # ruleIndex is an offset into the rules array, and ruleId is the name. They are built
        # from one tuple, so a shifted index or a swapped field makes them disagree -- which a
        # reader would never notice and a SARIF consumer resolves to the wrong rule.
        $rules = @($script:sarif.runs[0].tool.driver.rules)
        foreach ($r in @($script:sarif.runs[0].results)) {
            $rules[$r.ruleIndex].id | Should-Be $r.ruleId
        }
    }

    It 'says which metric, which value and which ceiling' {
        # The message is what a reviewer reads on the diff. Built from the same tuple as the
        # rule, so an index off by one silently reports the wrong number or the wrong metric
        # while still rendering a plausible sentence.
        $r = @($script:sarif.runs[0].results |
                Where-Object { $_.ruleId -eq 'PSCxCognitive' -and $_.partialFingerprints.psComplexityUnit -like '*Invoke-Hot' })[0]
        $r.message.text | Should-Be 'Invoke-Hot has cognitive complexity 6, over the ceiling of 1.'
    }

    It 'raises nothing for a metric sitting exactly ON its ceiling' {
        # At or under is within. Invoke-Hot is cyclomatic 4 and cognitive 6; ceilings 4/1 put it
        # over on one metric and exactly ON the other, so the unit IS a violation and only the
        # cognitive result belongs. Read as at-or-over, an extra cyclomatic finding appears for a
        # unit that is inside that ceiling -- and every earlier fixture had it over both, where
        # the two readings agree.
        $p = Join-Path $script:out 'boundary.sarif'
        Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 4 -MaxCognitive 1 `
            -SarifPath $p -WarningAction SilentlyContinue | Out-Null
        $r = @((Get-Content $p -Raw | ConvertFrom-Json).runs[0].results |
                Where-Object { $_.partialFingerprints.psComplexityUnit -like '*Invoke-Hot' })
        $r.Count | Should-Be 1
        $r[0].ruleId | Should-Be 'PSCxCognitive'
    }

    It 'raises nothing for a COGNITIVE metric sitting exactly on its ceiling' {
        # The mirror of the case above, and needed separately: the two ceilings are two
        # comparisons, and a fixture that only ever lands on one boundary leaves the other
        # reading at-or-over with nothing to notice. Invoke-Hot is cyclomatic 4, cognitive 6;
        # ceilings 1/6 put it over on cyclomatic and exactly ON cognitive.
        $p = Join-Path $script:out 'boundary-cog.sarif'
        Test-PSComplexity -Path (Join-Path $script:work 'hot.ps1') -MaxCyclomatic 1 -MaxCognitive 6 `
            -SarifPath $p -WarningAction SilentlyContinue | Out-Null
        $r = @((Get-Content $p -Raw | ConvertFrom-Json).runs[0].results |
                Where-Object { $_.partialFingerprints.psComplexityUnit -like '*Invoke-Hot' })
        $r.Count | Should-Be 1
        $r[0].ruleId | Should-Be 'PSCxCyclomatic'
    }

    It 'points at a file and a line code scanning can resolve' {
        $r = @($script:sarif.runs[0].results)[0]
        $r.locations[0].physicalLocation.artifactLocation.uri | Should-BeLikeString '*hot.ps1'
        $r.locations[0].physicalLocation.artifactLocation.uri | Should-NotBeLikeString '*\*'
        $r.locations[0].physicalLocation.region.startLine | Should-BeGreaterThan 0
    }

    It 'fingerprints a finding on identity, never on the line it sits at' {
        # Line moves whenever anything above the unit is edited. A fingerprint built on it would
        # close and reopen the same finding on an unrelated edit above -- which is exactly the
        # noise partialFingerprints exists to prevent.
        # Asserted as an EXACT composition rather than as "does not contain the line number":
        # the file path is a temp directory full of digits, so a wildcard for the line matches
        # by accident and the test passes whatever the fingerprint is built from.
        $r = @($script:sarif.runs[0].results |
                Where-Object { $_.partialFingerprints.psComplexityUnit -like '*Invoke-Hot' })[0]
        $r.partialFingerprints.psComplexityUnit |
            Should-Be "$($r.locations[0].physicalLocation.artifactLocation.uri)|Invoke-Hot"
    }

    It 'reports at error level, matching the build it just failed' {
        # A finding that renders as advice while the gate goes red says two different things
        # about one fact.
        (@($script:sarif.runs[0].results | ForEach-Object { $_.level } | Sort-Object -Unique) -join ',') |
            Should-Be 'error'
    }
}

Describe 'the version a report claims it came from' {

    It 'takes the version from the loaded module when there is one' {
        # The normal path for a consumer, and the one the suite never exercises on its own:
        # these tests dot-source src/ rather than importing a module, so without a mock this
        # branch is unreachable from here and ships unmeasured.
        Mock Get-Module { [pscustomobject]@{ Version = '9.9.9' } }
        Get-PSCxModuleVersion | Should-Be '9.9.9'
    }

    It 'falls back to the manifest beside src when nothing is loaded' {
        # Mocked rather than reading the real manifest, because a covering suite has to be
        # SELF-CONTAINED: the mutation sandbox copies src/, tests/ and schemas/ and no manifest,
        # so a test that reaches the repo root fails there while passing everywhere else.
        # It did, and it turned the baseline red.
        Mock Get-Module { @() }
        Mock Test-Path { $true }
        Mock Import-PowerShellDataFile { @{ ModuleVersion = '1.2.3' } }
        Get-PSCxModuleVersion | Should-Be '1.2.3'
    }

    It 'says unknown rather than inventing a plausible version' {
        # Neither an installed module nor a manifest is a REAL configuration, not a broken one:
        # a mutation sandbox copies src/ and tests/ and no manifest, and so does a consumer who
        # dot-sources src/ directly. An earlier version threw here, which turned the sandboxed
        # baseline red before a mutant ran.
        #
        # 'unknown' rather than '0.0.0' because a plausible-looking version is the worse
        # failure: it sits in a stored artefact claiming every such run came from one release.
        Mock Get-Module { @() }
        # A default mock as well as the filtered one: Pester 6 removed fall-through, so a call
        # matching no filter throws rather than reaching the real command.
        Mock Test-Path { $true }
        Mock Test-Path { $false } -ParameterFilter { "$LiteralPath" -like '*PSComplexity.psd1' }
        Get-PSCxModuleVersion | Should-Be 'unknown'
    }
}

Describe 'writing a document' {

    It 'creates the directory a report is asked for' {
        # reports/ on a fresh clone, or an artifacts directory a CI step has not made yet.
        $deep = Join-Path $script:out 'a/b/c/report.json'
        Save-PSCxDocument -Path $deep -Document ([ordered]@{ x = 1 })
        Should-BeTrue -Actual (Test-Path -LiteralPath $deep)
    }

    It 'writes a report named without any directory at all' {
        # A bare filename has no parent, and asking for the parent yields an empty string.
        # Creating a directory from that throws, so the guard has to be a real test rather than
        # a formality -- and every other test here passes a full path, where it never fires.
        Push-Location $script:out
        try {
            Save-PSCxDocument -Path 'bare.json' -Document ([ordered]@{ x = 1 })
            Should-BeTrue -Actual (Test-Path -LiteralPath (Join-Path $script:out 'bare.json'))
        }
        finally { Pop-Location }
    }

    It 'serialises a document nested as deeply as SARIF goes' {
        # Twelve levels is what a SARIF result needs. This is the deepest document the writer
        # must handle intact, and it is one level away from the case below -- a depth chosen a
        # little too small produces a valid file that quietly lost its tail.
        $p = Join-Path $script:out 'deep-ok.json'
        Save-PSCxDocument -Path $p -Document (Get-NestedDocument -Levels 12)
        (Get-Content $p -Raw) | Should-NotMatchString 'System\.Collections'
    }

    It 'refuses to write a document ConvertTo-Json truncated' {
        # Silent truncation leaves a VALID JSON file that no longer matches its schema, with a
        # .NET type name where a value belongs. It shipped here once: every SARIF location read
        # "System.Collections.Specialized.OrderedDictionary". Raising the depth fixed that
        # document; this is what stops the next nested field reintroducing it.
        # Thirteen levels, not twenty: the boundary is where the assertion has to sit, because a
        # wildly over-deep document fails at any plausible setting and proves nothing about the
        # one this writer uses.
        { Save-PSCxDocument -Path (Join-Path $script:out 'deep.json') -Document (Get-NestedDocument -Levels 13) } |
            Should-Throw -ExceptionMessage '*truncated*'
    }
}

Describe 'Read-PSCxDocument' {
    # The counterpart to Save-PSCxDocument, and the only place a baseline enters the process. A
    # path is the one thing a consumer types by hand, so each way it can be wrong is named
    # separately: a missing file is usually a wrong path, a parse failure usually a hand edit.
    #
    # Tested HERE rather than only through Test-PSComplexity -BaselineFile, which also exercises
    # it. Report.ps1's covering suite is this file, so a test in the other one covers these lines
    # without being able to kill their mutants -- and three of them survived exactly that way.

    BeforeAll {
        $script:docDir = Join-Path ([System.IO.Path]::GetTempPath()) "cxdoc-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:docDir -Force | Out-Null
    }
    AfterAll { Remove-Item $script:docDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads a document back' {
        # The kept half. Without it every refusal below passes just as well against a function
        # that refused everything.
        $p = Join-Path $script:docDir 'good.json'
        Set-Content -LiteralPath $p -Value '{ "schemaVersion": 1, "units": [] }' -Encoding utf8
        (Read-PSCxDocument -Path $p).schemaVersion | Should-Be 1
    }

    It 'names the path when there is no such file' {
        # Asserted on OUR wording, not just the filename. Drop the Test-Path guard and
        # Get-Content raises its own 'Cannot find path ...' quoting the same file, so an
        # assertion on the name alone matches the very failure it exists to detect -- which is
        # how that mutant survived a round.
        { Read-PSCxDocument -Path (Join-Path $script:docDir 'absent.json') } |
            Should-Throw -ExceptionMessage '*No such file*absent.json*'
    }

    It 'refuses an empty file rather than reading it as an empty document' {
        # Get-Content -Raw on an empty file yields $null, which ConvertFrom-Json turns into $null
        # -- and a $null passed on as a document reads as a baseline with no entries. That is a
        # changed verdict wearing the clothes of a successful read.
        $p = Join-Path $script:docDir 'empty.json'
        Set-Content -LiteralPath $p -Value '' -Encoding utf8
        { Read-PSCxDocument -Path $p } | Should-Throw -ExceptionMessage '*is empty*'
    }

    It 'refuses a file of nothing but whitespace' {
        # Not the same case as the one above, and the difference is the -or. For an empty file
        # both halves of that guard are true, so -and answers identically; for whitespace the
        # first half is FALSE and only -or still fires. This is the input that tells the two
        # operators apart, and the mutant survived until it existed.
        $p = Join-Path $script:docDir 'blank.json'
        Set-Content -LiteralPath $p -Value "   `n  " -Encoding utf8
        { Read-PSCxDocument -Path $p } | Should-Throw -ExceptionMessage '*is empty*'
    }

    It 'refuses a file that is not JSON, and says so' {
        $p = Join-Path $script:docDir 'bad.json'
        Set-Content -LiteralPath $p -Value 'not json {' -Encoding utf8
        { Read-PSCxDocument -Path $p } | Should-Throw -ExceptionMessage '*not valid JSON*'
    }

    It 'reads a path containing wildcard characters literally' {
        # LiteralPath throughout. A baseline under a directory named 'my[1]proj' is ordinary on
        # Windows, and the wildcard form reports it as missing -- the same class of bug as
        # Get-PSCxSourceFile's, which shipped.
        $odd = Join-Path $script:docDir 'my[1]proj'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        $p = Join-Path $odd 'b.json'
        Set-Content -LiteralPath $p -Value '{ "schemaVersion": 1 }' -Encoding utf8
        (Read-PSCxDocument -Path $p).schemaVersion | Should-Be 1
    }
}
