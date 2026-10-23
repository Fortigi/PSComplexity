# Finding, reading and applying a config file (#164).
#
# The COVERING SUITE for src/ConfigFile.ps1. Cheap: every fixture is a few empty directories and a
# small JSON file under a GUID-named temp directory, and nothing is measured. A fixture repository
# is a directory holding .git, which is all discovery looks for.

BeforeAll {
    $script:PathCmp = $IsLinux ? [System.StringComparison]::Ordinal : [System.StringComparison]::OrdinalIgnoreCase
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    $script:work = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) "cxcfgfile-$([System.Guid]::NewGuid().ToString('N'))"))
    New-Item -ItemType Directory -Path $script:work -Force | Out-Null

    function script:NewDir {
        param([string]$Relative)
        $p = Join-Path $script:work $Relative
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        return $p
    }
    function script:NewRepo {
        # A fresh repository under the work directory, with .git as a directory or as a file.
        param([switch]$GitFile)
        $repo = NewDir "repo-$([System.Guid]::NewGuid().ToString('N'))"
        if ($GitFile) { Set-Content -LiteralPath (Join-Path $repo '.git') -Value 'gitdir: elsewhere' }
        else { New-Item -ItemType Directory -Path (Join-Path $repo '.git') | Out-Null }
        return $repo
    }
    function script:WriteConfig {
        param([string]$Directory, [string]$Json = '{"schemaVersion": 1}')
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $p = Join-Path $Directory '.pscomplexity.json'
        Set-Content -LiteralPath $p -Value $Json -Encoding utf8
        return $p
    }
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'where discovery starts' {

    It 'is a directory itself, the directory of a file, and the nearest existing directory of anything else' {
        $d = NewDir 'start/a'
        Set-Content -LiteralPath (Join-Path $d 'f.ps1') -Value ''
        Get-PSCxSearchStart -Path $d -Root $script:work | Should-Be $d
        Get-PSCxSearchStart -Path (Join-Path $d 'f.ps1') -Root $script:work | Should-Be $d
        Get-PSCxSearchStart -Path (Join-Path $d 'missing/deeper/x.ps1') -Root $script:work | Should-Be $d
        Get-PSCxSearchStart -Path (Join-Path $d '*.ps1') -Root $script:work | Should-Be $d
    }

    It 'resolves a relative path against the root it is given' {
        $d = NewDir 'start/rel'
        Get-PSCxSearchStart -Path 'start/rel' -Root $script:work | Should-Be $d
    }
}

Describe 'the repository root' {

    It 'is the nearest directory holding .git, as a directory or as a file' {
        foreach ($repo in (NewRepo), (NewRepo -GitFile)) {
            $deep = Join-Path $repo 'a/b'
            New-Item -ItemType Directory -Path $deep -Force | Out-Null
            Get-PSCxRepositoryRoot -Directory $deep | Should-Be $repo
            Get-PSCxRepositoryRoot -Directory $repo | Should-Be $repo
        }
    }

    It 'is nothing outside a repository, and for no directory at all' {
        Get-PSCxRepositoryRoot -Directory (NewDir 'norepo/x') | Should-BeNull
        Get-PSCxRepositoryRoot -Directory '' | Should-BeNull
    }
}

Describe 'finding the config for one path' {

    It 'finds the config at the repository root from deep inside it' {
        $repo = NewRepo
        $config = WriteConfig $repo
        $deep = Join-Path $repo 'src/a'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null
        Find-PSCxConfigFile -Path $deep -Root $script:work | Should-Be $config
    }

    It 'prefers the nearer of two configs' {
        $repo = NewRepo
        WriteConfig $repo | Out-Null
        $near = WriteConfig (Join-Path $repo 'tests')
        Find-PSCxConfigFile -Path (Join-Path $repo 'tests') -Root $script:work | Should-Be $near
    }

    It 'stops at the repository root, never reading a config above it' {
        $outer = NewDir "outer-$([System.Guid]::NewGuid().ToString('N'))"
        WriteConfig $outer | Out-Null
        $repo = Join-Path $outer 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        Find-PSCxConfigFile -Path $repo -Root $script:work | Should-BeNull
    }

    It 'finds nothing outside a repository, even beside a config' {
        $plain = NewDir "plain-$([System.Guid]::NewGuid().ToString('N'))"
        WriteConfig $plain | Out-Null
        Find-PSCxConfigFile -Path $plain -Root $script:work | Should-BeNull
    }

    It 'ignores a DIRECTORY with the config name' {
        $repo = NewRepo
        New-Item -ItemType Directory -Path (Join-Path $repo '.pscomplexity.json') | Out-Null
        Find-PSCxConfigFile -Path $repo -Root $script:work | Should-BeNull
    }
}

Describe 'finding the config for a run' {

    It 'is the config every path shares, or nothing when none has one' {
        $repo = NewRepo
        $config = WriteConfig $repo
        New-Item -ItemType Directory -Path (Join-Path $repo 'a'), (Join-Path $repo 'b') -Force | Out-Null
        Find-PSCxRunConfigFile -Path (Join-Path $repo 'a'), (Join-Path $repo 'b') -Root $script:work -PathComparison $script:PathCmp | Should-Be $config
        $bare = NewRepo
        Find-PSCxRunConfigFile -Path $bare -Root $script:work -PathComparison $script:PathCmp | Should-BeNull
    }

    It 'refuses paths under different configs, naming each' {
        $one = NewRepo; WriteConfig $one | Out-Null
        $two = NewRepo; WriteConfig $two | Out-Null
        { Find-PSCxRunConfigFile -Path $one, $two -Root $script:work -PathComparison $script:PathCmp } |
            Should-Throw -ExceptionMessage "*different configs: $one -> $one*.pscomplexity.json; $two -> $two*.pscomplexity.json. *-ConfigFile*"
    }

    It 'refuses a path under a config beside one under none' {
        $one = NewRepo; WriteConfig $one | Out-Null
        $none = NewRepo
        { Find-PSCxRunConfigFile -Path $one, $none -Root $script:work -PathComparison $script:PathCmp } |
            Should-Throw -ExceptionMessage "*$none -> no config*"
    }

    It 'names the config as the first path spells it, when a case-insensitive comparison joins two spellings' {
        # Two spellings of one directory are one config where paths compare without case, so the
        # run is not refused -- and the name it reports is the first path's, not the last's.
        Mock Find-PSCxConfigFile { (Split-Path -Parent $Path) + '/.pscomplexity.json' }
        Find-PSCxRunConfigFile -Path 'R/One/a', 'r/one/b' -Root $script:work -PathComparison ([System.StringComparison]::OrdinalIgnoreCase) |
            Should-BeString -CaseSensitive 'R/One/.pscomplexity.json'
    }
}

Describe 'reading a config' {

    It 'resolves a valid one, naming its full path' {
        $repo = NewRepo
        $config = WriteConfig $repo '{"schemaVersion": 1, "maxCyclomatic": 4}'
        $c = Read-PSCxConfig -Path $config -Root $script:work -PathComparison $script:PathCmp
        $c.Path | Should-Be $config
        $c.MaxCyclomatic | Should-Be 4
    }

    It 'resolves a relative path against the root' {
        $repo = NewRepo
        $config = WriteConfig $repo
        $c = Read-PSCxConfig -Path ((Split-Path -Leaf $repo) + '/.pscomplexity.json') -Root $script:work -PathComparison $script:PathCmp
        $c.Path | Should-Be $config
    }

    It 'refuses an invalid one, naming the file and every fault' {
        $config = WriteConfig (NewRepo) '{"schemaVersion": 1, "maxCyclomatic": 0, "x": 1}'
        { Read-PSCxConfig -Path $config -Root $script:work -PathComparison $script:PathCmp } |
            Should-Throw -ExceptionMessage "Cannot use the config $config : *unknown key 'x'*; maxCyclomatic must be*."
    }

    It 'refuses one with a single fault' {
        # One, not two: the refusal is "any fault", and a fixture with several cannot tell that
        # from "more than one".
        $config = WriteConfig (NewRepo) '{"schemaVersion": 1, "maxCyclomatic": 0}'
        { Read-PSCxConfig -Path $config -Root $script:work -PathComparison $script:PathCmp } |
            Should-Throw -ExceptionMessage "Cannot use the config $config : maxCyclomatic must be*."
    }

    It 'refuses a file that is not there' {
        $missing = Join-Path $script:work 'nope/.pscomplexity.json'
        { Read-PSCxConfig -Path $missing -Root $script:work -PathComparison $script:PathCmp } |
            Should-Throw -ExceptionMessage "*No such file*"
    }
}

Describe 'the policy a gate run resolves' {

    BeforeAll {
        $script:repo = NewRepo
        WriteConfig $script:repo '{"schemaVersion": 1, "maxCyclomatic": 4, "baselineFile": "b.json"}' | Out-Null
        $script:other = WriteConfig (NewDir "loose-$([System.Guid]::NewGuid().ToString('N'))") '{"schemaVersion": 1, "maxCognitive": 2}'
        function script:Resolve {
            param([hashtable]$Bound, [string[]]$Path = @('.'))
            Push-Location $script:repo
            try { return Resolve-PSCxGatePolicy -Bound $Bound -Path $Path }
            finally { Pop-Location }
        }
    }

    It 'discovers the config, and says which one it used' {
        # Ignore, not SilentlyContinue: a redirect captures a silently-continued record anyway, so
        # only Ignore tells "shown regardless of the preference" from "left to the preference".
        $InformationPreference = 'Ignore'
        $out = Resolve @{} 6>&1
        $policy = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[0]
        $said = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $policy.MaxCyclomatic | Should-Be 4
        $said.Count | Should-Be 1
        "$($said[0].MessageData)" | Should-Be 'Using config .pscomplexity.json'
    }

    It 'stays quiet when the caller asked for quiet' {
        $InformationPreference = 'Ignore'
        @(Resolve @{ InformationAction = 'Ignore' } 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should-Be 0
    }

    It 'says nothing when there is no config' {
        @(Resolve @{ NoConfig = [switch]$true } 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should-Be 0
    }

    It 'applies no config with -NoConfig, and discovers one with -NoConfig:$false' {
        (Resolve @{ NoConfig = [switch]$true } 6>$null).MaxCyclomatic | Should-Be 15
        (Resolve @{ NoConfig = [switch]$false } 6>$null).MaxCyclomatic | Should-Be 4
    }

    It 'applies the config -ConfigFile names instead of the one it would find' {
        $p = Resolve @{ ConfigFile = $script:other } 6>$null
        $p.MaxCyclomatic | Should-Be 15
        $p.MaxCognitive | Should-Be 2
    }

    It 'refuses -ConfigFile beside -NoConfig' {
        { Resolve @{ ConfigFile = $script:other; NoConfig = [switch]$true } } | Should-Throw -ExceptionMessage '-ConfigFile and -NoConfig contradict*'
    }

    It 'updates the baseline the config names' {
        (Resolve @{ UpdateBaseline = [switch]$true } 6>$null).BaselineFile | Should-Be (Join-Path $script:repo 'b.json')
    }

    It 'refuses -UpdateBaseline with no baseline anywhere' {
        { Resolve @{ UpdateBaseline = [switch]$true; NoConfig = [switch]$true } } |
            Should-Throw -ExceptionMessage '-UpdateBaseline needs -BaselineFile, or a baselineFile in the config*'
    }

    It 'refuses -UpdateBaseline over the changed files only, and takes -ChangedFile without it (#203)' {
        { Resolve @{ UpdateBaseline = [switch]$true; ChangedFile = @('a.ps1') } 6>$null } |
            Should-Throw -ExceptionMessage '-UpdateBaseline cannot be combined with -ChangedFile*whole-tree run.'
        (Resolve @{ UpdateBaseline = [switch]$false; ChangedFile = @('a.ps1') } 6>$null).BaselineFile | Should-BeLikeString '*b.json'
        { Resolve @{ UpdateBaseline = [switch]$true; ChangedDiff = @('x') } 6>$null } |
            Should-Throw -ExceptionMessage '-UpdateBaseline cannot be combined with -ChangedFile or -ChangedDiff*'
    }

    It 'refuses -AllowNew without -UpdateBaseline, and takes it with one' {
        { Resolve @{ AllowNew = [switch]$true } 6>$null } | Should-Throw -ExceptionMessage '-AllowNew only applies with -UpdateBaseline*'
        { Resolve @{ AllowNew = [switch]$true; UpdateBaseline = [switch]$false } 6>$null } | Should-Throw -ExceptionMessage '-AllowNew only*'
        (Resolve @{ AllowNew = [switch]$true; UpdateBaseline = [switch]$true } 6>$null).BaselineFile | Should-BeLikeString '*b.json'
        (Resolve @{ AllowNew = [switch]$false } 6>$null).MaxCyclomatic | Should-Be 4
    }
}
