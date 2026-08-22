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
