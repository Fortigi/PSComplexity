# What a config file may say, and what it means for one gate run (#164).
#
# The COVERING SUITE for src/Config.ps1, and cheap on purpose: everything here is pure, so a
# config is a JSON string and a path is a string, and nothing touches a disk except the one test
# holding the shipped schema to the module's own answers. Finding and reading the file is
# tests/ConfigFile.Tests.ps1; the gate applying it end to end is tests/Measure.Tests.ps1.

BeforeAll {
    $script:PathCmp = $IsLinux ? [System.StringComparison]::Ordinal : [System.StringComparison]::OrdinalIgnoreCase
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }
    $script:schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/v1/config.schema.json'

    # A root and a config directory that need not exist: nothing here reads them.
    $script:Sep = [System.IO.Path]::DirectorySeparatorChar
    $script:Root = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'cxcfgroot'))
    $script:ConfigPath = Join-Path $script:Root '.pscomplexity.json'

    function script:Doc { param([string]$Json) return $Json | ConvertFrom-Json }
    function script:Fault {
        param([string]$Json, [System.StringComparison]$Cmp = $script:PathCmp)
        return @(Get-PSCxConfigFault -Document (Doc $Json) -PathComparison $Cmp)
    }
    function script:Under { param([string]$Relative) return Join-Path $script:Root ($Relative.Replace('/', $script:Sep)) }
    function script:Unit {
        param([string]$File = 'src/A.ps1', [int]$Cyc = 1, [int]$Cog = 0)
        return [pscustomobject]@{ File = $File; Unit = 'Invoke-Thing'; Line = 1; Cyclomatic = $Cyc; Cognitive = $Cog }
    }
    function script:Override {
        param([string]$Path, $Cyc = $null, $Cog = $null)
        return [pscustomobject]@{ Path = $Path; Full = (Under $Path); MaxCyclomatic = $Cyc; MaxCognitive = $Cog }
    }
    function script:Ceiling {
        param([object[]]$Units, [object[]]$Overrides, [int]$Cyc = 15, [int]$Cog = 15, [System.StringComparison]$Cmp = $script:PathCmp)
        return Get-PSCxFileCeiling -Unit $Units -Override $Overrides -MaxCyclomatic $Cyc -MaxCognitive $Cog -Root $script:Root -PathComparison $Cmp
    }
}

Describe 'a config document' {

    It 'is accepted with only a schemaVersion' {
        (Fault '{"schemaVersion": 1}').Count | Should-Be 0
    }

    It 'is accepted with every key set' {
        $json = '{"$schema": "./x.json", "_comment": "why", "schemaVersion": 1, "maxCyclomatic": 12, "maxCognitive": 0,
            "exclude": ["tests/fixtures", "**/*.g.ps1"], "overrides": [{"path": "tests", "maxCyclomatic": 25}],
            "accept": [{"file": "src/A.ps1", "unit": "Get-A", "reason": "table"}], "baselineFile": "baseline.json"}'
        (Fault $json).Count | Should-Be 0
    }

    It 'must be an object' {
        foreach ($json in '[1]', '"x"', '3') { @(Fault $json) | Should-BeCollection @('a config is a JSON object') }
        @(Get-PSCxConfigFault -Document $null -PathComparison $script:PathCmp) | Should-BeCollection @('a config is a JSON object')
    }

    It 'must carry a schemaVersion, and nothing else is read without one' {
        # Alone: under another version every other key may mean something else, so its faults
        # would be guesses.
        @(Fault '{"maxCyclomatic": "x"}') | Should-BeCollection @('the config has no schemaVersion -- this PSComplexity reads 1')
    }

    It 'refuses another schemaVersion, and reads nothing else' {
        @(Fault '{"schemaVersion": 2, "bogus": 1}') | Should-BeCollection @('the config is schemaVersion 2 and this PSComplexity reads 1')
        @(Fault '{"schemaVersion": 0}') | Should-BeCollection @('the config is schemaVersion 0 and this PSComplexity reads 1')
    }

    It 'refuses an unknown key, naming it, because a misspelt one silently does nothing' {
        $f = @(Fault '{"schemaVersion": 1, "maxCognitve": 9}')
        $f.Count | Should-Be 1
        $f[0] | Should-BeLikeString "the config has an unknown key 'maxCognitve'*maxCognitive*"
    }

    It 'names every fault at once, so fixing a file is one round trip' {
        $f = @(Fault '{"schemaVersion": 1, "maxCyclomatic": 0, "maxCognitive": -1, "exclude": "x", "baselineFile": "/abs"}')
        $f.Count | Should-Be 4
        $f[0] | Should-BeLikeString 'maxCyclomatic must be a whole number of at least 1*'
        $f[1] | Should-BeLikeString 'maxCognitive must be a whole number of at least 0*'
        $f[2] | Should-Be 'exclude must be a list'
        $f[3] | Should-BeLikeString "baselineFile is '/abs'*"
    }
}

Describe 'a ceiling value' {

    It 'takes a whole number at or above the floor' -ForEach @(
        @{ Value = [long]1; Minimum = 1 }
        @{ Value = [int]15; Minimum = 1 }
        @{ Value = [long]0; Minimum = 0 }
    ) {
        Get-PSCxCeilingValueFault -Value $Value -Where 'x' -Minimum $Minimum | Should-BeNull
    }

    It 'refuses one below the floor, a fraction, a string, a boolean and null' -ForEach @(
        @{ Value = [long]0; Minimum = 1 }
        @{ Value = [long]-1; Minimum = 0 }
        @{ Value = 15.0; Minimum = 1 }
        @{ Value = '15'; Minimum = 1 }
        @{ Value = $true; Minimum = 0 }
        @{ Value = $null; Minimum = 0 }
    ) {
        Get-PSCxCeilingValueFault -Value $Value -Where 'x' -Minimum $Minimum |
            Should-Be "x must be a whole number of at least $Minimum, got '$Value'"
    }

    It 'reads cyclomatic with a floor of 1 and cognitive with a floor of 0, in the document and in an override' {
        (Fault '{"schemaVersion": 1, "maxCognitive": 0, "overrides": [{"path": "t", "maxCognitive": 0}]}').Count | Should-Be 0
        Fault '{"schemaVersion": 1, "maxCyclomatic": 0}' | Should-BeLikeString '*at least 1*'
        Fault '{"schemaVersion": 1, "overrides": [{"path": "t", "maxCyclomatic": 0}]}' | Should-BeLikeString 'overrides`[0`].maxCyclomatic must be*at least 1*'
        Fault '{"schemaVersion": 1, "overrides": [{"path": "t", "maxCognitive": -1}]}' | Should-BeLikeString 'overrides`[0`].maxCognitive must be*at least 0*'
    }
}

Describe 'a path in a config' {

    It 'takes a relative path inside the config directory' -ForEach @(
        @{ Value = 'tests' }, @{ Value = './tests/' }, @{ Value = 'a/b.ps1' }, @{ Value = '..a/b' }
    ) {
        Get-PSCxConfigPathFault -Value $Value -Where 'p' | Should-BeNull
    }

    It 'refuses <Why>' -ForEach @(
        @{ Value = $null; Why = 'null'; Like = 'p must be a non-empty string' }
        @{ Value = 3; Why = 'a number'; Like = 'p must be a non-empty string' }
        @{ Value = '  '; Why = 'blank'; Like = 'p must be a non-empty string' }
        @{ Value = 'a\b'; Why = 'a backslash'; Like = '*forward slashes*' }
        @{ Value = '/etc/x'; Why = 'a leading slash'; Like = "*relative to the config's own directory" }
        @{ Value = 'C:/x'; Why = 'a drive, on every platform'; Like = "*relative to the config's own directory" }
        @{ Value = 'a/../../b'; Why = 'a .. segment'; Like = '*outside its own directory' }
        @{ Value = '..'; Why = 'a bare ..'; Like = '*outside its own directory' }
        @{ Value = './'; Why = 'the directory itself'; Like = "*names the config's own directory*" }
        @{ Value = 'a*'; Why = 'a star where no wildcard is allowed'; Like = '*wildcards are for exclude*' }
        @{ Value = 'a?'; Why = 'a question mark where no wildcard is allowed'; Like = '*wildcards are for exclude*' }
    ) {
        Get-PSCxConfigPathFault -Value $Value -Where 'p' | Should-BeLikeString $Like
    }

    It 'takes wildcards only when asked to' {
        Get-PSCxConfigPathFault -Value '**/*.g?.ps1' -Where 'p' -AllowWildcard | Should-BeNull
    }

    It 'splits into segments without empty ones or dots' {
        @(Get-PSCxConfigPathSegment -Path './a//b/./c/') | Should-BeCollection @('a', 'b', 'c')
        @(Get-PSCxConfigPathSegment -Path './').Count | Should-Be 0
    }
}

Describe 'the lists in a config' {

    It 'checks every exclude pattern, naming its index' {
        Fault '{"schemaVersion": 1, "exclude": ["ok", "/bad"]}' | Should-BeLikeString 'exclude`[1`] is ''/bad''*'
    }

    It 'refuses a list that is not one' -ForEach @(@{ Name = 'exclude' }, @{ Name = 'overrides' }, @{ Name = 'accept' }) {
        @(Fault "{`"schemaVersion`": 1, `"$Name`": {}}") | Should-BeCollection @("$Name must be a list")
    }

    It 'takes an empty list' {
        (Fault '{"schemaVersion": 1, "exclude": [], "overrides": [], "accept": []}').Count | Should-Be 0
    }

    It 'refuses an override that is <Why>' -ForEach @(
        @{ Json = '"t"'; Why = 'not an object'; Like = 'overrides`[0`] must be an object*' }
        @{ Json = '{"path": "t"}'; Why = 'setting no ceiling'; Like = '*sets neither maxCyclomatic nor maxCognitive*' }
        @{ Json = '{"path": "t", "maxCyclomatic": 3, "max": 1}'; Why = 'carrying an unknown key'; Like = 'overrides`[0`] has an unknown key ''max''*' }
        @{ Json = '{"path": "t", "maxCyclomatic": 3, "$schema": "x"}'; Why = 'carrying $schema, which only the top level takes'; Like = "*unknown key '`$schema'*" }
        @{ Json = '{"maxCyclomatic": 3}'; Why = 'missing its path'; Like = 'overrides`[0`].path must be a non-empty string' }
        @{ Json = '{"path": "t*", "maxCyclomatic": 3}'; Why = 'a wildcard'; Like = '*wildcards are for exclude*' }
    ) {
        Fault "{`"schemaVersion`": 1, `"overrides`": [$Json]}" | Should-BeLikeString $Like
    }

    It 'refuses two overrides for one path, however it is spelt' {
        $f = @(Fault '{"schemaVersion": 1, "overrides": [{"path": "tests", "maxCyclomatic": 3}, {"path": "./tests/", "maxCognitive": 3}]}')
        $f | Should-BeCollection @("overrides[1] names 'tests' again -- one override per path")
    }

    It 'compares override paths as the file system compares names' {
        $json = '{"schemaVersion": 1, "overrides": [{"path": "tests", "maxCyclomatic": 3}, {"path": "Tests", "maxCognitive": 3}]}'
        (Fault $json -Cmp Ordinal).Count | Should-Be 0
        (Fault $json -Cmp OrdinalIgnoreCase).Count | Should-Be 1
    }

    It 'does not count an override with no usable path as a duplicate' {
        $f = @(Fault '{"schemaVersion": 1, "overrides": [{"path": "./", "maxCyclomatic": 3}, {"path": ".", "maxCyclomatic": 3}]}')
        $f.Count | Should-Be 2
        $f | Should-NotContainCollection @("overrides[1] names '' again -- one override per path")
    }

    It 'refuses an acceptance that is <Why>' -ForEach @(
        @{ Json = '1'; Why = 'not an object'; Like = 'accept`[0`] must be an object*' }
        @{ Json = '{"file": "a.ps1", "unit": "U", "reason": "r", "why": 1}'; Why = 'carrying an unknown key'; Like = 'accept`[0`] has an unknown key ''why''*' }
        @{ Json = '{"file": "../a.ps1", "unit": "U", "reason": "r"}'; Why = 'outside the config directory'; Like = 'accept`[0`].file is*outside*' }
    ) {
        Fault "{`"schemaVersion`": 1, `"accept`": [$Json]}" | Should-BeLikeString $Like
    }

    It 'leaves whether an acceptance still describes the run to the gate' {
        # An empty reason is the gate's acceptance check to refuse, the same as for -Accept.
        (Fault '{"schemaVersion": 1, "accept": [{"file": "a.ps1", "unit": "U", "reason": ""}]}').Count | Should-Be 0
    }

    It 'refuses a key at the top level the config does not take, but not $schema or a comment' {
        $f = @(Get-PSCxConfigKeyFault -Object (Doc '{"$schema": 1, "_x": 2, "a": 3}') -Allowed 'b' -Where 'w' -TopLevel)
        $f | Should-BeCollection @("w has an unknown key 'a' -- the keys it takes are b")
        @(Get-PSCxConfigKeyFault -Object (Doc '{"_x": 2}') -Allowed 'b' -Where 'w').Count | Should-Be 1
    }
}

Describe 'an exclude pattern' {

    It '<Pattern> matches <Path>: <Expected>' -ForEach @(
        @{ Pattern = 'tests'; Path = 'tests'; Expected = $true }
        @{ Pattern = 'tests'; Path = 'tests/a.ps1'; Expected = $true }
        @{ Pattern = './tests/'; Path = 'tests/a/b.ps1'; Expected = $true }
        @{ Pattern = 'tests'; Path = 'tests2/a.ps1'; Expected = $false }
        @{ Pattern = 'tests'; Path = 'src/tests/a.ps1'; Expected = $false }
        @{ Pattern = '*.g.ps1'; Path = 'a.g.ps1'; Expected = $true }
        @{ Pattern = '*.g.ps1'; Path = 'd/a.g.ps1'; Expected = $false }
        @{ Pattern = '*.g.ps1'; Path = 'axgxps1'; Expected = $false }
        @{ Pattern = '**/*.g.ps1'; Path = 'a.g.ps1'; Expected = $true }
        @{ Pattern = '**/*.g.ps1'; Path = 'd/e/a.g.ps1'; Expected = $true }
        @{ Pattern = 'a/**'; Path = 'a/b/c.ps1'; Expected = $true }
        @{ Pattern = 'a/**'; Path = 'b/a/c.ps1'; Expected = $false }
        @{ Pattern = 'a/**/b'; Path = 'a/b/c.ps1'; Expected = $true }
        @{ Pattern = 'a/**/b'; Path = 'a/x/y/b'; Expected = $true }
        @{ Pattern = 'a/**/b'; Path = 'a/xb'; Expected = $false }
        @{ Pattern = 'a?.ps1'; Path = 'ab.ps1'; Expected = $true }
        @{ Pattern = 'a?.ps1'; Path = 'a/.ps1'; Expected = $false }
        @{ Pattern = 'a?.ps1'; Path = 'abc.ps1'; Expected = $false }
        @{ Pattern = 'a*'; Path = 'a/b'; Expected = $true }
        @{ Pattern = 'x/a*'; Path = 'x/ab/c'; Expected = $true }
        @{ Pattern = 'x/a*'; Path = 'xa'; Expected = $false }
    ) {
        (ConvertTo-PSCxGlobRegex -Pattern $Pattern -PathComparison Ordinal).IsMatch($Path) | Should-Be $Expected
    }

    It 'compares case as the run file system does' {
        (ConvertTo-PSCxGlobRegex -Pattern 'Tests' -PathComparison Ordinal).IsMatch('tests/a.ps1') | Should-BeFalse
        (ConvertTo-PSCxGlobRegex -Pattern 'Tests' -PathComparison OrdinalIgnoreCase).IsMatch('tests/a.ps1') | Should-BeTrue
    }
}

Describe 'a resolved config' {

    It 'resolves every path against the config directory, and acceptances against the root' {
        $configPath = Under 'sub/.pscomplexity.json'
        $json = '{"schemaVersion": 1, "maxCyclomatic": 9, "exclude": ["gen"],
            "overrides": [{"path": "./tests/", "maxCognitive": 30}],
            "accept": [{"file": "src/A.ps1", "unit": "Get-A", "reason": "table"}], "baselineFile": "bl/b.json"}'
        $c = Get-PSCxConfigPolicy -Document (Doc $json) -Path $configPath -Root $script:Root -PathComparison $script:PathCmp
        $c.Path | Should-Be $configPath
        $c.Display | Should-Be 'sub/.pscomplexity.json'
        $c.MaxCyclomatic | Should-Be 9
        $c.MaxCognitive | Should-BeNull
        $c.Exclude.Base | Should-Be (Under 'sub')
        @($c.Exclude.Pattern) | Should-BeCollection @('gen')
        $c.Exclude.Regex[0].IsMatch('gen/x.ps1') | Should-BeTrue
        $c.Overrides.Count | Should-Be 1
        $c.Overrides[0].Path | Should-Be 'tests'
        $c.Overrides[0].Full | Should-Be (Under 'sub/tests')
        $c.Overrides[0].MaxCyclomatic | Should-BeNull
        $c.Overrides[0].MaxCognitive | Should-Be 30
        $c.Accept[0].File | Should-Be 'sub/src/A.ps1'
        $c.Accept[0].Unit | Should-Be 'Get-A'
        $c.Accept[0].Reason | Should-Be 'table'
        $c.BaselineFile | Should-Be (Under 'sub/bl/b.json')
    }

    It 'sets nothing the file does not' {
        $c = Get-PSCxConfigPolicy -Document (Doc '{"schemaVersion": 1, "maxCognitive": 4}') -Path $script:ConfigPath -Root $script:Root -PathComparison $script:PathCmp
        $c.MaxCyclomatic | Should-BeNull
        $c.MaxCognitive | Should-Be 4
        $c.Exclude.Pattern.Count | Should-Be 0
        $c.Exclude.Regex.Count | Should-Be 0
        $c.Overrides.Count | Should-Be 0
        $c.Accept.Count | Should-Be 0
        $c.BaselineFile | Should-BeNull
    }

    It 'keeps an override that sets only cyclomatic with cognitive left open' {
        $c = Get-PSCxConfigPolicy -Document (Doc '{"schemaVersion": 1, "overrides": [{"path": "t", "maxCyclomatic": 7}]}') -Path $script:ConfigPath -Root $script:Root -PathComparison $script:PathCmp
        $c.Overrides[0].MaxCyclomatic | Should-Be 7
        $c.Overrides[0].MaxCognitive | Should-BeNull
    }

    It 'joins a path onto a directory with this platform separator' {
        Get-PSCxConfigFull -Directory $script:Root -Path './a//b' | Should-Be (Under 'a/b')
    }
}

Describe 'the policy a gate run applies' {

    BeforeAll {
        $script:Cfg = Get-PSCxConfigPolicy -Path $script:ConfigPath -Root $script:Root -PathComparison $script:PathCmp -Document (Doc '{"schemaVersion": 1,
            "maxCyclomatic": 9, "maxCognitive": 8, "exclude": ["gen"],
            "overrides": [{"path": "tests", "maxCyclomatic": 25}, {"path": "both", "maxCyclomatic": 3, "maxCognitive": 4}],
            "accept": [{"file": "src/A.ps1", "unit": "Get-A", "reason": "table"}], "baselineFile": "b.json"}')
    }

    It 'is 15 and 15 with nothing else, and accepts and excludes nothing' {
        $p = Get-PSCxGatePolicy -Config $null -Bound @{}
        $p.MaxCyclomatic | Should-Be 15
        $p.MaxCognitive | Should-Be 15
        $p.Overrides.Count | Should-Be 0
        $p.Accept.Count | Should-Be 0
        $p.BaselineFile | Should-Be ''
        $p.Exclude | Should-BeNull
        $p.Config | Should-BeNull
    }

    It 'takes what the config sets' {
        $p = Get-PSCxGatePolicy -Config $script:Cfg -Bound @{}
        $p.Config | Should-Be $script:Cfg
        $p.MaxCyclomatic | Should-Be 9
        $p.MaxCognitive | Should-Be 8
        $p.Overrides.Count | Should-Be 2
        $p.Accept[0].Unit | Should-Be 'Get-A'
        $p.BaselineFile | Should-Be (Under 'b.json')
        @($p.Exclude.Pattern) | Should-BeCollection @('gen')
    }

    It 'lets the command line win, ceiling by ceiling, everywhere' {
        $p = Get-PSCxGatePolicy -Config $script:Cfg -Bound @{ MaxCyclomatic = 5 }
        $p.MaxCyclomatic | Should-Be 5
        $p.MaxCognitive | Should-Be 8
        # tests set only cyclomatic, so it no longer applies at all; both keeps its cognitive.
        $p.Overrides.Count | Should-Be 1
        $p.Overrides[0].Path | Should-Be 'both'
        $p.Overrides[0].MaxCyclomatic | Should-BeNull
        $p.Overrides[0].MaxCognitive | Should-Be 4

        $q = Get-PSCxGatePolicy -Config $script:Cfg -Bound @{ MaxCognitive = 6 }
        $q.MaxCyclomatic | Should-Be 9
        $q.MaxCognitive | Should-Be 6
        $q.Overrides.Count | Should-Be 2
        $q.Overrides[1].MaxCyclomatic | Should-Be 3
        $q.Overrides[1].MaxCognitive | Should-BeNull
    }

    It 'replaces the acceptances and the baseline when the command line names them, even as empty' {
        $p = Get-PSCxGatePolicy -Config $script:Cfg -Bound @{ Accept = @(); BaselineFile = 'other.json' }
        $p.Accept.Count | Should-Be 0
        $p.BaselineFile | Should-Be 'other.json'
    }

    It 'uses a ceiling the command line gives without a config' {
        $p = Get-PSCxGatePolicy -Config $null -Bound @{ MaxCyclomatic = 2; MaxCognitive = 0 }
        $p.MaxCyclomatic | Should-Be 2
        $p.MaxCognitive | Should-Be 0
    }

    It 'drops an override the command line leaves setting nothing' {
        @(Get-PSCxEffectiveOverride -Override @(Override 'a' 3 4) -CyclomaticGiven $true -CognitiveGiven $true).Count | Should-Be 0
        @(Get-PSCxEffectiveOverride -Override @(Override 'a' 3 4) -CyclomaticGiven $false -CognitiveGiven $false).Count | Should-Be 1
        $o = @(Get-PSCxEffectiveOverride -Override @(Override 'a' 3 $null) -CyclomaticGiven $false -CognitiveGiven $true)
        $o[0].MaxCyclomatic | Should-Be 3
        $o[0].Full | Should-Be (Under 'a')
    }
}

Describe 'the ceilings a file faces' {

    It 'is empty with no overrides, so every unit faces the run ceilings' {
        (Ceiling -Units @(Unit) -Overrides @()).Count | Should-Be 0
    }

    It 'holds only the files an override reaches' {
        $map = Ceiling -Units @((Unit 'tests/a.ps1'), (Unit 'src/b.ps1'), (Unit 'tests2/c.ps1')) -Overrides @(Override 'tests' 25 30)
        $map.Count | Should-Be 1
        $map['tests/a.ps1'].Cyclomatic | Should-Be 25
        $map['tests/a.ps1'].Cognitive | Should-Be 30
    }

    It 'gives each metric to the deepest override that sets it, whatever order they come in' {
        $overrides = @((Override 'tests/fixtures' $null 40), (Override 'tests' 25 30), (Override 'tests/fixtures/deep' 50 $null))
        $map = Ceiling -Units @((Unit 'tests/fixtures/deep/a.ps1'), (Unit 'tests/fixtures/b.ps1'), (Unit 'tests/c.ps1')) -Overrides $overrides
        $map['tests/fixtures/deep/a.ps1'].Cyclomatic | Should-Be 50
        $map['tests/fixtures/deep/a.ps1'].Cognitive | Should-Be 40
        $map['tests/fixtures/b.ps1'].Cyclomatic | Should-Be 25
        $map['tests/fixtures/b.ps1'].Cognitive | Should-Be 40
        $map['tests/c.ps1'].Cyclomatic | Should-Be 25
    }

    It 'falls back to the run ceiling for a metric no reaching override sets' {
        $map = Ceiling -Units @(Unit 'tests/a.ps1') -Overrides @(Override 'tests' $null 30) -Cyc 7 -Cog 8
        $map['tests/a.ps1'].Cyclomatic | Should-Be 7
        $map['tests/a.ps1'].Cognitive | Should-Be 30
        $map = Ceiling -Units @(Unit 'tests/a.ps1') -Overrides @(Override 'tests' 20 $null) -Cyc 7 -Cog 8
        $map['tests/a.ps1'].Cyclomatic | Should-Be 20
        $map['tests/a.ps1'].Cognitive | Should-Be 8
    }

    It 'reaches a file an override names exactly' {
        (Ceiling -Units @(Unit 'src/Big.ps1') -Overrides @(Override 'src/Big.ps1' 40 $null))['src/Big.ps1'].Cyclomatic | Should-Be 40
    }

    It 'reaches a file outside the root only by its full path' {
        $outside = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'elsewhere/a.ps1')).Replace($script:Sep, '/')
        (Ceiling -Units @(Unit $outside) -Overrides @(Override 'tests' 25 $null)).Count | Should-Be 0
        $o = [pscustomobject]@{ Path = 'x'; Full = (Split-Path -Parent $outside.Replace('/', $script:Sep)); MaxCyclomatic = 33; MaxCognitive = $null }
        (Ceiling -Units @(Unit $outside) -Overrides @($o))[$outside].Cyclomatic | Should-Be 33
    }

    It 'compares paths as the run file system does, in the match and in the map' {
        (Ceiling -Units @(Unit 'Tests/a.ps1') -Overrides @(Override 'tests' 25 $null) -Cmp Ordinal).Count | Should-Be 0
        $map = Ceiling -Units @(Unit 'Tests/a.ps1') -Overrides @(Override 'tests' 25 $null) -Cmp OrdinalIgnoreCase
        $map['TESTS/A.PS1'].Cyclomatic | Should-Be 25
    }

    It 'lists each file once however many units it holds' {
        (Ceiling -Units @((Unit 'tests/a.ps1'), (Unit 'tests/a.ps1')) -Overrides @(Override 'tests' 25 $null)).Count | Should-Be 1
    }
}

Describe 'the published config schema' {

    BeforeAll {
        $script:schemaText = Get-Content -LiteralPath $script:schemaPath -Raw
        # The return value is the verdict (#197): 7.6.7 writes no error for a fault in a list.
        function script:SchemaAccepts { param([string]$Json) return (Test-Json -Json $Json -Schema $script:schemaText -ErrorAction SilentlyContinue) }
    }

    It 'agrees with the module on <Json>' -ForEach @(
        @{ Json = '{"schemaVersion": 1}' }
        @{ Json = '{"$schema": "x", "_c": 1, "schemaVersion": 1, "maxCyclomatic": 1, "maxCognitive": 0, "exclude": ["**/*.g.ps1", "./t/"], "overrides": [{"path": "t", "maxCognitive": 2}], "accept": [{"file": "a.ps1", "unit": "U", "reason": "r"}], "baselineFile": "b.json"}' }
        @{ Json = '{}' }
        @{ Json = '{"schemaVersion": 2}' }
        @{ Json = '{"schemaVersion": 1, "x": 1}' }
        @{ Json = '{"schemaVersion": 1, "maxCyclomatic": 0}' }
        @{ Json = '{"schemaVersion": 1, "maxCognitive": -1}' }
        @{ Json = '{"schemaVersion": 1, "maxCyclomatic": 1.5}' }
        @{ Json = '{"schemaVersion": 1, "exclude": "t"}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["/t"]}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["C:/t"]}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["a\\b"]}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["a/../b"]}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["./"]}' }
        @{ Json = '{"schemaVersion": 1, "exclude": ["..a"]}' }
        @{ Json = '{"schemaVersion": 1, "overrides": [{"path": "t"}]}' }
        @{ Json = '{"schemaVersion": 1, "overrides": [{"path": "t*", "maxCyclomatic": 2}]}' }
        @{ Json = '{"schemaVersion": 1, "overrides": [{"path": "t", "maxCyclomatic": 2, "y": 1}]}' }
        @{ Json = '{"schemaVersion": 1, "accept": [{"file": "a.ps1", "unit": "U", "reason": "r", "y": 1}]}' }
        @{ Json = '{"schemaVersion": 1, "baselineFile": "../b.json"}' }
    ) {
        $module = (Fault $Json).Count -eq 0
        SchemaAccepts -Json $Json | Should-Be $module
    }
}
