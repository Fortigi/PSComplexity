# The PSComplexity rule for PSScriptAnalyzer (#163). Point CustomRulePath at this file:
#
#   Invoke-ScriptAnalyzer -Path ./src -Recurse -IncludeDefaultRules `
#       -CustomRulePath (Join-Path (Get-Module PSComplexity -ListAvailable)[0].ModuleBase 'rules')
#
# or set CustomRulePath in the PSScriptAnalyzerSettings.psd1 the PowerShell extension reads, and
# every unit over its ceiling is marked while it is being written.
#
# Deliberately thin: it loads the PSComplexity module it ships with -- so the editor and the gate are
# always the same version -- and turns that module's findings into diagnostic records. What a finding
# is, and the same verdict the gate reaches, is src/AnalyzerRule.ps1.

$script:PSCxModule = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSComplexity.psd1') -PassThru

function Measure-PSComplexityCeiling {
    <#
    .SYNOPSIS
        Warns on each function, method or script body over the PSComplexity ceilings, with the
        same verdict Test-PSComplexity reaches.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] [System.Management.Automation.Language.ScriptBlockAst]$ScriptBlockAst
    )
    # PSScriptAnalyzer hands a rule every script block in a file; the whole script is the one with
    # no parent, and measuring it once is what keeps one breach from being reported per block.
    if ($null -ne $ScriptBlockAst.Parent) { return }
    $findings = & $script:PSCxModule { param($a) Get-PSCxRuleFinding -Ast $a } $ScriptBlockAst
    foreach ($f in $findings) {
        [Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord]@{
            Message  = $f.Message
            Extent   = $f.Extent
            RuleName = $PSCmdlet.MyInvocation.InvocationName
            Severity = 'Warning'
        }
    }
}

Export-ModuleMember -Function Measure-PSComplexityCeiling
