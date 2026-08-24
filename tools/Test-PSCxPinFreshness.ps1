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
return [string[]]@($faults)
