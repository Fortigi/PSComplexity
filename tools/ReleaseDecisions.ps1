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

function Get-PSCxStaleVersionFault {
    <#
    .SYNOPSIS
        The fault, if any, when main claims a version that has already shipped.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$ModuleVersion,
        [Parameter(Mandatory)] [bool]$IsPublished,
        [Parameter(Mandatory)] [bool]$HasUnreleasedContent
    )
    # The question that stays open after ModuleVersion, the newest heading and ReleaseNotes
    # all agree: HAS the version they agree on already shipped? It once had -- main stood at
    # 0.2.0 with 0.2.0 on the gallery and merged work sitting under [Unreleased], and every
    # gate passed. Two people installing "0.2.0", one from the gallery and one from a clone,
    # got different code with nothing in the repo able to tell them apart.
    #
    # BOTH conditions, because either alone is a normal state. Sitting on a published version
    # with nothing unreleased is exactly where a repo rests between releases; unreleased work
    # under a version not yet shipped is a release being prepared. Only the pair is wrong.
    if (-not $IsPublished) { return $null }
    if (-not $HasUnreleasedContent) { return $null }
    return ("ModuleVersion $ModuleVersion is already on the gallery, and CHANGELOG.md has " +
        "unreleased entries above it. Anyone installing $ModuleVersion gets different code " +
        "depending on whether they took it from the gallery or from this repository. Bump " +
        "ModuleVersion and give the entries their own heading.")
}

function Test-PSCxHasUnreleasedContent {
    <#
    .SYNOPSIS
        Whether the [Unreleased] heading has anything under it.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines)
    # Scanned in one pass, in the same style as Get-PSCxConsumerNotes: enter at the
    # [Unreleased] heading, leave at the next `## [` heading of any kind.
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -match '^##\s*\[Unreleased\]') { $inside = $true; continue }
        if ($inside -and $line -match '^##\s*\[') { return $false }
        # Any non-blank line counts. A section holding only whitespace is the resting state
        # between releases and must not read as pending work.
        if ($inside -and -not [string]::IsNullOrWhiteSpace($line)) { return $true }
    }
    return $false
}

function Get-PSCxStalePinFault {
    <#
    .SYNOPSIS
        The fault, if any, when a pinned module has a newer release available.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Pinned,
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string]$Latest
    )
    # A pin is a decision that was correct on the day it was made. Without a watcher it decays
    # into a decision nobody is making, and the failure is asymmetric: a stale pin never breaks
    # the build, it just quietly stops protecting you. The PSMutant pin sat at 0.1.0 across two
    # majors -- one of which fixed a bug that scored EVERY mutant killed -- and CI was green
    # throughout.
    if ([string]::IsNullOrWhiteSpace($Pinned)) { return "$Name has no pinned version in .github/pins.env." }
    # "Could not look" is not "nothing newer". Reported as its own fault, because a checker
    # that treats an unreachable gallery as good news stops being able to fail at all.
    if ([string]::IsNullOrWhiteSpace($Latest)) {
        return "$Name is pinned at $Pinned and the gallery did not answer, so freshness is unknown."
    }
    $p = [version]$Pinned
    $l = [version]$Latest
    if ($l -le $p) { return $null }
    return "$Name is pinned at $Pinned; $Latest is available."
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

function Get-PSCxLintFault {
    <#
    .SYNOPSIS
        Why the lint gate should fail, or $null if it should pass.
    .DESCRIPTION
        One finding is enough. No -Severity filter reaches the analyzer: rules are excluded by
        NAME in PSScriptAnalyzerSettings.psd1, each with a reason, so anything still reported is
        a rule somebody decided to keep. A gate needing two would let every lone
        Information-severity finding through.

        A count rather than the findings themselves, because the decision is arithmetic and the
        rendering is the caller's business.
    .OUTPUTS
        [string] the reason, or $null.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int]$FindingCount)
    if ($FindingCount -gt 0) {
        return "$FindingCount PSScriptAnalyzer finding(s) - lint gate failed"
    }
    return $null
}

function Get-PSCxTestRunFault {
    # Why a Pester run must not be treated as green, or $null when it may be.
    #
    # FailedCount alone is not enough, and that is the whole reason this exists. A test file
    # that fails to PARSE contributes zero tests and zero failures: the run reports
    # "passed=87 failed=0" while an entire file never executed, and every gate that asks
    # only about FailedCount says yes. Observed, not theorised -- one dropped brace in a
    # merge resolution hid 42 tests behind a green result.
    #
    # Pure so it can be tested without running Pester, because a gate that quietly stops
    # being able to fail looks exactly like a gate with nothing to report.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$FailedCount,
        # Container results, one string each: 'Passed', 'Failed', 'Skipped'...
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ContainerResult,
        # Names for the message, aligned with $ContainerResult.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ContainerName
    )
    # Failures first: when a test genuinely fails its container is 'Failed' too, and
    # "3 tests failed" is a better answer than "a file did not run".
    if ($FailedCount -gt 0) { return "$FailedCount test(s) failed." }

    $unrun = @()
    for ($i = 0; $i -lt $ContainerResult.Count; $i++) {
        # Skipped is legitimate -- a container can be filtered out deliberately. Anything
        # else with no failures behind it means the file did not run at all.
        if ($ContainerResult[$i] -ne 'Passed' -and $ContainerResult[$i] -ne 'Skipped') {
            $unrun += $(if ($i -lt $ContainerName.Count) { $ContainerName[$i] } else { "container $i" })
        }
    }
    if ($unrun.Count -gt 0) {
        return ("$($unrun.Count) test file(s) reported no failures because they never ran: " +
            ($unrun -join ', ') + '. A parse error in a test file looks exactly like a green suite.')
    }
    return $null
}
