# The machine-readable forms of a run, and the one place that writes a file.
#
# Two published formats leave this module: our own report, defined by
# schemas/v1/report.schema.json and shipped beside the code, and SARIF 2.1.0, which has its own
# published schema and needs none of ours. Both are built as pure documents and written by a
# single function, so what a report SAYS can be tested without touching a disk.
#
# A report is not a new shape. It is the scan serialised -- Get-PSCxScan already answers what was
# in scope, what was measured and what was skipped -- so nothing here decides anything the
# measurement did not already know.

$script:PSCxSchemaVersion = 1

function Get-PSCxModuleVersion {
    # What goes in the report's producedBy. Prefers the loaded module and falls back to the
    # manifest beside src/, because the suite dot-sources these files without importing a module
    # and a report written from there must still say which version shaped it.
    #
    # Returns the literal 'unknown' when it can find neither, rather than throwing or inventing
    # something plausible. Three options, and the middle one is the trap:
    #
    #   throw     -- refuses to write the report at all, and "neither" is a REAL configuration:
    #                a mutation sandbox copies src/ and tests/ and no manifest, and so does a
    #                consumer who dot-sources src/ directly. This function threw, and it turned
    #                the sandboxed baseline red before a single mutant ran.
    #   '0.0.0'   -- worst of the three. It looks like an answer, so every report from every
    #                such run claims to come from one release nobody published.
    #   'unknown' -- cannot be mistaken for a version by a reader or by a comparison, and the
    #                report still gets written.
    [OutputType([string])]
    [CmdletBinding()]
    param()
    $loaded = @(Get-Module -Name PSComplexity)
    if ($loaded.Count -gt 0) { return "$($loaded[0].Version)" }
    $manifest = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSComplexity.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) { return 'unknown' }
    return "$((Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion)"
}

function Get-PSCxReportSummary {
    # The aggregates, over the units actually measured.
    #
    # Every one is reconcilable against the units array in the same document. None of them is the
    # only place a fact lives, which is what lets a consumer disagree with a number rather than
    # take it on trust.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit)
    # An empty scan is a real outcome -- a path that matched no PowerShell -- and
    # Measure-PSComplexity does not refuse it the way the gate does. It needs no special case:
    # Measure-Object over nothing yields $null, and both the [int] cast and [math]::Round turn
    # that into 0, so every field below is already correct for an empty list.
    #
    # There WAS a special case here, an early return of six zeros. It was deleted because it is
    # indistinguishable from its own absence, which is precisely what the mutation gate reported
    # -- six mutants inside a branch whose removal changes no answer. The counts beside the
    # maxima are what tell "zero complexity" from "nothing measured".
    $cyc = @($Unit | ForEach-Object { $_.Cyclomatic })
    $cog = @($Unit | ForEach-Object { $_.Cognitive })
    return [ordered]@{
        fileCount         = @($Unit | ForEach-Object { $_.File } | Sort-Object -Unique).Count
        unitCount         = $Unit.Count
        # Cast, because Measure-Object returns a double and ConvertTo-Json then writes 9.0
        # where the schema and every reader expect 9. The averages stay real numbers.
        maxCyclomatic     = [int]($cyc | Measure-Object -Maximum).Maximum
        maxCognitive      = [int]($cog | Measure-Object -Maximum).Maximum
        averageCyclomatic = [math]::Round(($cyc | Measure-Object -Average).Average, 2)
        averageCognitive  = [math]::Round(($cog | Measure-Object -Average).Average, 2)
    }
}

function Get-PSCxReportDocument {
    # The report as a document. Pure: the version and the timestamp arrive as parameters rather
    # than being read here, so the whole shape is testable without a clock or a manifest.
    #
    # -Gate is what separates the two published shapes. Absent, this is a measurement and the
    # document carries no verdict -- and the schema FORBIDS one, because Measure-PSComplexity
    # applies no thresholds and a `passed` beside its numbers would be an answer nobody computed.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [Parameter(Mandatory)] [string]$ModuleVersion,
        [Parameter(Mandatory)] [datetime]$GeneratedAt,
        $Gate
    )
    $mode = 'Measure'
    if ($Gate) { $mode = 'Gate' }
    $document = [ordered]@{
        # Provenance first, so a reader opening the file sees what produced it before what it says.
        generatedFrom = 'PSComplexity'
        schemaVersion = $script:PSCxSchemaVersion
        producedBy    = [ordered]@{ module = 'PSComplexity'; version = "$ModuleVersion" }
        # Round-trippable and sortable as text, and UTC so reports from two machines compare
        # without knowing where either ran.
        generatedAt   = $GeneratedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode          = $mode
        # Required by the schema, and the reason is the whole point: the metric has already moved
        # twice for source that did not change, so a stored number that cannot be checked for
        # comparability is a trend chart waiting to mislead.
        metricVersion = $Scan.MetricVersion
        scope         = [ordered]@{
            path    = @($Scan.Scope.Path)
            recurse = [bool]$Scan.Scope.Recurse
            # Forward slashes, like every File in the same document. A published format that
            # spells one path two ways makes a consumer guess which one it is holding.
            root    = ([string]$Scan.Scope.Root).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        }
        # Beside the summary, never instead of it: an aggregate that cannot say what it excluded
        # is the failure this project exists to find in other people's code.
        skipped       = @($Scan.Skipped | ForEach-Object { [ordered]@{ file = $_.File; reason = $_.Reason } })
        summary       = Get-PSCxReportSummary -Unit @($Scan.Units)
        units         = @($Scan.Units)
    }
    if ($Gate) {
        $document['thresholds'] = [ordered]@{
            cyclomatic = $Gate.MaxCyclomatic
            cognitive  = $Gate.MaxCognitive
        }
        $document['passed'] = [bool]$Gate.Passed
        $document['violations'] = @($Gate.Violations)
        # What the run EXCUSED, with the argument for each. A gate report that reported a pass
        # without saying what it excused would be the mute button the acceptance concept exists
        # instead of.
        $document['accepted'] = @($Gate.Accepted | ForEach-Object {
                [ordered]@{ file = [string]$_.File; unit = [string]$_.Unit; reason = [string]$_.Reason }
            })
        # And what the BASELINE excused, by the same argument. A baseline routinely excuses far
        # more units than an acceptance ever will, so a report that recorded one and not the other
        # would say "passed" over a set it never named -- the shape of aggregate this project
        # exists to distrust. Each carries the score it was held to, not just its name, because
        # "excused" without a number does not say how much room was left.
        $document['baselined'] = @($Gate.Baselined | ForEach-Object {
                [ordered]@{
                    file       = [string]$_.File
                    unit       = [string]$_.Unit
                    cyclomatic = [int]$_.Cyclomatic
                    cognitive  = [int]$_.Cognitive
                }
            })
    }
    return $document
}

function Get-PSCxSarifRule {
    # One SARIF rule per metric, so a unit over both produces two results.
    #
    # Two rules rather than one: they render against the same line but suppress independently,
    # and a team that has decided cyclomatic is not their problem should not have to silence
    # cognitive to say so.
    [OutputType([object[]])]
    [CmdletBinding()]
    param()
    return @(
        [ordered]@{
            id               = 'PSCxCyclomatic'
            name             = 'CyclomaticComplexity'
            shortDescription = [ordered]@{ text = 'Cyclomatic complexity exceeds the configured ceiling.' }
            fullDescription  = [ordered]@{ text = 'Cyclomatic complexity counts decision points: each if/elseif, switch clause, loop, catch, trap, ternary and each -and/-or. It is a count of paths, not of how hard the code is to follow.' }
            helpUri          = 'https://github.com/Fortigi/PSComplexity#the-two-metrics'
        }
        [ordered]@{
            id               = 'PSCxCognitive'
            name             = 'CognitiveComplexity'
            shortDescription = [ordered]@{ text = 'Cognitive complexity exceeds the configured ceiling.' }
            fullDescription  = [ordered]@{ text = 'Cognitive complexity follows the SonarSource rules: structures score one each, and nesting adds its depth on top. It tracks how hard code is to follow rather than how many paths it has.' }
            helpUri          = 'https://github.com/Fortigi/PSComplexity#the-two-metrics'
        }
    )
}

function Get-PSCxSarifResult {
    # One result per breached ceiling for one unit: none, one, or two.
    #
    # Declares what a caller RECEIVES -- individual results, streamed -- rather than an array of
    # them, which is a single return value this never produces.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Unit,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    $breaches = @()
    if ($Unit.Cyclomatic -gt $MaxCyclomatic) {
        $breaches += , @('PSCxCyclomatic', 0, 'cyclomatic', $Unit.Cyclomatic, $MaxCyclomatic)
    }
    if ($Unit.Cognitive -gt $MaxCognitive) {
        $breaches += , @('PSCxCognitive', 1, 'cognitive', $Unit.Cognitive, $MaxCognitive)
    }
    foreach ($b in $breaches) {
        [ordered]@{
            ruleId              = $b[0]
            ruleIndex           = $b[1]
            # error, not warning: this run failed a gate on it. A finding that renders as advice
            # while the build goes red says two different things about one fact.
            level               = 'error'
            message             = [ordered]@{ text = "$($Unit.Unit) has $($b[2]) complexity $($b[3]), over the ceiling of $($b[4])." }
            locations           = @(
                [ordered]@{
                    physicalLocation = [ordered]@{
                        # Forward slashes and relative to the repo, which is what code scanning
                        # matches against the checkout. Measure-PSComplexity already produces
                        # File in exactly that form.
                        artifactLocation = [ordered]@{ uri = $Unit.File }
                        region           = [ordered]@{ startLine = $Unit.Line }
                    }
                }
            )
            # File and Unit, never Line. Line is explicitly not an identity in this project -- it
            # moves whenever anything above the unit is edited -- and a fingerprint built on it
            # would close and reopen the same finding on an unrelated edit above it.
            partialFingerprints = [ordered]@{ psComplexityUnit = "$($Unit.File)|$($Unit.Unit)" }
        }
    }
}

function Get-PSCxSarifDocument {
    # A SARIF 2.1.0 log for the units this run failed on.
    #
    # Written by the gate and not by measurement: without thresholds there is no such thing as a
    # finding, and a SARIF file from a run that applied no ceilings would be an empty results
    # array claiming a clean bill of health.
    #
    # An accepted unit produces no result. The gate excused it, and the argument is not lost --
    # the JSON report carries it under `accepted`, which is where "what did this run excuse"
    # is answered.
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Violation,
        [Parameter(Mandatory)] [string]$ModuleVersion,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive
    )
    $results = @(foreach ($u in $Violation) {
            Get-PSCxSarifResult -Unit $u -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive
        })
    return [ordered]@{
        '$schema' = 'https://json.schemastore.org/sarif-2.1.0.json'
        version   = '2.1.0'
        runs      = @(
            [ordered]@{
                tool    = [ordered]@{
                    driver = [ordered]@{
                        name           = 'PSComplexity'
                        version        = "$ModuleVersion"
                        informationUri = 'https://github.com/Fortigi/PSComplexity'
                        rules          = Get-PSCxSarifRule
                    }
                }
                results = $results
            }
        )
    }
}

function Write-PSCxGateArtifact {
    # The gate's optional files, decided in one place so Test-PSComplexity stays a thin
    # predicate: two more branches in its end block would push it toward the ceiling this
    # module gates itself on, for wiring rather than for a decision.
    #
    # Both paths are optional and independent -- a team may want the SARIF for its pull requests
    # and no JSON, or the JSON for a trend and no SARIF.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Scan,
        [Parameter(Mandatory)] [bool]$Passed,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Violation,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Accept,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        # Optional so a run with no baseline records an empty list rather than nothing: absent and
        # empty are different answers, and a consumer iterating this should not have to tell them
        # apart.
        [AllowEmptyCollection()] [object[]]$Baselined = @(),
        [AllowEmptyString()] [string]$ReportPath,
        [AllowEmptyString()] [string]$SarifPath
    )
    if ($ReportPath) {
        $gate = [pscustomobject]@{
            MaxCyclomatic = $MaxCyclomatic
            MaxCognitive  = $MaxCognitive
            Passed        = $Passed
            Violations    = $Violation
            Accepted      = $Accept
            Baselined     = $Baselined
        }
        Save-PSCxDocument -Path $ReportPath -Document (Get-PSCxReportDocument -Scan $Scan `
                -ModuleVersion (Get-PSCxModuleVersion) -GeneratedAt (Get-Date) -Gate $gate)
    }
    if ($SarifPath) {
        Save-PSCxDocument -Path $SarifPath -Document (Get-PSCxSarifDocument -Violation $Violation `
                -ModuleVersion (Get-PSCxModuleVersion) -MaxCyclomatic $MaxCyclomatic -MaxCognitive $MaxCognitive)
    }
}

function Save-PSCxDocument {
    # The only function here that touches a disk, so everything above stays testable without one.
    [OutputType([void])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)] [string]$Path
    )
    $parent = Split-Path -Parent $Path
    # A report path pointing into a directory that does not exist yet is an ordinary thing to
    # ask for -- reports/ on a fresh clone, or an artifacts directory a CI step has not made.
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    # Deep enough for SARIF, which is the deeper of the two formats by a long way: a result
    # reaches root > runs > run > results > result > locations > location > physicalLocation >
    # artifactLocation > uri, nine levels down. Our own report needs six.
    #
    # ConvertTo-Json truncates past its depth SILENTLY, replacing the tail with the .NET type
    # name -- so the file stays valid JSON and stops matching its schema, which is the shape of
    # bug this module exists to find. Depth 6 shipped exactly that here: every SARIF location
    # was the string "System.Collections.Specialized.OrderedDictionary".
    # WarningAction, because PowerShell's own truncation warning is redundant beside the
    # throw below and far less actionable -- it names a depth, not the file it ruined.
    $json = $Document | ConvertTo-Json -Depth 12 -WarningAction SilentlyContinue
    # Asserted rather than trusted, because raising the depth fixes today's document and the
    # next nested field silently reintroduces it. A type name where a value belongs is never
    # something this module means to write.
    foreach ($marker in 'System.Collections.Specialized.OrderedDictionary', 'System.Object[]', 'System.Collections.Hashtable') {
        if ($json.Contains($marker)) {
            throw "Refusing to write $Path : ConvertTo-Json truncated the document and left '$marker' where a value belongs. Raise the depth in Save-PSCxDocument."
        }
    }
    # ErrorAction Stop because Set-Content fails non-terminatingly by default: an unwritable
    # path would otherwise leave the run green and the artefact absent.
    $json | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
}

function Read-PSCxDocument {
    # A JSON document off disk, or a throw naming the path and what was wrong with it.
    #
    # The counterpart to Save-PSCxDocument, and here for the same reason: this file owns document
    # I/O so that everything deciding what a document MEANS stays testable without a disk.
    #
    # Three distinct failures, named separately, because a baseline path is the one thing a
    # consumer types by hand and a single "could not read" sends them to check the wrong one. A
    # missing file is usually a wrong path; a parse failure is usually a hand edit.
    [OutputType([object])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string]$Path
    )
    # LiteralPath throughout: a baseline living under a directory with [ or ] in its name is
    # ordinary on Windows, and the wildcard form would report it as missing.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No such file: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    # An empty file parses to $null rather than failing, and $null would then be read as a
    # document with no entries -- a baseline permitting nothing, which is a silent verdict
    # change rather than an error.
    if (-not $text -or -not $text.Trim()) {
        throw "$Path is empty. An empty baseline is a document with an empty units array, not an empty file."
    }
    try {
        return $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Path is not valid JSON: $($_.Exception.Message)"
    }
}
