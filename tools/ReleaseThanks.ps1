<#
.SYNOPSIS
    Who to thank for a release (#220): the outside contributors whose issues and pull requests went
    into it, as a section of the GitHub release and as a comment on each item.

.DESCRIPTION
    The same mechanism as Fortigi/PSMutant's tools/ReleaseThanks.ps1 (PSMutant#314 and #317), kept
    in step with it as the other release gates are.

    The GitHub release already carries GitHub's generated notes, which list each merged pull
    request "by @user" and call out a FIRST contribution. Nothing thanked anyone, a person who only
    reported an issue was not named at all, and a returning contributor was not called out.

    Outside is GitHub's author association together with the author's permission here: a member,
    an owner, a collaborator or anyone with write access is the team, and a bot is not a person.

    The decisions are pure functions over plain records, tested in tests/ReleaseThanks.Tests.ps1.
    Get-PSCxReleaseContribution is the one function that asks GitHub, through gh, and does
    nothing but turn its answers into those records.
#>

# The author associations that mean "not one of us". FIRST_TIMER is a first contribution to GitHub
# as a whole; FIRST_TIME_CONTRIBUTOR a first one to this repository; NONE a reporter with no commit.
$script:PSCxOutsideAssociation = @('CONTRIBUTOR', 'FIRST_TIME_CONTRIBUTOR', 'FIRST_TIMER', 'NONE')

# The repository permissions that make someone the team (PSMutant#317). Asked as well as the
# association, because the association depends on who asks: to the workflow's token a PRIVATE
# organisation membership is invisible, and a maintainer then reads CONTRIBUTOR -- PSMutant's
# 0.9.1 release thanked one.
$script:PSCxTeamPermission = @('admin', 'maintain', 'write')

function Test-PSCxTeamPermission {
    # True for a permission on this repository that only the team holds. Pure.
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Permission)
    return $script:PSCxTeamPermission -contains $Permission
}

function Test-PSCxOutsideAuthor {
    # True for an author worth thanking: outside the team by association AND by permission, and a
    # person.
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Association,
        [bool]$IsBot = $false,
        [bool]$IsTeam = $false
    )
    return (-not $IsBot) -and (-not $IsTeam) -and ($script:PSCxOutsideAssociation -contains $Association)
}

function Get-PSCxOutsideContribution {
    <#
    .SYNOPSIS
        Pure: per outside contributor, the issues they reported and the pull requests they wrote.
    .PARAMETER PullRequest
        The merged pull requests of the release: { Number; Author; Association; IsBot; IsTeam; Closes },
        where Closes holds the issues it closes in the same shape, without Closes.
    .OUTPUTS
        { Login; Reported; Authored }, ordered by login, numbers ascending and each once.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$PullRequest)
    $by = @{}
    $note = {
        param($Item, $Kind)
        $outside = Test-PSCxOutsideAuthor -Association ([string]$Item.Association) -IsBot ([bool]$Item.IsBot) -IsTeam ([bool]$Item.IsTeam)
        if (-not $outside) { return }
        if (-not $by.ContainsKey($Item.Author)) { $by[$Item.Author] = @{ Reported = @(); Authored = @() } }
        $by[$Item.Author][$Kind] += [int]$Item.Number
    }
    foreach ($pr in $PullRequest) {
        & $note $pr 'Authored'
        foreach ($issue in @($pr.Closes)) { if ($issue) { & $note $issue 'Reported' } }
    }
    foreach ($login in ($by.Keys | Sort-Object)) {
        [pscustomobject]@{
            Login    = $login
            Reported = [int[]]@($by[$login].Reported | Sort-Object -Unique)
            Authored = [int[]]@($by[$login].Authored | Sort-Object -Unique)
        }
    }
}

function Join-PSCxItemList {
    # "#1", "#1 and #2", "#1, #2 and #3": how a sentence names several items.
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int[]]$Number)
    $refs = @($Number | ForEach-Object { "#$_" })
    if ($refs.Count -eq 1) { return $refs[0] }
    return ($refs[0..($refs.Count - 2)] -join ', ') + ' and ' + $refs[-1]
}

function Format-PSCxThankYou {
    <#
    .SYNOPSIS
        Pure: the "Thank you" section of a GitHub release, or $null when nobody outside contributed.
    .DESCRIPTION
        One list item per person, naming what they did, so a reporter is credited for the report and
        an author for the change. Markdown, because the GitHub release renders it and an @mention
        there notifies the person; the gallery notes are plain text and are not given this.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Contribution)
    $lines = foreach ($c in $Contribution) {
        # "for reporting #309 and #310", "for #312", or both: "..., and for #312".
        $what = @()
        if (@($c.Reported).Count) { $what += "reporting $(Join-PSCxItemList -Number $c.Reported)" }
        if (@($c.Authored).Count) { $what += Join-PSCxItemList -Number $c.Authored }
        # The heading already says thank you, so each line names the person and what they did.
        if ($what.Count) { "- @$($c.Login) for $($what -join ', and for ')." }
    }
    if (-not $lines) { return $null }
    return "### Thank you`n`n" + (@($lines) -join "`n")
}

function Get-PSCxThanksComment {
    <#
    .SYNOPSIS
        Pure: the comment for each outside item, { Number; Body }, ordered by number.
    .DESCRIPTION
        One comment per issue or pull request, never two: an item is either reported or authored by
        one person. Posted once the release exists, so the link in it resolves.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Contribution,
        [Parameter(Mandatory)] [string]$Tag,
        [Parameter(Mandatory)] [string]$ReleaseUrl
    )
    $out = foreach ($c in $Contribution) {
        foreach ($n in @($c.Reported)) {
            [pscustomobject]@{ Number = $n; Body = "Thank you for reporting this, @$($c.Login)! The fix shipped in [$Tag]($ReleaseUrl)." }
        }
        foreach ($n in @($c.Authored)) {
            [pscustomobject]@{ Number = $n; Body = "Thank you for this, @$($c.Login)! It shipped in [$Tag]($ReleaseUrl)." }
        }
    }
    return @($out | Sort-Object Number)
}

function Get-PSCxReleaseContribution {
    <#
    .SYNOPSIS
        Ask GitHub for the merged pull requests between two tags, and the issues each closes, as
        the records Get-PSCxOutsideContribution reads.
    .DESCRIPTION
        Not pure, and so kept to translation: the pull requests are the ones GitHub associates with
        the commits in Previous..Tag, merged into the default branch.
    #>
    [OutputType([pscustomobject[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$Previous,
        [Parameter(Mandatory)] [string]$Tag
    )
    $owner, $name = $Repository -split '/', 2
    $shas = @(gh api "repos/$Repository/compare/$Previous...$Tag" --jq '.commits[].sha')
    if ($LASTEXITCODE -ne 0) { throw "Could not compare $Previous...$Tag." }
    $numbers = @(foreach ($sha in $shas) {
            gh api "repos/$Repository/commits/$sha/pulls" --jq '.[] | select(.merged_at != null) | .number'
        }) | Sort-Object -Unique
    $query = 'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){' +
    'number authorAssociation author{__typename login} closingIssuesReferences(first:50){nodes{' +
    'number authorAssociation author{__typename login}}}}}}'
    # Each author's permission here, asked once: a 404 -- no collaborator, or a bot -- is no permission.
    $team = @{}
    $isTeam = {
        param($Login)
        if (-not $team.ContainsKey($Login)) {
            $permission = gh api "repos/$Repository/collaborators/$Login/permission" --jq '.permission' 2>$null
            $team[$Login] = Test-PSCxTeamPermission -Permission ([string]$permission)
        }
        $team[$Login]
    }
    foreach ($n in $numbers) {
        $pr = (gh api graphql -f query=$query -F o=$owner -F r=$name -F n=$n | ConvertFrom-Json).data.repository.pullRequest
        [pscustomobject]@{
            Number = $pr.number; Author = $pr.author.login; Association = $pr.authorAssociation
            IsBot = $pr.author.__typename -eq 'Bot'; IsTeam = & $isTeam $pr.author.login
            Closes = @(foreach ($i in $pr.closingIssuesReferences.nodes) {
                    [pscustomobject]@{
                        Number = $i.number; Author = $i.author.login; Association = $i.authorAssociation
                        IsBot = $i.author.__typename -eq 'Bot'; IsTeam = & $isTeam $i.author.login
                    }
                })
        }
    }
}
