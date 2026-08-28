# The release gate decides whether an irreversible publish may proceed. A gate that quietly
# stops being able to fail looks exactly like a green build, so each decision is exercised
# with a case that passes AND a case that does not -- a fixture with only one outcome
# certifies whatever the code happens to do.

BeforeAll {
    . (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'tools/ReleaseDecisions.ps1')

    $script:Changelog = @(
        '# Changelog'
        ''
        '## [Unreleased]'
        ''
        '## [1.2.3] - 2026-01-01'
        ''
        '### For consumers'
        ''
        'A thing changed.'
        'It changed for a reason.'
        ''
        '### Fixed'
        '- an internal detail nobody outside needs'
        ''
        '## [1.2.2] - 2025-12-01'
        '### For consumers'
        'The previous release.'
    )
}

Describe 'Get-PSCxNewestVersion' {
    It 'takes the first released heading and not [Unreleased]' {
        # [Unreleased] sits above every version and is not one. Reading it as a version
        # would compare ModuleVersion against a word.
        Get-PSCxNewestVersion -Lines $script:Changelog | Should-Be '1.2.3'
    }
    It 'returns null when there is no released heading at all' {
        Get-PSCxNewestVersion -Lines @('# Changelog', '', '## [Unreleased]') | Should-BeNull
    }
}

Describe 'Get-PSCxConsumerNotes' {
    It 'collects the block as one line' {
        Get-PSCxConsumerNotes -Lines $script:Changelog -Version '1.2.3' |
            Should-Be 'A thing changed. It changed for a reason.'
    }
    It 'stops at the next ### heading, so internal entries never reach the gallery' {
        # The paired half of the test above: if the block ran on, the Fixed bullet would
        # appear in the published notes, which is where maintainer prose leaks to consumers.
        Get-PSCxConsumerNotes -Lines $script:Changelog -Version '1.2.3' |
            Should-NotBeLikeString '*internal detail*'
    }
    It 'stops at the next version heading' {
        Get-PSCxConsumerNotes -Lines $script:Changelog -Version '1.2.2' |
            Should-Be 'The previous release.'
    }
    It 'returns null when the version has no For consumers block' {
        $lines = @('## [9.9.9] - 2026-01-01', '### Fixed', '- something')
        Get-PSCxConsumerNotes -Lines $lines -Version '9.9.9' | Should-BeNull
    }
}

Describe 'Get-PSCxExpectedReleaseNotes' {
    It 'prefixes the version and appends the link' {
        Get-PSCxExpectedReleaseNotes -Version '1.2.3' -Notes 'A thing.' -DetailUrl 'https://x/CHANGELOG.md' |
            Should-Be '1.2.3: A thing. Full changelog: https://x/CHANGELOG.md'
    }
    It 'omits the link entirely when there is no url' {
        # Paired with the case above: appending an empty url would publish a dangling
        # "Full changelog:" with nothing after it.
        Get-PSCxExpectedReleaseNotes -Version '1.2.3' -Notes 'A thing.' -DetailUrl '' |
            Should-Be '1.2.3: A thing.'
    }
}

Describe 'Get-PSCxRewrittenManifest' {
    BeforeAll {
        $script:Manifest = @'
@{
    # A comment that explains WHY, which is the kind a manifest most needs.
    ModuleVersion = '1.2.3'
    PrivateData = @{
        PSData = @{
            ProjectUri   = 'https://example/repo'
            ReleaseNotes = 'old notes'
        }
    }
}
'@
    }

    It 'changes the notes and nothing else' {
        # The whole reason this exists rather than Update-ModuleManifest, which regenerates
        # the file: the comment, the layout and every other value have to survive.
        $out = Get-PSCxRewrittenManifest -ManifestText $script:Manifest -Notes 'new notes'
        $out | Should-BeLikeString "*ReleaseNotes = 'new notes'*"
        $out | Should-BeLikeString '*A comment that explains WHY*'
        $out | Should-BeLikeString "*ProjectUri   = 'https://example/repo'*"
        $out | Should-NotBeLikeString '*old notes*'
    }

    It 'doubles a quote so the result still parses' {
        # An apostrophe in the notes would otherwise close the string and leave a manifest
        # that cannot be read at all -- discovered at publish, on the irreversible step.
        $out = Get-PSCxRewrittenManifest -ManifestText $script:Manifest -Notes "it's fixed"
        $out | Should-BeLikeString "*'it''s fixed'*"
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "psd-$([System.Guid]::NewGuid().ToString('N')).psd1"
        try {
            Set-Content -LiteralPath $f -Value $out -Encoding utf8
            (Import-PowerShellDataFile -LiteralPath $f).PrivateData.PSData.ReleaseNotes |
                Should-Be "it's fixed"
        }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a manifest with no ReleaseNotes value rather than silently doing nothing' {
        # Returning the text unchanged would make -Apply a no-op and the verify step would
        # then fail forever with no way to fix it.
        { Get-PSCxRewrittenManifest -ManifestText '@{ ModuleVersion = ''1.0.0'' }' -Notes 'x' } |
            Should-Throw
    }
}

Describe 'Get-PSCxReleaseFault' {
    BeforeAll {
        $script:Good = @{
            ModuleVersion = '1.2.3'; ChangelogVersion = '1.2.3'
            ConsumerNotes = 'A thing changed.'; ActualNotes = '1.2.3: A thing changed.'; DetailUrl = ''
        }
    }
    It 'reports nothing when all three agree' {
        @(Get-PSCxReleaseFault @script:Good).Count | Should-Be 0
    }
    It 'catches a manifest version that does not match the changelog' {
        $a = $script:Good.Clone(); $a.ModuleVersion = '1.2.4'
        @(Get-PSCxReleaseFault @a).Count | Should-Be 1
    }
    It 'catches a missing For consumers block' {
        $a = $script:Good.Clone(); $a.ConsumerNotes = $null
        (@(Get-PSCxReleaseFault @a) -join ' ') | Should-BeLikeString '*For consumers*'
    }
    It 'catches notes that drifted from the changelog' {
        # The exact failure this gate exists for: the two were edited separately.
        $a = $script:Good.Clone(); $a.ActualNotes = '1.2.3: Something else entirely.'
        (@(Get-PSCxReleaseFault @a) -join ' ') | Should-BeLikeString '*do not match the CHANGELOG*'
    }
    It 'refuses a changelog with no released version, and says so first' {
        $a = $script:Good.Clone(); $a.ChangelogVersion = $null
        (@(Get-PSCxReleaseFault @a) -join ' ') | Should-BeLikeString '*no released version heading*'
    }
    It 'reports BOTH a version mismatch and a missing block in one run' {
        # Collected rather than thrown one at a time: a release is prepared by hand, and
        # finding the second fault only after fixing the first costs another full run.
        $a = $script:Good.Clone(); $a.ModuleVersion = '9.9.9'; $a.ConsumerNotes = ''
        @(Get-PSCxReleaseFault @a).Count | Should-Be 2
    }
}

Describe 'Get-PSCxPinValue' {
    BeforeAll {
        $script:Pins = @(
            '# a comment'
            ''
            'PSSA_VERSION=1.25.0'
            'PSSA_PATHS=./src ./tests ./tools'
            '#PSSA_VERSION=9.9.9'
            'ODD=a=b'
        )
    }

    It 'reads a simple value' {
        Get-PSCxPinValue -Line $script:Pins -Name 'PSSA_VERSION' | Should-Be '1.25.0'
    }
    It 'keeps a value containing spaces, because PSSA_PATHS is a list' {
        Get-PSCxPinValue -Line $script:Pins -Name 'PSSA_PATHS' | Should-Be './src ./tests ./tools'
    }
    It 'splits on the FIRST equals only' {
        # A value may legitimately contain one. Splitting on all of them silently truncates.
        Get-PSCxPinValue -Line $script:Pins -Name 'ODD' | Should-Be 'a=b'
    }
    It 'ignores a commented-out key rather than reading it' {
        # Paired with the first test: the same key appears commented below, and reading it
        # would pin the analyzer to a version nobody chose.
        Get-PSCxPinValue -Line $script:Pins -Name 'PSSA_VERSION' | Should-Be '1.25.0'
    }
    It 'matches the key in full' {
        # PSSA_VERSION must not answer for PSSA, or a prefix silently wins.
        Get-PSCxPinValue -Line $script:Pins -Name 'PSSA' | Should-BeNull
    }
    It 'returns null for a key that is not there' {
        # The caller turns this into an error. If it returned an empty string instead, the
        # analyzer gate would scan nothing and pass.
        Get-PSCxPinValue -Line $script:Pins -Name 'NOPE' | Should-BeNull
    }
    It 'survives a file of only blank lines and comments' {
        Get-PSCxPinValue -Line @('', '# x', '   ') -Name 'ANY' | Should-BeNull
    }
}

Describe 'Get-PSCxVersionListFault' {
    BeforeAll {
        # One shape reused: three legs at 5.0/5.1/6.0, and a feed that has more.
        $script:ours = @('5.0.4', '5.1.1', '6.0.1')
        $script:feed = @('4.9.0', '5.0.1', '5.0.4', '5.1.0', '5.1.1', '6.0.0', '6.0.1')
    }

    It 'says nothing when every leg is the newest patch of its minor' {
        # The kept case. Without it every assertion below would pass against a function that
        # returned a fault for everything.
        @(Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available $script:feed).Count | Should-Be 0
    }

    It 'reports a leg that is no longer the newest patch of its minor' {
        (Get-PSCxVersionListFault -Name 'X' -Ours @('5.0.1', '5.1.1', '6.0.1') -Available $script:feed) -join ' ' |
            Should-BeLikeString '*PATCH: X leg 5.0.1 is superseded by 5.0.4*'
    }

    It 'reports a released minor that no leg covers' {
        (Get-PSCxVersionListFault -Name 'X' -Ours @('5.0.4', '6.0.1') -Available $script:feed) -join ' ' |
            Should-BeLikeString '*MINOR: X 5.1 has been released*'
    }

    It 'reports a whole major that nothing tests' {
        (Get-PSCxVersionListFault -Name 'X' -Ours @('5.0.4', '5.1.1') -Available $script:feed) -join ' ' |
            Should-BeLikeString '*MAJOR: X 6.x exists*'
    }

    It 'ignores everything below the lowest leg' {
        # The floor. The feed holds 4.9.0 and the promise starts at 5.0 -- reporting it would be a
        # gap in a range the module never claimed, and the first run of this check did exactly that
        # for two whole Pester majors.
        (Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available $script:feed) -join ' ' |
            Should-NotBeLikeString '*4.9*'
    }

    It 'honours an exemption for a minor nobody covers' {
        @(Get-PSCxVersionListFault -Name 'X' -Ours @('5.0.4', '6.0.1') -Available $script:feed -ExemptMinor @('5.1')).Count |
            Should-Be 0
    }

    It 'refuses an exemption for a version that was never released' {
        (Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available $script:feed -ExemptMinor @('9.9')) -join ' ' |
            Should-BeLikeString '*EXEMPTION: X 9.9 is exempted but has never been released*'
    }

    It 'refuses an exemption for a minor that IS covered' {
        # Both halves of a contradiction are faults, because either one alone is a lie about the
        # list: an exemption that is also tested has stopped describing anything, exactly like a
        # stale equivalence declaration.
        (Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available $script:feed -ExemptMinor @('5.1')) -join ' ' |
            Should-BeLikeString '*exempted and also covered by a leg*'
    }

    It 'reports an unreachable feed rather than reading silence as good news' {
        (Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available @()) -join ' ' |
            Should-BeLikeString '*could not be checked*'
    }

    It 'reports an empty list rather than passing over nothing' {
        (Get-PSCxVersionListFault -Name 'X' -Ours @() -Available $script:feed) -join ' ' |
            Should-BeLikeString '*no compatibility versions pinned*'
    }

    It 'survives a prerelease string in the feed' {
        # A gallery feed answers with things like 6.2.0-beta1, which [version] refuses outright. One
        # such entry must not fail the whole check -- and its MINOR still counts as released.
        (Get-PSCxVersionListFault -Name 'X' -Ours $script:ours -Available ($script:feed + '6.2.0-beta1')) -join ' ' |
            Should-BeLikeString '*MINOR: X 6.2*'
    }
}

Describe 'the pins file itself' {
    It 'declares every key the workflows require' {
        # The workflows assert this at run time; asserting it here means a missing pin fails
        # in the suite rather than five minutes into a job.
        $pins = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/pins.env')
        foreach ($k in 'PESTER_VERSION', 'PESTER_COMPAT_VERSIONS', 'PSSA_VERSION',
            'PS_COMPAT_VERSIONS', 'PSMUTANT_VERSION', 'CONVERTTOSARIF_VERSION', 'PSSA_PATHS') {
            Get-PSCxPinValue -Line $pins -Name $k | Should-NotBeNull -Because "pins.env must define $k"
        }
    }
    It 'lists a compatibility version for every supported Pester minor' {
        # The gate proves whatever this list names, so the list IS the compatibility claim. A leg
        # silently dropped here would narrow the promise without narrowing what the README says,
        # and the run would stay green -- which is the shape this project refuses elsewhere.
        #
        # Minors, not the exact patches: a patch may be superseded and the pin bumped, but a whole
        # minor disappearing means a range nobody tests any more.
        $pins = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/pins.env')
        $versions = @((Get-PSCxPinValue -Line $pins -Name 'PESTER_COMPAT_VERSIONS') -split ' ' | Where-Object { $_ })
        $minors = @($versions | ForEach-Object { $v = [version]$_; "$($v.Major).$($v.Minor)" })

        # No exact-version assertion here, deliberately. Every leg is the newest patch of its minor,
        # including the floor's, so pinning one exactly would freeze the single leg the rule says
        # should move -- and the rule is what this test defends. The floor's MINOR is in the list
        # below like any other.
        foreach ($m in '5.0', '5.1', '5.2', '5.3', '5.4', '5.5', '5.6', '5.7', '5.8', '5.9', '6.0', '6.1') {
            $minors | Should-ContainCollection $m -Because "no leg covers Pester $m"
        }
    }
    It 'lists a PowerShell version for every supported minor' {
        # The manifest's PowerShellVersion is the floor consumers are told; this list is what
        # executes against it. A minor quietly dropped here narrows what is proven without
        # narrowing what is promised, and the run stays green.
        #
        # The floor itself must be covered by its own minor, and the ceiling is open on purpose:
        # the runners' PowerShell is newer than anything listed and the ordinary suite covers it.
        $pins = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) '.github/pins.env')
        $versions = @((Get-PSCxPinValue -Line $pins -Name 'PS_COMPAT_VERSIONS') -split ' ' | Where-Object { $_ })
        $minors = @($versions | ForEach-Object { $v = [version]$_; "$($v.Major).$($v.Minor)" })

        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSComplexity.psd1')
        $floor = [version]$manifest.PowerShellVersion
        $minors | Should-ContainCollection "$($floor.Major).$($floor.Minor)" -Because 'the declared floor must be one of the versions actually run'
        foreach ($m in '7.0', '7.1', '7.2', '7.3', '7.4', '7.5') {
            $minors | Should-ContainCollection $m -Because "no leg covers PowerShell $m"
        }
    }
    It 'names only paths that exist' {
        # An entry naming a moved directory makes the analyzer refuse rather than scan less,
        # but only because it checks; this catches it a step earlier.
        $root = Split-Path -Parent $PSScriptRoot
        $pins = Get-Content (Join-Path $root '.github/pins.env')
        foreach ($p in (Get-PSCxPinValue -Line $pins -Name 'PSSA_PATHS') -split ' ') {
            Test-Path (Join-Path $root $p) | Should-BeTrue -Because "PSSA_PATHS names $p"
        }
    }
}

Describe 'Get-PSCxLintFault' {
    It 'passes a run that found nothing' {
        Should-BeNull -Actual (Get-PSCxLintFault -FindingCount 0)
    }

    It 'fails on a single finding' {
        # One, not many. No -Severity filter reaches the analyzer and rules are excluded by name
        # with a reason, so anything reported at all is a rule somebody decided to keep -- a gate
        # needing two would let every lone Information-severity finding through.
        Get-PSCxLintFault -FindingCount 1 | Should-BeLikeString '*lint gate failed*'
    }

    It 'says how many it found' {
        # A failure without a number sends the reader back to run it again to size the work.
        Get-PSCxLintFault -FindingCount 4 | Should-BeLikeString '*4 PSScriptAnalyzer finding*'
    }
}

Describe 'Get-PSCxTestRunFault' {
    It 'says nothing about a run where every container passed' {
        Get-PSCxTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Passed') -ContainerName @('a', 'b') |
            Should-BeNull
    }

    It 'reports failing tests, and reports them FIRST' {
        # When a test genuinely fails its container is 'Failed' too. "3 tests failed" is the
        # better answer; "a file did not run" would send the reader to the wrong place.
        Get-PSCxTestRunFault -FailedCount 3 -ContainerResult @('Failed') -ContainerName @('a') |
            Should-BeLikeString '*3 test(s) failed*'
    }

    It 'catches a file that never ran, which FailedCount cannot see' {
        # The whole point. A test file with a parse error contributes zero tests and zero
        # failures, so every gate asking only about FailedCount reports green.
        Get-PSCxTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Failed') -ContainerName @('ok.Tests.ps1', 'broken.Tests.ps1') |
            Should-BeLikeString '*broken.Tests.ps1*'
    }

    It 'allows a deliberately skipped container' {
        # Paired with the case above: treating every non-Passed result as a fault would make
        # a legitimate -Skip fail the build, and the fix would be to remove the check.
        Get-PSCxTestRunFault -FailedCount 0 -ContainerResult @('Passed', 'Skipped') -ContainerName @('a', 'b') |
            Should-BeNull
    }

    It 'names every unrun file, not just the first' {
        (Get-PSCxTestRunFault -FailedCount 0 -ContainerResult @('Failed', 'Failed') -ContainerName @('x.Tests.ps1', 'y.Tests.ps1')) |
            Should-BeLikeString '*x.Tests.ps1, y.Tests.ps1*'
    }
}

Describe 'Get-PSCxProcessStateFault' {
    It 'says nothing about a run that put everything back' {
        $m = @{ 'env:PATH' = '/usr/bin'; 'env:HOME' = '/home/x' }
        Get-PSCxProcessStateFault -Before $m -After @{ 'env:PATH' = '/usr/bin'; 'env:HOME' = '/home/x' } |
            Should-BeNull
    }

    It 'says nothing when there was nothing to compare' {
        # Paired with the case above rather than left out: an empty environment must read as
        # clean, not as every variable having been removed.
        Get-PSCxProcessStateFault -Before @{} -After @{} | Should-BeNull
    }

    It 'names a variable the run added' {
        Get-PSCxProcessStateFault -Before @{} -After @{ 'env:PSCX_LEAK' = '1' } |
            Should-BeLikeString '*added: env:PSCX_LEAK*'
    }

    It 'names a variable the run removed' {
        # The sibling's actual failure was this one: an AfterEach cleared a variable and never
        # put it back, so every file after it ran in a different environment.
        Get-PSCxProcessStateFault -Before @{ 'env:GITHUB_ACTIONS' = 'true' } -After @{} |
            Should-BeLikeString '*removed: env:GITHUB_ACTIONS*'
    }

    It 'names a variable the run changed' {
        Get-PSCxProcessStateFault -Before @{ 'env:TERM' = 'xterm' } -After @{ 'env:TERM' = 'dumb' } |
            Should-BeLikeString '*changed: env:TERM*'
    }

    It 'treats a change of CASE as a change' {
        # The comparison is -cne, not -ne. A case-insensitive compare calls 'true' and 'True'
        # equal, and a variable whose value is read case-sensitively downstream is then reported
        # as untouched. The one input that tells the two operators apart.
        Get-PSCxProcessStateFault -Before @{ 'env:CI' = 'true' } -After @{ 'env:CI' = 'TRUE' } |
            Should-BeLikeString '*changed: env:CI*'
    }

    It 'withholds the values' {
        # Not tidiness. An environment variable holds tokens as often as it holds flags, and
        # this message is printed into a build log that anybody can read. The key says which
        # variable; the value would say what it was.
        $fault = Get-PSCxProcessStateFault -Before @{ 'env:TOKEN' = 'ghp_secret' } `
            -After @{ 'env:TOKEN' = 'ghp_other' }
        $fault | Should-BeLikeString '*env:TOKEN*'
        $fault | Should-NotBeLikeString '*ghp_secret*'
        $fault | Should-NotBeLikeString '*ghp_other*'
    }

    It 'reports all three kinds at once, and every key in each' {
        # One fault per run, so a message that stopped at the first kind would send the reader
        # back for another round per variable.
        $fault = Get-PSCxProcessStateFault `
            -Before @{ 'env:GONE_A' = '1'; 'env:GONE_B' = '1'; 'env:SAME' = 'x'; 'env:MOVED' = 'x' } `
            -After @{ 'env:SAME' = 'x'; 'env:MOVED' = 'y'; 'env:NEW' = '1' }
        $fault | Should-BeLikeString '*added: env:NEW*'
        $fault | Should-BeLikeString '*removed: env:GONE_A, env:GONE_B*'
        $fault | Should-BeLikeString '*changed: env:MOVED*'
        $fault | Should-NotBeLikeString '*env:SAME*'
    }
}

Describe 'main must not claim a version that already shipped' {
    # It once did: main stood at 0.2.0, 0.2.0 was on the gallery, and merged work sat under
    # [Unreleased] with every gate passing. Two people installing "0.2.0" -- one from the
    # gallery, one from a clone -- got different code, and nothing in the repo could tell
    # them apart.

    It 'faults when a published version has unreleased entries above it' {
        Get-PSCxStaleVersionFault -ModuleVersion '0.2.0' -IsPublished $true -HasUnreleasedContent $true |
            Should-MatchString ([regex]::Escape('already on the gallery'))
    }

    It 'is silent when a published version has nothing unreleased' {
        # The resting state between releases, and the first of two kept cases. Without it a
        # gate that faults on IsPublished alone would fail every green main.
        Should-BeNull -Actual (Get-PSCxStaleVersionFault -ModuleVersion '0.2.0' -IsPublished $true -HasUnreleasedContent $false)
    }

    It 'is silent when unreleased entries sit above a version not yet shipped' {
        # The second kept case: a release being prepared. Faulting here would refuse exactly
        # the state this repo is in while writing a release.
        Should-BeNull -Actual (Get-PSCxStaleVersionFault -ModuleVersion '0.5.0' -IsPublished $false -HasUnreleasedContent $true)
    }

    It 'reads content under [Unreleased] and stops at the next heading' {
        $lines = @('# CL', '', '## [Unreleased]', '', '### Fixed', '- a thing', '', '## [0.4.0] - 2026-08-23', '- x')
        Should-BeTrue -Actual (Test-PSCxHasUnreleasedContent -Lines $lines)
    }

    It 'treats a whitespace-only [Unreleased] as empty' {
        # Blank lines are how the section looks between releases; counting them as content
        # would fault every repo that keeps the heading in place.
        $lines = @('# CL', '', '## [Unreleased]', '', '   ', '', '## [0.4.0] - 2026-08-23', '- x')
        Should-BeFalse -Actual (Test-PSCxHasUnreleasedContent -Lines $lines)
    }

    It 'does not mistake a later version body for unreleased content' {
        # The discriminating case: entries exist in the file, but below the next heading. A
        # scan that forgets to stop would report every changelog as having unreleased work.
        $lines = @('# CL', '', '## [Unreleased]', '', '## [0.4.0] - 2026-08-23', '', '### Fixed', '- a released thing')
        Should-BeFalse -Actual (Test-PSCxHasUnreleasedContent -Lines $lines)
    }

    It 'is false when there is no [Unreleased] heading at all' {
        $lines = @('# CL', '', '## [0.4.0] - 2026-08-23', '- x')
        Should-BeFalse -Actual (Test-PSCxHasUnreleasedContent -Lines $lines)
    }
}

Describe 'a pin is watched, not just written down' {
    # A pin is a decision that was correct on the day it was made. Nothing watched them, and
    # the failure is asymmetric: a stale pin never breaks the build, it just quietly stops
    # protecting you. The PSMutant pin sat at 0.1.0 across two majors -- one of which fixed a
    # bug that scored EVERY mutant killed -- and CI was green throughout.

    It 'reports a pin the gallery has moved past' {
        Get-PSCxStalePinFault -Name 'Pester' -Pinned '5.0.0' -Latest '6.1.0' |
            Should-MatchString ([regex]::Escape('6.1.0 is available'))
    }

    It 'says nothing when the pin is the newest release' {
        # First kept case. Without it, a checker that faulted on every pin would pass the
        # test above and file an issue every week about nothing.
        Should-BeNull -Actual (Get-PSCxStalePinFault -Name 'Pester' -Pinned '6.1.0' -Latest '6.1.0')
    }

    It 'says nothing when the pin is ahead of the gallery' {
        # Second kept case, and not hypothetical: a prerelease or a yanked version leaves the
        # pin ahead, and a string comparison would call 6.1.0 newer than 10.0.0.
        Should-BeNull -Actual (Get-PSCxStalePinFault -Name 'Pester' -Pinned '10.0.0' -Latest '6.1.0')
    }

    It 'reports an unreachable gallery as unknown, not as current' {
        # The one that decides whether this is worth having. Find-Module returns nothing both
        # when a module is current and when the gallery cannot be reached; treating those
        # alike would make every run report all-clear -- a watcher that has silently stopped
        # being able to fail.
        Get-PSCxStalePinFault -Name 'Pester' -Pinned '6.1.0' -Latest '' |
            Should-MatchString 'freshness is unknown'
    }

    It 'reports a module with no pin at all' {
        Get-PSCxStalePinFault -Name 'Pester' -Pinned '' -Latest '6.1.0' |
            Should-MatchString 'no pinned version'
    }

    It 'watches every module the workflows install' {
        # The list in the checker and the keys in pins.env must not drift apart: a module
        # installed by CI and absent from the watcher is exactly the pin that goes stale.
        $script = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Test-PSCxPinFreshness.ps1') -Raw
        foreach ($key in 'PESTER_VERSION', 'PSSA_VERSION', 'PSMUTANT_VERSION', 'CONVERTTOSARIF_VERSION') {
            $script | Should-MatchString ([regex]::Escape($key))
        }
    }
}
