# The pass/fail decisions behind the release gate, as pure functions over text.
#
# They live apart from the script that reads the files because a gate that quietly stops
# being able to fail looks exactly like a green build, and these are the checks standing
# between a hand-edited manifest and a gallery version that cannot be withdrawn. String
# comparison is free to test; it is also where an inversion hides.

function Get-PSCxNewestVersion {
    # The newest released version in the changelog: the first `## [x.y.z]` heading, skipping
    # `## [Unreleased]`, which is not a version and must never be mistaken for one.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^##\s*\[(\d+\.\d+\.\d+)\]') { return $Matches[1] }
    }
    return $null
}

function Get-PSCxConsumerNotes {
    # The `### For consumers` block under a given version heading, as one line.
    #
    # Returns $null when the version has no such block, so the caller can refuse rather than
    # publish an empty field. A gate that treats "absent" as "nothing to check" is the shape
    # this whole script exists to remove.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Notes is a mass noun and names the manifest field these become. A singular "ConsumerNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines,
        [Parameter(Mandatory)] [string]$Version
    )
    $inVersion = $false
    $inBlock = $false
    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -match '^##\s*\[') {
            # A new version heading ends the previous one. Reached while collecting, it
            # means the block ran to the end of its section.
            if ($inBlock) { break }
            $inVersion = $line -match ('^##\s*\[' + [regex]::Escape($Version) + '\]')
            continue
        }
        if (-not $inVersion) { continue }
        if ($line -match '^###\s') {
            if ($inBlock) { break }
            $inBlock = $line -match '^###\s+For consumers\s*$'
            continue
        }
        if ($inBlock) { $body.Add($line) }
    }
    if (-not $inBlock -and $body.Count -eq 0) { return $null }

    # Collapse to one line: the manifest field is a single string, and a newline in it does
    # not survive being read back off the gallery page.
    #
    # It also keeps the release gate platform-independent, which is not obvious and is worth
    # knowing before someone preserves the newlines here. Git rewrites line endings inside a
    # stored string on checkout, so a multi-line value reads LF on a Linux runner and CRLF on
    # a Windows one and an exact comparison then reports on the checkout rather than the
    # release. That bit the sibling repo -- CI green, gate red on every maintainer machine.
    # .gitattributes pins eol=lf so the cause is gone either way.
    $text = ($body -join ' ') -replace '\s+', ' '
    return $text.Trim()
}

function Get-PSCxExpectedReleaseNotes {
    # What the manifest's ReleaseNotes must contain, derived from the changelog. Prefixed
    # with the version so a reader of the gallery page knows which release they are looking
    # at without cross-referencing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'ReleaseNotes is the name of the manifest field this produces. A singular "ReleaseNote" would name something that does not exist.')]
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [string]$Notes,
        [AllowEmptyString()] [string]$DetailUrl
    )
    $text = "${Version}: $Notes"

    # A link, because this field is read where a browser may not be -- `Find-Module | Select
    # ReleaseNotes` in a console -- and the summary has to stand alone there while still
    # leading somewhere complete. Appended rather than substituted for that reason.
    if (-not [string]::IsNullOrWhiteSpace($DetailUrl)) { $text += " Full changelog: $DetailUrl" }
    return $text
}

function Get-PSCxReleaseFault {
    # Every disagreement between the three sources, as sentences. Empty means consistent.
    #
    # All of them are collected rather than thrown one at a time, because a release is
    # prepared by hand and finding the second fault only after fixing the first costs
    # another full run.
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ModuleVersion,
        [AllowNull()] [string]$ChangelogVersion,
        [AllowNull()] [string]$ConsumerNotes,
        [AllowNull()] [string]$ActualNotes,
        [AllowEmptyString()] [string]$DetailUrl
    )
    $faults = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($ChangelogVersion)) {
        $faults.Add('CHANGELOG.md has no released version heading. Expected a line like "## [1.2.3] - date".')
        return $faults.ToArray()
    }
    if ($ModuleVersion -ne $ChangelogVersion) {
        $faults.Add("ModuleVersion is $ModuleVersion but the newest CHANGELOG heading is $ChangelogVersion. " +
            'Publishing would ship one version described by another.')
    }
    if ([string]::IsNullOrWhiteSpace($ConsumerNotes)) {
        $faults.Add("CHANGELOG.md has no '### For consumers' block under [$ChangelogVersion]. " +
            'That block is the source of the published release notes, so without it the gallery ' +
            'entry would say nothing about what changed.')
        return $faults.ToArray()
    }

    $expected = Get-PSCxExpectedReleaseNotes -Version $ChangelogVersion -Notes $ConsumerNotes -DetailUrl $DetailUrl
    if ($ActualNotes -ne $expected) {
        $faults.Add('The manifest ReleaseNotes do not match the CHANGELOG. Run ' +
            './tools/Test-PSCxRelease.ps1 -Apply to regenerate them from the changelog, which is the source.')
    }
    return $faults.ToArray()
}

function Get-PSCxRewrittenManifest {
    # The manifest TEXT with only its ReleaseNotes value replaced. Returns a string and writes
    # nothing -- the caller decides whether to save it.
    #
    # Not Update-ModuleManifest: that regenerates the whole file from the data it parsed, so
    # the hand-written layout goes, a "Generated on <today>" stamp appears that churns on
    # every run, and any comment explaining WHY a setting is what it is -- the kind a manifest
    # most needs -- is gone. A release note is one string; changing it should touch one string.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ManifestText,
        [Parameter(Mandatory)] [string]$Notes
    )
    # PowerShell escapes a literal quote inside a single-quoted string by doubling it.
    $literal = "'" + ($Notes -replace "'", "''") + "'"
    $pattern = "(?s)(ReleaseNotes\s*=\s*)'.*?'(?=\s*(?
|\}))"
    if ($ManifestText -notmatch $pattern) {
        throw 'Manifest has no single-quoted ReleaseNotes value to replace.'
    }
    return [regex]::Replace($ManifestText, $pattern, { param($m) $m.Groups[1].Value + $literal }, 1)
}


function Get-PSCxPinValue {
    # The value of one key in .github/pins.env, or $null when it is not there.
    #
    # A decision rather than plumbing, and the reason it is tested: the analyzer gate derives
    # the paths it scans from PSSA_PATHS. A parser that quietly returns nothing makes that
    # gate scan NOTHING and pass -- green, fast, and blind.
    #
    # Split on the FIRST '=' only. Values legitimately contain both '=' and spaces, since
    # PSSA_PATHS is a space-separated list. Comment and blank lines are ignored, and the key
    # must match in full so PSSA_VERSION does not answer for PSSA_VERSION_EXTRA.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # AllowEmptyString as well as AllowEmptyCollection: pins.env has blank lines, and a
        # Mandatory [string[]] otherwise refuses the whole file over one of them.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Line,
        [Parameter(Mandatory)] [string]$Name
    )
    foreach ($l in $Line) {
        $trimmed = $l.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        $split = $trimmed.IndexOf('=')
        if ($split -lt 1) { continue }
        if ($trimmed.Substring(0, $split) -ne $Name) { continue }
        return $trimmed.Substring($split + 1).Trim()
    }
    return $null
}
