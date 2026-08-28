# The baseline FILE: reading it, refusing it, and writing it back.
#
# Apart from Policy.ps1, which decides what a baseline MEANS, because this half touches a disk
# and that half must stay pure. Apart from Measure-PSComplexity.ps1, which owns the scan and the
# two public commands, for a reason that is measured rather than aesthetic: a covering suite is
# re-run once per mutant of the file it covers, and Measure.Tests.ps1 takes 18 seconds because it
# measures real source. These two functions need no measurement at all -- unit records are
# ordinary objects and a baseline is a small JSON file -- so leaving their 28 mutants in that
# file cost about eight minutes of every gate run for nothing.
#
# MetricVersion arrives as a parameter rather than being read from Measure-PSComplexity.ps1's
# module state. A $script: variable is read only by the file that writes it, and reaching across
# would also make the dependency circular: the gate calls in here, so here cannot call back.

function Get-PSCxBaselineState {
    # The recorded scores to hold units to, having refused every way the file could fail to
    # describe this run. An empty map when no baseline was asked for, which is what makes every
    # unit face the real ceilings.
    #
    # The I/O and the refusals live here rather than in the gate for the reason every decision in
    # this module does: Test-PSComplexity is a thin predicate, and a baseline that half-applies is
    # the failure mode worth keeping out of it.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        [Parameter(Mandatory)] [int]$MetricVersion
    )
    if (-not $Path) { return @{} }
    $document = Read-PSCxDocument -Path $Path
    $documentFault = Get-PSCxBaselineDocumentFault -Document $document `
        -MetricVersion $MetricVersion -SchemaVersion (Get-PSCxBaselineSchemaVersion)
    if ($documentFault) { throw "Cannot use the baseline $Path : $documentFault." }

    $entries = @($document.units)
    # Thrown, not returned as a failing gate. A baseline entry that no longer describes the run
    # is a fault in the policy rather than a complaint about the code, and reporting it as a
    # failure would send somebody to refactor a unit that is fine.
    $faults = @($entries | Get-PSCxBaselineFault -Unit $Unit -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
    if ($faults.Count -gt 0) {
        throw ("The baseline $Path does not describe this run: " + ($faults -join '; ') +
            '. A ratchet that has stopped matching is a suppression list, so it fails here rather than ageing quietly.')
    }
    return Get-PSCxBaselineMap -Entry $entries
}

function Write-PSCxBaselineFile {
    # Record every breaching, unaccepted unit at the score it has now -- refusing, first, to
    # record any of them worse than the file already does.
    #
    # That refusal is the whole ratchet. Without it, re-running with -UpdateBaseline absorbs
    # whatever regression the gate had just caught, and the file becomes a suppression list that
    # updates itself.
    # No SupportsShouldProcess. Its only caller is Test-PSComplexity, which has no -WhatIf to
    # forward, so the guard could never return false -- a branch that cannot fire looks exactly
    # like one that keeps passing, and it would sit here at 100% coverage saying nothing.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        [Parameter(Mandatory)] [int]$MetricVersion
    )
    # Absent is the ordinary first run, not an error: seeding a baseline is the reason this
    # switch exists.
    $existing = (Test-Path -LiteralPath $Path -PathType Leaf) ? (Read-PSCxDocument -Path $Path) : $null
    # Only compare against a file whose numbers still mean the same thing. When the metric
    # version has moved, the recorded scores are not smaller or larger -- they are answers to a
    # different question, and a ratchet cannot be enforced across that. Regenerating wholesale is
    # the fix, and the diff is where it gets reviewed.
    $comparable = $null -ne $existing -and -not (Get-PSCxBaselineDocumentFault -Document $existing `
            -MetricVersion $MetricVersion -SchemaVersion (Get-PSCxBaselineSchemaVersion))
    if ($comparable) {
        $raised = @(Get-PSCxBaselineRaise -Unit $Unit -Map (Get-PSCxBaselineMap -Entry @($existing.units)))
        if ($raised.Count -gt 0) {
            throw ("Refusing to update $Path : " +
                (($raised | ForEach-Object { "$($_.File) $($_.Unit) is now cyclomatic $($_.Cyclomatic), cognitive $($_.Cognitive)" }) -join '; ') +
                ' -- worse than recorded. A baseline only ever ratchets down; fix the regression, or accept the unit with an argument for it.')
        }
    }
    Save-PSCxDocument -Path $Path -Document (Get-PSCxBaselineDocument -Unit $Unit -Accept $Accept `
            -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive `
            -MetricVersion $MetricVersion -SchemaVersion (Get-PSCxBaselineSchemaVersion) `
            -GeneratedAt (Get-Date))
}
