<#
.SYNOPSIS
    Report pinned modules that have a newer release on the PowerShell Gallery.

.DESCRIPTION
    A pin is a decision that was correct on the day it was made. Nothing here watched them, and
    the failure mode is asymmetric: a stale pin never breaks the build, it just quietly stops
    protecting you. The PSMutant pin sat at 0.1.0 across two majors -- one of which fixed a bug
    that scored every mutant killed -- and CI was green throughout. It was found by reading the
    file.

    Reports rather than throws, because a stale pin is a decision to make, not a build to
    break. The scheduled workflow turns the output into an issue.

.OUTPUTS
    [string[]] one sentence per stale or unverifiable pin. Empty means every pin is current.
#>
[CmdletBinding()]
[OutputType([string[]])]
param([string]$PinsPath)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'ReleaseDecisions.ps1')
$repo = Split-Path -Parent $PSScriptRoot
if (-not $PinsPath) { $PinsPath = Join-Path $repo '.github/pins.env' }
if (-not (Test-Path -LiteralPath $PinsPath)) { throw "Cannot check pins: '$PinsPath' does not exist." }

$pins = Get-Content -LiteralPath $PinsPath
# Name in the gallery -> key in pins.env. Both Pester keys point at the same module: the estate
# pin and the compatibility pin are different decisions and go stale independently.
$watched = [ordered]@{
    'Pester'           = 'PESTER_VERSION'
    'PSScriptAnalyzer' = 'PSSA_VERSION'
    'PSMutant'         = 'PSMUTANT_VERSION'
    'ConvertToSARIF'   = 'CONVERTTOSARIF_VERSION'
}

$faults = [System.Collections.Generic.List[string]]::new()
foreach ($name in $watched.Keys) {
    $pinned = Get-PSCxPinValue -Line $pins -Name $watched[$name]
    $latest = ''
    try {
        $found = Find-Module -Name $name -ErrorAction Stop
        $latest = [string]$found.Version
    }
    catch {
        # Left empty on purpose: the decision function reports "could not look" as its own
        # fault rather than as good news.
        Write-Verbose "Find-Module failed for ${name}: $($_.Exception.Message)"
    }
    $fault = Get-PSCxStalePinFault -Name $name -Pinned $pinned -Latest $latest
    if ($fault) { $faults.Add($fault) }
}
# --- the LISTS ------------------------------------------------------------------------------------
# A single pin and a per-minor list go stale differently, so they are asked different questions. The
# loop above asks "is something newer out?"; this asks three, because the list IS the compatibility
# claim and an open-ended minimum promises every future release.
$lists = @(
    @{ Name = 'Pester'; Key = 'PESTER_COMPAT_VERSIONS'; ExemptKey = 'PESTER_COMPAT_EXEMPT_MINORS'; Source = 'gallery' }
    @{ Name = 'PowerShell'; Key = 'PS_COMPAT_VERSIONS'; ExemptKey = 'PS_COMPAT_EXEMPT_MINORS'; Source = 'github' }
)
foreach ($list in $lists) {
    $ours = @((Get-PSCxPinValue -Line $pins -Name $list.Key) -split ' ' | Where-Object { $_ })
    $exempt = @((Get-PSCxPinValue -Line $pins -Name $list.ExemptKey) -split ' ' | Where-Object { $_ })
    $available = @()
    try {
        if ($list.Source -eq 'gallery') {
            $available = @(Find-Module -Name $list.Name -AllVersions -ErrorAction Stop | ForEach-Object { [string]$_.Version })
        }
        else {
            # PowerShell is a RUNTIME, not a gallery module, so its releases come from where the
            # compatibility gate downloads them. Prereleases are excluded: a leg pins something
            # installable, and reporting a beta as an uncovered minor would be noise every month.
            #
            # PAGED, and that is not tidiness. One page of 100 reaches back only to 7.2.3 -- so a
            # single request cannot see 7.0 or 7.1 at all, and the watcher was blind to its own
            # FLOOR going stale while reporting cheerfully on everything newer. A checker whose
            # blind spot is the oldest thing it guards is worse than none.
            #
            # The cap exists so a paging bug cannot turn a weekly job into an unbounded crawl; ten
            # pages is roughly triple the releases that exist above the floor today.
            #
            # Assigned WITHOUT @( ), which is the opposite of the usual advice and is load-bearing.
            # Invoke-RestMethod hands back a JSON array as a SINGLE object, so @( ) wraps rather than
            # flattens: the result is one element whose .tag_name is every tag at once, .Count is 1,
            # the loop breaks after one page, and the filter removes the lone nested entry. The
            # symptom is a watcher that silently sees nothing while reporting no faults.
            $available = @()
            for ($page = 1; $page -le 10; $page++) {
                $batch = Invoke-RestMethod -ErrorAction Stop -Headers @{ 'User-Agent' = 'PSComplexity-pin-freshness' } `
                    -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=100&page=$page"
                if (-not $batch) { break }
                $available += @($batch | Where-Object { -not $_.prerelease } | ForEach-Object { $_.tag_name -replace '^v', '' })
                if ($batch.Count -lt 100) { break }
            }
        }
    }
    catch {
        # Left empty on purpose, exactly as above: the decision reports "could not look" itself.
        Write-Verbose "Version lookup failed for $($list.Name): $($_.Exception.Message)"
    }
    foreach ($f in (Get-PSCxVersionListFault -Name $list.Name -Ours $ours -Available $available -ExemptMinor $exempt)) {
        $faults.Add($f)
    }
}

return [string[]]@($faults)
