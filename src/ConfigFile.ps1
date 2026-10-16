# The config FILE (#164): finding it, reading it, and turning it into the policy one gate run
# applies. The I/O half; what a config means is decided in Config.ps1, which stays pure.
#
# Discovery is what lets a gate in CI, a gate run by hand and a future analyzer rule (#163) share
# one source of truth -- an analyzer rule has no way to be handed a -ConfigFile. It is also how a
# stray file quietly changes a verdict, so it is fenced three ways: it stops at the repository
# root, it never happens outside a repository at all, and the file it found is printed and
# recorded in the report, so a number cannot be read without the policy behind it.

$script:PSCxConfigFileName = '.pscomplexity.json'

function Get-PSCxSearchStart {
    # The directory discovery starts from for one -Path: the path itself when it is a directory,
    # otherwise the nearest existing directory above it -- which covers a file, a wildcard and a
    # path that is not there, the last of which the scan refuses on its own terms.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )
    $current = [System.IO.Path]::IsPathRooted($Path) ? $Path : (Join-Path $Root $Path)
    $current = [System.IO.Path]::GetFullPath($current)
    while ($current -and -not (Test-Path -LiteralPath $current -PathType Container)) {
        $current = Split-Path -Parent $current
    }
    return $current
}

function Get-PSCxRepositoryRoot {
    # The nearest directory at or above Directory that holds .git -- a directory in a clone, a FILE
    # in a worktree or a submodule -- or $null outside any repository.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Directory)
    $current = $Directory
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) { return $current }
        $current = Split-Path -Parent $current
    }
    return $null
}

function Find-PSCxConfigFile {
    # The config that governs one -Path: the nearest .pscomplexity.json from where the path starts
    # up to the repository root, or $null.
    #
    # $null OUTSIDE a repository, even if a config sits somewhere above. Without a root there is no
    # place to stop, and the search would reach a home directory, where a file left by another
    # project would start deciding this one's verdicts.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root
    )
    $start = Get-PSCxSearchStart -Path $Path -Root $Root
    $repository = Get-PSCxRepositoryRoot -Directory $start
    if (-not $repository) { return $null }
    $current = $start
    while ($current.Length -ge $repository.Length) {
        $candidate = Join-Path $current $script:PSCxConfigFileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $current = Split-Path -Parent $current
    }
    return $null
}

function Find-PSCxRunConfigFile {
    # The ONE config every -Path of this run falls under, or $null when none does.
    #
    # Refused when two paths disagree -- one under a config and one under another, or under none.
    # Applying either to both would gate one tree by a policy nobody wrote for it, and picking by
    # argument order would make the verdict depend on how the command was typed.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$Path,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $found = @($Path | ForEach-Object { [string](Find-PSCxConfigFile -Path $_ -Root $Root) })
    $distinct = [System.Collections.Generic.HashSet[string]]::new([string[]]$found, [System.StringComparer]::FromComparison($PathComparison))
    if ($distinct.Count -gt 1) {
        $named = for ($i = 0; $i -lt $Path.Count; $i++) { "$($Path[$i]) -> $(($found[$i]) ? $found[$i] : 'no config')" }
        throw ('The paths of this run fall under different configs: ' + ($named -join '; ') +
            '. Gate them in separate runs, or name the one that applies with -ConfigFile.')
    }
    return ($found[0]) ? $found[0] : $null
}

function Read-PSCxConfig {
    # A config file, checked and resolved -- or a throw naming the file and every fault in it.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [System.StringComparison]$PathComparison
    )
    $full = [System.IO.Path]::GetFullPath(([System.IO.Path]::IsPathRooted($Path) ? $Path : (Join-Path $Root $Path)))
    $document = Read-PSCxDocument -Path $full
    $faults = @(Get-PSCxConfigFault -Document $document -PathComparison $PathComparison)
    if ($faults.Count -gt 0) { throw "Cannot use the config $full : $($faults -join '; ')." }
    return Get-PSCxConfigPolicy -Document $document -Path $full -Root $Root -PathComparison $PathComparison
}

function Resolve-PSCxGatePolicy {
    # Everything Test-PSComplexity applies besides the code itself: which config, if any, and the
    # ceilings, acceptances, excludes and baseline that come out of it and the command line.
    #
    # Here rather than in the gate, which is a thin predicate and was one branch from its own
    # ceiling before a config existed. The two refusals about -UpdateBaseline moved with it,
    # because whether there is a baseline to update is now a question about the config too.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # The gate's $PSBoundParameters.
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory)] [string[]]$Path
    )
    # Switches through the indexer, which answers $null for one not given and $false for -X:$false.
    $noConfig = [bool]$Bound['NoConfig']
    if ($Bound.ContainsKey('ConfigFile') -and $noConfig) {
        throw '-ConfigFile and -NoConfig contradict each other: one names the config to apply and the other says to apply none.'
    }
    $root = Get-PSCxWorkingRoot
    $pathComparison = Get-PSCxRunPathComparison -Root $root
    # The indexer answers $null for a parameter not given, which [string] makes '' -- no config.
    $configPath = [string]$Bound['ConfigFile']
    if (-not $configPath -and -not $noConfig) {
        $configPath = Find-PSCxRunConfigFile -Path $Path -Root $root -PathComparison $pathComparison
    }
    $config = $null
    if ($configPath) {
        $config = Read-PSCxConfig -Path $configPath -Root $root -PathComparison $pathComparison
        # Said every time, because a config is a policy the command line does not show. Information
        # rather than a warning: nothing is wrong. Shown unless the caller asked for quiet.
        $action = $Bound.ContainsKey('InformationAction') ? $InformationPreference : 'Continue'
        Write-Information "Using config $($config.Display)" -InformationAction $action
    }
    $policy = Get-PSCxGatePolicy -Config $config -Bound $Bound
    # Before the scan, because neither answer depends on it and the scan is the expensive part.
    $update = [bool]$Bound['UpdateBaseline']
    if ($update -and -not $policy.BaselineFile) {
        throw '-UpdateBaseline needs -BaselineFile, or a baselineFile in the config: there is no default path, because a file the gate reads without being told to is one nobody reviews.'
    }
    # Refused rather than ignored: a gate run carrying -AllowNew believes it permitted something,
    # and it permits nothing without an update to apply it to.
    if ([bool]$Bound['AllowNew'] -and -not $update) {
        throw '-AllowNew only applies with -UpdateBaseline: it permits an update to record units the baseline has never seen, and without an update there is nothing for it to permit.'
    }
    return $policy
}
