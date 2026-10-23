# Acceptances written in the code (#165): a line comment directly above a unit's declaration,
# carrying the argument for letting that unit exceed a ceiling.
#
# The SAME checked declaration as -Accept, not a suppression comment: the gate puts these through
# the acceptance checks -List and config entries face -- a reason is required, and an acceptance
# whose unit is back within its ceilings fails the run. What it adds is that the argument sits
# next to the code it excuses and moves with it, which a File+Unit list cannot.
#
# Whole units only. A score belongs to a unit, so excusing one construct would mean passing a unit
# on a number nobody measured.
#
# Pure: it reads the text and the tokens one parse already produced, and the unit table.

# Anywhere in the text; each hit is then checked against the tokens, so a mention inside a string
# or a here-string is not a declaration. Case-insensitive, as PowerShell is about its own keywords.
$script:PSCxInlineAcceptPattern = [regex]::new('#[ \t]*PSCx-Accept[ \t]*:([^\r\n]*)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

function Get-PSCxTokenIndexAt {
    # The index of the token starting exactly at Offset, or -1. Tokens arrive in source order, so
    # a binary search over their offsets -- .NET's, not one written here, whose fencepost
    # variants all give the same answers and so cannot be told apart by any test.
    #
    # The offsets are read per call, about 40ms on a 120,000-token file. That is paid once per
    # declaration, and a file without one never gets here.
    [OutputType([int])]
    [CmdletBinding()]
    param(
        # Never empty: the parser always ends the list with an EndOfInput token.
        [Parameter(Mandatory)] [object[]]$Token,
        [Parameter(Mandatory)] [int]$Offset
    )
    $offsets = [int[]]@($Token.Extent.StartOffset)
    $found = [System.Array]::BinarySearch($offsets, $Offset)
    # PSMutant-Equivalent: 0 -> (-1): a search that misses answers -1 or less, and -1 is exactly what the miss arm returns.
    return ($found -ge 0) ? $found : -1
}

function Get-PSCxInlineTarget {
    # The line of the code a declaration comment stands directly above, or why it stands above
    # none: [pscustomobject]@{ Line; Fault }, one of the two set.
    #
    # Directly above means through the comment lines that follow it -- a help block written as
    # line comments keeps working -- with no blank line, and no code before it on its own line.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        [Parameter(Mandatory)] [int]$Index
    )
    $kind = [System.Management.Automation.Language.TokenKind]
    if ($Index -gt 0 -and $Token[$Index - 1].Kind -ne $kind::NewLine) {
        return [pscustomobject]@{ Line = $null; Fault = 'it shares its line with code -- put it on its own line, directly above the unit' }
    }
    $newLines = 0
    # PSMutant-Equivalent: 1 -> 0: Token[Index] is the declaration's own comment, and a comment is skipped without touching the count, so starting one token early changes nothing.
    for ($i = $Index + 1; $i -lt $Token.Count; $i++) {
        $t = $Token[$i]
        if ($t.Kind -eq $kind::NewLine) {
            $newLines++
            # Two line breaks with nothing between them: a blank line.
            if ($newLines -gt 1) { return [pscustomobject]@{ Line = $null; Fault = 'a blank line separates it from the code below' } }
            continue
        }
        $newLines = 0
        if ($t.Kind -eq $kind::Comment) { continue }
        if ($t.Kind -eq $kind::EndOfInput) { break }
        return [pscustomobject]@{ Line = $t.Extent.StartLineNumber; Fault = $null }
    }
    return [pscustomobject]@{ Line = $null; Fault = 'no code follows it' }
}

function Get-PSCxInlineAccept {
    # The acceptances one file declares in its code, and the declarations that excuse nothing.
    #
    # A declaration that excuses nothing is RETURNED, never dropped: the gate refuses it, because a
    # reason that has drifted away from its function -- a blank line inserted, the function moved
    # -- would otherwise sit there believing it excuses something.
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Text,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        # Unit key -> the line its declaration starts on, as Get-PSCxUnitTable gives it.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$UnitLine,
        # Unit key -> the name a record carries.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Display,
        # The file as a record names it.
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$File
    )
    $accept = [System.Collections.Generic.List[object]]::new()
    $stray = [System.Collections.Generic.List[object]]::new()
    # Declaration line -> the units starting on it. The script body is in it at line 1, where no
    # declaration can point -- one always stands ABOVE its target -- so it cannot be excused this
    # way, and -Accept is how it is.
    $byLine = @{}
    foreach ($key in $UnitLine.Keys) {
        $at = $UnitLine[$key]
        if (-not $byLine.ContainsKey($at)) { $byLine[$at] = @() }
        $byLine[$at] += $key
    }
    $claimed = @{}
    foreach ($match in $script:PSCxInlineAcceptPattern.Matches($Text)) {
        $index = Get-PSCxTokenIndexAt -Token $Token -Offset $match.Index
        # Not the start of a token: the text sits inside a string, or further into a comment that
        # is about something else. Neither declares anything. A token that DOES start at a `#` is
        # a comment, because nothing else in PowerShell can, so the kind needs no second look.
        if ($index -lt 0) { continue }
        $line = $Token[$index].Extent.StartLineNumber
        $target = Get-PSCxInlineTarget -Token $Token -Index $index
        $fault = Get-PSCxInlineFault -Target $target -ByLine $byLine -Claimed $claimed
        if ($fault) {
            $stray.Add([pscustomobject]@{ File = $File; Line = $line; Fault = $fault })
            continue
        }
        # PSMutant-Equivalent: 0 -> (-1): no fault means exactly one unit starts on the target line, so its first key and its last are the same one.
        $key = $byLine[$target.Line][0]
        $claimed[$key] = $line
        $accept.Add([pscustomobject]@{ File = $File; Unit = [string]$Display[$key]; Reason = $match.Groups[1].Value.Trim(); Line = $line; Source = 'inline' })
    }
    return [pscustomobject]@{ Accept = @($accept); Stray = @($stray) }
}

function Get-PSCxInlineFault {
    # Why a declaration excuses no unit, as text, or nothing when it names exactly one.
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        # Declaration line -> the unit keys starting on it.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$ByLine,
        # Unit key -> the line of the declaration already accepting it.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [hashtable]$Claimed
    )
    if ($Target.Fault) { return $Target.Fault }
    # Filtered, because @() over a missing key is an array of one $null, not an empty one.
    $keys = @($ByLine[$Target.Line] | Where-Object { $null -ne $_ })
    if ($keys.Count -eq 0) { return "the code below it, on line $($Target.Line), starts no function, method or constructor" }
    # Two units starting on one line -- `function A { } function B { }` -- cannot be told apart by
    # where a comment sits, so the declaration names neither rather than guessing.
    if ($keys.Count -gt 1) { return "$($keys.Count) units start on line $($Target.Line), so it cannot say which one it excuses" }
    # PSMutant-Equivalent: 0 -> (-1): none and several returned above, so exactly one key is left and its first and its last are the same one.
    $only = $keys[0]
    if ($Claimed.ContainsKey($only)) { return "the unit below it is already accepted by the declaration on line $($Claimed[$only])" }
}
