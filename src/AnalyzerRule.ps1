# The editor rule (#163): what the gate would say about one file, as findings a PSScriptAnalyzer
# custom rule hands to an editor. rules/PSComplexity.Rules.psm1 is the rule itself, and stays thin;
# everything it decides is here, under the same coverage and mutation gates as the rest.
#
# The same scoring and the same verdict as Test-PSComplexity, so the editor and the gate cannot
# disagree: the config the file sits under (#164), or 15 and 15; its per-path ceilings and excludes;
# acceptances in the config and in the code (#165); units held by the config's baseline.
#
# What it does NOT do is refuse. The gate throws on a stale acceptance or baseline entry, because a
# run cannot vouch for a policy that has stopped describing it; an editor showing one file has not
# seen the run, so it applies what it can and leaves the refusals to the gate.

function Get-PSCxRuleFinding {
    # The units of one script the gate would fail, each with the message and the extent to show:
    # [pscustomobject]@{ Unit; Message; Extent }. Nothing for a script that does not parse --
    # PSScriptAnalyzer reports that itself -- or for a file the config excludes.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # The whole script, as PSScriptAnalyzer passes it. Its text is measured, not the file on
        # disk, so an unsaved edit is judged as it stands. Untyped, because a type named in the
        # code of src/ reads to tests/Vocabulary.Tests.ps1 as a construct the metrics score.
        [Parameter(Mandatory)] $Ast
    )
    $file = [string]$Ast.Extent.File
    $tokens = $null
    $errors = $null
    $parsed = [System.Management.Automation.Language.Parser]::ParseInput($Ast.Extent.Text, $file, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { return }
    $root = Get-PSCxWorkingRoot
    $pathComparison = Get-PSCxRunPathComparison -Root $root
    $policy = Get-PSCxRulePolicy -File $file -Root $root -PathComparison $pathComparison
    if ($file -and -not (Test-PSCxSelectedFile -File $file -Root $root -PathComparison $pathComparison `
                -Exclude $policy.Exclude -Excluded ([System.Collections.Generic.List[string]]::new()))) { return }
    # An unsaved buffer has no path, so its units are filed under a name no file can have and no
    # acceptance or baseline entry can match.
    $relative = $file ? (Get-PSCxRelativePath -Path $file -Root $root -PathComparison $pathComparison) : '<untitled>'
    Clear-PSCxAstCache
    $scan = Get-PSCxParsedScan -Ast $parsed -Token @($tokens) -File $relative
    $units = @($scan.Units)
    $fileCeiling = Get-PSCxFileCeiling -Unit $units -Override $policy.Overrides -MaxCyclomatic $policy.MaxCyclomatic `
        -MaxCognitive $policy.MaxCognitive -Root $root -PathComparison $pathComparison
    $map = Get-PSCxRuleBaseline -Path $policy.BaselineFile -PathComparison $pathComparison
    $violations = @(Get-PSCxUnacceptedUnit -Unit $units -Accept (@($policy.Accept) + @($scan.InlineAccept)) `
            -MaxCyclomatic $policy.MaxCyclomatic -MaxCognitive $policy.MaxCognitive -BaselineMap $map `
            -PathComparison $pathComparison -FileCeiling $fileCeiling)
    foreach ($v in $violations) {
        $ceiling = Get-PSCxUnitCeiling -File $v.File -MaxCyclomatic $policy.MaxCyclomatic -MaxCognitive $policy.MaxCognitive -FileCeiling $fileCeiling
        [pscustomobject]@{
            Unit    = $v.Unit
            Message = ('{0} is over the complexity ceiling: cyclomatic {1} (max {2}), cognitive {3} (max {4}).' -f
                $v.Unit, $v.Cyclomatic, $ceiling.Cyclomatic, $v.Cognitive, $ceiling.Cognitive)
            Extent  = Get-PSCxRuleExtent -Ast $Ast -Line $v.Line
        }
    }
}

function Get-PSCxRulePolicy {
    # The policy one file is judged by: the config it sits under, read as the gate reads it with
    # nothing on the command line, or the defaults. An unsaved buffer has no path, so no config.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$File,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $config = $null
    $found = $File ? (Find-PSCxConfigFile -Path $File -Root $Root) : $null
    if ($found) { $config = Read-PSCxConfig -Path $found -Root $Root -PathComparison $PathComparison }
    return Get-PSCxGatePolicy -Config $config -Bound @{}
}

function Get-PSCxRuleBaseline {
    # The config's baseline as a lookup, or an empty one: no baseline, a file not there yet, or one
    # recorded by another metric version, whose numbers mean something else. The entries are not
    # checked against a run -- the editor has not seen one -- so a stale entry stays the gate's to
    # refuse.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Path,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    $document = Read-PSCxDocument -Path $Path
    if (Get-PSCxBaselineDocumentFault -Document $document -MetricVersion (Get-PSCxMetricVersion) `
            -SchemaVersion (Get-PSCxBaselineSchemaVersion)) { return @{} }
    return Get-PSCxBaselineMap -Entry @($document.units) -PathComparison $PathComparison
}

function Get-PSCxRuleExtent {
    # Where an editor marks a unit: the first line of its declaration, not the whole body -- a
    # squiggle under two hundred lines says nothing the first line does not. The script body's
    # first line when no declaration starts on the line.
    [OutputType([System.Management.Automation.Language.ScriptExtent])]
    [CmdletBinding()]
    param(
        # The whole script; untyped for the reason Get-PSCxRuleFinding gives.
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)] [int]$Line
    )
    $text = ($Ast.Extent.Text -split '\r?\n')[$Line - 1]
    $start = [System.Management.Automation.Language.ScriptPosition]::new($Ast.Extent.File, $Line, 1, $text)
    $end = [System.Management.Automation.Language.ScriptPosition]::new($Ast.Extent.File, $Line, $text.Length + 1, $text)
    return [System.Management.Automation.Language.ScriptExtent]::new($start, $end)
}
