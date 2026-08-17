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
    It 'does not recurse without -Recurse' {
        $recs = Measure-PSComplexity -Path $script:work
        ($recs | Where-Object Unit -eq 'Get-B') | Should -BeNullOrEmpty
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

# ─────────────────────────────────────────────────────────────────────────────
# Top-level script code: decisions and calls that sit OUTSIDE any function.
# Every fixture above wraps its logic in one, so the "walked to the top without
# finding a function" fallbacks in Ast.ps1 were never reached. That shape is not
# exotic — a crawler entry point, a build script or a profile is exactly this,
# and it is the code most likely to be complex and least likely to be tested.
# ─────────────────────────────────────────────────────────────────────────────

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
        # call must not be scored — a script that calls a command sharing its file
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
