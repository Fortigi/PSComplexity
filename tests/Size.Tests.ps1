# Lines of code per unit (#166), counted as SonarQube counts ncloc: a physical line holding at
# least one character that is neither whitespace nor part of a comment, attributed to the
# innermost unit. Every case below is a line someone could reasonably count the other way.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }
    function script:Get-Loc { param([string]$Code)
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$null)
        Clear-PSCxAstCache
        $map = Get-PSCxLinesOfCodeMap -Token @($tokens) -Span (Get-PSCxUnitSpan -Ast $ast)
        # Keyed by the unit's internal key, which carries an @offset; the published name drops it.
        $out = @{}
        foreach ($k in $map.Keys) { $out[($k -replace '@\d+$', '')] = $map[$k] }
        return $out
    }
    # A token the way the parser hands one over, for the cases a real parse cannot produce.
    function script:New-Tok { param([int]$Start, [int]$Line, [string]$Kind = 'Identifier')
        [pscustomobject]@{ Kind = $Kind; Extent = [pscustomobject]@{ StartOffset = $Start; StartLineNumber = $Line; EndLineNumber = $Line; Text = 'x' } }
    }
}

Describe 'Get-PSCxLinesOfCodeMap' {
    It 'counts a realistic file the Sonar way, unit by unit' {
        $code = @'
# file header comment

param($Path)
function Outer {
    <#
    .SYNOPSIS
    Help.
    #>
    param($a)

    if ($a) {
        Get-Thing -One 1 `
            -Two 2
    }
    function Inner { 1 }
    $s = @"
line one

line three
"@
}
class K {
    [int] V() { return 1 }
}
Outer 1
'@
        $loc = Get-Loc $code
        # Outer: its own line, param, if, both continued lines, the closing brace of the if, the
        # here-string's four non-blank lines, and its closing brace -- 11. Not the help block, the
        # blank lines, the blank line inside the here-string, or Inner's line.
        "$($loc['<script-body>'])/$($loc['Outer'])/$($loc['Outer/Inner'])/$($loc['K.V'])" | Should-Be '4/11/1/1'
    }

    It 'counts <Name>' -ForEach @(
        @{ Name = 'a line holding only a brace'; Code = "function F {`n    1`n}"; Expected = 3 }
        @{ Name = 'every line of a continued statement'; Code = "function F {`n    Get-X -A 1 ``" + "`n        -B 2`n}"; Expected = 4 }
        @{ Name = 'a line holding only a continuation backtick'; Code = "function F {`n    Get-X ``" + "`n    ``" + "`n    -B 2`n}"; Expected = 5 }
        @{ Name = 'the non-blank lines inside a here-string'; Code = "function F {`n    @'`n    a`n`n    b`n'@`n}"; Expected = 6 }
    ) {
        (Get-Loc $Code)['F'] | Should-Be $Expected
    }

    It 'does not count <Name>' -ForEach @(
        @{ Name = 'a blank line'; Code = "function F {`n`n    1`n`n}" }
        @{ Name = 'a comment line'; Code = "function F {`n    # note`n    1`n}" }
        @{ Name = 'comment-based help'; Code = "function F {`n    <#`n    .SYNOPSIS`n    x`n    #>`n    1`n}" }
        @{ Name = 'a trailing comment, beyond the code it trails'; Code = "function F {`n    1 # trailing`n}" }
    ) {
        (Get-Loc $Code)['F'] | Should-Be 3
    }

    It 'gives a nested function''s lines to it, not to its parent' {
        $loc = Get-Loc "function Outer {`n    function Inner {`n        1`n    }`n    2`n}"
        "$($loc['Outer'])/$($loc['Outer/Inner'])" | Should-Be '3/3'
    }

    It 'counts a line holding code of two units once for each' {
        # `;` between them is the script body's own code on that line.
        $loc = Get-Loc 'function A { 1 }; function B { 2 }'
        "$($loc['A'])/$($loc['B'])/$($loc['<script-body>'])" | Should-Be '1/1/1'
    }

    It 'gives a class''s own lines to the script body and a method''s to the method' {
        $loc = Get-Loc "class C {`n    [int] M() {`n        return 1`n    }`n}"
        "$($loc['C.M'])/$($loc['<script-body>'])" | Should-Be '3/2'
    }

    It 'reports every unit, a code-free one as 0, and a file with no code as 0 lines' {
        $loc = Get-Loc '# only a comment'
        $loc['<script-body>'] | Should-Be 0
        (Get-PSCxLinesOfCodeMap -Token @() -Span @{ 'F' = [pscustomobject]@{ Start = 0; End = 5 } })['F'] | Should-Be 0
    }
}

Describe 'Get-PSCxTokenUnit' {
    It 'puts the OUTER of two units starting at one offset on the stack first' {
        # Outer [0,30), inner [0,10). A token at 5 is the inner's, one at 20 the outer's. Opened in
        # the other order, the outer would sit on top and own both.
        $span = @{ 'outer' = [pscustomobject]@{ Start = 0; End = 30 }; 'inner' = [pscustomobject]@{ Start = 0; End = 10 } }
        $owner = Get-PSCxTokenUnit -Token @((New-Tok 5 1), (New-Tok 20 2), (New-Tok 40 3)) -Span $span
        ($owner -join ',') | Should-Be 'inner,outer,<script-body>'
    }

    It 'owns no token that is not code' {
        $toks = @((New-Tok 0 1 'Comment'), (New-Tok 1 1 'NewLine'), (New-Tok 2 2 'EndOfInput'), (New-Tok 3 2 'LineContinuation'))
        $owner = Get-PSCxTokenUnit -Token $toks -Span @{}
        "$($null -eq $owner[0])/$($null -eq $owner[1])/$($null -eq $owner[2])/$($owner[3])" | Should-Be 'True/True/True/<script-body>'
    }

    It 'closes a unit exactly at its end offset' {
        # End is exclusive: a token starting AT a unit's end is outside it.
        $owner = Get-PSCxTokenUnit -Token @((New-Tok 9 1), (New-Tok 10 1)) -Span @{ 'u' = [pscustomobject]@{ Start = 0; End = 10 } }
        ($owner -join ',') | Should-Be 'u,<script-body>'
    }

    It 'opens a unit exactly at its start offset' {
        $owner = Get-PSCxTokenUnit -Token @((New-Tok 4 1), (New-Tok 5 1)) -Span @{ 'u' = [pscustomobject]@{ Start = 5; End = 9 } }
        ($owner -join ',') | Should-Be '<script-body>,u'
    }
}

Describe 'Get-PSCxCodeLine' {
    It 'gives the lines of a multi-line token that hold something other than whitespace' {
        $t = [pscustomobject]@{ Extent = [pscustomobject]@{ StartLineNumber = 7; Text = "@'`r`n  a`r`n   `r`n'@" } }
        ((Get-PSCxCodeLine -Token $t) -join ',') | Should-Be '7,8,10'
    }
}
