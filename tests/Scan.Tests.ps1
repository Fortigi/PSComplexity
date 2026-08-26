# The scan: paths in, measured units out, as data.
#
# The COVERING SUITE for src/Scan.ps1, and cheap on purpose. It touches a disk -- resolving paths
# and parsing files is what the scan IS -- but it does so over one small fixture created once,
# rather than the 134 separate measurements tests/Measure.Tests.ps1 performs.
#
# That suite is 19s, and profiling it showed 16.7s in test BODIES against 2.3s of setup: the cost
# is the measuring, not the fixtures, so making the fixtures cheaper would have bought two seconds.
# Moving these 35 mutants onto a suite that measures once is the lever that actually works.
#
# The end-to-end proofs did not move. Measure.Tests.ps1 still drives all of this through the public
# commands, because covering a function is not covering its application.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Every src file, discovered rather than listed. A hand-kept list here is a second copy
    # of the one in PSComplexity.psm1, and this is the copy that goes stale -- a file
    # missing from it fails with 'term not recognized' in whichever test happens to call
    # into it, which reads as a broken test rather than an unloaded file. Order does not
    # matter: every cross-file reference sits in a function body and resolves at call time.
    foreach ($f in Get-ChildItem $src -Filter *.ps1) { . $f.FullName }

    # ONE fixture tree, built once. Flat and nested, .ps1 and .psm1 and a file that is neither,
    # plus one that does not parse -- so every branch below has something to find.
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "cxscan-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:work 'nested') -Force | Out-Null
    Set-Content (Join-Path $script:work 'flat.ps1') "function Get-Flat { param(`$x) if (`$x) { 1 } }`n`$top = 1" -Encoding utf8
    Set-Content (Join-Path $script:work 'mod.psm1') "function Get-Mod { 1 }" -Encoding utf8
    Set-Content (Join-Path $script:work 'notes.txt') 'not powershell' -Encoding utf8
    Set-Content (Join-Path $script:work 'nested/deep.ps1') "function Get-Deep { param(`$y) foreach (`$i in `$y) { if (`$i) { 1 } } }" -Encoding utf8

    # Unparseable lives APART, outside any path the other tests walk: kept alongside, it makes
    # every scan emit a skip that most of these tests do not care about.
    $script:broken = Join-Path $script:work 'broken'
    New-Item -ItemType Directory -Path $script:broken -Force | Out-Null
    # Exactly ONE parse error, deliberately. The skip message is built from $errors[0], and a
    # fixture producing several lets a mutant read $errors[1] instead and still print a real
    # message -- 'function Get-Bad { if (' yields two, and that mutant survived against it.
    # An unclosed brace yields one, so reading past it produces "parse error: " and nothing else.
    Set-Content -LiteralPath (Join-Path $script:broken 'bad.ps1') -Value 'function Get-Bad {' -Encoding utf8

    $script:flat = Join-Path $script:work 'flat.ps1'

    # Get-PSCxPathScan dedupes files across the paths it is given, so the caller owns the set.
    # A fresh one per call keeps each test independent of the ones before it.
    #
    # COMMA-WRAPPED. A HashSet is enumerable, so returning an EMPTY one from a function unrolls
    # it to nothing and the caller gets $null -- which then fails to bind to a mandatory
    # parameter, several lines away from the return that caused it.
    function script:NewSeen { return , [System.Collections.Generic.HashSet[string]]::new() }
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-PSCxSourceFile' {
    It 'returns a single file asked for by name' {
        @(Get-PSCxSourceFile -Path $script:flat).Count | Should-Be 1
    }

    It 'takes .ps1 and .psm1 from a directory, and nothing else' {
        # Filtered on the extension rather than with -Include, which a directory IGNORES unless
        # -Recurse is also given -- a flat folder would resolve to zero files and every number
        # after it would describe the empty set.
        $names = @(Get-PSCxSourceFile -Path $script:work | ForEach-Object { Split-Path $_ -Leaf })
        $names | Should-ContainCollection 'flat.ps1'
        $names | Should-ContainCollection 'mod.psm1'
        $names | Should-NotContainCollection 'notes.txt'
    }

    It 'stays flat without -Recurse, and descends with it' {
        # Paired, because a filter that always recursed would pass the second half alone.
        $flatOnly = @(Get-PSCxSourceFile -Path $script:work | ForEach-Object { Split-Path $_ -Leaf })
        $flatOnly | Should-NotContainCollection 'deep.ps1'
        $deep = @(Get-PSCxSourceFile -Path $script:work -Recurse | ForEach-Object { Split-Path $_ -Leaf })
        $deep | Should-ContainCollection 'deep.ps1'
    }

    It 'takes an existing path LITERALLY, so a bracket in a directory name still resolves' {
        # -Path glob-parses '[', so a real directory named 'my[1]proj' matches nothing and the
        # scan reports a clean zero over code it never opened.
        $odd = Join-Path $script:work 'my[1]proj'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $odd 'a.ps1') -Value 'function Get-A { 1 }' -Encoding utf8
        @(Get-PSCxSourceFile -Path $odd).Count | Should-Be 1
    }

    It 'returns a named file whatever its extension, because you asked for it by name' {
        # The leaf branch returns the file directly; only the DIRECTORY branch filters on
        # extension. Force that test false and a named .txt falls through to the filter and
        # disappears -- while a named .ps1 still comes back, so a .ps1 fixture cannot tell.
        @(Get-PSCxSourceFile -Path (Join-Path $script:work 'notes.txt')).Count | Should-Be 1
    }

    It 'never returns a DIRECTORY that happens to be named like a script' {
        # The enumeration asks for files only. Without that, a directory called something.ps1
        # matches the extension filter and is handed on to be parsed as source.
        $trap = Join-Path $script:work 'looks-like.ps1'
        New-Item -ItemType Directory -Path $trap -Force | Out-Null
        @(Get-PSCxSourceFile -Path $script:work | ForEach-Object { Split-Path $_ -Leaf }) |
            Should-NotContainCollection 'looks-like.ps1'
    }

    It 'falls back to wildcard matching when the path does not exist literally' {
        # The other half of that decision: a path nobody has is treated as a pattern.
        @(Get-PSCxSourceFile -Path (Join-Path $script:work '*.psm1')).Count | Should-Be 1
    }
}

Describe 'Get-PSCxRelativePath' {
    It 'renders a path under the root relative, with forward slashes' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $file = Join-Path $root (Join-Path 'src' 'A.ps1')
        Get-PSCxRelativePath -Path $file -Root $root | Should-Be 'src/A.ps1'
    }

    It 'resolves a RELATIVE path against Root, not the working directory' {
        # GetFullPath alone silently uses the CWD, so the function only gave the right answer
        # while its caller happened to pass an absolute path AND a Root equal to the CWD -- two
        # conditions that both had to hold and neither of which was stated.
        Get-PSCxRelativePath -Path 'src/A.ps1' -Root ([System.IO.Path]::GetFullPath('/repo')) |
            Should-Be 'src/A.ps1'
    }

    It 'keeps the FULL path for a file outside the root' {
        # A ../../ chain says less than the absolute path does and is no more portable, so
        # pretending would only hide where the file came from.
        $out = Get-PSCxRelativePath -Path ([System.IO.Path]::GetFullPath('/elsewhere/B.ps1')) `
            -Root ([System.IO.Path]::GetFullPath('/repo'))
        $out | Should-BeLikeString '*elsewhere/B.ps1'
        $out | Should-NotBeLikeString '..*'
    }

    It 'treats a root with and without a trailing separator alike' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $file = Join-Path $root (Join-Path 'src' 'A.ps1')
        (Get-PSCxRelativePath -Path $file -Root $root) |
            Should-Be (Get-PSCxRelativePath -Path $file -Root ($root + $sep))
    }

    It 'matches the root case-insensitively' {
        # A config may spell a drive or directory in either case, and a run that reported one
        # file twice under two spellings would double it in any per-file total.
        $root = [System.IO.Path]::GetFullPath('/Repo')
        $file = Join-Path ([System.IO.Path]::GetFullPath('/repo')) 'A.ps1'
        Get-PSCxRelativePath -Path $file -Root $root | Should-Be 'A.ps1'
    }

    It 'never leaves a platform separator in the result' {
        # The PLATFORM separator is replaced, not a literal backslash: on Linux a backslash is an
        # ordinary filename character, so replacing it there corrupts a legal path -- and doing so
        # is a no-op on the one platform the mutation gate runs, which is how a hard-coded one
        # survived every mutant while looking tested.
        $root = [System.IO.Path]::GetFullPath('/repo')
        $file = Join-Path $root (Join-Path 'a' (Join-Path 'b' 'C.ps1'))
        Get-PSCxRelativePath -Path $file -Root $root |
            Should-NotBeLikeString "*$([System.IO.Path]::DirectorySeparatorChar)*"
    }
}

Describe 'Get-PSCxUnitRecord' {
    It 'carries the published fields, and only those, without -Detailed' {
        $r = Get-PSCxUnitRecord -File 'src/A.ps1' -Unit 'Get-A' -Line 3 -Cyclomatic 2 -Cognitive 1 -MetricVersion 1
        ($r.PSObject.Properties.Name -join ',') |
            Should-Be 'File,Unit,Line,Cyclomatic,Cognitive,MetricVersion'
    }

    It 'keeps the numbers apart' {
        # Chosen so a swapped pair cannot pass: equal values would hide it.
        $r = Get-PSCxUnitRecord -File 'f' -Unit 'u' -Line 7 -Cyclomatic 2 -Cognitive 9 -MetricVersion 3
        $r.Line | Should-Be 7
        $r.Cyclomatic | Should-Be 2
        $r.Cognitive | Should-Be 9
        $r.MetricVersion | Should-Be 3
    }

    It 'adds an EMPTY Contributions with -Detailed for a decision-free unit' {
        # Absent and empty are different answers, and a consumer iterating this should not have
        # to tell them apart -- so a decision-free unit still gets the property.
        #
        # -Contributions @() explicitly, which is what the scan passes. Omitting it entirely
        # yields @($null), an array of ONE null, because that is what @() does to a null in
        # PowerShell -- a shape no caller produces and not worth a guard in the record shaper.
        $r = Get-PSCxUnitRecord -File 'f' -Unit 'u' -Line 1 -Cyclomatic 1 -Cognitive 0 `
            -MetricVersion 1 -Contributions @() -Detailed
        $r.PSObject.Properties.Name | Should-ContainCollection 'Contributions'
        @($r.Contributions).Count | Should-Be 0
    }

    It 'omits Contributions entirely without -Detailed' {
        $r = Get-PSCxUnitRecord -File 'f' -Unit 'u' -Line 1 -Cyclomatic 1 -Cognitive 0 -MetricVersion 1 `
            -Contributions @([pscustomobject]@{ Kind = 'if' })
        $r.PSObject.Properties.Name | Should-NotContainCollection 'Contributions'
    }
}

Describe 'Get-PSCxFileScan' {
    It 'returns the units of a file that parses, with no skip reason' {
        $scan = Get-PSCxFileScan -File $script:flat
        @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Flat'
        $scan.SkipReason | Should-BeNull
    }

    It 'reports the script body as a unit of its own' {
        # A decision-free unit still reports, so a file of top-level code is measured rather
        # than silently producing nothing.
        @(Get-PSCxFileScan -File $script:flat).Units.Unit | Should-ContainCollection '<script-body>'
    }

    It 'names a file that does not parse, with a reason, and emits no units' {
        # A skip that exists only on the error stream is a fact the caller has to rebuild by
        # capturing the stream and reading message text -- which is what the gate used to do,
        # with -ErrorAction SilentlyContinue, so any unrelated failure reached the user
        # described as a parse error.
        $scan = Get-PSCxFileScan -File (Join-Path $script:broken 'bad.ps1')
        @($scan.Units).Count | Should-Be 0
        # Matched with a regex demanding a non-space AFTER the prefix, not just the prefix.
        # The message is built from $errors[0]; read $errors[1] instead and there is no second
        # error, so the text becomes "parse error: " -- which still contains "parse error" and
        # passes any assertion written on the prefix alone.
        [string]$scan.SkipReason | Should-MatchString '^parse error: \S'
        [string]$scan.File | Should-BeLikeString '*bad.ps1'
    }

    It 'stamps every unit with the metric version' {
        @(Get-PSCxFileScan -File $script:flat).Units[0].MetricVersion | Should-Be (Get-PSCxMetricVersion)
    }

    It 'carries contributions only with -Detailed' {
        (Get-PSCxFileScan -File $script:flat).Units[0].PSObject.Properties.Name |
            Should-NotContainCollection 'Contributions'
        (Get-PSCxFileScan -File $script:flat -Detailed).Units[0].PSObject.Properties.Name |
            Should-ContainCollection 'Contributions'
    }

    It 'fills in the contributions of a unit that HAS decisions' {
        # The property existing is not the claim -- its contents are. Skip the lookup that
        # populates them and every unit still reports a Contributions property, just an empty
        # one, which an assertion on the property name alone cannot tell apart.
        $unit = @((Get-PSCxFileScan -File $script:flat -Detailed).Units |
                Where-Object Unit -eq 'Get-Flat')[0]
        @($unit.Contributions).Count | Should-BeGreaterThan 0
    }

    It 'gives a decision-free unit EXACTLY zero contributions, not one null' {
        # The paired half, and the trap the source comment names: a missing key looked up anyway
        # yields $null, and @($null) is an array of ONE -- a contribution with no line, no
        # construct and no amount, which survives a count check by looking like data.
        $bare = Join-Path $script:work 'bare.ps1'
        Set-Content -LiteralPath $bare -Value 'function Get-Bare { 1 }' -Encoding utf8
        $unit = @((Get-PSCxFileScan -File $bare -Detailed).Units |
                Where-Object Unit -eq 'Get-Bare')[0]
        @($unit.Contributions).Count | Should-Be 0
    }

    It 'does not build a breakdown nobody asked for' {
        # -Detailed costs an extra walk of the whole AST per file, and this is the command a CI
        # gate runs on every push. The guard is invisible in the output either way -- the records
        # are identical whether or not the map was built -- so nothing but this assertion stops
        # it being dropped, and the cost would land on every consumer.
        #
        # Both halves, because the negative alone passes just as well against a guard that never
        # calls it at all.
        Mock Get-PSCxContributionMap { @{} }
        Get-PSCxFileScan -File $script:flat | Out-Null
        Should-NotInvoke Get-PSCxContributionMap
        Get-PSCxFileScan -File $script:flat -Detailed | Out-Null
        Should-Invoke Get-PSCxContributionMap -Times 1 -Exactly
    }
}

Describe 'Get-PSCxPathScan' {
    # It EMITS one file scan per file rather than returning an aggregate -- Get-PSCxScan below is
    # what collects units and skips into one answer.

    It 'measures every source file under a path' {
        $scans = @(Get-PSCxPathScan -Path $script:work -Seen (NewSeen) -Recurse)
        $units = @($scans | ForEach-Object { $_.Units } | ForEach-Object Unit)
        $units | Should-ContainCollection 'Get-Deep'
        $units | Should-ContainCollection 'Get-Flat'
    }

    It 'emits a scan for the broken file too, rather than dropping it' {
        # A scan over a tree with one unparseable file must still report the good ones, and a
        # fixture containing only good files cannot tell that apart from a walk that stops on the
        # first failure. So: one of each, in one call.
        $mixed = Join-Path $script:work 'mixed'
        New-Item -ItemType Directory -Path $mixed -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mixed 'ok.ps1') -Value 'function Get-Ok { 1 }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $mixed 'bad.ps1') -Value 'function Get-Bad { if (' -Encoding utf8
        $scans = @(Get-PSCxPathScan -Path $mixed -Seen (NewSeen))
        $scans.Count | Should-Be 2
        @($scans | Where-Object { $_.SkipReason }).Count | Should-Be 1
        @($scans | ForEach-Object { $_.Units } | ForEach-Object Unit) | Should-ContainCollection 'Get-Ok'
    }

    It 'measures a file once when two paths both reach it' {
        # The seen-set is the whole reason this takes one: gate ./src and ./src/A.ps1 together and
        # the file would otherwise be measured twice and counted twice in any per-file total.
        $seen = NewSeen
        $scans = @(Get-PSCxPathScan -Path @($script:flat, $script:flat) -Seen $seen)
        $scans.Count | Should-Be 1
    }
}

Describe 'Get-PSCxScan' {
    It 'reports what it was asked to read' {
        # Scope is what lets a report say which set a number describes. Without it a consumer
        # cannot tell a clean sweep from a run pointed at one file.
        $scan = Get-PSCxScan -Path @($script:flat) -Recurse:$false
        @($scan.Scope.Path) | Should-ContainCollection $script:flat
        $scan.Scope.Recurse | Should-BeFalse
    }

    It 'records -Recurse as asked' {
        (Get-PSCxScan -Path @($script:work) -Recurse).Scope.Recurse | Should-BeTrue
    }

    It 'carries the metric version at the top level' {
        (Get-PSCxScan -Path @($script:flat)).MetricVersion | Should-Be (Get-PSCxMetricVersion)
    }

    It 'keeps skips BESIDE the units, not instead of them' {
        # An aggregate that cannot say what it excluded is the failure this project exists to
        # find. Both halves in one call, because a tree of only-good files cannot tell a working
        # scan from one that drops everything on the first parse error.
        $mixed2 = Join-Path $script:work 'mixed2'
        New-Item -ItemType Directory -Path $mixed2 -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mixed2 'ok.ps1') -Value 'function Get-Ok2 { 1 }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $mixed2 'bad.ps1') -Value 'function Get-Bad2 { if (' -Encoding utf8
        $scan = Get-PSCxScan -Path @($mixed2)
        @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Ok2'
        @($scan.Skipped).Count | Should-Be 1
        [string]$scan.Skipped[0].Reason | Should-BeLikeString '*parse error*'
    }

    It 'merges several paths into one scan' {
        $scan = Get-PSCxScan -Path @($script:flat, (Join-Path $script:work 'nested')) -Recurse
        $names = @($scan.Units | ForEach-Object Unit)
        $names | Should-ContainCollection 'Get-Flat'
        $names | Should-ContainCollection 'Get-Deep'
    }
}

Describe 'Get-PSCxMetricVersion' {
    It 'reports the version this build measures with' {
        # Read through the function rather than the variable, because no other file may reach
        # into this one's module state -- tests/Layering.Tests.ps1 asserts exactly that.
        Get-PSCxMetricVersion | Should-Be 1
    }
}
