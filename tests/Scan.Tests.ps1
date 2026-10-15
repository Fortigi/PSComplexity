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
    # The comparison a real run makes on this platform's usual file system. Tests about case
    # pass both values explicitly instead (#151).
    $script:PathCmp = $IsLinux ? [System.StringComparison]::Ordinal : [System.StringComparison]::OrdinalIgnoreCase
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

    # And the same for the unmatched-path list, which the caller owns for the same reason: paths
    # arrive one invocation at a time, so a list created inside the walk would forget the last one.
    # Comma-wrapped for the reason above -- an empty List unrolls to nothing on the way out.
    function script:NewUnmatched { return , [System.Collections.Generic.List[object]]::new() }
}

AfterAll { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Get-PSCxSourceFile' {
    It 'returns a single file asked for by name' {
        (Get-PSCxSourceFile -Path $script:flat).Count | Should-Be 1
    }

    It 'takes .ps1 and .psm1 from a directory, and nothing else' {
        # Filtered on the extension rather than with -Include, which a directory IGNORES unless
        # -Recurse is also given -- a flat folder would resolve to zero files and every number
        # after it would describe the empty set.
        $names = @((Get-PSCxSourceFile -Path $script:work) | ForEach-Object { Split-Path $_ -Leaf })
        $names | Should-ContainCollection 'flat.ps1'
        $names | Should-ContainCollection 'mod.psm1'
        $names | Should-NotContainCollection 'notes.txt'
    }

    It 'stays flat without -Recurse, and descends with it' {
        # Paired, because a filter that always recursed would pass the second half alone.
        $flatOnly = @((Get-PSCxSourceFile -Path $script:work) | ForEach-Object { Split-Path $_ -Leaf })
        $flatOnly | Should-NotContainCollection 'deep.ps1'
        $deep = @((Get-PSCxSourceFile -Path $script:work -Recurse) | ForEach-Object { Split-Path $_ -Leaf })
        $deep | Should-ContainCollection 'deep.ps1'
    }

    It 'walks a dot-directory and takes a dot-file, on every OS (#161)' {
        # Linux treats a dot-name as hidden and Get-ChildItem skips it without -Force; Windows
        # hides by attribute and did not. The same tree measured differently per platform, and
        # `.github/scripts/x.ps1` vanished from a Linux gate without a word. Its own directory,
        # so the counts other tests take over the shared fixture do not move.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "cxdot-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $root '.hidden') -Force | Out-Null
        Set-Content (Join-Path $root '.hidden/inner.ps1') 'function Get-Inner { 1 }' -Encoding utf8
        Set-Content (Join-Path $root '.dotfile.ps1') 'function Get-Dot { 1 }' -Encoding utf8
        Set-Content (Join-Path $root 'plain.ps1') 'function Get-Plain { 1 }' -Encoding utf8
        try {
            $names = @((Get-PSCxSourceFile -Path $root -Recurse) | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
            ($names -join ',') | Should-Be '.dotfile.ps1,inner.ps1,plain.ps1'
        }
        finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'takes an existing path LITERALLY, so a bracket in a directory name still resolves' {
        # -Path glob-parses '[', so a real directory named 'my[1]proj' matches nothing and the
        # scan reports a clean zero over code it never opened.
        $odd = Join-Path $script:work 'my[1]proj'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $odd 'a.ps1') -Value 'function Get-A { 1 }' -Encoding utf8
        (Get-PSCxSourceFile -Path $odd).Count | Should-Be 1
    }

    It 'returns a named file whatever its extension, because you asked for it by name' {
        # The leaf branch returns the file directly; only the DIRECTORY branch filters on
        # extension. Force that test false and a named .txt falls through to the filter and
        # disappears -- while a named .ps1 still comes back, so a .ps1 fixture cannot tell.
        (Get-PSCxSourceFile -Path (Join-Path $script:work 'notes.txt')).Count | Should-Be 1
    }

    It 'never returns a DIRECTORY that happens to be named like a script' {
        # The enumeration asks for files only. Without that, a directory called something.ps1
        # matches the extension filter and is handed on to be parsed as source.
        $trap = Join-Path $script:work 'looks-like.ps1'
        New-Item -ItemType Directory -Path $trap -Force | Out-Null
        @((Get-PSCxSourceFile -Path $script:work) | ForEach-Object { Split-Path $_ -Leaf }) |
            Should-NotContainCollection 'looks-like.ps1'
    }

    It 'falls back to wildcard matching when the path does not exist literally' {
        # The other half of that decision: a path nobody has is treated as a pattern.
        (Get-PSCxSourceFile -Path (Join-Path $script:work '*.psm1')).Count | Should-Be 1
    }
}

Describe 'Get-PSCxRelativePath' {
    It 'renders a path under the root relative, with forward slashes' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $file = Join-Path $root (Join-Path 'src' 'A.ps1')
        Get-PSCxRelativePath -PathComparison $script:PathCmp -Path $file -Root $root | Should-Be 'src/A.ps1'
    }

    It 'decides what is under the root by the run path comparison, both ways (#151)' {
        # On a case-sensitive file system /REPO is not /repo, so a file there is outside the root
        # and keeps its full path. Ignoring case it is the same directory, the file is relative
        # to it, and a config spelling the root in another case does not name one file twice.
        $root = [System.IO.Path]::GetFullPath('/repo')
        $file = Join-Path ([System.IO.Path]::GetFullPath('/REPO')) 'A.ps1'
        Get-PSCxRelativePath -PathComparison Ordinal -Path $file -Root $root |
            Should-BeString $file.Replace([System.IO.Path]::DirectorySeparatorChar, '/') -CaseSensitive
        Get-PSCxRelativePath -PathComparison OrdinalIgnoreCase -Path $file -Root $root | Should-BeString 'A.ps1' -CaseSensitive
    }

    It 'resolves a RELATIVE path against Root, not the working directory' {
        # GetFullPath alone silently uses the CWD, so the function only gave the right answer
        # while its caller happened to pass an absolute path AND a Root equal to the CWD -- two
        # conditions that both had to hold and neither of which was stated.
        Get-PSCxRelativePath -PathComparison $script:PathCmp -Path 'src/A.ps1' -Root ([System.IO.Path]::GetFullPath('/repo')) |
            Should-Be 'src/A.ps1'
    }

    It 'keeps the FULL path for a file outside the root' {
        # A ../../ chain says less than the absolute path does and is no more portable, so
        # pretending would only hide where the file came from.
        $out = Get-PSCxRelativePath -PathComparison $script:PathCmp -Path ([System.IO.Path]::GetFullPath('/elsewhere/B.ps1')) `
            -Root ([System.IO.Path]::GetFullPath('/repo'))
        $out | Should-BeLikeString '*elsewhere/B.ps1'
        $out | Should-NotBeLikeString '..*'
    }

    It 'treats a root with and without a trailing separator alike' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $file = Join-Path $root (Join-Path 'src' 'A.ps1')
        (Get-PSCxRelativePath -PathComparison $script:PathCmp -Path $file -Root $root) |
            Should-Be (Get-PSCxRelativePath -PathComparison $script:PathCmp -Path $file -Root ($root + $sep))
    }

    It 'separates every level with a forward slash' {
        # Asserted as the exact string it should be, on BOTH platforms.
        #
        # Written as "contains no DirectorySeparatorChar" this passed on Windows and failed on
        # Linux, where that character IS '/' and the correct answer is full of them. The claim it
        # was reaching for -- that the code replaces the PLATFORM separator rather than a literal
        # backslash -- is a no-op on Linux and therefore not observable there at all, which
        # CLAUDE.md already records as the reason a hard-coded backslash once survived every
        # mutant while looking tested. An exact expectation says the observable half on both.
        $root = [System.IO.Path]::GetFullPath('/repo')
        $file = Join-Path $root (Join-Path 'a' (Join-Path 'b' 'C.ps1'))
        Get-PSCxRelativePath -PathComparison $script:PathCmp -Path $file -Root $root | Should-Be 'a/b/C.ps1'
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
        $scan = Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat
        @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Flat'
        $scan.SkipReason | Should-BeNull
    }

    It 'reports the script body as a unit of its own' {
        # A decision-free unit still reports, so a file of top-level code is measured rather
        # than silently producing nothing.
        @(Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat).Units.Unit | Should-ContainCollection '<script-body>'
    }

    It 'names a file that does not parse, with a reason, and emits no units' {
        # A skip that exists only on the error stream is a fact the caller has to rebuild by
        # capturing the stream and reading message text -- which is what the gate used to do,
        # with -ErrorAction SilentlyContinue, so any unrelated failure reached the user
        # described as a parse error.
        $scan = Get-PSCxFileScan -PathComparison $script:PathCmp -File (Join-Path $script:broken 'bad.ps1')
        @($scan.Units).Count | Should-Be 0
        # Matched with a regex demanding a non-space AFTER the prefix, not just the prefix.
        # The message is built from $errors[0]; read $errors[1] instead and there is no second
        # error, so the text becomes "parse error: " -- which still contains "parse error" and
        # passes any assertion written on the prefix alone.
        [string]$scan.SkipReason | Should-MatchString '^parse error: \S'
        [string]$scan.File | Should-BeLikeString '*bad.ps1'
    }

    It 'stamps every unit with the metric version' {
        @(Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat).Units[0].MetricVersion | Should-Be (Get-PSCxMetricVersion)
    }

    It 'carries contributions only with -Detailed' {
        (Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat).Units[0].PSObject.Properties.Name |
            Should-NotContainCollection 'Contributions'
        (Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat -Detailed).Units[0].PSObject.Properties.Name |
            Should-ContainCollection 'Contributions'
    }

    It 'fills in the contributions of a unit that HAS decisions' {
        # The property existing is not the claim -- its contents are. Skip the lookup that
        # populates them and every unit still reports a Contributions property, just an empty
        # one, which an assertion on the property name alone cannot tell apart.
        $unit = @((Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat -Detailed).Units |
                Where-Object Unit -eq 'Get-Flat')[0]
        @($unit.Contributions).Count | Should-BeGreaterThan 0
    }

    It 'gives a decision-free unit EXACTLY zero contributions, not one null' {
        # The paired half, and the trap the source comment names: a missing key looked up anyway
        # yields $null, and @($null) is an array of ONE -- a contribution with no line, no
        # construct and no amount, which survives a count check by looking like data.
        $bare = Join-Path $script:work 'bare.ps1'
        Set-Content -LiteralPath $bare -Value 'function Get-Bare { 1 }' -Encoding utf8
        $unit = @((Get-PSCxFileScan -PathComparison $script:PathCmp -File $bare -Detailed).Units |
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
        Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat | Out-Null
        Should-NotInvoke Get-PSCxContributionMap
        Get-PSCxFileScan -PathComparison $script:PathCmp -File $script:flat -Detailed | Out-Null
        Should-Invoke Get-PSCxContributionMap -Times 1 -Exactly
    }
}

Describe 'Get-PSCxPathScan' {
    # It EMITS one file scan per file rather than returning an aggregate -- Get-PSCxScan below is
    # what collects units and skips into one answer.

    It 'measures every source file under a path' {
        $scans = @(Get-PSCxPathScan -PathComparison $script:PathCmp -Path $script:work -Seen (NewSeen) -Unmatched (NewUnmatched) -Recurse)
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
        $scans = @(Get-PSCxPathScan -PathComparison $script:PathCmp -Path $mixed -Seen (NewSeen) -Unmatched (NewUnmatched))
        $scans.Count | Should-Be 2
        @($scans | Where-Object { $_.SkipReason }).Count | Should-Be 1
        @($scans | ForEach-Object { $_.Units } | ForEach-Object Unit) | Should-ContainCollection 'Get-Ok'
    }

    It 'measures a file once when two paths both reach it' {
        # The seen-set is the whole reason this takes one: gate ./src and ./src/A.ps1 together and
        # the file would otherwise be measured twice and counted twice in any per-file total.
        $seen = NewSeen
        $scans = @(Get-PSCxPathScan -PathComparison $script:PathCmp -Path @($script:flat, $script:flat) -Seen $seen -Unmatched (NewUnmatched))
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

    It 'measures BOTH of two files whose names differ only in case, on Linux (#151)' -Skip:(-not $IsLinux) {
        # On Windows and macOS these are one file and cannot be created side by side. On Linux
        # the second was skipped as already seen, and the gate passed over code it never read.
        $pair = Join-Path $script:work "case-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $pair -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pair 'A.ps1') -Value 'function Get-Upper { 1 }' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $pair 'a.ps1') -Value 'function Get-Lower { 1 }' -Encoding utf8
        # From inside the pair, so the run reads case sensitivity from the file system the pair
        # is on rather than from wherever the suite happens to be run.
        Push-Location -LiteralPath $pair
        try { $scan = Get-PSCxScan -Path @('.') }
        finally { Pop-Location }
        @($scan.Skipped).Count | Should-Be 0
        (@($scan.Units | Where-Object Unit -ne '<script-body>' | ForEach-Object Unit | Sort-Object) -join ',') |
            Should-Be 'Get-Lower,Get-Upper'
    }

    It 'measures one file reached under two casings ONCE, where the file system ignores case' -Skip:$IsLinux {
        # The other half of the same comparer: on Windows and macOS the directory and the
        # upper-cased literal are one file, and counting it twice doubles its rows.
        Push-Location -LiteralPath $script:work
        try { $scan = Get-PSCxScan -Path @('.', 'FLAT.PS1') }
        finally { Pop-Location }
        @($scan.Skipped).Count | Should-Be 0
        @($scan.Units | Where-Object Unit -eq 'Get-Flat').Count | Should-Be 1
    }

    It 'records how it compared file paths, read from the working directory (#151)' {
        # The suite's two CI legs are Linux on ext4 and Windows on NTFS, so the answer here is the
        # file system's and happens to match the platform. What is pinned is that the scan
        # RECORDS it, which is what the gate keys the baseline by.
        Push-Location -LiteralPath $script:work
        try { $scan = Get-PSCxScan -Path @('flat.ps1') }
        finally { Pop-Location }
        $scan.PathComparison | Should-Be (Get-PSCxRunPathComparison -Root $script:work)
    }

    It 'merges several paths into one scan' {
        $scan = Get-PSCxScan -Path @($script:flat, (Join-Path $script:work 'nested')) -Recurse
        $names = @($scan.Units | ForEach-Object Unit)
        $names | Should-ContainCollection 'Get-Flat'
        $names | Should-ContainCollection 'Get-Deep'
    }
}

Describe 'a provider-qualified path, which is what a UNC path becomes (#171)' {
    # PowerShell writes a UNC location as 'Microsoft.PowerShell.Core\FileSystem::\\server\share',
    # and .Path keeps that prefix where .ProviderPath drops it. A UNC share cannot be relied on
    # on a CI runner, but a LOCAL path written provider-qualified takes the same route through the
    # same two properties on every platform -- which is how the bug was reproduced, and how
    # these tests reach it.
    BeforeAll {
        $script:plainWork = (Resolve-Path -LiteralPath $script:work).ProviderPath
        $script:plainFlat = (Resolve-Path -LiteralPath $script:flat).ProviderPath
        $script:qualify = { param($p) "Microsoft.PowerShell.Core\FileSystem::$p" }
    }

    It 'resolves a qualified file to the plain file-system path' {
        # The exact string, so the assertion says the prefix is gone rather than merely that
        # something was returned.
        $files = Get-PSCxSourceFile -Path (& $script:qualify $script:plainFlat)
        ($files -join '|') | Should-Be $script:plainFlat
    }

    It 'reads the working root as a file-system path from a qualified location' {
        Push-Location -LiteralPath (& $script:qualify $script:plainWork)
        try { Get-PSCxWorkingRoot | Should-Be $script:plainWork }
        finally { Pop-Location }
    }

    It 'measures a qualified file exactly as it measures the plain one' {
        $plain = Get-PSCxScan -Path @($script:plainFlat)
        $qualified = Get-PSCxScan -Path @(& $script:qualify $script:plainFlat)
        @($qualified.Skipped).Count | Should-Be 0
        @($qualified.Units).Count | Should-BeGreaterThan 0
        (@($qualified.Units | ForEach-Object { "$($_.File)|$($_.Unit)|$($_.Cyclomatic)|$($_.Cognitive)" }) -join ';') |
            Should-Be (@($plain.Units | ForEach-Object { "$($_.File)|$($_.Unit)|$($_.Cyclomatic)|$($_.Cognitive)" }) -join ';')
    }

    It 'measures a RELATIVE path from a qualified location, named relative to it' {
        # The half a share user hits first: Set-Location to the share, then gate ./src.
        Push-Location -LiteralPath (& $script:qualify $script:plainWork)
        try { $scan = Get-PSCxScan -Path @('./flat.ps1') }
        finally { Pop-Location }
        @($scan.Skipped).Count | Should-Be 0
        (@($scan.Units | ForEach-Object File | Sort-Object -Unique) -join '|') | Should-Be 'flat.ps1'
    }

    It 'names files under a DIRECTORY relative to a qualified location' {
        # The quiet half. A directory always measured -- Get-ChildItem hands back plain paths --
        # but against a prefixed root every File came out absolute, so a baseline or acceptance
        # keyed 'flat.ps1' matched nothing. Measured before the fix: the full share path.
        Push-Location -LiteralPath (& $script:qualify $script:plainWork)
        try { $scan = Get-PSCxScan -Path @('.') }
        finally { Pop-Location }
        @($scan.Units | ForEach-Object File) | Should-ContainCollection 'flat.ps1'
    }

    It 'matches -ChangedFile from a qualified location' {
        # The dangerous half. With an absolute File on every unit, a repo-relative changed list
        # matched nothing, and "no changed PowerShell" is a PASS -- over zero units.
        Push-Location -LiteralPath (& $script:qualify $script:plainWork)
        try { $scan = Get-PSCxScan -Path @('.') -ChangedFile @('flat.ps1') }
        finally { Pop-Location }
        (@($scan.Units | ForEach-Object Unit | Sort-Object -Unique) -join '|') | Should-Be '<script-body>|Get-Flat'
    }
}

Describe 'Get-PSCxMetricVersion' {
    It 'reports the version this build measures with' {
        # Read through the function rather than the variable, because no other file may reach
        # into this one's module state -- tests/Layering.Tests.ps1 asserts exactly that.
        # Moved to 2 with 0.6.0, when the .ForEach() and .Where() methods started to score (#159).
        Get-PSCxMetricVersion | Should-Be 2
    }
}

Describe 'Get-PSCxChangedSet' {
    # Both sides of the filter have to be spelled the same way or it matches nothing and the run
    # reports a confident pass over zero units. A list arrives from git as repo-relative with
    # forward slashes; a record's File comes from Get-PSCxRelativePath.

    It 'treats every spelling of one path as the same entry' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $set = Get-PSCxChangedSet -PathComparison $script:PathCmp -Root $root -ChangedFile @(
            'src/A.ps1', './src/A.ps1', (Join-Path $root (Join-Path 'src' 'A.ps1')))
        $set.Count | Should-Be 1
        $set.Contains('src/A.ps1') | Should-BeTrue
    }

    It 'matches case by the run path comparison, both ways (#151)' {
        # On Linux a list naming SRC/A.PS1 names a different file from src/a.ps1.
        $root = [System.IO.Path]::GetFullPath('/repo')
        $exact = Get-PSCxChangedSet -PathComparison Ordinal -Root $root -ChangedFile @('SRC/A.PS1')
        $exact.Contains('src/a.ps1') | Should-BeFalse
        $exact.Contains('SRC/A.PS1') | Should-BeTrue
        (Get-PSCxChangedSet -PathComparison OrdinalIgnoreCase -Root $root -ChangedFile @('SRC/A.PS1')).Contains('src/a.ps1') |
            Should-BeTrue
    }

    It 'ignores blank entries, which a diff can emit as a trailing line' {
        $set = Get-PSCxChangedSet -PathComparison $script:PathCmp -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @('src/A.ps1', '', '   ')
        $set.Count | Should-Be 1
    }

    It 'trims surrounding whitespace' {
        $set = Get-PSCxChangedSet -PathComparison $script:PathCmp -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @("  src/A.ps1`t")
        $set.Contains('src/A.ps1') | Should-BeTrue
    }

    It 'returns an empty SET, not a null, for a list of nothing but blanks' {
        # A HashSet is enumerable, so returning an empty one unrolls it to nothing and the caller
        # gets $null -- which then fails to bind several frames from the return that caused it.
        $set = Get-PSCxChangedSet -PathComparison $script:PathCmp -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @('')
        ($null -ne $set) | Should-BeTrue
        $set.Count | Should-Be 0
    }
}

Describe 'Assert-PSCxChangedFile' {
    # From the fixture directory, as a gate runs from the repository root: the list is resolved
    # against the current directory, which is the whole of #160.
    BeforeEach { Push-Location $script:work }
    AfterEach { Pop-Location }

    It 'accepts a list naming files that are there, however each is spelled' {
        # Trimmed, backslashed, and a non-PowerShell entry that is NOT there -- a deleted README
        # changes no answer, so only .ps1 and .psm1 entries are checked. And a blank line.
        Assert-PSCxChangedFile -ChangedFile @(' flat.ps1 ', 'nested\deep.ps1', 'mod.psm1', 'gone.md', '')
        # No exception is the assertion; Pester fails the test on one. Paired with the refusals
        # below, which is what stops a guard that refuses everything passing this file.
        $true | Should-BeTrue
    }

    It 'refuses a listed <Name> that is not there, naming it and the likely cause (#160)' -ForEach @(
        @{ Name = '.ps1'; File = 'gone.ps1' }
        @{ Name = '.psm1'; File = 'gone.psm1' }
        @{ Name = 'extension in another case'; File = 'gone.PS1' }
    ) {
        # Only the missing entry is named, not the one that is there beside it.
        { Assert-PSCxChangedFile -ChangedFile @('flat.ps1', $File) } |
            Should-Throw -ExceptionMessage "*names 1 PowerShell file(s) that do not exist from '*': $File. The list is resolved against the current directory*run from the root*--diff-filter=d*"
    }

    It 'refuses a list resolved from the wrong directory -- the case behind #160' {
        # git prints nested/deep.ps1 relative to the root. From inside nested/ that names nothing,
        # and the run used to measure 0 units and pass.
        Push-Location (Join-Path $script:work 'nested')
        try {
            { Assert-PSCxChangedFile -ChangedFile @('nested/deep.ps1') } |
                Should-Throw -ExceptionMessage '*that do not exist from*nested*: nested/deep.ps1.*'
        }
        finally { Pop-Location }
    }

    It 'refuses a listed directory that merely ends in .ps1' {
        # A directory cannot be the changed FILE the entry claims; measured as a path it would be
        # walked for its contents instead.
        New-Item -ItemType Directory -Path (Join-Path $script:work 'dir.ps1') -Force | Out-Null
        { Assert-PSCxChangedFile -ChangedFile @('dir.ps1') } | Should-Throw -ExceptionMessage '*: dir.ps1.*'
    }

    It 'refuses an empty list' {
        # An empty list restricts the run to nothing and reports a pass over zero units -- and it
        # is what a diff command prints when it fails, matches nothing, or runs against a shallow
        # clone whose base ref is missing.
        { Assert-PSCxChangedFile -ChangedFile @() } |
            Should-Throw -ExceptionMessage '*skip the gate rather than asking it to measure an empty set*'
    }

    It 'refuses a list of nothing but blanks' {
        # `git diff --name-only` piped through PowerShell can yield an empty trailing line, so a
        # "non-empty" list is not the same as a list naming a file.
        { Assert-PSCxChangedFile -ChangedFile @('', '   ') } |
            Should-Throw -ExceptionMessage '*empty set*'
    }
}

Describe 'Get-PSCxSubsetNotice' {
    It 'says nothing about a whole-tree run' {
        Get-PSCxSubsetNotice -Scan (Get-PSCxScan -Path @($script:flat)) | Should-BeNull
    }

    It 'names the counts for a diff-scoped run' {
        # A filtered pass reported as a whole-tree pass reads as a stronger claim than it is, and
        # the gate prints nothing at all when it passes.
        $scan = Get-PSCxScan -Path @($script:work) -Recurse -ChangedFile @($script:flat)
        $notice = Get-PSCxSubsetNotice -Scan $scan
        $notice | Should-BeLikeString '*not the whole tree*'
        $notice | Should-BeLikeString '*1 changed file(s)*'
    }
}

Describe 'Get-PSCxScan -ChangedFile' {
    It 'measures only the units in the files named' {
        $scan = Get-PSCxScan -Path @($script:work) -Recurse -ChangedFile @($script:flat)
        @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Flat'
        @($scan.Units | ForEach-Object Unit) | Should-NotContainCollection 'Get-Deep'
    }

    It 'measures everything when the parameter is omitted' {
        # The kept half. Without it a filter that excluded everything would pass the case above.
        $scan = Get-PSCxScan -Path @($script:work) -Recurse
        @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Deep'
    }

    It 'records the filter in Scope as an ARRAY, even for one file' {
        # A $( ) subexpression unrolls a one-element array to the element, so a run filtered to a
        # single file recorded a bare string where every consumer expects a list -- and the report
        # then serialised it as one, which the published schema rejects.
        $scan = Get-PSCxScan -Path @($script:work) -Recurse -ChangedFile @($script:flat)
        $scan.Scope.ChangedFile -is [array] | Should-BeTrue
        @($scan.Scope.ChangedFile).Count | Should-Be 1
    }

    It 'records NULL, not an empty list, for a whole-tree run' {
        # Absent and empty are different answers: only one of them may be read as a measurement
        # of everything under Path.
        (Get-PSCxScan -Path @($script:flat)).Scope.ChangedFile | Should-BeNull
    }

    It 'measures nothing when the changed files hold no source' {
        # An ordinary outcome -- a pull request that touches only markdown -- and not an error.
        # What makes it safe is that Scope still says a filter was applied.
        $scan = Get-PSCxScan -Path @($script:work) -Recurse -ChangedFile @('notes.txt')
        @($scan.Units).Count | Should-Be 0
        $scan.Scope.ChangedFile | Should-NotBeNull
    }
}

Describe 'Get-PSCxEmptyScanFault' {
    # "No unit breached a ceiling" and "no unit was measured" are the same $true, so a gate
    # pointed at the wrong place reports clean. Tested HERE and not only through the gate:
    # Scan.ps1's covering suite is this file, so a test in the other one covers these lines
    # without being able to kill their mutants.

    It 'says nothing when units were measured' {
        Get-PSCxEmptyScanFault -UnitCount 3 -Filtered $false -Path @('./src') -Recurse $true |
            Should-BeNull
    }

    It 'refuses a whole-tree run that measured nothing, naming the paths' {
        Get-PSCxEmptyScanFault -UnitCount 0 -Filtered $false -Path @('./a', './b') -Recurse $true |
            Should-BeLikeString '*./a, ./b*describe an empty set*'
    }

    It 'allows a DIFF-SCOPED run that measured nothing' {
        # An ordinary pull request touching only markdown. Refusing it would fail every such
        # build, and the subset notice is what keeps the pass honest instead.
        Get-PSCxEmptyScanFault -UnitCount 0 -Filtered $true -Path @('./src') -Recurse $true |
            Should-BeNull
    }

    It 'suggests -Recurse only when it was not given' {
        # Both halves: the hint is useless noise on a run that already recursed, and the missing
        # switch is the most common reason a flat scan finds nothing.
        Get-PSCxEmptyScanFault -UnitCount 0 -Filtered $false -Path @('./src') -Recurse $false |
            Should-BeLikeString '*add -Recurse*'
        Get-PSCxEmptyScanFault -UnitCount 0 -Filtered $false -Path @('./src') -Recurse $true |
            Should-NotBeLikeString '*add -Recurse*'
    }

    It 'is the COUNT that matters, not merely being filtered' {
        # The guard is `UnitCount -gt 0 -or Filtered`. A filtered run that DID measure something
        # is fine for both reasons, so it cannot tell the two halves apart -- these two can.
        Get-PSCxEmptyScanFault -UnitCount 1 -Filtered $false -Path @('./src') -Recurse $true |
            Should-BeNull
        Get-PSCxEmptyScanFault -UnitCount 0 -Filtered $false -Path @('./src') -Recurse $true |
            Should-NotBeNull
    }
}

Describe 'Get-PSCxUnmatchedPath' {
    # A path that produced no source file is a FACT the scan carries, not a stray Get-ChildItem
    # error. It used to be neither: the error was attributed to Get-ChildItem, named this module's
    # own source line, and did not reach the caller's -ErrorVariable -- so all a consumer saw was
    # zero units.

    It 'says a path is not there when it is not there' {
        $r = Get-PSCxUnmatchedPath -Path (Join-Path $script:work 'no-such-directory')
        $r.Reason | Should-Be 'no such path'
        $r.Exists | Should-BeFalse
    }

    It 'says a real directory holds no PowerShell, which is a different mistake' {
        # Two situations, told apart because they send the reader to different places: a typo, or
        # a missing -Recurse. Collapsing them makes the commonest gate misconfiguration
        # indistinguishable from the second commonest.
        $empty = Join-Path $script:work 'nosource'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $empty 'readme.md') -Value '# not powershell' -Encoding utf8
        $r = Get-PSCxUnmatchedPath -Path $empty
        $r.Reason | Should-Be 'holds no .ps1 or .psm1 file'
        $r.Exists | Should-BeTrue
    }

    It 'sees a directory whose name contains a wildcard character' {
        # -Path glob-parses '[', so only the LiteralPath spelling finds 'my[1]proj'. Reported as
        # "no such path" it would send somebody looking for a directory that is plainly there.
        $lit = Join-Path $script:work 'my[1]proj'
        [System.IO.Directory]::CreateDirectory($lit) | Out-Null
        (Get-PSCxUnmatchedPath -Path $lit).Exists | Should-BeTrue
    }

    It 'reports the path it was given, not a resolved one' {
        # The message has to name what the CALLER typed. A resolved path they never wrote is a
        # worse answer to "which of my arguments was wrong".
        (Get-PSCxUnmatchedPath -Path './definitely-not-here').Path | Should-Be './definitely-not-here'
    }
}

Describe 'Get-PSCxSourceFile, for a path that resolves to nothing' {
    It 'returns an empty list rather than letting Get-ChildItem raise' {
        # The old form handed a non-existent path to Get-ChildItem, which wrote a PathNotFound
        # error naming this module's own source line. Returning empty is what lets the walk record
        # the fact instead.
        #
        # The COUNT alone cannot see the difference: Get-ChildItem over a missing path also
        # returns nothing, so an empty result is true either way and the guard survived every
        # mutant. Silence on the error stream is the observable half, and the only half that says
        # the guard fired rather than the command failing quietly behind it.
        #
        # REDIRECTED with 2>&1, not captured with -ErrorVariable, and that distinction is the
        # whole bug in miniature: -ErrorVariable on this function does NOT see an error raised by
        # a cmdlet it calls -- the record is attributed to Get-ChildItem and reaches only $Error.
        # An assertion written with -ErrorVariable passes under the mutant, which is exactly how
        # a consumer saw nothing but zero units.
        $records = @(Get-PSCxSourceFile -Path (Join-Path $script:work 'no-such-directory') 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count |
            Should-Be 0
        # Everything else is the function's own result, which is ONE value: an empty array. Asserted
        # as an array, because $null.Count is 0 too and a count could not tell the two apart.
        $result = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $result.Count | Should-Be 1
        $result[0] -is [array] | Should-BeTrue
        $result[0].Count | Should-Be 0
    }

    It 'still finds files under a path that IS there' {
        # The other half, in the same file. A test that only pins the absence would pass just as
        # well if discovery had stopped working altogether.
        (Get-PSCxSourceFile -Path $script:work -Recurse).Count | Should-BeGreaterThan 0
    }
}

Describe 'Get-PSCxSourceFile returns an array, whatever it found' {
    BeforeAll {
        $script:arr = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-arr-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:arr 'empty') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:arr 'one') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:arr 'one/a.ps1') -Value '1'
    }
    AfterAll { Remove-Item -LiteralPath $script:arr -Recurse -Force -ErrorAction SilentlyContinue }

    # -is [array], never .Count: $null.Count is 0 and a scalar string answers .Count with 1, so a
    # count passes for every one of the wrong answers this guards against.
    It 'is an empty array for a directory holding no PowerShell' {
        $r = Get-PSCxSourceFile -Path (Join-Path $script:arr 'empty')
        $r -is [array] | Should-BeTrue
        $r.Count | Should-Be 0
    }

    It 'is an empty array for a path that is not there' {
        $r = Get-PSCxSourceFile -Path (Join-Path $script:arr 'missing')
        $r -is [array] | Should-BeTrue
    }

    It 'is an array of one for a directory holding one file, and for the file itself' {
        foreach ($p in (Join-Path $script:arr 'one'), (Join-Path $script:arr 'one/a.ps1')) {
            $r = Get-PSCxSourceFile -Path $p
            $r -is [array] | Should-BeTrue -Because $p
            $r.Count | Should-Be 1
        }
    }
}

Describe 'Get-PSCxUnmatchedPathFault' {
    It 'is silent when every path matched something' {
        Get-PSCxUnmatchedPathFault -Unmatched @() | Should-BeNull
    }

    It 'names every unmatched path and why' {
        # THE hole this closes. Get-PSCxEmptyScanFault fires only when the run measured nothing,
        # so one valid path masked any number of mistyped ones -- measured, the gate returned
        # $true over a path that did not exist.
        $fault = Get-PSCxUnmatchedPathFault -Unmatched @(
            [pscustomobject]@{ Path = '/nope'; Reason = 'no such path'; Exists = $false }
            [pscustomobject]@{ Path = './docs'; Reason = 'holds no .ps1 or .psm1 file'; Exists = $true }
        )
        $fault | Should-BeLikeString '*/nope -- no such path*'
        $fault | Should-BeLikeString '*./docs -- holds no .ps1 or .psm1 file*'
        $fault | Should-BeLikeString '*2 of the path(s)*'
    }
}

Describe 'Write-PSCxUnmatchedPath' {
    It 'reports a path that is not there' {
        $err = @()
        Write-PSCxUnmatchedPath -Unmatched @(
            [pscustomobject]@{ Path = '/nope'; Reason = 'no such path'; Exists = $false }
        ) -ErrorVariable err -ErrorAction SilentlyContinue
        @($err).Count | Should-Be 1
        "$($err[0])" | Should-BeLikeString "*Measured nothing under '/nope' -- no such path*"
    }

    It 'stays silent for a real directory that holds no PowerShell' {
        # Measure-PSComplexity applies no thresholds and reaches no verdict, so an empty directory
        # is an outcome rather than a fault -- and under ErrorActionPreference = Stop an error here
        # would terminate a run over a directory the caller knows is empty. The GATE refuses it,
        # where a ceiling applied to nothing genuinely is a broken gate.
        $err = @()
        Write-PSCxUnmatchedPath -Unmatched @(
            [pscustomobject]@{ Path = './docs'; Reason = 'holds no .ps1 or .psm1 file'; Exists = $true }
        ) -ErrorVariable err -ErrorAction SilentlyContinue
        @($err).Count | Should-Be 0
    }
}

Describe 'Get-PSCxSkipReason' {
    It 'calls a file it could not read what it is' {
        # Parser::ParseFile reports an I/O failure through the SAME out-parameter as a syntax
        # error. Calling every one of them a parse error sent the reader to inspect syntax that
        # was perfectly correct -- and the gate then advised fixing it.
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:work 'no-such-file.ps1'), [ref]$null, [ref]$e)
        @($e)[0].ErrorId | Should-Be 'FileReadError'
        Get-PSCxSkipReason -ParseError @($e)[0] -Token @() | Should-BeLikeString 'could not be read: *'
    }

    It 'still calls a syntax error a parse error' {
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:broken 'bad.ps1'), [ref]$null, [ref]$e)
        Get-PSCxSkipReason -ParseError @($e)[0] -Token @() | Should-BeLikeString 'parse error: *'
    }

    It 'calls a workflow what it is, not a parse error (#161)' {
        # PowerShell 7 parses no workflow, on any OS. The source is fine; the host is not.
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput('workflow Test-Wf { 1 }', [ref]$null, [ref]$e)
        Get-PSCxSkipReason -ParseError @($e)[0] -Token @() |
            Should-BeLikeString 'a workflow, which PowerShell 7 cannot parse: Workflow is not supported*'
    }

    It 'calls a DSC Configuration the host cannot load what it is, keeping one line (#161)' {
        # Constructed rather than parsed, so it reads the same on every OS: Windows parses the
        # Configuration, and the failure only exists where the DSC schema store is missing.
        # The real message is the .NET exception and its stack trace; only the first line stays.
        $t = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput('Configuration MyConfig { }', [ref]$t, [ref]$null)
        $err = [System.Management.Automation.Language.ParseError]::new($t[1].Extent, 'ParserError',
            "System.IO.DirectoryNotFoundException: Unable to find DSC schema store.`n   at Somewhere()`n   at Elsewhere()")
        Get-PSCxSkipReason -ParseError $err -Token $t |
            Should-Be 'a DSC Configuration, which this host cannot parse without the DSC schema store: System.IO.DirectoryNotFoundException: Unable to find DSC schema store.'
    }

    It 'keeps only the first line of any message, whatever its line ending' {
        $t = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput('1', [ref]$t, [ref]$null)
        $crlf = [System.Management.Automation.Language.ParseError]::new($t[0].Extent, 'Other', "first`r`nsecond")
        $lf = [System.Management.Automation.Language.ParseError]::new($t[0].Extent, 'Other', "first`nsecond")
        Get-PSCxSkipReason -ParseError $crlf -Token $t | Should-Be 'parse error: first'
        Get-PSCxSkipReason -ParseError $lf -Token $t | Should-Be 'parse error: first'
    }
}

Describe 'Test-PSCxDscSchemaFault' {
    # By position: the DSC load failure sits on the configuration's NAME, the token straight
    # after the keyword, and has only the generic ErrorId.
    BeforeAll {
        $script:dscTokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput(
            "Configuration MyConfig {`n  1 +`n}", [ref]$script:dscTokens, [ref]$null)
        function script:Fault { param($Extent, [string]$Id = 'ParserError')
            return [System.Management.Automation.Language.ParseError]::new($Extent, $Id, 'm')
        }
    }

    It 'is true for a ParserError on the name after the Configuration keyword' {
        Test-PSCxDscSchemaFault -ParseError (Fault $script:dscTokens[1].Extent) -Token $script:dscTokens | Should-BeTrue
    }

    It 'is false for another ErrorId at the same place' {
        Test-PSCxDscSchemaFault -ParseError (Fault $script:dscTokens[1].Extent 'UnexpectedToken') -Token $script:dscTokens | Should-BeFalse
    }

    It 'is false for a ParserError anywhere else in the configuration' {
        # A genuine syntax error inside a Configuration is still a syntax error. On the keyword
        # itself, and on a token later in the body.
        Test-PSCxDscSchemaFault -ParseError (Fault $script:dscTokens[0].Extent) -Token $script:dscTokens | Should-BeFalse
        Test-PSCxDscSchemaFault -ParseError (Fault $script:dscTokens[2].Extent) -Token $script:dscTokens | Should-BeFalse
    }

    It 'is false when the token before is not the Configuration keyword' {
        $t = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput('function MyConfig { }', [ref]$t, [ref]$null)
        Test-PSCxDscSchemaFault -ParseError (Fault $t[1].Extent) -Token $t | Should-BeFalse
    }

    It 'is false with no tokens' {
        Test-PSCxDscSchemaFault -ParseError (Fault $script:dscTokens[1].Extent) -Token @() | Should-BeFalse
    }
}

Describe 'a host-dependent file, end to end (#161)' {
    It 'either measures a DSC Configuration or names why it could not' {
        # Windows parses one; Linux without the DSC schema store cannot. Both are right, and the
        # one thing that must not happen is a skip described as a syntax error.
        $f = Join-Path $script:work 'dsc-161.ps1'
        Set-Content $f "Configuration MyConfig {`n    Node 'localhost' { }`n}`nfunction Get-Ok { 1 }" -Encoding utf8
        try {
            $scan = Get-PSCxScan -Path @($f)
            if ($scan.Skipped.Count -gt 0) {
                $scan.Skipped[0].Reason | Should-BeLikeString 'a DSC Configuration, which this host cannot parse without the DSC schema store: *'
                $scan.Skipped[0].Reason | Should-NotBeLikeString "*`n*"
            }
            else { @($scan.Units | ForEach-Object Unit) | Should-ContainCollection 'Get-Ok' }
        }
        finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the scan records what it could not read' {
    It 'carries the unmatched paths beside the units' {
        $scan = Get-PSCxScan -Path @($script:work, (Join-Path $script:work 'no-such-directory')) -Recurse
        @($scan.Units).Count | Should-BeGreaterThan 0
        @($scan.Unmatched).Count | Should-Be 1
        $scan.Unmatched[0].Reason | Should-Be 'no such path'
    }

    It 'records nothing when every path matched' {
        @((Get-PSCxScan -Path $script:work -Recurse).Unmatched).Count | Should-Be 0
    }

    It 'records the path BEFORE the changed-file filter is applied' {
        # "This path is not there" and "nothing in this path changed" are different answers, and
        # only the first is a mistake. Filtered after, a diff-scoped run would report every path
        # it filtered away as missing.
        $scan = Get-PSCxScan -Path $script:work -Recurse -ChangedFile @('no-such-file.ps1')
        @($scan.Unmatched).Count | Should-Be 0
        @($scan.Units).Count | Should-Be 0
    }
}

Describe 'Get-PSCxScanFault' {
    # The ORDER of the two scan-level refusals, held as a decision rather than inferred from
    # statement order in the gate. Reversed, the count rule could never fire -- and a rule that
    # cannot fire looks exactly like a rule that keeps passing.

    function script:FakeScan { param($Units, $Unmatched)
        return [pscustomobject]@{ Units = @($Units); Unmatched = @($Unmatched) }
    }

    It 'is silent for a run that measured something and found every path' {
        Get-PSCxScanFault -Scan (FakeScan @('u') @()) -Path @('./src') -Filtered $false -Recurse |
            Should-BeNull
    }

    It 'answers a run that measured NOTHING with the count rule, which carries the -Recurse hint' {
        $fault = Get-PSCxScanFault -Scan (FakeScan @() @(
                [pscustomobject]@{ Path = '/nope'; Reason = 'no such path'; Exists = $false })) `
            -Path @('/nope') -Filtered $false
        $fault | Should-BeLikeString '*Measured no units under*'
        $fault | Should-BeLikeString '*add -Recurse*'
    }

    It 'answers a run that measured SOMETHING but missed a path with the path rule' {
        # The hole this closes. A unit count cannot see a mistyped path next to a good one.
        Get-PSCxScanFault -Scan (FakeScan @('u') @(
                [pscustomobject]@{ Path = '/nope'; Reason = 'no such path'; Exists = $false })) `
            -Path @('./src', '/nope') -Filtered $false -Recurse |
            Should-BeLikeString '*could not read*'
    }

    It 'still refuses a missed path on a DIFF-SCOPED run, where the count rule stands down' {
        # A filtered run that measured nothing is ordinary -- a pull request touching only
        # markdown -- so the count rule is silent. A path that is not there is a mistake either
        # way, and must not become invisible just because -ChangedFile was given.
        Get-PSCxScanFault -Scan (FakeScan @() @(
                [pscustomobject]@{ Path = '/nope'; Reason = 'no such path'; Exists = $false })) `
            -Path @('/nope') -Filtered $true -Recurse |
            Should-BeLikeString '*could not read*'
    }
}

Describe 'case sensitivity, read from the file system rather than the platform (#151)' {
    # Each CI leg can only build what its own file system allows: a pair of names differing only
    # in case exists on Linux, never on NTFS without a flag CI cannot set. So the both-ways
    # questions are asked with the answer passed IN, and the file-system answers are asserted
    # against the leg's own file system. The self-mutation gate runs on Linux, which is the leg
    # that can build a pair.
    BeforeAll {
        $script:caseRoot = Join-Path $script:work "fs-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:caseRoot -Force | Out-Null
        function script:NewDir([string[]]$Names) {
            $d = Join-Path $script:caseRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            foreach ($n in $Names) { Set-Content -LiteralPath (Join-Path $d $n) -Value "function Get-$([System.Guid]::NewGuid().ToString('N')) { 1 }" -Encoding utf8 }
            return $d
        }
        # The temp directory's own answer on this leg: case-sensitive on Linux's ext4, not on NTFS.
        $script:fsSensitive = [bool]$IsLinux
    }

    It 'compares exactly, or ignoring case, as asked' {
        Get-PSCxPathComparison -CaseSensitive $true | Should-Be ([System.StringComparison]::Ordinal)
        Get-PSCxPathComparison -CaseSensitive $false | Should-Be ([System.StringComparison]::OrdinalIgnoreCase)
    }

    It 'finds an entry only by its exact spelling' {
        $d = NewDir @('Probe.ps1')
        Test-PSCxExactEntry -Directory $d -Name 'Probe.ps1' | Should-BeTrue
        Test-PSCxExactEntry -Directory $d -Name 'PROBE.PS1' | Should-BeFalse
    }

    It 'resolves a file and a directory alike' {
        $d = NewDir @('probe.ps1')
        Test-PSCxEntryExist -Path (Join-Path $d 'probe.ps1') | Should-BeTrue
        Test-PSCxEntryExist -Path $d | Should-BeTrue
        Test-PSCxEntryExist -Path (Join-Path $d 'absent') | Should-BeFalse
    }

    It 'calls a directory case-INSENSITIVE where a flipped name resolves to the same entry, on every leg' {
        # The Windows answer, MOCKED so the Linux leg runs it too: there a flipped name never
        # resolves unless it is an entry of its own, so this arm is otherwise unreachable where
        # the self-mutation gate runs.
        Mock Test-PSCxEntryExist { $true }
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('probe.ps1')) | Should-BeFalse
    }

    It 'cannot tell from a directory with nothing in it, or nothing with a letter' {
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @()) | Should-BeNull
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('123')) | Should-BeNull
    }

    It 'reads the file system from a lower-case name and from an upper-case one' {
        # Both, because each takes a different arm of the flip.
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('probe.ps1')) | Should-Be $script:fsSensitive
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('PROBE')) | Should-Be $script:fsSensitive
    }

    It 'passes over a name with no letter to the next one' {
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('123', 'probe.ps1')) | Should-Be $script:fsSensitive
    }

    It 'calls a directory holding both spellings case-sensitive' -Skip:(-not $IsLinux) {
        # The flipped name RESOLVES here, which on its own reads as case-insensitive. Only the
        # exact-entry check tells a directory holding two spellings from one holding one.
        Test-PSCxCaseSensitiveDirectory -Path (NewDir @('Twin', 'TWIN')) | Should-BeTrue
    }

    It 'takes the run answer from the directory, and the fallback only when it cannot say' {
        $empty = NewDir @()
        Get-PSCxRunPathComparison -Root $empty -Fallback $true | Should-Be ([System.StringComparison]::Ordinal)
        Get-PSCxRunPathComparison -Root $empty -Fallback $false | Should-Be ([System.StringComparison]::OrdinalIgnoreCase)
        # The opposite fallback, so a probe that was ignored would show.
        $expected = Get-PSCxPathComparison -CaseSensitive $script:fsSensitive
        Get-PSCxRunPathComparison -Root (NewDir @('probe.ps1')) -Fallback (-not $script:fsSensitive) | Should-Be $expected
    }

    It 'calls two spellings one file when only one of them is an entry' {
        $d = NewDir @('flat.ps1')
        Test-PSCxSameEntry -Path (Join-Path $d 'flat.ps1') -Other (Join-Path $d 'flat.ps1') | Should-BeTrue
        Test-PSCxSameEntry -Path (Join-Path $d 'flat.ps1') -Other (Join-Path $d 'FLAT.PS1') | Should-BeTrue
    }

    It 'calls them two files when a directory holds both spellings, at any depth' -Skip:(-not $IsLinux) {
        $d = NewDir @('A.ps1', 'a.ps1')
        Test-PSCxSameEntry -Path (Join-Path $d 'A.ps1') -Other (Join-Path $d 'a.ps1') | Should-BeFalse
        # The difference in a DIRECTORY name, with the file names alike.
        foreach ($sub in 'Sub', 'sub') { New-Item -ItemType Directory -Path (Join-Path $d $sub) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path (Join-Path $d $sub) 'x.ps1') -Value '1' -Encoding utf8 }
        Test-PSCxSameEntry -Path (Join-Path (Join-Path $d 'Sub') 'x.ps1') -Other (Join-Path (Join-Path $d 'sub') 'x.ps1') |
            Should-BeFalse
    }

    It 'calls two spellings two files when the directory holds both, on every leg' {
        # The file system's answer MOCKED, so the Windows leg -- which cannot create the pair --
        # still runs this arm and keeps coverage at 100% there. The Linux-only test above asks the
        # real file system the same question.
        Mock Test-PSCxExactEntry { $true }
        $d = NewDir @('flat.ps1')
        Test-PSCxSameEntry -Path (Join-Path $d 'flat.ps1') -Other (Join-Path $d 'FLAT.PS1') | Should-BeFalse
    }

    It 'turns a case twin into a skip naming the file it collides with, on every leg' {
        Mock Test-PSCxSameEntry { $false }
        $d = NewDir @('flat.ps1')
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$seen.Add((Join-Path $d 'flat.ps1'))
        Push-Location -LiteralPath $d
        try {
            $skip = Get-PSCxCaseTwinScan -File (Join-Path $d 'FLAT.PS1') -Seen $seen -PathComparison OrdinalIgnoreCase
        }
        finally { Pop-Location }
        $skip.File | Should-BeString 'FLAT.PS1' -CaseSensitive
        @($skip.Units).Count | Should-Be 0
        $skip.SkipReason | Should-BeLikeString 'differs only in case from flat.ps1.*Rename one*' -CaseSensitive
    }

    It 'says nothing about another spelling of a file already measured' {
        # FLAT.PS1 is not an entry; it is flat.ps1 reached by a case-insensitive lookup. One
        # file, so no skip -- the case a twin check that skipped every different spelling gets
        # wrong.
        $d = NewDir @('flat.ps1')
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$seen.Add((Join-Path $d 'flat.ps1'))
        Get-PSCxCaseTwinScan -File (Join-Path $d 'FLAT.PS1') -Seen $seen -PathComparison OrdinalIgnoreCase | Should-BeNull
    }

    It 'says nothing about a path already measured under the same spelling' {
        $d = NewDir @('flat.ps1')
        $file = Join-Path $d 'flat.ps1'
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$seen.Add($file)
        Get-PSCxCaseTwinScan -File $file -Seen $seen -PathComparison OrdinalIgnoreCase | Should-BeNull
    }

    It 'skips a case twin in a run that ignores case, naming the file it collides with' -Skip:(-not $IsLinux) {
        # A case-sensitive folder inside a case-insensitive run: built on Linux by handing the
        # walk an ignore-case set, which is what such a run hands it.
        $d = NewDir @('A.ps1', 'a.ps1')
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Push-Location -LiteralPath $d
        try {
            $scans = @(Get-PSCxPathScan -Path @('.') -Seen $seen -Unmatched ([System.Collections.Generic.List[object]]::new()) `
                    -PathComparison OrdinalIgnoreCase)
        }
        finally { Pop-Location }
        $scans.Count | Should-Be 2
        $skips = @($scans | Where-Object SkipReason)
        $skips.Count | Should-Be 1
        $other = @('A.ps1', 'a.ps1') | Where-Object { $_ -cne $skips[0].File }
        $skips[0].SkipReason | Should-BeLikeString "differs only in case from $other.*Rename one*" -CaseSensitive
    }
}
