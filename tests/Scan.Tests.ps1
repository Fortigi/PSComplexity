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

    # And the same for the unmatched-path list, which the caller owns for the same reason: paths
    # arrive one invocation at a time, so a list created inside the walk would forget the last one.
    # Comma-wrapped for the reason above -- an empty List unrolls to nothing on the way out.
    function script:NewUnmatched { return , [System.Collections.Generic.List[object]]::new() }
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
        Get-PSCxRelativePath -Path $file -Root $root | Should-Be 'a/b/C.ps1'
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
        $scans = @(Get-PSCxPathScan -Path $script:work -Seen (NewSeen) -Unmatched (NewUnmatched) -Recurse)
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
        $scans = @(Get-PSCxPathScan -Path $mixed -Seen (NewSeen) -Unmatched (NewUnmatched))
        $scans.Count | Should-Be 2
        @($scans | Where-Object { $_.SkipReason }).Count | Should-Be 1
        @($scans | ForEach-Object { $_.Units } | ForEach-Object Unit) | Should-ContainCollection 'Get-Ok'
    }

    It 'measures a file once when two paths both reach it' {
        # The seen-set is the whole reason this takes one: gate ./src and ./src/A.ps1 together and
        # the file would otherwise be measured twice and counted twice in any per-file total.
        $seen = NewSeen
        $scans = @(Get-PSCxPathScan -Path @($script:flat, $script:flat) -Seen $seen -Unmatched (NewUnmatched))
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

Describe 'Get-PSCxChangedSet' {
    # Both sides of the filter have to be spelled the same way or it matches nothing and the run
    # reports a confident pass over zero units. A list arrives from git as repo-relative with
    # forward slashes; a record's File comes from Get-PSCxRelativePath.

    It 'treats every spelling of one path as the same entry' {
        $root = [System.IO.Path]::GetFullPath('/repo')
        $set = Get-PSCxChangedSet -Root $root -ChangedFile @(
            'src/A.ps1', './src/A.ps1', (Join-Path $root (Join-Path 'src' 'A.ps1')))
        $set.Count | Should-Be 1
        $set.Contains('src/A.ps1') | Should-BeTrue
    }

    It 'matches case-insensitively' {
        $set = Get-PSCxChangedSet -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @('SRC/A.PS1')
        $set.Contains('src/a.ps1') | Should-BeTrue
    }

    It 'ignores blank entries, which a diff can emit as a trailing line' {
        $set = Get-PSCxChangedSet -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @('src/A.ps1', '', '   ')
        $set.Count | Should-Be 1
    }

    It 'trims surrounding whitespace' {
        $set = Get-PSCxChangedSet -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @("  src/A.ps1`t")
        $set.Contains('src/A.ps1') | Should-BeTrue
    }

    It 'returns an empty SET, not a null, for a list of nothing but blanks' {
        # A HashSet is enumerable, so returning an empty one unrolls it to nothing and the caller
        # gets $null -- which then fails to bind several frames from the return that caused it.
        $set = Get-PSCxChangedSet -Root ([System.IO.Path]::GetFullPath('/repo')) -ChangedFile @('')
        ($null -ne $set) | Should-BeTrue
        $set.Count | Should-Be 0
    }
}

Describe 'Assert-PSCxChangedFile' {
    It 'accepts a list naming at least one file' {
        Assert-PSCxChangedFile -ChangedFile @('src/A.ps1')
        # No exception is the assertion; Pester fails the test on one. Paired with the refusals
        # below, which is what stops a guard that refuses everything passing this file.
        $true | Should-BeTrue
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
        @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }).Count |
            Should-Be 0
    }

    It 'still finds files under a path that IS there' {
        # The other half, in the same file. A test that only pins the absence would pass just as
        # well if discovery had stopped working altogether.
        @(Get-PSCxSourceFile -Path $script:work -Recurse).Count | Should-BeGreaterThan 0
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
        Get-PSCxSkipReason -ParseError @($e)[0] | Should-BeLikeString 'could not be read: *'
    }

    It 'still calls a syntax error a parse error' {
        $e = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:broken 'bad.ps1'), [ref]$null, [ref]$e)
        Get-PSCxSkipReason -ParseError @($e)[0] | Should-BeLikeString 'parse error: *'
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
