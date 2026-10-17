# The editor rule (#163): the findings the PSScriptAnalyzer rule shows, with the gate's verdict.
#
# The COVERING SUITE for src/AnalyzerRule.ps1. Each fixture is a small repository under a
# GUID-named temp directory, entered with Push-Location so the working root is the repository the
# way an editor's is. The rule module itself, run through PSScriptAnalyzer, is
# tests/AnalyzerRuleModule.Tests.ps1.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    # Big breaches 15 / 15 on cognitive only (17); Small breaches nothing.
    $script:code = @(
        'function Big {'
        '  param($a) if ($a) { if ($a) { if ($a) { if ($a) { if ($a -and $b -or $c) { 1 } } } } }'
        '}'
        'function Small { 1 }'
    ) -join "`n"

    $script:repos = [System.Collections.Generic.List[string]]::new()
    function script:NewRepo {
        param([string]$Config, [string]$Code = $script:code, [string]$Name = 'src/a.ps1')
        $repo = Join-Path ([System.IO.Path]::GetTempPath()) "cxrule-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $repo '.git'), (Join-Path $repo 'src') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo $Name), $Code)
        if ($Config) { [System.IO.File]::WriteAllText((Join-Path $repo '.pscomplexity.json'), $Config) }
        $script:repos.Add($repo)
        return $repo
    }
    function script:Findings {
        # The rule's findings for a file in a repository, measured from the text given -- the file
        # on disk by default, as PSScriptAnalyzer passes it.
        param([string]$Repo, [string]$Name = 'src/a.ps1', [string]$Text)
        $path = Join-Path $Repo $Name
        if (-not $Text) { $Text = [System.IO.File]::ReadAllText($path) }
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, $path, [ref]$null, [ref]$null)
        Push-Location $Repo
        try { return @(Get-PSCxRuleFinding -Ast $ast) }
        finally { Pop-Location }
    }
}

AfterAll { foreach ($r in $script:repos) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'a unit over the ceiling' {
    It 'is a finding naming the unit and both scores against the ceilings, and a unit within is not' {
        $repo = NewRepo
        $f = Findings $repo
        $f.Count | Should-Be 1
        $f[0].Unit | Should-Be 'Big'
        $f[0].Message | Should-Be 'Big is over the complexity ceiling: cyclomatic 8 (max 15), cognitive 17 (max 15).'
    }

    It 'is marked on the first line of its declaration, from the first column to the end of the line' {
        $repo = NewRepo -Code ("# lead`n`n" + $script:code)
        $e = (Findings $repo)[0].Extent
        $e.StartLineNumber | Should-Be 3
        $e.EndLineNumber | Should-Be 3
        $e.StartColumnNumber | Should-Be 1
        $e.EndColumnNumber | Should-Be ('function Big {'.Length + 1)
        $e.Text | Should-Be 'function Big {'
        $e.File | Should-Be (Join-Path $repo 'src/a.ps1')
    }

    It 'judges the text it is given, not the file on disk' {
        $repo = NewRepo -Code 'function Small { 1 }'
        (Findings $repo -Text $script:code).Count | Should-Be 1
    }

    It 'is nothing for a script that does not parse, even with a unit over the ceiling in it' {
        # Exactly ONE parse error -- a stray closing brace -- after a unit that would warn, so the
        # guard is what stops it, and a guard counting past one error is caught too.
        $text = $script:code + "`n}"
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors.Count | Should-Be 1
        (Findings (NewRepo) -Text $text).Count | Should-Be 0
    }

    It 'is found in an unsaved buffer, with the defaults even inside a repository with a config' {
        $repo = NewRepo -Config '{ "schemaVersion": 1, "maxCognitive": 30 }'
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:code, [ref]$null, [ref]$null)
        Push-Location $repo
        try { $f = @(Get-PSCxRuleFinding -Ast $ast) }
        finally { Pop-Location }
        $f.Count | Should-Be 1
        $f[0].Extent.StartLineNumber | Should-Be 1
    }
}

Describe 'the same verdict as the gate' {
    It 'applies <Why>' -ForEach @(
        @{ Why = 'the config ceiling'; Config = '{ "schemaVersion": 1, "maxCognitive": 17 }'; Count = 0 }
        @{ Why = 'a config ceiling it still breaches'; Config = '{ "schemaVersion": 1, "maxCognitive": 16 }'; Count = 1 }
        @{ Why = 'a per-path override'; Config = '{ "schemaVersion": 1, "overrides": [ { "path": "src", "maxCognitive": 20 } ] }'; Count = 0 }
        @{ Why = 'an exclude'; Config = '{ "schemaVersion": 1, "exclude": [ "src/a.ps1" ] }'; Count = 0 }
        @{ Why = 'an acceptance in the config'; Config = '{ "schemaVersion": 1, "accept": [ { "file": "src/a.ps1", "unit": "Big", "reason": "a table" } ] }'; Count = 0 }
        @{ Why = 'an acceptance for another unit'; Config = '{ "schemaVersion": 1, "accept": [ { "file": "src/a.ps1", "unit": "Small", "reason": "x" } ] }'; Count = 1 }
    ) {
        (Findings (NewRepo -Config $Config)).Count | Should-Be $Count
    }

    It 'names the ceiling a per-path override set' {
        $f = Findings (NewRepo -Config '{ "schemaVersion": 1, "overrides": [ { "path": "src", "maxCognitive": 10, "maxCyclomatic": 9 } ] }')
        $f[0].Message | Should-Be 'Big is over the complexity ceiling: cyclomatic 8 (max 9), cognitive 17 (max 10).'
    }

    It 'applies an acceptance written in the code' {
        (Findings (NewRepo -Code ("# PSCx-Accept: a table`n" + $script:code))).Count | Should-Be 0
    }

    It 'applies the config''s baseline, and not one recorded by another metric version' {
        foreach ($case in @(@((Get-PSCxMetricVersion), 0), @(((Get-PSCxMetricVersion) + 1), 1))) {
            $repo = NewRepo -Config '{ "schemaVersion": 1, "baselineFile": "baseline.json" }'
            [ordered]@{
                schemaVersion = Get-PSCxBaselineSchemaVersion; metricVersion = $case[0]; generatedAt = '2026-01-01T00:00:00Z'
                units = @([ordered]@{ file = 'src/a.ps1'; unit = 'Big'; cyclomatic = 8; cognitive = 17 })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $repo 'baseline.json') -Encoding utf8
            (Findings $repo).Count | Should-Be $case[1]
        }
    }

    It 'warns as without a baseline when the config names one that is not there yet' {
        (Findings (NewRepo -Config '{ "schemaVersion": 1, "baselineFile": "baseline.json" }')).Count | Should-Be 1
    }
}

Describe 'Get-PSCxRuleBaseline' {
    It 'is an empty map without a path' {
        $m = Get-PSCxRuleBaseline -Path '' -PathComparison Ordinal
        Should-BeTrue -Actual ($m -is [hashtable])
        $m.Count | Should-Be 0
    }
}
