# The config file (#164): what a .pscomplexity.json may say, and what it means for one gate run.
#
# Pure. Finding the file and reading it off a disk is ConfigFile.ps1's half, for the reason Policy
# and BaselineFile are two files: this half decides, so it is tested without a disk, and every
# mutant of it re-runs a suite that needs none.
#
# Everything a config names that is a PATH is relative to the directory the config sits in, never
# to the working directory. The file is committed at one place in a repository and read from
# wherever somebody happens to run the gate; a path that meant something different from a
# subdirectory would make the same file two policies.

# The config FORMAT, versioned on its own like the baseline file, because it changes for its own
# reasons: a field changing meaning or going away. A config naming another version is refused,
# never read as though it were this one.
$script:PSCxConfigSchemaVersion = 1

# The ceiling a unit faces when nothing says otherwise. Here rather than as a parameter default on
# Test-PSComplexity, because the default now applies only when NEITHER the command line NOR the
# config sets one -- and a parameter default cannot tell "not given" from "given as 15".
$script:PSCxDefaultCeiling = 15

# The keys a config may hold at the top level. `$schema` is there for editors, which use it to
# validate and complete the file; a `_`-prefixed key is a comment, as in PSMutant's config. Anything
# else is refused, because a misspelt key -- maxCognitve -- is otherwise a setting that silently
# does nothing, and the one it meant to set keeps its default.
$script:PSCxConfigKey = @('schemaVersion', 'maxCyclomatic', 'maxCognitive', 'exclude', 'overrides', 'accept', 'baselineFile')

function Get-PSCxConfigKeyFault {
    # The keys on one config object that are not allowed there, as text. Nothing when all are.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string[]]$Allowed,
        # Where the object sits, for the message: 'the config', 'overrides[2]'.
        [Parameter(Mandatory)] [string]$Where,
        # Only the top level takes $schema and comments. Inside an entry a stray key is a typo.
        [switch]$TopLevel
    )
    foreach ($name in $Object.PSObject.Properties.Name) {
        if ($name -in $Allowed) { continue }
        if ($TopLevel -and ($name -eq '$schema' -or $name.StartsWith('_'))) { continue }
        "$Where has an unknown key '$name' -- the keys it takes are $($Allowed -join ', ')"
    }
}

function Get-PSCxCeilingValueFault {
    # Why one ceiling value cannot be used, as text. Nothing when it can.
    #
    # A whole number at or above the metric's floor. JSON's 15.0 arrives as a double and is refused rather than
    # truncated: a ceiling is a count, and a reader of the file should see the number the gate uses.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [Parameter(Mandatory)] [string]$Where,
        # 1 for cyclomatic, which every unit scores at least; 0 for cognitive, where a ceiling of
        # 0 is a real policy -- no branching at all -- as the report schema already allows.
        [Parameter(Mandatory)] [int]$Minimum
    )
    if (($Value -is [long] -or $Value -is [int]) -and $Value -ge $Minimum) { return }
    return "$Where must be a whole number of at least $Minimum, got '$Value'"
}

function Get-PSCxConfigPathFault {
    # Why one path in a config cannot be used, as text. Nothing when it can.
    #
    # Relative to the config's own directory, forward slashes, and inside it. A rooted path would
    # make the committed file mean something on one machine only; a `..` would let it reach out of
    # the tree it is committed in; a backslash is an ordinary file-name character on Linux, so a
    # Windows-spelt path would silently match nothing there.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Value,
        [Parameter(Mandatory)] [string]$Where,
        # Exclude patterns take * and ?; an override path or a file name does not, because "the
        # most specific path wins" needs paths that can be ordered by depth.
        [switch]$AllowWildcard
    )
    if ($Value -isnot [string] -or -not $Value.Trim()) { return "$Where must be a non-empty string" }
    if ($Value.Contains('\')) { return "$Where is '$Value' -- write paths with forward slashes, which mean the same on every platform" }
    # Spelt out rather than asked of IsPathRooted, which answers for THIS platform: C:/x is rooted
    # on Windows and an ordinary relative name on Linux, and one committed file must mean the same
    # on both CI legs.
    if ($Value.StartsWith('/') -or $Value -match '^[A-Za-z]:') {
        return "$Where is '$Value' -- paths in a config are relative to the config's own directory"
    }
    $segments = @(Get-PSCxConfigPathSegment -Path $Value)
    if ($segments -contains '..') { return "$Where is '$Value' -- a config cannot name a path outside its own directory" }
    if ($segments.Count -eq 0) { return "$Where is '$Value', which names the config's own directory -- that is every file" }
    if (-not $AllowWildcard -and ($Value.Contains('*') -or $Value.Contains('?'))) {
        return "$Where is '$Value' -- wildcards are for exclude, not here"
    }
}

function Get-PSCxConfigPathSegment {
    # A config path's segments, without the empty ones a doubled or trailing slash leaves and
    # without '.', so './tests/' and 'tests' are the same path.
    [OutputType([string[]])]
    [CmdletBinding()]
    # AllowEmptyString: an override with no path reaches here as '' on its way to being refused.
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Path)
    return [string[]]@($Path -split '/' | Where-Object { $_ -and $_ -ne '.' })
}

function Get-PSCxOverrideFault {
    # Why one per-path override cannot be used, as text. Nothing when it can.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Override,
        [Parameter(Mandatory)] [string]$Where
    )
    if ($Override -isnot [System.Management.Automation.PSCustomObject]) { return "$Where must be an object with a path and a ceiling" }
    Get-PSCxConfigKeyFault -Object $Override -Allowed 'path', 'maxCyclomatic', 'maxCognitive' -Where $Where
    Get-PSCxConfigPathFault -Value $Override.path -Where "$Where.path"
    $names = $Override.PSObject.Properties.Name
    # An override that sets neither ceiling changes nothing, and reads as though it did.
    if ('maxCyclomatic' -notin $names -and 'maxCognitive' -notin $names) {
        return "$Where sets neither maxCyclomatic nor maxCognitive, so it changes nothing"
    }
    if ('maxCyclomatic' -in $names) { Get-PSCxCeilingValueFault -Value $Override.maxCyclomatic -Where "$Where.maxCyclomatic" -Minimum 1 }
    if ('maxCognitive' -in $names) { Get-PSCxCeilingValueFault -Value $Override.maxCognitive -Where "$Where.maxCognitive" -Minimum 0 }
}

function Get-PSCxConfigAcceptFault {
    # Why one acceptance in a config cannot be used, as text. Nothing when it can.
    #
    # Its SHAPE only. Whether it still describes the run -- the unit exists, still breaches, has a
    # reason -- is the gate's acceptance check, which the command line's -Accept goes through too.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Acceptance,
        [Parameter(Mandatory)] [string]$Where
    )
    if ($Acceptance -isnot [System.Management.Automation.PSCustomObject]) { return "$Where must be an object with file, unit and reason" }
    Get-PSCxConfigKeyFault -Object $Acceptance -Allowed 'file', 'unit', 'reason' -Where $Where
    Get-PSCxConfigPathFault -Value $Acceptance.file -Where "$Where.file"
}

function Get-PSCxConfigListFault {
    # Why one list in a config cannot be used, as text, checking each entry. Nothing when it can.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)] [ValidateSet('exclude', 'overrides', 'accept')] [string]$Name,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    if ($Name -notin $Document.PSObject.Properties.Name) { return }
    $list = $Document.$Name
    if ($list -isnot [array]) { return "$Name must be a list" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::FromComparison($PathComparison))
    for ($i = 0; $i -lt $list.Count; $i++) {
        $where = "$Name[$i]"
        switch ($Name) {
            'exclude' { Get-PSCxConfigPathFault -Value $list[$i] -Where $where -AllowWildcard }
            'accept' { Get-PSCxConfigAcceptFault -Acceptance $list[$i] -Where $where }
            'overrides' {
                Get-PSCxOverrideFault -Override $list[$i] -Where $where
                # Two overrides for one path leave "the most specific wins" with no answer.
                $key = (Get-PSCxConfigPathSegment -Path ([string]$list[$i].path)) -join '/'
                if ($key -and -not $seen.Add($key)) { "$where names '$key' again -- one override per path" }
            }
        }
    }
}

function Get-PSCxConfigFault {
    # Every reason a config document cannot be used, as text. Nothing when it can.
    #
    # All of them rather than the first, so fixing a hand-edited file is one round trip. Checked
    # here rather than by the published schema: Test-Json words its messages differently on every
    # PowerShell, and on 7.6.7 writes none at all for a fault inside a list (#197). The schema ships
    # for editors, and a test holds the two to the same answers.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Document,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    # The full type name, never [pscustomobject]: as a type TEST that accelerator means PSObject,
    # which any value passed down a pipeline is wrapped in, so a bare number passed it.
    if ($Document -isnot [System.Management.Automation.PSCustomObject]) { return 'a config is a JSON object' }
    $names = $Document.PSObject.Properties.Name
    # The version first and alone: under another version every other key may mean something else.
    if ('schemaVersion' -notin $names) { return "the config has no schemaVersion -- this PSComplexity reads $script:PSCxConfigSchemaVersion" }
    if ($Document.schemaVersion -ne $script:PSCxConfigSchemaVersion) {
        return "the config is schemaVersion $($Document.schemaVersion) and this PSComplexity reads $script:PSCxConfigSchemaVersion"
    }
    Get-PSCxConfigKeyFault -Object $Document -Allowed $script:PSCxConfigKey -Where 'the config' -TopLevel
    if ('maxCyclomatic' -in $names) { Get-PSCxCeilingValueFault -Value $Document.maxCyclomatic -Where 'maxCyclomatic' -Minimum 1 }
    if ('maxCognitive' -in $names) { Get-PSCxCeilingValueFault -Value $Document.maxCognitive -Where 'maxCognitive' -Minimum 0 }
    foreach ($list in 'exclude', 'overrides', 'accept') {
        Get-PSCxConfigListFault -Document $Document -Name $list -PathComparison $PathComparison
    }
    if ('baselineFile' -in $names) { Get-PSCxConfigPathFault -Value $Document.baselineFile -Where 'baselineFile' }
}

function ConvertTo-PSCxGlobRegex {
    # One exclude pattern as a regular expression over a path relative to the config's directory.
    #
    # `*` and `?` stay inside one segment, `**` spans any number of them, and a pattern also matches
    # everything BELOW what it names -- so `tests/fixtures` excludes the directory without needing
    # `/**`, as .gitignore reads it.
    [OutputType([regex])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Pattern,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $segments = @(Get-PSCxConfigPathSegment -Path $Pattern)
    $body = ''
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $last = $i -eq $segments.Count - 1
        if ($segments[$i] -eq '**') {
            $body += $last ? '.*' : '(?:[^/]+/)*'
            continue
        }
        $body += [regex]::Escape($segments[$i]).Replace('\*', '[^/]*').Replace('\?', '[^/]')
        if (-not $last) { $body += '/' }
    }
    # Case as the run's file system compares names, the same rule every other path here follows.
    $options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($PathComparison -eq [System.StringComparison]::OrdinalIgnoreCase) {
        $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    return [regex]::new("^$body(?:/.*)?$", $options)
}

function Get-PSCxConfigFull {
    # A config-relative path as a full path, spelt with this platform's separator.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Directory,
        [Parameter(Mandatory)] [string]$Path
    )
    # The segments go in as -AdditionalChildPath rather than joined first: PowerShell 7.6 made
    # -ChildPath a list, so a -join here does nothing there and is needed below it -- code no test on
    # the newest host can pin. -AdditionalChildPath reads the same from 6.0 on, and the '.' it hangs
    # off is gone after GetFullPath.
    $segments = Get-PSCxConfigPathSegment -Path $Path
    return [System.IO.Path]::GetFullPath((Join-Path -Path $Directory -ChildPath '.' -AdditionalChildPath $segments))
}

function Get-PSCxConfigPolicy {
    # A valid config document, resolved against the directory it sits in.
    #
    # Every path becomes a full path, and every acceptance's file becomes the File a record carries
    # -- relative to the working root -- because that is what the gate matches it against. Only the
    # keys the file SETS are set here: whether a ceiling came from the file or from nowhere is what
    # lets the command line override one and not the other.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Document,
        # The full path of the config file itself, for the report and for resolving what it names.
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $directory = Split-Path -Parent $Path
    $names = $Document.PSObject.Properties.Name
    $patterns = [string[]]@($Document.exclude | Where-Object { $null -ne $_ })
    return [pscustomobject]@{
        Path          = $Path
        # How the report and the console name it: as a record names a File, so the two read alike.
        Display       = Get-PSCxRelativePath -Path $Path -Root $Root -PathComparison $PathComparison
        MaxCyclomatic = ('maxCyclomatic' -in $names) ? [int]$Document.maxCyclomatic : $null
        MaxCognitive  = ('maxCognitive' -in $names) ? [int]$Document.maxCognitive : $null
        Exclude       = [pscustomobject]@{
            Base    = $directory
            Pattern = $patterns
            Regex   = [regex[]]@($patterns | ForEach-Object { ConvertTo-PSCxGlobRegex -Pattern $_ -PathComparison $PathComparison })
        }
        Overrides     = @($Document.overrides | Where-Object { $null -ne $_ } | ForEach-Object {
                $o = $_.PSObject.Properties.Name
                [pscustomobject]@{
                    Path          = (Get-PSCxConfigPathSegment -Path $_.path) -join '/'
                    Full          = Get-PSCxConfigFull -Directory $directory -Path $_.path
                    MaxCyclomatic = ('maxCyclomatic' -in $o) ? [int]$_.maxCyclomatic : $null
                    MaxCognitive  = ('maxCognitive' -in $o) ? [int]$_.maxCognitive : $null
                }
            })
        Accept        = @($Document.accept | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{
                    File   = Get-PSCxRelativePath -Path (Get-PSCxConfigFull -Directory $directory -Path $_.file) -Root $Root -PathComparison $PathComparison
                    Unit   = [string]$_.unit
                    Reason = [string]$_.reason
                }
            })
        BaselineFile  = ('baselineFile' -in $names) ? (Get-PSCxConfigFull -Directory $directory -Path $Document.baselineFile) : $null
    }
}

function Get-PSCxGatePolicy {
    # What this gate run applies: the command line where it says something, the config where it
    # does not, the default where neither does.
    #
    # An explicit ceiling wins EVERYWHERE, per-path overrides included. A caller who types
    # -MaxCognitive 10 means every unit, and an override that quietly kept tests/ at 25 would make
    # the flag mean "10, except where somebody once wrote otherwise". The two metrics are decided
    # separately, so -MaxCyclomatic alone leaves the file's cognitive ceilings as they were.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # The resolved config, or $null when the run has none.
        [Parameter(Mandatory)] [AllowNull()] $Config,
        # The gate's $PSBoundParameters: what was given, which is not what has a value.
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Bound
    )
    $cyclomaticGiven = $Bound.ContainsKey('MaxCyclomatic')
    $cognitiveGiven = $Bound.ContainsKey('MaxCognitive')
    $overrides = @(Get-PSCxEffectiveOverride -Override @($Config.Overrides | Where-Object { $null -ne $_ }) `
            -CyclomaticGiven $cyclomaticGiven -CognitiveGiven $cognitiveGiven)
    return [pscustomobject]@{
        Config        = $Config
        MaxCyclomatic = $cyclomaticGiven ? [int]$Bound['MaxCyclomatic'] : ($Config.MaxCyclomatic ?? $script:PSCxDefaultCeiling)
        MaxCognitive  = $cognitiveGiven ? [int]$Bound['MaxCognitive'] : ($Config.MaxCognitive ?? $script:PSCxDefaultCeiling)
        Overrides     = $overrides
        Accept        = $Bound.ContainsKey('Accept') ? @($Bound['Accept']) : @($Config.Accept | Where-Object { $null -ne $_ })
        BaselineFile  = $Bound.ContainsKey('BaselineFile') ? [string]$Bound['BaselineFile'] : [string]$Config.BaselineFile
        Exclude       = $Config.Exclude
    }
}

function Get-PSCxEffectiveOverride {
    # The config's overrides with every metric the command line set taken out, and an override
    # left setting nothing dropped -- so the report lists only the per-path ceilings that applied.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Override,
        [Parameter(Mandatory)] [bool]$CyclomaticGiven,
        [Parameter(Mandatory)] [bool]$CognitiveGiven
    )
    foreach ($o in $Override) {
        $effective = [pscustomobject]@{
            Path          = $o.Path
            Full          = $o.Full
            MaxCyclomatic = $CyclomaticGiven ? $null : $o.MaxCyclomatic
            MaxCognitive  = $CognitiveGiven ? $null : $o.MaxCognitive
        }
        if ($null -ne $effective.MaxCyclomatic -or $null -ne $effective.MaxCognitive) { $effective }
    }
}

function Get-PSCxFileCeiling {
    # File -> the ceilings its units face, for every measured file an override reaches. A file no
    # override reaches is left out, and faces the run's ceilings.
    #
    # The most specific override wins, per metric: tests/ at cyclomatic 25 and tests/fixtures/ at
    # cognitive 30 give a fixture both. Overrides name directories or files and never wildcards, so
    # "most specific" is "deepest", and two overrides of one depth cannot both reach a file.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'Keyed by File, which compares as the run file system compares names (#151); the literal @{} always ignores case.')]
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Unit,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Override,
        [Parameter(Mandatory)] [int]$MaxCyclomatic,
        [Parameter(Mandatory)] [int]$MaxCognitive,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $map = [hashtable]::new([System.StringComparer]::FromComparison($PathComparison))
    # Deepest first, so the first override setting a metric is the one that decides it.
    $ordered = @($Override | Sort-Object { $_.Full.Length } -Descending)
    foreach ($file in @($Unit | ForEach-Object { [string]$_.File } | Select-Object -Unique)) {
        $reaching = @(Get-PSCxReachingOverride -File $file -Override $ordered -Root $Root -PathComparison $PathComparison)
        if ($reaching.Count -eq 0) { continue }
        $cyclomatic = @($reaching.MaxCyclomatic | Where-Object { $null -ne $_ })
        $cognitive = @($reaching.MaxCognitive | Where-Object { $null -ne $_ })
        $map[$file] = [pscustomobject]@{
            Cyclomatic = ($cyclomatic.Count -gt 0) ? [int]$cyclomatic[0] : $MaxCyclomatic
            Cognitive  = ($cognitive.Count -gt 0) ? [int]$cognitive[0] : $MaxCognitive
        }
    }
    return $map
}

function Get-PSCxReachingOverride {
    # The overrides whose path is this file or a directory above it, in the order given.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # A record's File: relative to Root with forward slashes, or a full path outside it.
        [Parameter(Mandatory)] [string]$File,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Override,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $native = $File.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $full = [System.IO.Path]::IsPathRooted($native) ? $native : [System.IO.Path]::GetFullPath((Join-Path $Root $native))
    $Override | Where-Object {
        $full.Equals($_.Full, $PathComparison) -or
        $full.StartsWith($_.Full + [System.IO.Path]::DirectorySeparatorChar, $PathComparison)
    }
}
