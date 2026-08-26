# Dogfood: PSComplexity gates its own source with the command it ships, at that command's
# own default ceilings -- the same bar it exists to enforce for others.

BeforeAll {
    $script:src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $script:src -Filter *.ps1) { . $f.FullName }
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
