# End-to-end tests for the public API: file/directory resolution, per-unit records,
# the <script-body> unit, parse-error handling, and the Test-PSComplexity gate.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    foreach ($f in 'Ast.ps1', 'Cyclomatic.ps1', 'Cognitive.ps1', 'Measure-PSComplexity.ps1', 'Report.ps1') { . (Join-Path $src $f) }

    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) "cxmeasure-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path (Join-Path $script:work 'nested') -Force | Out-Null
    Set-Content (Join-Path $script:work 'a.ps1') "function Get-A { param(`$x) if (`$x) { 1 } }`n`$top = 1" -Encoding utf8
    Set-Content (Join-Path $script:work 'nested/b.ps1') "function Get-B { param(`$y) foreach (`$i in `$y) { if (`$i) { 1 } } }" -Encoding utf8
    # Unparseable fixtures live APART from the clean ones, and outside any path the other
    # tests walk. Kept in the shared root they made every measurement emit an error that
    # most tests did not care about, and the only way to keep those readable was to silence
    # them one by one -- which is how an unexpected error becomes invisible.
    $script:broken = Join-Path ([System.IO.Path]::GetTempPath()) "cxbroken-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:broken -Force | Out-Null
    Set-Content (Join-Path $script:broken 'broken.ps1') "function Oops { param(" -Encoding utf8
}

AfterAll {
    Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $script:broken -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'the record shape a consumer depends on' {
    # This object IS the public API, besides the two command names. Unpinned, it was still a
    # contract -- just one discoverable only by running the command, and unchangeable once
    # anyone had. Four queued features want to widen it (#2 baseline, #3 attribution,
    # #5 report, #7 changed-files), so widening has to fail here first and be a decision.

    It 'emits exactly these five fields, in this order' {
        $row = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1'))[0]
        # Joined rather than Should-BeCollection, which ignores order: property order is
        # what Format-Table shows a consumer, so a reordering is a visible change.
        ($row.PSObject.Properties.Name -join ',') | Should-Be 'File,Unit,Line,Cyclomatic,Cognitive,MetricVersion'
    }

    It 'emits those fields with the types a consumer sorts and compares on' {
        # Line being a string rather than an int is as breaking as a rename: it silently
        # turns a numeric sort into a lexical one, where 10 precedes 2.
        $row = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1'))[0]
        $row.File       | Should-HaveType ([string])
        $row.Unit       | Should-HaveType ([string])
        $row.Line       | Should-HaveType ([int])
        $row.Cyclomatic | Should-HaveType ([int])
        $row.Cognitive  | Should-HaveType ([int])
        $row.MetricVersion | Should-HaveType ([int])
    }

    It 'pins the shape for every record, not only the first' {
        # The kept half of the pair. Asserting the first record alone passes against a
        # command that emits a different shape for the <script-body> unit, or for the second
        # file in a directory walk -- which is exactly where a widening would land.
        $rows = @(Measure-PSComplexity -Path $script:work -Recurse)
        $rows.Count | Should-BeGreaterThan 2
        $shapes = @($rows | ForEach-Object { $_.PSObject.Properties.Name -join ',' } | Sort-Object -Unique)
        ($shapes -join ' | ') | Should-Be 'File,Unit,Line,Cyclomatic,Cognitive,MetricVersion'
    }
}

Describe 'two units on one line are two units' {
    # A unit was keyed by name-and-LINE, and a line is not unique. Two overloads written on
    # one physical line produced ONE key, so their scores were ADDED and the file reported a
    # single unit that exists nowhere in the source -- a wrong number, not just a wrong name.

    BeforeAll {
        $script:oneline = Join-Path $script:work 'overloads.ps1'
        Set-Content $script:oneline `
            'class Repo { [void] Add([int]$a) { if ($a) { } } [void] Add([string]$b) { if ($b) { } } }' -Encoding utf8
    }

    It 'emits one row per overload, each separately named' {
        $rows = @(Measure-PSComplexity -Path $script:oneline | Where-Object Unit -like 'Repo.Add*')
        $rows.Count | Should-Be 2
        # An ordinal on BOTH, not just the second: suffixing only the later one would
        # silently rename the first the day an overload is added.
        ($rows | ForEach-Object Unit | Sort-Object) -join ',' | Should-Be 'Repo.Add#1,Repo.Add#2'
    }

    It 'scores each overload on its own rather than summing them' {
        # The number is the point. Merged, this file reported cyclomatic 3 for a unit that
        # does not exist; each overload is 2. Asserting only the row COUNT would pass against
        # code that split the rows and still divided one total between them.
        $rows = @(Measure-PSComplexity -Path $script:oneline | Where-Object Unit -like 'Repo.Add*')
        ($rows | ForEach-Object Cyclomatic | Sort-Object) -join ',' | Should-Be '2,2'
        ($rows | ForEach-Object Cognitive  | Sort-Object) -join ',' | Should-Be '1,1'
    }

    It 'still merges nothing that was never separate' {
        # The kept half: a file whose units are on distinct lines must be unaffected, or the
        # test above passes against code that splits every unit into duplicates.
        $rows = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1'))
        ($rows | ForEach-Object Unit | Sort-Object) -join ',' | Should-Be '<script-body>,Get-A'
    }
}

Describe 'a unit name a second machine can match' {
    # Neither published field used to be both unique-within-file and stable-across-machines.
    # Anything comparing two runs -- a committed baseline, a per-file report, a changed-files
    # scan -- needs one that is.

    BeforeAll {
        $script:nested = Join-Path $script:work 'nestednames.ps1'
        Set-Content $script:nested @'
function Get-OuterA { function Get-Inner { if ($x) { 1 } } }
function Get-OuterB { function Get-Inner { if ($y) { 1 } if ($z) { 2 } } }
'@ -Encoding utf8
    }

    It 'qualifies a nested function by the unit that encloses it' {
        # Both used to read `Get-Inner`, and they score differently, so a baseline keyed on
        # the name merged two units and reported whichever it saw last.
        $rows = @(Measure-PSComplexity -Path $script:nested | Where-Object Unit -like '*Get-Inner')
        ($rows | ForEach-Object Unit | Sort-Object) -join ',' |
            Should-Be 'Get-OuterA/Get-Inner,Get-OuterB/Get-Inner'
    }

    It 'leaves an unnested function unqualified' {
        # The kept half: qualification must apply where there is something to qualify BY, or
        # every top-level function would grow a prefix nobody asked for.
        $rows = @(Measure-PSComplexity -Path $script:nested | Where-Object Unit -notlike '*/*' | Where-Object Unit -like 'Get-Outer*')
        ($rows | ForEach-Object Unit | Sort-Object) -join ',' | Should-Be 'Get-OuterA,Get-OuterB'
    }

    It 'reports a path relative to where the caller stands, with forward slashes' {
        # File was absolute and platform-separated, so the two CI legs produced disjoint key
        # sets for identical source. A backslash key cannot be matched by a Linux run at all.
        Push-Location $script:work
        try {
            $rows = @(Measure-PSComplexity -Path 'nested/b.ps1')
            $rows[0].File | Should-Be 'nested/b.ps1'
        }
        finally { Pop-Location }
    }

    It 'keeps a full path for a file outside the root' {
        # A ../../ chain is no more portable than the absolute path and says less about where
        # the file came from, so outside the root the full path is the honest answer.
        $outside = Join-Path ([System.IO.Path]::GetTempPath()) "cxout-$([System.Guid]::NewGuid().ToString('N')).ps1"
        Set-Content $outside 'function Get-X { 1 }' -Encoding utf8
        try {
            Push-Location $script:work
            try { $rows = @(Measure-PSComplexity -Path $outside) } finally { Pop-Location }
            $rows[0].File | Should-NotBeLikeString '*..*'
            $rows[0].File | Should-BeLikeString '*cxout-*'
            # Separators too. Without this the assertion passes whatever character the
            # normaliser replaces, so a full path could keep its backslashes and read as
            # portable while being unmatchable by a Linux run.
            $rows[0].File | Should-NotBeLikeString '*\*'
        }
        finally { Remove-Item $outside -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-PSCxRelativePath' {
    It 'resolves a relative path against Root, not against the working directory' {
        # The function only gave the right answer while its one caller happened to pass an
        # absolute path AND a Root equal to the CWD. Both had to hold; neither was stated. A
        # second caller passing a relative path would have got a path under wherever the shell
        # happened to be standing, which is a wrong answer that looks entirely plausible.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'some-repo'
        Push-Location ([System.IO.Path]::GetTempPath())
        try { Get-PSCxRelativePath -Path 'src/a.ps1' -Root $root | Should-Be 'src/a.ps1' }
        finally { Pop-Location }
    }

    It 'still takes an absolute path as it stands' {
        # The kept half: the production caller passes absolute paths, so a fix that only
        # handled the relative case would break the one path that actually runs.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'some-repo'
        Get-PSCxRelativePath -Path (Join-Path $root 'src/b.ps1') -Root $root | Should-Be 'src/b.ps1'
    }

    It 'strips a root that already ends with a separator' {
        # A root ending in a separator is not exotic -- a drive root and the temp directory
        # both do. Appending a second one unconditionally makes the prefix match fail, and the
        # path silently comes back absolute rather than relative.
        $root = [System.IO.Path]::GetTempPath()   # ends with a separator on both platforms
        $file = Join-Path $root 'rooted.ps1'
        Get-PSCxRelativePath -Path $file -Root $root | Should-Be 'rooted.ps1'
    }

    It 'strips a root that does not end with a separator' {
        # The kept half: both shapes must give the same answer, or the test above passes
        # against code that only ever handles one of them.
        $root = ([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $file = Join-Path $root 'rooted.ps1'
        Get-PSCxRelativePath -Path $file -Root $root | Should-Be 'rooted.ps1'
    }
}

Describe 'a function nested inside a class method' {
    It 'is qualified by the method, and the method is named once' {
        # The walk resolves a method body back to its member, so without the identity check
        # the same method is appended twice and the unit reads C.M/C.M/Inner.
        $f = Join-Path $script:work 'inclass.ps1'
        Set-Content $f 'class C { [void] M() { function Get-Inner { if ($x) { 1 } } } }' -Encoding utf8
        $rows = @(Measure-PSComplexity -Path $f | Where-Object Unit -like '*Get-Inner')
        $rows.Count | Should-Be 1
        $rows[0].Unit | Should-Be 'C.M/Get-Inner'
    }
}

Describe 'a score says which metric produced it' {
    # Two numbers are comparable only if the same metric produced them, and this one has moved
    # twice for unchanged source: 0.3.0 taught it PowerShell's flow constructs, 0.4.0 stopped
    # merging two units written on one line. Both were corrections; both silently re-scored code
    # nobody had touched. A committed baseline (#2) compares a stored score with a fresh one, so
    # without this it would absorb an upgrade as if it were a change in the code.

    It 'stamps every record with the metric version' {
        $rows = @(Measure-PSComplexity -Path $script:work -Recurse)
        $rows.Count | Should-BeGreaterThan 1
        # Every record, not the first: a stamp applied in one branch of the emitter and not
        # another is worse than none, because the gap is invisible.
        @($rows | Where-Object { $_.MetricVersion -ne 1 }).Count | Should-Be 0
    }

    It 'is an int, so a consumer can compare it rather than parse it' {
        (@(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1'))[0]).MetricVersion |
            Should-HaveType ([int])
    }
}

Describe 'a scan says what it is reading' {
    # A slow scan and a stuck one looked identical: no output at all until everything was
    # measured. That matters because analysis is O(nodes x depth), so one deeply nested file
    # can dominate a run -- and because Test-PSComplexity is the entry point people automate,
    # so it runs against whole repositories where nobody is watching a terminal.

    It 'names each file as it is read' {
        $lines = @(Measure-PSComplexity -Path $script:work -Recurse -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        ($lines -join "`n") | Should-MatchString 'a\.ps1'
        ($lines -join "`n") | Should-MatchString 'b\.ps1'
    }

    It 'names the file BEFORE measuring it, so a stuck scan points at the culprit' {
        # The ordering is the whole feature. Written afterwards, the last line names a file
        # that is already finished, and a scan stuck on the next one looks exactly like a scan
        # that completed. Asserted by counting: the first verbose line must arrive before the
        # first record does.
        $stream = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1') -Verbose 4>&1)
        $firstVerbose = [array]::FindIndex($stream, [Predicate[object]] { param($x) $x -is [System.Management.Automation.VerboseRecord] })
        $firstRecord = [array]::FindIndex($stream, [Predicate[object]] { param($x) $x -isnot [System.Management.Automation.VerboseRecord] })
        $firstVerbose | Should-BeLessThan $firstRecord
    }

    It 'says nothing when the caller did not ask' {
        # The kept half. A gate that chatters by default gets its output filtered, and the
        # filter takes the parse errors with it -- which are the one thing this command must
        # never lose.
        $lines = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1') 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $lines.Count | Should-Be 0
    }

    It 'reaches the gate, which is the command people automate' {
        # Test-PSComplexity calls Measure-PSComplexity, so -Verbose has to survive the nested
        # call for this to be worth anything to CI.
        $lines = @(Test-PSComplexity -Path $script:work -Recurse -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] })
        $lines.Count | Should-BeGreaterThan 0
    }
}

Describe 'the declared output types' {
    It 'declares what a caller actually receives, not an array of it' {
        # These commands STREAM individual records. [pscustomobject[]] claimed a single
        # return value that is a collection, which neither ever produces -- and OutputType
        # is what Get-Help and IntelliSense show, so it is documentation that no test could
        # previously contradict.
        ((Get-Command Measure-PSComplexity).OutputType.Name -join ',') |
            Should-Be 'System.Management.Automation.PSObject'
        ((Get-Command Test-PSComplexity).OutputType.Name -join ',') | Should-Be 'System.Boolean'
    }
}

Describe 'the shipped help' {
    It 'describes every kind of unit the module actually reports' {
        # The synopsis said "each function/filter, plus one <script-body>" for two releases
        # after class members became units. Nothing contradicted it, because help text is
        # prose and prose is checked by nobody. This asserts the claim against the vocabulary
        # the code actually produces.
        $h = (Get-Help Measure-PSComplexity).Synopsis -replace '\s+', ' '
        foreach ($kind in 'function', 'class method', 'constructor', 'property', '<script-body>') {
            $h | Should-BeLikeString "*$kind*" -Because "the synopsis omits $kind"
        }
    }

    It 'documents every parameter it accepts' {
        # Every parameter must carry SOME description. This does not police where the text
        # comes from: PowerShell synthesises a description from a comment sitting immediately
        # above a parameter as readily as from a .PARAMETER block, and -Detailed shipped
        # documented that way -- by an argument written for a maintainer rather than guidance
        # written for a caller, which is a different complaint and not one a test can make.
        #
        # What it does catch is a parameter with neither, where Get-Help shows a bare name.
        # Confirmed by adding one; an earlier version of this test asserted on parameter NAMES
        # and passed against exactly that.
        $common = @([System.Management.Automation.Cmdlet]::CommonParameters) +
                  @([System.Management.Automation.Cmdlet]::OptionalCommonParameters)
        foreach ($cmd in 'Measure-PSComplexity', 'Test-PSComplexity') {
            # Filtered on DESCRIPTION, not on name. PowerShell synthesises a parameter entry
            # from the param block whether or not a .PARAMETER block exists, so a name check
            # passes against exactly the undocumented switch this test was written to catch --
            # it did, before this line.
            $documented = @((Get-Help $cmd).parameters.parameter |
                    Where-Object { ($_.Description | Out-String).Trim() } |
                    ForEach-Object { $_.Name })
            $declared = @((Get-Command $cmd).Parameters.Keys | Where-Object { $_ -notin $common })
            $missing = @($declared | Where-Object { $_ -notin $documented })
            ($missing -join ',') | Should-Be '' -Because "$cmd does not document $($missing -join ', ')"
        }
    }

    It 'names every field the record actually carries in its .OUTPUTS' {
        # The .OUTPUTS block said "these five names" and listed five, from the release that
        # made it six. The record contract is pinned by a test; the prose describing it to
        # consumers was not, so the two could disagree indefinitely.
        #
        # The expected list is read off a REAL record rather than written out here, so a field
        # added to the record fails this until the help mentions it.
        $fields = @((Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1') -Detailed)[0].PSObject.Properties.Name)
        $fields.Count | Should-Be 7 -Because 'six published fields plus Contributions under -Detailed'
        $outputs = ((Get-Help Measure-PSComplexity).returnValues | Out-String) -replace '\s+', ' '
        foreach ($f in $fields) {
            $outputs | Should-BeLikeString "*$f*" -Because "the .OUTPUTS block never names $f"
        }
    }

    It 'resolves to the command help, not to a file header' {
        # A <# #> block immediately before `function` becomes that function's help, so a file
        # header written that way silently shadows the documentation meant for users. Paired
        # with the case above: both would pass on an empty synopsis otherwise.
        (Get-Help Test-PSComplexity).Synopsis | Should-BeLikeString '*Return $true if every unit*'
    }
}

Describe 'Measure-PSComplexity' {
    It 'reports a record per unit including the script body' {
        $recs = Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1')
        ($recs | Where-Object Unit -eq 'Get-A').Cyclomatic | Should-Be 2
        @($recs | Where-Object Unit -eq '<script-body>').Count | Should-Be 1
    }
    It 'emits units in SOURCE order, not hashtable order' {
        # The names are deliberately anti-alphabetical, and the hashtable happens to
        # enumerate them Alpha, Mike, <script-body>, Zulu -- neither source order nor
        # alphabetical, and not required to be stable at all.
        #
        # JOINED and compared as a string: Should-BeCollection ignores order and has no
        # switch to make it strict, so it would pass against every permutation -- which is
        # the entire claim being made here.
        $f = Join-Path $script:work 'order.ps1'
        Set-Content $f @'
$top = 1
function Zulu { if ($a) { 1 } }
function Alpha { if ($b) { 1 } }
function Mike { if ($c) { 1 } }
'@ -Encoding utf8
        ((Measure-PSComplexity -Path $f | ForEach-Object Unit) -join ',') |
            Should-Be '<script-body>,Zulu,Alpha,Mike'
    }

    It 'breaks a same-line tie by unit name, so the order is total' {
        # Two units CAN start on one line. A tie left unbroken puts the nondeterminism
        # straight back, in the one case a line-number sort cannot separate.
        $f = Join-Path $script:work 'sameline.ps1'
        Set-Content $f 'function Beta { if ($a) { 1 } } function Alfa { if ($b) { 1 } }' -Encoding utf8
        ((Measure-PSComplexity -Path $f | Where-Object Unit -ne '<script-body>' | ForEach-Object Unit) -join ',') |
            Should-Be 'Alfa,Beta'
    }

    It 'measures a file once when two inputs name it' {
        # A directory and a file inside it. Measuring it twice doubled that file's
        # contribution to anything that counts rows rather than taking a max.
        $recs = @(Measure-PSComplexity -Path $script:work, (Join-Path $script:work 'a.ps1'))
        @($recs | Where-Object Unit -eq 'Get-A').Count | Should-Be 1
    }

    It 'still measures two DIFFERENT files given as two inputs' {
        # Paired with the test above: deduplicating on something too coarse -- the input
        # string, or the directory -- would satisfy it by measuring less.
        $recs = @(Measure-PSComplexity -Path (Join-Path $script:work 'a.ps1'), (Join-Path $script:work 'nested/b.ps1'))
        @($recs | Where-Object Unit -eq 'Get-A').Count | Should-Be 1
        @($recs | Where-Object Unit -eq 'Get-B').Count | Should-Be 1
    }

    It 'does not report enum members as units' {
        # An initialised member is a PropertyMemberAst with a value, exactly like a class
        # property, so `Red = 1` became a unit while a bare `Green` did not -- an enum's
        # complexity depended on whether anyone numbered it. A label is not code.
        $f = Join-Path $script:work 'enum.ps1'
        Set-Content $f @'
enum Colour {
    Red = 1
    Green
    Blue = 3
}
'@ -Encoding utf8
        ((Measure-PSComplexity -Path $f | ForEach-Object Unit) -join ',') | Should-Be '<script-body>'
    }

    It 'still reports an initialised CLASS property as a unit' {
        # The other half of the same predicate. Excluding enum members by testing for an
        # initialiser alone would take class properties with it, and those do hold code.
        $f = Join-Path $script:work 'class-prop.ps1'
        Set-Content $f 'class Box { [int]$Size = $(if ($env:BIG) { 9 } else { 1 }) }' -Encoding utf8
        @(Measure-PSComplexity -Path $f | Where-Object Unit -eq 'Box.Size').Count | Should-Be 1
    }

    It 'reports Cyclomatic 1 / Cognitive 0 for a decision-free unit' {
        $flat = Join-Path $script:work 'flat.ps1'
        Set-Content $flat 'function Get-Flat { param($x) $x }' -Encoding utf8
        $r = Measure-PSComplexity -Path $flat | Where-Object Unit -eq 'Get-Flat'
        $r.Cyclomatic | Should-Be 1
        $r.Cognitive  | Should-Be 0
    }
    It 'recurses a directory and finds nested files' {
        $recs = Measure-PSComplexity -Path $script:work -Recurse
        @($recs | Where-Object Unit -eq 'Get-B').Count | Should-Be 1
    }
    It 'measures a flat directory without -Recurse, and only that directory' {
        # Two assertions, and the FIRST one is the test. Asserting only that the nested
        # unit is absent passes just as well when discovery found nothing at all, which
        # is what it used to do -- so the gate returned $true over breaching code.
        $recs = Measure-PSComplexity -Path $script:work
        @($recs | Where-Object Unit -eq 'Get-A').Count | Should-Be 1
        @($recs | Where-Object Unit -eq 'Get-B').Count | Should-Be 0
    }
    It 'gives a directory the same units with and without -Recurse when nothing is nested' {
        # The flat and recursive forms must agree on a flat folder. They did not: one
        # measured every file and the other measured none, and nothing compared them.
        $flatDir = Join-Path $script:work 'flatonly'
        New-Item -ItemType Directory -Path $flatDir -Force | Out-Null
        Set-Content (Join-Path $flatDir 'c.ps1') 'function Get-C { if ($z) { 1 } }' -Encoding utf8

        $shallow = @(Measure-PSComplexity -Path $flatDir)
        $deep    = @(Measure-PSComplexity -Path $flatDir -Recurse)
        $shallow.Count | Should-Be 2   # Get-C and the script body
        $shallow.Count | Should-Be $deep.Count
    }
    It 'measures a directory whose name contains wildcard characters' {
        # -Path glob-parses '[': a real directory called 'my[1]proj' matched nothing, so
        # a monorepo folder with a bracket in its name scored a confident, empty zero.
        $odd = Join-Path $script:work 'my[1]proj'
        New-Item -ItemType Directory -Path $odd -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $odd 'd.ps1') 'function Get-D { if ($q) { 1 } }' -Encoding utf8

        $recs = @(Measure-PSComplexity -Path $odd -Recurse)
        @($recs | Where-Object Unit -eq 'Get-D').Count | Should-Be 1
    }
    It 'still accepts a wildcard path that matches nothing literally' {
        # Resolving an existing path literally must not cost wildcard support: a pattern
        # names no file on disk, so it has to keep falling through to -Path.
        $recs = @(Measure-PSComplexity -Path (Join-Path $script:work '*.ps1'))
        @($recs | Where-Object Unit -eq 'Get-A').Count | Should-Be 1
    }
    It 'measures a file named explicitly whatever its extension, but not one it discovered' {
        # Two halves of one contract, and both are needed. The extension filter belongs to
        # DISCOVERY: name a file and you get it measured; hand over a directory and only
        # PowerShell files come back. Drop the leaf check and the explicit half returns
        # nothing, silently, for the file the caller pointed straight at.
        $odd = Join-Path $script:work 'named.psx'
        Set-Content -LiteralPath $odd 'function Get-Odd { if ($a) { 1 } }' -Encoding utf8

        @(Measure-PSComplexity -Path $odd | Where-Object Unit -eq 'Get-Odd').Count | Should-Be 1
        @(Measure-PSComplexity -Path $script:work -Recurse | Where-Object Unit -eq 'Get-Odd').Count | Should-Be 0
    }

    It 'skips an unparseable file, and says so on the error stream' {
        # The error stream, not the warning stream: CI logs routinely swallow warnings, and
        # this is the module admitting it did not measure something it was asked to.
        $ev = $null
        $recs = Measure-PSComplexity -Path (Join-Path $script:broken 'broken.ps1') -ErrorVariable ev -ErrorAction SilentlyContinue
        @($recs).Count | Should-Be 0
        @($ev).Count | Should-Be 1
        ($ev[0].Exception.Message) | Should-BeLikeString '*parse error*'
    }

    It 'keeps measuring the files it CAN parse' {
        # Lenient by design: one broken file in a tree must not cost the other results.
        # Paired with the refusal below -- Measure reports, Test refuses.
        Set-Content (Join-Path $script:broken 'fine.ps1') 'function Get-Fine { if ($a) { 1 } }' -Encoding utf8
        $recs = Measure-PSComplexity -Path $script:broken -ErrorVariable ev -ErrorAction SilentlyContinue
        @($recs | Where-Object Unit -eq 'Get-Fine').Count | Should-Be 1
        @($ev).Count | Should-BeGreaterThan 0
    }
    It 'accepts pipeline input' {
        $recs = (Join-Path $script:work 'a.ps1') | Measure-PSComplexity
        @($recs | Where-Object Unit -eq 'Get-A').Count | Should-Be 1
    }
}

Describe 'Test-PSComplexity' {
    It 'judges EVERY path piped to it, not just the last' {
        # The discriminating case, and the reason this is not a one-word fix. Adding
        # ValueFromPipeline to a function whose body is a bare block gives it an `end` block
        # only: it runs once, with $Path holding the LAST item, and the gate then returns a
        # confident verdict about one path while silently ignoring the rest.
        #
        # The breaching file is piped FIRST and the clean one second, so a gate that kept
        # only the last item would answer $true.
        $big = Join-Path $script:work 'piped-big.ps1'
        $small = Join-Path $script:work 'piped-small.ps1'
        Set-Content $big 'function PipedBig { if ($a) { if ($b) { if ($c) { 1 } } } }' -Encoding utf8
        Set-Content $small 'function PipedSmall { 1 }' -Encoding utf8

        (@($big, $small) | Test-PSComplexity -MaxCognitive 1 -WarningAction SilentlyContinue) |
            Should-BeFalse
    }

    It 'accepts a single path from the pipeline' {
        $small = Join-Path $script:work 'piped-only.ps1'
        Set-Content $small 'function PipedOnly { 1 }' -Encoding utf8
        ($small | Test-PSComplexity) | Should-BeTrue
    }

    It 'still accepts paths as an argument' {
        # Paired with the pipeline cases: restructuring into begin/process/end must not cost
        # the ordinary call, which is how every consumer uses it today.
        $small = Join-Path $script:work 'piped-only.ps1'
        Set-Content $small 'function PipedOnly { 1 }' -Encoding utf8
        Test-PSComplexity -Path $small | Should-BeTrue
    }

    It 'returns $true when everything is within the ceilings' {
        Test-PSComplexity -Path (Join-Path $script:work 'a.ps1') | Should-BeTrue
    }
    It 'returns $false and warns when a unit exceeds a ceiling' {
        $wv = $null
        $result = Test-PSComplexity -Path (Join-Path $script:work 'a.ps1') -MaxCyclomatic 1 -WarningVariable wv -WarningAction SilentlyContinue
        $result | Should-BeFalse
        @($wv).Count | Should-Be 1   # Get-A breaches; the script body does not
    }
    It 'honours the cognitive ceiling independently' {
        # Get-B has cognitive 3 (foreach + nested if); ceiling 2 should trip it.
        #
        # Pointed at nested/ rather than the whole fixture: the root holds a deliberately
        # unparseable file, and the gate now refuses to give a verdict when it could not
        # read something. This test is about the CEILING, so it must not be answering the
        # refusal instead.
        Test-PSComplexity -Path $script:work -Recurse -MaxCognitive 2 -WarningAction SilentlyContinue | Should-BeFalse
    }

    It 'refuses a verdict when a file did not parse' {
        # The gate's other silence: "no unit exceeded a ceiling" is trivially true of a file
        # that produced no units. Paired with the ceiling test above, which must still return
        # a real $false rather than throwing.
        # Asserted on the TAIL of the message, not the head. Break the concatenation that
        # builds it and PowerShell raises a conversion error that QUOTES its left operand --
        # so "Cannot convert value "Refusing to vouch for 1 file(s) that did not parse: "
        # to type System.Int32" still matches a '*did not parse*' pattern. The assertion
        # matched the very failure it existed to detect. Only text from after the break
        # distinguishes them.
        { Test-PSComplexity -Path $script:broken -Recurse } |
            Should-Throw -ExceptionMessage '*Fix the syntax*'
    }
    It 'throws rather than passing when it measured nothing' {
        # A directory with no PowerShell in it. Returning $true here is the same answer
        # the gate gives for code that is entirely within its ceilings, so a gate aimed
        # at the wrong path reported clean and nothing distinguished the two.
        $empty = Join-Path $script:work 'nosource'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Set-Content (Join-Path $empty 'notes.txt') 'not powershell' -Encoding utf8

        { Test-PSComplexity -Path $empty -Recurse } | Should-Throw -ExceptionMessage '*Measured no units*'
    }
    It 'names the path it measured nothing under' {
        # The message has to say WHERE. A gate that fails without naming the path sends
        # the reader to the ceilings, which are not the problem.
        $empty = Join-Path $script:work 'nosource2'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        { Test-PSComplexity -Path $empty -Recurse } |
            Should-Throw -ExceptionMessage "*$([System.IO.Path]::GetFileName($empty))*"
    }
    It 'suggests -Recurse only when -Recurse was not given' {
        # Two calls, because a hint that always appears is not a hint. Suggesting
        # -Recurse to someone who passed it sends them to look at the wrong thing.
        $empty = Join-Path $script:work 'nosource3'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null

        # Inspect the message rather than using -Not -Throw: both calls throw, and the
        # claim is about what the message says, not about whether one was raised.
        $withRecurse = $null
        try { Test-PSComplexity -Path $empty -Recurse } catch { $withRecurse = $_.Exception.Message }

        { Test-PSComplexity -Path $empty } | Should-Throw -ExceptionMessage '*-Recurse*'
        $withRecurse | Should-BeLikeString '*Measured no units*'
        $withRecurse | Should-NotBeLikeString '*-Recurse*'
    }
    It 'still passes over a real file that is within the ceilings' {
        # Paired with the refusal above: the empty case must fail and a measured, clean
        # case must still succeed, or "throws on empty" is satisfied by throwing always.
        Test-PSComplexity -Path (Join-Path $script:work 'a.ps1') | Should-BeTrue
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
        @($body).Count   | Should-Be 1
        $body.Cyclomatic | Should-Be 2   # baseline 1 + the if
        $body.Cognitive  | Should-Be 2   # +1 the if, +1 the else branch
    }

    It 'nests top-level decisions the same way it nests them inside a function' {
        # Pins that the script body is a real unit for cognitive scoring, not a
        # bucket that only collects a flat count: the inner if is +2 (nesting), so
        # a body that ignored depth would score 2 instead of 3.
        $p = Join-Path $script:work 'toplevel-nested.ps1'
        Set-Content $p 'if ($a) { if ($b) { "x" } }' -Encoding utf8
        $body = Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>'
        $body.Cyclomatic | Should-Be 3
        $body.Cognitive  | Should-Be 3
    }

    It 'does not count a top-level call as recursion' {
        # Recursion detection compares a call name against its ENCLOSING function
        # name. At script level there is none, so the lookup returns $null and the
        # call must not be scored -- a script that calls a command sharing its file
        # name would otherwise pick up a phantom recursion point.
        $p = Join-Path $script:work 'toplevel-call.ps1'
        Set-Content $p 'Get-Date' -Encoding utf8
        $body = Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>'
        $body.Cognitive | Should-Be 0
    }

    It 'still detects recursion inside a function in the same file' {
        # The counterpart to the case above: proving the $null guard did not simply
        # switch recursion detection off.
        $p = Join-Path $script:work 'toplevel-plus-recursion.ps1'
        Set-Content $p "Get-Date`nfunction Get-Loop { Get-Loop }" -Encoding utf8
        $recs = Measure-PSComplexity -Path $p
        ($recs | Where-Object Unit -like 'Get-Loop*').Cognitive | Should-Be 1
        ($recs | Where-Object Unit -eq '<script-body>').Cognitive | Should-Be 0
    }
}

Describe 'Measure-PSComplexity - reporting details that the suite never pinned' {

    It 'reports the script body as starting at line 1' {
        # The unit table seeds '<script-body>' with its start line. Nothing asserted
        # the Line column for it, so the seed could be any number and every score
        # stayed correct while the record pointed at the wrong place.
        $p = Join-Path $script:work 'body-line.ps1'
        Set-Content $p "if (`$a) { 1 }" -Encoding utf8
        (Measure-PSComplexity -Path $p | Where-Object Unit -eq '<script-body>').Line | Should-Be 1
    }

    It 'counts a ternary as exactly one cyclomatic decision' {
        # Every branch contributes Amount = 1. A ternary scoring 2 would inflate
        # every unit using one, and no cyclomatic test used a ternary at all.
        $p = Join-Path $script:work 'ternary-cyc.ps1'
        Set-Content $p 'function Get-T { param($x) $x ? 1 : 2 }' -Encoding utf8
        (Measure-PSComplexity -Path $p | Where-Object Unit -like 'Get-T*').Cyclomatic | Should-Be 2
    }

    It 'names the FIRST parse error in the skip message' {
        # The message reads $errors[0]. Read as $errors[1] it reports a different error, or
        # nothing at all when there is only one -- leaving a report that says a file was
        # skipped without saying why, which is the only thing the message is for.
        $p = Join-Path $script:broken 'one-error.ps1'
        Set-Content $p 'if ($a) {' -Encoding utf8
        Measure-PSComplexity -Path $p -ErrorVariable ev -ErrorAction SilentlyContinue | Out-Null
        (@($ev) -join ' ') | Should-BeLikeString "*Missing closing '}'*"
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

        $ev = $null
        $recs = Measure-PSComplexity -Path $script:work -Recurse -ErrorVariable ev -ErrorAction SilentlyContinue
        # The real file inside it is still measured...
        @($recs | Where-Object Unit -like 'Get-Inner*').Count | Should-Be 1
        # ...and the directory itself is never treated as a source file.
        @($recs | Where-Object File -eq $d).Count | Should-Be 0
        # ...and it is never even HANDED to the parser. Drop the -File filter in discovery
        # and a directory called weird.ps1 passes the extension test, reaches ParseFile and
        # fails there -- producing no record, so the two assertions above still pass. This
        # is the only one that can tell.
        (@($ev) -join ' ') | Should-NotBeLikeString "*weird.ps1'*"
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
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Cyclomatic | Should-Be 5
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Cognitive  | Should-Be 10
    }

    It 'reports each method exactly once' {
        @($script:clsRecs | Where-Object Unit -eq 'Order.Process') | Should-BeCollection -Count 1
    }

    It 'keeps same-named methods on different classes apart, and apart from a function' {
        $names = @($script:clsRecs | Where-Object { $_.Unit -like '*Process*' } | ForEach-Object Unit | Sort-Object)
        # Joined rather than Should-BeCollection: that one ignores order and has no switch to
        # make it strict, so it passes against any permutation -- and the sort above exists
        # precisely so this comparison is deterministic.
        ($names -join ',') | Should-Be 'Invoice.Process,Order.Process,Process'
    }

    It 'names a constructor after its class' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Order').Cyclomatic | Should-Be 2
    }

    It 'reports a static method' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Helper').Cyclomatic | Should-Be 1
    }

    It 'makes an initialised property its own unit and leaves the script body alone' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Threshold').Cyclomatic | Should-Be 2
        ($script:clsRecs | Where-Object Unit -eq '<script-body>').Cyclomatic  | Should-Be 1
    }

    It 'does not create a unit for a property with no initialiser' {
        # No initialiser means no code, so there is nothing to measure or gate.
        @($script:clsRecs | Where-Object Unit -eq 'Order.Plain').Count | Should-Be 0
    }

    It 'reports the line of the member, not of the class' {
        ($script:clsRecs | Where-Object Unit -eq 'Order.Process').Line | Should-Be 5
    }

    It 'lets the gate fail a single over-complex method' {
        # The point of the whole change: a per-unit ceiling can now name the method.
        Test-PSComplexity -Path $script:clsFile -MaxCognitive 9 -WarningAction SilentlyContinue | Should-BeFalse
        Test-PSComplexity -Path $script:clsFile -MaxCognitive 10 -WarningAction SilentlyContinue | Should-BeTrue
    }
}

Describe 'a score can say where it came from' {
    # A unit comes back as Cognitive = 23. Correct, and completely unactionable: nothing says
    # whether that is one deeply-nested loop or twenty flat guards, and those call for opposite
    # fixes. The data existed internally and the summation was the only reason it was lost.

    BeforeAll {
        $script:DetailFile = Join-Path $script:work 'detail.ps1'
        Set-Content $script:DetailFile @'
function Invoke-Thing {
    param($a, $b, $xs)
    foreach ($x in $xs) {
        if ($a) { 1 }
        if ($a -and $b) { 2 }
    }
}
'@ -Encoding utf8
    }

    It 'says nothing extra by default' {
        # The default shape is a CONTRACT -- CI consumers parse these records, and a field that
        # appears unbidden is a breaking change dressed as a feature.
        $row = @(Measure-PSComplexity -Path $script:DetailFile)[0]
        ($row.PSObject.Properties.Name -join ',') | Should-Be 'File,Unit,Line,Cyclomatic,Cognitive,MetricVersion'
    }

    It 'adds Contributions when asked' {
        $row = @(Measure-PSComplexity -Path $script:DetailFile -Detailed)[0]
        ($row.PSObject.Properties.Name -join ',') |
            Should-Be 'File,Unit,Line,Cyclomatic,Cognitive,MetricVersion,Contributions'
    }

    It 'accounts for every point: the contributions sum to the score' {
        # Guards ATTRIBUTION, not scoring, and the difference is worth stating because the
        # test looks stronger than it is: the score and this list are summed from the same
        # rows, so dropping or misgrouping a row on the way here fails, while a collector that
        # scores a construct wrong moves both sides equally and passes. Checked by doing both.
        # Whether a construct is scored correctly is what the reference-score suite is for.
        $unit = @(Measure-PSComplexity -Path $script:DetailFile -Detailed | Where-Object Unit -eq 'Invoke-Thing')[0]
        (($unit.Contributions | Measure-Object Amount -Sum).Sum) | Should-Be $unit.Cognitive
    }

    It 'names the construct and the line for each point' {
        $unit = @(Measure-PSComplexity -Path $script:DetailFile -Detailed | Where-Object Unit -eq 'Invoke-Thing')[0]
        # foreach at 3, if at 4 (+1 nesting), then the boolean run and the if at 5.
        (($unit.Contributions | ForEach-Object { "$($_.Construct)@$($_.Line)+$($_.Amount)" }) -join ' ') |
            Should-Be 'block@3+1 if@4+2 boolean-run@5+1 if@5+2'
    }

    It 'orders them by line, because that is how the unit is read' {
        $unit = @(Measure-PSComplexity -Path $script:DetailFile -Detailed | Where-Object Unit -eq 'Invoke-Thing')[0]
        $lines = @($unit.Contributions | ForEach-Object { $_.Line })
        ($lines -join ',') | Should-Be (($lines | Sort-Object) -join ',')
    }

    It 'does not build a breakdown nobody asked for' {
        # -Detailed costs an extra walk of the whole AST per file, and this is the command a
        # CI gate runs on every push. The guard is invisible in the output either way -- the
        # records are identical whether or not the map was built -- so nothing but this
        # assertion stops it being dropped, and the cost would land on every consumer.
        #
        # Both halves, because the negative alone passes just as well against a guard that
        # never calls it at all.
        Mock Get-PSCxContributionMap { @{} }
        Measure-PSComplexity -Path $script:DetailFile | Out-Null
        Should-NotInvoke Get-PSCxContributionMap
        Measure-PSComplexity -Path $script:DetailFile -Detailed | Out-Null
        Should-Invoke Get-PSCxContributionMap -Times 1 -Exactly
    }

    It 'gives a decision-free unit an empty list rather than nothing' {
        # Absent and empty are different answers, and a consumer iterating the property should
        # not have to tell them apart.
        $flat = Join-Path $script:work 'flat.ps1'
        Set-Content $flat 'function Get-Flat { param($x) $x }' -Encoding utf8
        try {
            $unit = @(Measure-PSComplexity -Path $flat -Detailed | Where-Object Unit -eq 'Get-Flat')[0]
            ($unit.PSObject.Properties.Name -contains 'Contributions') | Should-BeTrue
            @($unit.Contributions).Count | Should-Be 0
        }
        finally { Remove-Item $flat -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the scan is the measurement; the record stream is a projection of it' {
    # Facts about the RUN -- which files were skipped and why, what was in scope -- used to be
    # destroyed at emission, exactly as construct and line used to be destroyed when amounts
    # were summed at emission. The gate then rebuilt the skip list by capturing its own
    # module's error stream, which is the shape this pins shut.

    BeforeAll {
        $script:scanDir = Join-Path ([System.IO.Path]::GetTempPath()) "cxscan-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:scanDir -Force | Out-Null
        # One good file and one broken one in the SAME directory. A fixture with only the
        # broken file proves a skip was recorded but not that measuring carried on around it,
        # and a fixture with only the good file proves nothing about skips at all.
        Set-Content (Join-Path $script:scanDir 'good.ps1') 'function Get-Good { param($x) if ($x) { 1 } }' -Encoding utf8
        Set-Content (Join-Path $script:scanDir 'bad.ps1') 'function Oops { param(' -Encoding utf8
        New-Item -ItemType Directory -Path (Join-Path $script:scanDir 'nested') -Force | Out-Null
        Set-Content (Join-Path $script:scanDir 'nested/deep.ps1') 'function Get-Deep { param($x) if ($x) { 1 } }' -Encoding utf8
    }

    AfterAll { Remove-Item $script:scanDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records a skip as data, writing nothing to the error stream' {
        # The purity claim, and the reason the gate can stop capturing errors. A scan that
        # announced skips on the error stream would leave the caller reconstructing text.
        $ev = $null
        $scan = Get-PSCxScan -Path $script:scanDir -ErrorVariable ev -ErrorAction SilentlyContinue
        @($ev).Count | Should-Be 0
        $scan.Skipped.Count | Should-Be 1
    }

    It 'keeps measuring around a file it had to skip' {
        # The kept half. One broken file must not cost the other results, and asserting only
        # the skip would pass just as well against a scan that stopped at the first failure.
        $scan = Get-PSCxScan -Path $script:scanDir
        (@($scan.Units | Where-Object Unit -eq 'Get-Good')).Count | Should-Be 1
    }

    It 'names the file and the reason for every skip' {
        # A skip that does not say which file or why is the fact this type exists to carry.
        $scan = Get-PSCxScan -Path $script:scanDir
        $scan.Skipped[0].File | Should-BeLikeString '*bad.ps1'
        $scan.Skipped[0].Reason | Should-BeLikeString '*parse error*'
    }

    It 'projects exactly the units the record stream emits' {
        # The projection claim. If these two ever disagree there are two measurements, which
        # is the thing having one noun is for.
        $scan = Get-PSCxScan -Path $script:scanDir
        $streamed = @(Measure-PSComplexity -Path $script:scanDir -ErrorAction SilentlyContinue)
        (@($scan.Units | ForEach-Object { $_.Unit }) -join ',') |
            Should-Be (@($streamed | ForEach-Object { $_.Unit }) -join ',')
    }

    It 'records what it was asked for, not just what it found' {
        # Scope is what a changed-files run and a committed baseline both need: "these units"
        # means nothing without "under this path, recursively or not".
        $scan = Get-PSCxScan -Path $script:scanDir -Recurse
        $scan.Scope.Recurse | Should-BeTrue
        (@($scan.Scope.Path) -join ',') | Should-Be $script:scanDir
        (Get-PSCxScan -Path $script:scanDir).Scope.Recurse | Should-BeFalse
    }

    It 'accepts an empty seen set, which is the normal starting point' {
        # Mandatory alone rejects an empty collection, and the binding failure then surfaces
        # wherever the caller reports errors -- the gate announced it as a file that did not
        # parse. A test because the fix is one attribute that reads like decoration.
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $scans = @(Get-PSCxPathScan -Path (Join-Path $script:scanDir 'good.ps1') -Seen $seen)
        $scans.Count | Should-Be 1
        $scans[0].SkipReason | Should-BeNull
    }

    It 'honours -Recurse when collecting, not only when recording it' {
        # Scope saying Recurse=$true while the walk stayed flat is a scan that lies about
        # itself, and the gate reads this and nothing else. Both halves: asserting only that
        # the nested unit IS found passes just as well against a walk that always recurses.
        $flat = Get-PSCxScan -Path $script:scanDir
        $deep = Get-PSCxScan -Path $script:scanDir -Recurse
        (@($flat.Units | Where-Object Unit -eq 'Get-Deep')).Count | Should-Be 0
        (@($deep.Units | Where-Object Unit -eq 'Get-Deep')).Count | Should-Be 1
    }

    It 'passes -Detailed through to the units it collects, and withholds it otherwise' {
        # The switch travels two hops to reach a record, and nothing about the gate's own
        # output changes if it is dropped or forced -- so only an assertion on both shapes
        # keeps the pass-through honest.
        $with = Get-PSCxScan -Path $script:scanDir -Detailed
        $without = Get-PSCxScan -Path $script:scanDir
        ($with.Units[0].PSObject.Properties.Name -contains 'Contributions') | Should-BeTrue
        ($without.Units[0].PSObject.Properties.Name -contains 'Contributions') | Should-BeFalse
    }

    It 'tells the gate which file it could not read' {
        # The gate used to join Exception.Message from a captured error stream. It now reads
        # File and Reason off the scan, so the message names the file as data rather than as
        # whatever text happened to be in an error record.
        { Test-PSComplexity -Path $script:scanDir } |
            Should-Throw -ExceptionMessage '*bad.ps1*'
    }
}

Describe 'an acceptance is a checkable claim, not a mute button' {
    # Every complexity gate meets a unit that is genuinely, irreducibly complex. The only
    # answers used to be lower the ceiling for everyone or stop measuring the file, and the
    # second is what this repo does to its own tests. An acceptance is the third answer -- and
    # it fails when it stops being true, which is the whole difference between it and a
    # suppression list.

    BeforeAll {
        $script:accDir = Join-Path ([System.IO.Path]::GetTempPath()) "cxacc-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:accDir -Force | Out-Null
        # One unit that breaches a low ceiling and one that cannot: an acceptance test needs
        # both, or "accepted" is indistinguishable from "nothing breached".
        Set-Content (Join-Path $script:accDir 'hot.ps1') @'
function Invoke-Hot {
    param($a, $b, $c)
    if ($a) { if ($b) { if ($c) { 1 } } }
}
function Get-Cool { param($x) $x }
'@ -Encoding utf8
        $script:accFile = (Measure-PSComplexity -Path (Join-Path $script:accDir 'hot.ps1') |
                Where-Object Unit -eq 'Invoke-Hot').File
        $script:accPath = Join-Path $script:accDir 'hot.ps1'
    }

    AfterAll { Remove-Item $script:accDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'lets a breaching unit pass when it carries an argument' {
        $ok = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'a deliberately nested fixture' })
        Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $ok `
            -WarningAction SilentlyContinue | Should-BeTrue
    }

    It 'still fails the same unit when nobody argued for it' {
        # The kept half. Without this the test above passes just as well against a gate that
        # stopped checking ceilings altogether.
        Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 `
            -WarningAction SilentlyContinue | Should-BeFalse
    }

    It 'accepts only the unit named, not every unit in the file' {
        # Accepting Get-Cool must not excuse Invoke-Hot. A key compared too loosely -- on file
        # alone -- passes the first test and silently mutes the whole file.
        $wrong = @(@{ File = $script:accFile; Unit = 'Get-Cool'; Reason = 'r' })
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $wrong `
                -WarningAction SilentlyContinue } | Should-Throw -ExceptionMessage '*within both ceilings*'
    }

    It 'throws when the acceptance names a unit that was not measured' {
        # The stale case, and the reason this is a claim rather than a suppression: a unit that
        # was renamed away takes its argument with it, and nothing else would say so.
        $ghost = @(@{ File = $script:accFile; Unit = 'Invoke-Ghost'; Reason = 'r' })
        # Asserted on the TAIL of the message, past the last concatenation. Break the `+` that
        # builds it and PowerShell raises a conversion error QUOTING its left operand -- which
        # contains every earlier phrase, so an assertion on one of those matches the very
        # failure it exists to detect. Only text from after the break tells them apart.
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $ghost `
                -WarningAction SilentlyContinue } |
            Should-Throw -ExceptionMessage '*no such unit was measured*ageing quietly*'
    }

    It 'throws when the accepted unit is back within both ceilings' {
        # Somebody fixed it and left the note. Left alone, the note goes on excusing a unit
        # that no longer needs excusing, and the next breach of it passes unnoticed.
        $fixed = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'r' })
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 15 -MaxCognitive 15 -Accept $fixed `
                -WarningAction SilentlyContinue } | Should-Throw -ExceptionMessage '*within both ceilings*'
    }

    It 'throws when an acceptance carries no argument' {
        # Whitespace, not absence: a Reason of spaces is the shape a copied template arrives in,
        # and it is exactly the mute button this concept exists instead of.
        $bare = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = '   ' })
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $bare `
                -WarningAction SilentlyContinue } | Should-Throw -ExceptionMessage '*with no reason*'
    }

    It 'throws when an acceptance does not say which unit it is about' {
        $vague = @(@{ File = $script:accFile; Reason = 'r' })
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $vague `
                -WarningAction SilentlyContinue } | Should-Throw -ExceptionMessage '*needs both File and Unit*'
    }

    It 'reports every fault at once rather than the first' {
        # A gate that fixes one acceptance per run costs a CI round trip each time.
        $many = @(
            @{ File = $script:accFile; Unit = 'Invoke-Ghost'; Reason = 'r' }
            @{ File = $script:accFile; Unit = 'Get-Cool'; Reason = 'r' }
        )
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $many `
                -WarningAction SilentlyContinue } |
            Should-Throw -ExceptionMessage '*no such unit was measured*within both ceilings*'
    }

    It 'accepts a unit that breaches only the cyclomatic ceiling' {
        # Invoke-Hot is cyclomatic 4, cognitive 6. Ceilings 3/6 put it over one and inside the
        # other, which is the only shape that tells "within BOTH ceilings" from "within either".
        # Every earlier test had a unit over both or under both, where -and and -or agree and
        # the first comparison never decides anything.
        $ok = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'over on cyclomatic only' })
        Test-PSComplexity -Path $script:accPath -MaxCyclomatic 3 -MaxCognitive 6 -Accept $ok `
            -WarningAction SilentlyContinue | Should-BeTrue
    }

    It 'accepts a unit that breaches only the cognitive ceiling' {
        # The mirror image, ceilings 4/5, so the SECOND comparison is the one that decides.
        # Both halves are needed: each comparison is read separately, and a fault in one is
        # invisible while the other still guards the result.
        $ok = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'over on cognitive only' })
        Test-PSComplexity -Path $script:accPath -MaxCyclomatic 4 -MaxCognitive 5 -Accept $ok `
            -WarningAction SilentlyContinue | Should-BeTrue
    }

    It 'treats a unit sitting exactly ON both ceilings as within them' {
        # At or under, not under. Ceilings 4/6 against cyclomatic 4 and cognitive 6: the unit is
        # inside, so the acceptance is the one that should be deleted. Read as strictly-less
        # this reports nothing and the stale acceptance survives -- and a fencepost here is
        # silent, because it only ever shows up for a unit that lands exactly on the line.
        $fixed = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'r' })
        { Test-PSComplexity -Path $script:accPath -MaxCyclomatic 4 -MaxCognitive 6 -Accept $fixed `
                -WarningAction SilentlyContinue } |
            Should-Throw -ExceptionMessage '*within both ceilings*ageing quietly*'
    }

    It 'still measures a unit it accepts' {
        # An acceptance is gate POLICY, not a measurement filter. Hiding the unit from
        # Measure-PSComplexity would take it out of any report or baseline built on the same
        # records, so the argument would disappear along with the number it is about.
        $ok = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'r' })
        Test-PSComplexity -Path $script:accPath -MaxCyclomatic 1 -MaxCognitive 1 -Accept $ok `
            -WarningAction SilentlyContinue | Out-Null
        (@(Measure-PSComplexity -Path $script:accPath | Where-Object Unit -eq 'Invoke-Hot')).Count |
            Should-Be 1
    }

    It 'keys on file AND unit, so the same name in another file is a different claim' {
        # File is half the identity. Compared on unit name alone, one acceptance excuses every
        # like-named unit in the tree -- which is the failure mode of every suppression list
        # that keys on a symbol.
        $other = Join-Path $script:accDir 'other.ps1'
        Set-Content $other @'
function Invoke-Hot {
    param($a, $b, $c)
    if ($a) { if ($b) { if ($c) { 1 } } }
}
'@ -Encoding utf8
        try {
            # BOTH files in one run, so the acceptance describes this run and the only question
            # left is which unit it excuses. Gating other.ps1 alone would throw instead --
            # correctly, but for the different reason that the claim names a unit not measured.
            $ok = @(@{ File = $script:accFile; Unit = 'Invoke-Hot'; Reason = 'r' })
            Test-PSComplexity -Path $script:accDir -MaxCyclomatic 1 -MaxCognitive 1 -Accept $ok `
                -WarningAction SilentlyContinue | Should-BeFalse
        }
        finally { Remove-Item $other -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'a run can be written down' {
    # The wiring lives in Measure-PSComplexity.ps1, so it is tested HERE: the mutation config
    # maps that file to this suite, and the same assertions written in Report.Tests.ps1 cover
    # the code without being able to kill a single one of its mutants.
    #
    # What the report SAYS is Report.Tests.ps1's business. This is only about the switch.

    BeforeAll {
        $script:rpDir = Join-Path ([System.IO.Path]::GetTempPath()) "cxrp-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:rpDir -Force | Out-Null
        Set-Content (Join-Path $script:rpDir 'one.ps1') 'function Get-One { param($x) if ($x) { 1 } }' -Encoding utf8
    }

    AfterAll { Remove-Item $script:rpDir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes a report where it was asked to' {
        $p = Join-Path $script:rpDir 'r.json'
        Measure-PSComplexity -Path (Join-Path $script:rpDir 'one.ps1') -ReportPath $p | Out-Null
        Should-BeTrue -Actual (Test-Path -LiteralPath $p)
    }

    It 'writes nothing when no report was asked for' {
        # The paired half. Without it the test above passes against a command that writes a
        # report unbidden, which would litter every consumer's working tree.
        $before = @(Get-ChildItem $script:rpDir -File -Filter *.json).Count
        Measure-PSComplexity -Path (Join-Path $script:rpDir 'one.ps1') | Out-Null
        @(Get-ChildItem $script:rpDir -File -Filter *.json).Count | Should-Be $before
    }

    It 'emits each unit exactly once while also writing a report' {
        # With -ReportPath the whole run is emitted from `end`, out of one scan, and the
        # per-item streaming path returns early. Drop that early return and every unit is
        # emitted TWICE -- once streamed, once from the scan -- which reads as a doubled
        # codebase to anything counting, and no assertion on the report file would show it.
        $p = Join-Path $script:rpDir 'r2.json'
        $units = @(Measure-PSComplexity -Path (Join-Path $script:rpDir 'one.ps1') -ReportPath $p)
        @($units | Where-Object Unit -eq 'Get-One').Count | Should-Be 1
        $units.Count | Should-Be 2
    }

    It 'still reports a file it could not read while writing a report' {
        # The error stream is the same projection either way. A report must not quietly buy
        # silence about a file the run could not measure.
        $bad = Join-Path $script:rpDir 'broken'
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        Set-Content (Join-Path $bad 'bad.ps1') 'function Oops { param(' -Encoding utf8
        try {
            $ev = $null
            Measure-PSComplexity -Path $bad -ReportPath (Join-Path $script:rpDir 'r3.json') `
                -ErrorVariable ev -ErrorAction SilentlyContinue | Out-Null
            @($ev).Count | Should-Be 1
            ($ev[0].Exception.Message) | Should-BeLikeString '*parse error*'
        }
        finally { Remove-Item $bad -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
