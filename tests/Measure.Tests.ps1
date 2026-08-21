# End-to-end tests for the public API: file/directory resolution, per-unit records,
# the <script-body> unit, parse-error handling, and the Test-PSComplexity gate.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1') { . (Join-Path $src $f) }

    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "cxmeasure-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:work 'nested') -Force | Out-Null
    Set-Content (Join-Path $script:work 'a.ps1') "function Get-A { param(`$x) if (`$x) { 1 } }`n`$top = 1" -Encoding utf8
    Set-Content (Join-Path $script:work 'nested/b.ps1') "function Get-B { param(`$y) foreach (`$i in `$y) { if (`$i) { 1 } } }" -Encoding utf8
    Set-Content (Join-Path $script:work 'broken.ps1') "function Oops { param(" -Encoding utf8
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Measure-PSComplexity' {
    It 'reports a record per unit including the script body' {
        $recs = Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1')
        ($recs | Where-Object Unit -eq 'Get-A').Cyclomatic | Should -Be 2
        ($recs | Where-Object Unit -eq '<script-body>') | Should -Not -BeNullOrEmpty
    }
    It 'reports Cyclomatic 1 / Cognitive 0 for a decision-free unit' {
        $flat = Join-Path $script:work 'flat.ps1'
        Set-Content $flat 'function Get-Flat { param($x) $x }' -Encoding utf8
        $r = Measure-PSComplexity -Path $flat | Where-Object Unit -eq 'Get-Flat'
        $r.Cyclomatic | Should -Be 1
        $r.Cognitive  | Should -Be 0
    }
    It 'recurses a directory and finds nested files' {
        $recs = Measure-PSComplexity -Path $script:work -Recurse
        ($recs | Where-Object Unit -eq 'Get-B') | Should -Not -BeNullOrEmpty
    }
    It 'measures a flat directory without -Recurse, and only that directory' {
        # Two assertions, and the FIRST one is the test. Asserting only that the nested
        # unit is absent passes just as well when discovery found nothing at all, which
        # is what it used to do -- so the gate returned $true over breaching code.
        $recs = Measure-PSComplexity -Path $script:work
        ($recs | Where-Object Unit -eq 'Get-A') | Should -Not -BeNullOrEmpty
        ($recs | Where-Object Unit -eq 'Get-B') | Should -BeNullOrEmpty
    }
    It 'gives a directory the same units with and without -Recurse when nothing is nested' {
        # The flat and recursive forms must agree on a flat folder. They did not: one
        # measured every file and the other measured none, and nothing compared them.
        $flatDir = Join-Path $script:work 'flatonly'
        New-Item -ItemType Directory -Path $flatDir -Force | Out-Null
        Set-Content (Join-Path $flatDir 'c.ps1') 'function Get-C { if ($z) { 1 } }' -Encoding utf8

        $shallow = @(Measure-PSComplexity -Path $flatDir)
        $deep    = @(Measure-PSComplexity -Path $flatDir -Recurse)
        $shallow.Count | Should -BeGreaterThan 0
        $shallow.Count | Should -Be $deep.Count
    }
    It 'measures a directory whose name contains wildcard characters' {
        # -Path glob-parses '[': a real directory called 'my[1]proj' matched nothing, so
        # a monorepo folder with a bracket in its name scored a confident, empty zero.
        $odd = Join-Path $script:work 'my[1]proj'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $odd 'd.ps1') 'function Get-D { if ($q) { 1 } }' -Encoding utf8

        $recs = @(Measure-PSComplexity -Path $odd -Recurse)
        ($recs | Where-Object Unit -eq 'Get-D') | Should -Not -BeNullOrEmpty
    }
    It 'still accepts a wildcard path that matches nothing literally' {
        # Resolving an existing path literally must not cost wildcard support: a pattern
        # names no file on disk, so it has to keep falling through to -Path.
        $recs = @(Measure-PSComplexity -Path (Join-Path $script:work '*.ps1'))
        ($recs | Where-Object Unit -eq 'Get-A') | Should -Not -BeNullOrEmpty
    }
    It 'skips an unparseable file with a warning' {
        $recs = Measure-PSComplexity -Path (Join-Path $script:work 'broken.ps1') -WarningAction SilentlyContinue
        @($recs).Count | Should -Be 0
    }
    It 'accepts pipeline input' {
        $recs = (Join-Path $script:work 'a.ps1') | Measure-PSComplexity
        ($recs | Where-Object Unit -eq 'Get-A') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-PSComplexity' {
    It 'returns $true when everything is within the ceilings' {
        Test-PSComplexity -Path (Join-Path $script:work 'a.ps1') | Should -BeTrue
    }
    It 'returns $false and warns when a unit exceeds a ceiling' {
        $wv = $null
        $result = Test-PSComplexity -Path (Join-Path $script:work 'a.ps1') -MaxCyclomatic 1 -WarningVariable wv -WarningAction SilentlyContinue
        $result | Should -BeFalse
        @($wv).Count | Should -BeGreaterThan 0
    }
    It 'honours the cognitive ceiling independently' {
        # Get-B has cognitive 3 (foreach + nested if); ceiling 2 should trip it.
        Test-PSComplexity -Path $script:work -Recurse -MaxCognitive 2 -WarningAction SilentlyContinue | Should -BeFalse
    }
}

# -----------------------------------------------------------------------------
# Top-level script code: decisions and calls that sit OUTSIDE any function.
# Every fixture above wraps its logic in one, so the "walked to the top without
# finding a function" fallbacks in Ast.ps1 were never reached. That shape is not
# exotic -- a crawler entry point, a build script or a profile is exactly this,
# and it is the code most likely to be complex and least likely to be tested.
# -----------------------------------------------------------------------------

Describe 'Measure-PSComplexity - script-level code outside any function' {

    # NOTE: no angle brackets in It names here. Pester expands <...> in a test
    # name as a -ForEach data placeholder, so 'to <script-body>' is parsed as the
    # expression $script-body and the test dies with a token error before it runs.
    It 'attributes a top-level decision to the script-body unit' {
        # Get-PSCxUnitName walks to the nearest enclosing function; with none, it
        # falls back to '<script-body>'. Without a top-level DECISION that fallback
        # never runs: an assignment at script level creates the unit but asks
        # nothing about which unit a decision belongs to.
        $p = Join-Path $script:work 'toplevel-if.ps1'
        Set-Content $p 'if ($env:CI) { "ci" } else { "local" }' -Encoding utf8
        $body = Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>'
        $body            | Should -Not -BeNullOrEmpty
        $body.Cyclomatic | Should -Be 2   # baseline 1 + the if
        $body.Cognitive  | Should -Be 2   # +1 the if, +1 the else branch
    }

    It 'nests top-level decisions the same way it nests them inside a function' {
        # Pins that the script body is a real unit for cognitive scoring, not a
        # bucket that only collects a flat count: the inner if is +2 (nesting), so
        # a body that ignored depth would score 2 instead of 3.
        $p = Join-Path $script:work 'toplevel-nested.ps1'
        Set-Content $p 'if ($a) { if ($b) { "x" } }' -Encoding utf8
        $body = Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>'
        $body.Cyclomatic | Should -Be 3
        $body.Cognitive  | Should -Be 3
    }

    It 'does not count a top-level call as recursion' {
        # Recursion detection compares a call name against its ENCLOSING function
        # name. At script level there is none, so the lookup returns $null and the
        # call must not be scored -- a script that calls a command sharing its file
        # name would otherwise pick up a phantom recursion point.
        $p = Join-Path $script:work 'toplevel-call.ps1'
        Set-Content $p 'Get-Date' -Encoding utf8
        $body = Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>'
        $body.Cognitive | Should -Be 0
    }

    It 'still detects recursion inside a function in the same file' {
        # The counterpart to the case above: proving the $null guard did not simply
        # switch recursion detection off.
        $p = Join-Path $script:work 'toplevel-plus-recursion.ps1'
        Set-Content $p "Get-Date`nfunction Get-Loop { Get-Loop }" -Encoding utf8
        $recs = Measure-PSComplexity -Path $p
        ($recs | Where-Object Unit -like 'Get-Loop*').Cognitive | Should -Be 1
        ($recs | Where-Object Unit -eq '<script-body>').Cognitive | Should -Be 0
    }
}

Describe 'Measure-PSComplexity - reporting details that the suite never pinned' {

    It 'reports the script body as starting at line 1' {
        # The unit table seeds '<script-body>' with its start line. Nothing asserted
        # the Line column for it, so the seed could be any number and every score
        # stayed correct while the record pointed at the wrong place.
        $p = Join-Path $script:work 'body-line.ps1'
        Set-Content $p "if (`$a) { 1 }" -Encoding utf8
        (Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>').Line | Should -Be 1
    }

    It 'counts a ternary as exactly one cyclomatic decision' {
        # Every branch contributes Amount = 1. A ternary scoring 2 would inflate
        # every unit using one, and no cyclomatic test used a ternary at all.
        $p = Join-Path $script:work 'ternary-cyc.ps1'
        Set-Content $p 'function Get-T { param($x) $x ? 1 : 2 }' -Encoding utf8
        (Measure-PSComplexity -Path $p | Where-Object Unit -like 'Get-T*').Cyclomatic | Should -Be 2
    }

    It 'names the FIRST parse error in the skip warning' {
        # The warning reads $errors[0]. Read as $errors[1] it reports a different
        # error, or nothing at all when there is only one -- leaving a warning that
        # says a file was skipped without saying why, which is the only thing that
        # warning is for.
        $p = Join-Path $script:work 'one-error.ps1'
        Set-Content $p 'if ($a) {' -Encoding utf8
        Measure-PSComplexity -Path $p -WarningVariable w -WarningAction SilentlyContinue | Out-Null
        ($w -join ' ') | Should -BeLike "*Missing closing '}'*"
    }

    It 'ignores a DIRECTORY whose name ends in .ps1' {
        # File discovery filters to files. Drop that filter and a directory matching
        # the include pattern is handed to ParseFile, which cannot read it -- so one
        # legal (if odd) directory name pollutes or breaks a whole scan.
        #
        # -Recurse matters: without it, Get-ChildItem -Include returns nothing at
        # all for this shape, so the filtered and unfiltered forms agree and the
        # case proves nothing. The recursive walk is where they diverge.
        $d = Join-Path $script:work 'weird.ps1'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content (Join-Path $d 'inner.ps1') 'function Get-Inner { 1 }' -Encoding utf8

        $wv = $null
        $recs = Measure-PSComplexity -Path $script:work -Recurse -WarningVariable wv -WarningAction SilentlyContinue
        # The real file inside it is still measured...
        ($recs | Where-Object Unit -like 'Get-Inner*') | Should -Not -BeNullOrEmpty
        # ...and the directory itself is never treated as a source file.
        @($recs | Where-Object File -eq $d).Count | Should -Be 0
        ($wv -join ' ') | Should -Not -BeLike "*weird.ps1'*"
    }
}

Describe 'Measure-PSComplexity - class members as units' {
    BeforeAll {
        $script:clsFile = Join-Path $script:work 'cls.ps1'
        Set-Content $script:clsFile @'
class Order {
    [int] $Threshold = $(if ($env:X) { 5 } else { 1 })
    [string] $Plain
    Order() { if ($env:Y) { $this.Plain = 'y' } }
    [int] Process([object]$o) {
        if ($o.A) { if ($o.B) { foreach ($x in $o.C) { if ($x) { return 1 } } } }
        return 0
    }
    static [int] Helper() { return 1 }
}
class Invoice {
    [int] Process([object]$o) { return 0 }
}
function Process { if (1) { } }
'@ -Encoding utf8
        $script:clsRecs = Measure-PSComplexity -Path $script:clsFile
    }

    It 'qualifies a method with its class name' {
        # A method body is itself a FunctionDefinitionAst, so an unqualified 'Process'
        # is what you get without treating the member as the unit -- and then three
        # different units in this file all answer to that one name.
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Cyclomatic | Should -Be 5
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Cognitive  | Should -Be 10
    }

    It 'reports each method exactly once' {
        @($script:clsRecs | Where-Object Unit -eq 'Order.Process') | Should -HaveCount 1
    }

    It 'keeps same-named methods on different classes apart, and apart from a function' {
        $names = @($script:clsRecs | Where-Object { $_.Unit -like '*Process*' } | ForEach-Object Unit | Sort-Object)
        $names | Should -Be @('Invoice.Process', 'Order.Process', 'Process')
    }

    It 'names a constructor after its class' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Order').Cyclomatic | Should -Be 2
    }

    It 'reports a static method' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Helper').Cyclomatic | Should -Be 1
    }

    It 'makes an initialised property its own unit and leaves the script body alone' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Threshold').Cyclomatic | Should -Be 2
        ($script:clsRecs | Where-Object Unit -eq '<script-body>').Cyclomatic  | Should -Be 1
    }

    It 'does not create a unit for a property with no initialiser' {
        # No initialiser means no code, so there is nothing to measure or gate.
        ($script:clsRecs | Where-Object Unit -eq 'Order.Plain') | Should -BeNullOrEmpty
    }

    It 'reports the line of the member, not of the class' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Line | Should -Be 5
    }

    It 'lets the gate fail a single over-complex method' {
        # The point of the whole change: a per-unit ceiling can now name the method.
        Test-PSComplexity -Path $script:clsFile -MaxCognitive 9 -WarningAction SilentlyContinue | Should -BeFalse
        Test-PSComplexity -Path $script:clsFile -MaxCognitive 10 -WarningAction SilentlyContinue | Should -BeTrue
    }
}
