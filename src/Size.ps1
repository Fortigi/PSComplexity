# The size of each unit: lines of code, counted the way SonarQube counts ncloc (#166).
#
# A line of code is a physical line holding at least one character that is neither whitespace
# nor part of a comment. So a line with only a brace counts, every line of a statement continued
# over several lines counts, a line holding only a line-continuation backtick counts, and the
# non-blank lines inside a here-string count. Blank lines, comment lines and comment-based help do
# not. That is SonarQube's definition, word for word, chosen over an invented one: SonarSource was
# asked to stop counting brace-only lines and declined, on the ground that one rule across
# languages is worth more than a better rule for one, and PowerShell has no definition of its own
# -- the one PowerShell tool that reported this per function counted line BREAKS and kept comment
# lines, contrary to its own documentation.
#
# Attributed to the INNERMOST unit, as every other number on a record is: a nested function's
# lines are its own and not its parent's, and the script body counts what no function or member
# owns. A line holding code of two units -- `} function Next {` -- counts for both.
#
# Information only. Nothing here gates anything, and nothing here reads anything but tokens and
# offsets, so it is pure.

function Get-PSCxTokenUnit {
    # For each token, the key of the innermost unit it belongs to -- or $null for a token that is
    # not code (a comment, a line break, the end of input). Aligned with -Token by index.
    #
    # ONE pass in order, with a stack of the units open at the current token. Unit extents nest --
    # a function inside a function, a method inside a class -- so the innermost open unit is the
    # top of the stack, and anything outside every unit is the script body's. Operators only: a
    # function call per token would cost ~30us each (#155), so this is one call per FILE.
    #
    # Both output types, and the second is the price of the comma-wrap that keeps the array whole:
    # `, $x` is statically an Object[] wrapper, so declaring only [string[]] fails the analyzer.
    [OutputType([string[]], [object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        [Parameter(Mandatory)] [hashtable]$Span
    )
    # Outer before inner when two start at one offset: the outer must be on the stack first.
    $order = @($Span.Keys | Sort-Object @{ Expression = { $Span[$_].Start } }, @{ Expression = { $Span[$_].End }; Descending = $true })
    $owner = [string[]]::new($Token.Count)
    $stack = [string[]]::new($order.Count)
    $top = -1
    $next = 0
    for ($i = 0; $i -lt $Token.Count; $i++) {
        # Comments, line breaks and the end of input are not code. A line continuation is: its
        # backtick is a character that is neither whitespace nor comment.
        if ($Token[$i].Kind -in 'Comment', 'NewLine', 'EndOfInput') { continue }
        $at = $Token[$i].Extent.StartOffset
        while ($top -ge 0 -and $Span[$stack[$top]].End -le $at) { $top-- }
        while ($next -lt $order.Count -and $Span[$order[$next]].Start -le $at) { $stack[++$top] = $order[$next++] }
        $owner[$i] = ($top -ge 0) ? $stack[$top] : '<script-body>'
    }
    return , $owner
}

function Get-PSCxLinesOfCodeMap {
    # unit key -> lines of code, for every unit in -Span plus the script body.
    #
    # Each unit remembers the last line it counted. Tokens arrive in order, so a line already
    # counted for a unit is never counted again however many tokens it holds -- and a line holding
    # code of two units counts once for each.
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        # The parser's tokens, in source order, as Parser::ParseFile returns them.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]]$Token,
        # Get-PSCxUnitSpan: unit key -> Start, End offsets. The script body is not in it.
        [Parameter(Mandatory)] [hashtable]$Span
    )
    $count = @{ '<script-body>' = 0 }
    $last = @{ '<script-body>' = 0 }
    foreach ($k in $Span.Keys) { $count[$k] = 0; $last[$k] = 0 }
    $owner = Get-PSCxTokenUnit -Token $Token -Span $Span
    for ($i = 0; $i -lt $Token.Count; $i++) {
        $unit = $owner[$i]
        if ($null -eq $unit) { continue }
        # Every token through the same function, one line or several. A shortcut for the one-line
        # case gave identical output and, measured over three interleaved rounds on a 545 KB file,
        # was not faster -- so it was a branch with nothing to show for itself.
        foreach ($line in (Get-PSCxCodeLine -Token $Token[$i])) {
            if ($line -gt $last[$unit]) { $count[$unit]++; $last[$unit] = $line }
        }
    }
    return $count
}

function Get-PSCxCodeLine {
    # The lines of one token that hold a character other than whitespace: its own line for almost
    # every token, and each non-blank line of one spanning several -- a here-string, a multi-line
    # string, a continuation.
    [OutputType([int[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Token)
    $segments = $Token.Extent.Text -split '\r?\n'
    $first = $Token.Extent.StartLineNumber
    return [int[]]@(for ($i = 0; $i -lt $segments.Count; $i++) { if ($segments[$i] -match '\S') { $first + $i } })
}
