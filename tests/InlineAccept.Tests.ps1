# Acceptances written in the code (#165): which unit a declaration comment excuses, and why one
# excuses none.
#
# The COVERING SUITE for src/InlineAccept.ps1, and cheap: every fixture is a string parsed in
# memory. Applying the declarations -- the duplicate and staleness checks, the report -- is
# tests/Policy.Tests.ps1 and tests/Measure.Tests.ps1.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    function script:Inline {
        param([string]$Source)
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$null)
        $lines = Get-PSCxUnitTable -Ast $ast
        $display = Get-PSCxDisplayName -OrderedKeys @($lines.Keys)
        return Get-PSCxInlineAccept -Text $ast.Extent.Text -Token @($tokens) -UnitLine $lines -Display $display -File 'src/a.ps1'
    }
    function script:Tokens {
        param([string]$Source)
        $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$null)
        return , @($tokens)
    }
}

Describe 'a declaration directly above a unit' {

    It 'accepts the function below it, with its reason, file, line and source' {
        $r = Inline "function Small { 1 }`n# PSCx-Accept: a dispatch table`nfunction Big { 1 }"
        $r.Stray.Count | Should-Be 0
        $r.Accept.Count | Should-Be 1
        $r.Accept[0].File | Should-Be 'src/a.ps1'
        $r.Accept[0].Unit | Should-Be 'Big'
        $r.Accept[0].Reason | Should-Be 'a dispatch table'
        $r.Accept[0].Line | Should-Be 2
        $r.Accept[0].Source | Should-Be 'inline'
    }

    It 'reads the first line of a file' {
        $r = Inline "# PSCx-Accept: first`nfunction Big { 1 }"
        $r.Accept[0].Unit | Should-Be 'Big'
        $r.Accept[0].Line | Should-Be 1
    }

    It 'reads through the comment lines between it and the declaration, so line-comment help still works' {
        $r = Inline "# PSCx-Accept: a table`n# .SYNOPSIS`n#   Does a thing.`nfunction Big { 1 }"
        $r.Accept[0].Unit | Should-Be 'Big'
    }

    It 'accepts a class method, an attributed method, a constructor and an initialised property by the names records carry' {
        $r = Inline "class C {`n  # PSCx-Accept: m`n  [int] M() { return 1 }`n  # PSCx-Accept: n`n  [OutputType([int])] [int] N() { return 1 }`n  # PSCx-Accept: c`n  C() { }`n  # PSCx-Accept: p`n  [int] `$P = 1`n}"
        $r.Stray.Count | Should-Be 0
        @($r.Accept.Unit) | Should-BeCollection @('C.M', 'C.N', 'C.C', 'C.P')
    }

    It 'is case-insensitive, and keeps an empty reason for the gate to refuse' {
        $r = Inline "#pscx-accept:`nfunction Big { 1 }"
        $r.Accept.Count | Should-Be 1
        $r.Accept[0].Reason | Should-Be ''
    }

    It 'is no declaration inside a string, a here-string, or further into a comment' {
        $r = Inline "`$s = '# PSCx-Accept: no'`n`$h = @'`n# PSCx-Accept: no`n'@`n# see PSCx-Accept: no`nfunction Big { 1 }"
        $r.Accept.Count | Should-Be 0
        $r.Stray.Count | Should-Be 0
    }
}

Describe 'a declaration that excuses nothing' {

    It 'is refused when <Why>' -ForEach @(
        @{ Why = 'a blank line follows it'; Source = "# PSCx-Accept: x`n`nfunction Big { 1 }"; Like = '*blank line*' }
        @{ Why = 'it shares a line with code'; Source = "`$x = 1 # PSCx-Accept: x`nfunction Big { 1 }"; Like = '*shares its line with code*' }
        @{ Why = 'it follows the first token of the file'; Source = "x # PSCx-Accept: x`nfunction Big { 1 }"; Like = '*shares its line with code*' }
        @{ Why = 'nothing follows it'; Source = "function Big { 1 }`n# PSCx-Accept: x"; Like = '*no code follows it*' }
        @{ Why = 'only comments follow it'; Source = "function Big { 1 }`n# PSCx-Accept: x`n# more"; Like = '*no code follows it*' }
        @{ Why = 'the code below starts no unit'; Source = "# PSCx-Accept: x`n`$x = 1`nfunction Big { 1 }"; Like = '*on line 2, starts no function*' }
        @{ Why = 'two units start on the line below'; Source = "# PSCx-Accept: x`nfunction A { 1 }; function B { 1 }"; Like = '*2 units start on line 2*' }
        @{ Why = 'the unit is already accepted above'; Source = "# PSCx-Accept: x`n# PSCx-Accept: y`nfunction Big { 1 }"; Like = '*already accepted by the declaration on line 1*' }
    ) {
        $r = Inline $Source
        $r.Stray.Count | Should-Be 1
        $r.Stray[0].File | Should-Be 'src/a.ps1'
        $r.Stray[0].Fault | Should-BeLikeString $Like
    }

    It 'names the line of the declaration that excuses nothing' {
        $r = Inline "function A { 1 }`n# PSCx-Accept: x`n`nfunction Big { 1 }"
        $r.Stray[0].Line | Should-Be 2
    }

    It 'keeps the first of two declarations for one unit and refuses the second' {
        $r = Inline "# PSCx-Accept: x`n# PSCx-Accept: y`nfunction Big { 1 }"
        $r.Accept.Count | Should-Be 1
        $r.Accept[0].Reason | Should-Be 'x'
        $r.Stray[0].Line | Should-Be 2
    }

    It 'treats the script body as a unit no declaration can name' {
        $r = Inline "# PSCx-Accept: x`n`$x = 1"
        $r.Stray.Count | Should-Be 1
        $r.Accept.Count | Should-Be 0
    }
}

Describe 'finding a token by offset' {

    It 'finds the token starting at an offset, and none between tokens or past either end' {
        $t = Tokens 'a b cd e'
        Get-PSCxTokenIndexAt -Token $t -Offset 0 | Should-Be 0
        Get-PSCxTokenIndexAt -Token $t -Offset 2 | Should-Be 1
        Get-PSCxTokenIndexAt -Token $t -Offset 4 | Should-Be 2
        Get-PSCxTokenIndexAt -Token $t -Offset 7 | Should-Be 3
        Get-PSCxTokenIndexAt -Token $t -Offset 5 | Should-Be -1
        Get-PSCxTokenIndexAt -Token $t -Offset 99 | Should-Be -1
        # The last token is the end of input, and it is found too.
        Get-PSCxTokenIndexAt -Token $t -Offset $t[-1].Extent.StartOffset | Should-Be ($t.Count - 1)
    }

    It 'finds every token of a longer run, first and last included' {
        $t = Tokens ((1..9 | ForEach-Object { "x$_" }) -join ' ')
        for ($i = 0; $i -lt 9; $i++) { Get-PSCxTokenIndexAt -Token $t -Offset $t[$i].Extent.StartOffset | Should-Be $i }
    }
}

Describe 'the target of a declaration' {

    It 'is the first code line after it, through comments' {
        $t = Tokens "# a`n# b`n  `$x = 1"
        $r = Get-PSCxInlineTarget -Token $t -Index 0
        $r.Line | Should-Be 3
        $r.Fault | Should-BeNull
    }

    It 'allows one line break between lines, and refuses two' {
        (Get-PSCxInlineTarget -Token (Tokens "# a`n`$x") -Index 0).Line | Should-Be 2
        (Get-PSCxInlineTarget -Token (Tokens "# a`n`n`$x") -Index 0).Fault | Should-BeLikeString '*blank line*'
    }

    It 'resets the count of line breaks at each comment' {
        (Get-PSCxInlineTarget -Token (Tokens "# a`n# b`n# c`n`$x") -Index 0).Line | Should-Be 4
    }
}
