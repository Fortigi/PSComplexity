# Release consistency gate: ModuleVersion, the newest CHANGELOG heading and the published
# ReleaseNotes must agree, and the CHANGELOG is the source of the notes rather than a second
# copy of them.
#
# A gallery version cannot be withdrawn, only unlisted, so this is the last check before an
# irreversible step. It runs in ci.yml as well as publish.yml on purpose: drift is introduced
# by the PR that edits one of the three, and failing there is cheaper than failing at the tag.
#
# -Apply regenerates the manifest field from the changelog. Without it the script only reports,
# so CI can never rewrite what it is meant to be checking.
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ManifestPath,
    [string]$ChangelogPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReleaseDecisions.ps1')

$repo = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $repo 'PSComplexity.psd1' }
if (-not $ChangelogPath) { $ChangelogPath = Join-Path $repo 'CHANGELOG.md' }

foreach ($p in $ManifestPath, $ChangelogPath) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Release gate cannot run: '$p' does not exist." }
}

$lines = @(Get-Content -LiteralPath $ChangelogPath)
$manifest = Import-PowerShellDataFile -LiteralPath $ManifestPath
$moduleVersion = [string]$manifest.ModuleVersion
$actual = [string]$manifest.PrivateData.PSData.ReleaseNotes

# Derived from ProjectUri rather than written out, so the repository is named in one place
# and a fork does not publish a link back to this one.
$projectUri = [string]$manifest.PrivateData.PSData.ProjectUri
$detailUrl = if ($projectUri) { "$($projectUri.TrimEnd('/'))/blob/main/CHANGELOG.md" } else { '' }

$changelogVersion = Get-PSCxNewestVersion -Lines $lines
$notes = if ($changelogVersion) { Get-PSCxConsumerNotes -Lines $lines -Version $changelogVersion } else { $null }

if ($Apply) {
    if (-not $changelogVersion) { throw 'Cannot apply: CHANGELOG.md has no released version heading.' }
    if ([string]::IsNullOrWhiteSpace($notes)) {
        throw "Cannot apply: CHANGELOG.md has no '### For consumers' block under [$changelogVersion]."
    }
    $expected = Get-PSCxExpectedReleaseNotes -Version $changelogVersion -Notes $notes -DetailUrl $detailUrl
    Update-ModuleManifest -Path $ManifestPath -ReleaseNotes $expected
    $check = [string](Import-PowerShellDataFile -LiteralPath $ManifestPath).PrivateData.PSData.ReleaseNotes
    if ($check -ne $expected) { throw 'ReleaseNotes did not survive the manifest update.' }
    Write-Output "Applied $($expected.Length) chars of release notes for $changelogVersion."
    return
}

$faults = @(Get-PSCxReleaseFault -ModuleVersion $moduleVersion -ChangelogVersion $changelogVersion `
        -ConsumerNotes $notes -ActualNotes $actual -DetailUrl $detailUrl)
if ($faults.Count -gt 0) {
    foreach ($f in $faults) { Write-Output "RELEASE FAULT: $f" }
    throw "$($faults.Count) release consistency fault(s)."
}
Write-Output "Release consistent: $moduleVersion, notes $($actual.Length) chars, from CHANGELOG.md."
