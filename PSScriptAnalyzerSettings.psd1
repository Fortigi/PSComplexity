@{
    # No rule exclusions: PSComplexity emits via Write-Warning/pipeline (not Write-Host)
    # and keeps sources ASCII, so the full default rule set applies.
    IncludeDefaultRules = $true
}
