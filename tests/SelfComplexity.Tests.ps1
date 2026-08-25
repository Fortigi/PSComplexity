# Dogfood: PSComplexity gates its own source with the command it ships, at that command's
# own default ceilings -- the same bar it exists to enforce for others.

BeforeAll {
    $script:src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1', 'Report.ps1') { . (Join-Path $script:src $f) }
    $script:units = @(Measure-PSComplexity -Path $script:src -Recurse)
}

Describe 'Self complexity gate' {
    It 'measured its own units' {
        # Deliberately NOT an exact count: this asserts that the gate below judged something,
        # and a literal here would fail on every unrelated edit to src/ while proving no more.
        $script:units.Count | Should-BeGreaterThan 0
    }
    It 'passes the gate it ships, at the ceilings it ships' {
        # Calls Test-PSComplexity rather than re-deriving the comparison. It used to do the
        # latter, which meant the shipped command and the gate that proves this project
        # meets its own bar could disagree without anything noticing -- and the ceilings had
        # to be written out again here, so changing the default missed this file.
        #
        # The warnings carry the offending units, so a failure still names them.
        $wv = $null
        $ok = Test-PSComplexity -Path $script:src -Recurse -WarningVariable wv -WarningAction SilentlyContinue
        $ok | Should-BeTrue -Because (($wv | ForEach-Object { $_.Message }) -join '; ')
    }
}
