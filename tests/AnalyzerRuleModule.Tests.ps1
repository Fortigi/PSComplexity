# The rule module PSScriptAnalyzer loads (#163), run through PSScriptAnalyzer itself: that it is
# found, warns once per unit over the ceiling, and names itself. What a finding is, and the
# verdict, is tests/AnalyzerRule.Tests.ps1.
#
# Skipped where PSScriptAnalyzer is not installed. CI installs it for the lint gate.

BeforeDiscovery {
    $script:noAnalyzer = $null -eq (Get-Module -ListAvailable PSScriptAnalyzer)
}

BeforeAll {
    $script:rule = Join-Path (Split-Path -Parent $PSScriptRoot) 'rules/PSComplexity.Rules.psm1'
    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) "cxrulemod-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
    # Nested script blocks on purpose: the analyzer hands the rule each of them, and the whole
    # script is measured once.
    $script:file = Join-Path $script:dir 'a.ps1'
    [System.IO.File]::WriteAllText($script:file, (@(
                'function Big {'
                '  param($a) if ($a) { if ($a) { if ($a) { if ($a) { if ($a -and $b -or $c) { & { 1 } } } } } }'
                '}'
                'function Small { 1 }'
            ) -join "`n"))
}

AfterAll { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'the PSScriptAnalyzer rule module' -Skip:$script:noAnalyzer {
    It 'warns once, on the unit over the ceiling, under its own rule name' {
        Push-Location $script:dir
        try { $records = @(Invoke-ScriptAnalyzer -Path $script:file -CustomRulePath $script:rule) }
        finally { Pop-Location }
        $records.Count | Should-Be 1
        $records[0].RuleName | Should-BeLikeString '*Measure-PSComplexityCeiling'
        "$($records[0].Severity)" | Should-Be 'Warning'
        $records[0].Line | Should-Be 1
        $records[0].Message | Should-BeLikeString 'Big is over the complexity ceiling*'
    }
}
