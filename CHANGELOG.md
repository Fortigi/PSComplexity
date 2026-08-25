# Changelog

All notable changes to PSComplexity are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

## [0.4.0] - 2026-08-23

### For consumers

BEHAVIOUR CHANGE -- two published values change shape, and anything that stored them will
not match. Read this before upgrading a pipeline that keeps records.

`Unit` and `File` were neither unique within a file nor stable across machines, and both are
fixed together because a half-fixed identity is still not one.

**`Unit` is now qualified and disambiguated.** A function nested in another reads
`Get-OuterA/Get-Inner` rather than `Get-Inner` -- two such units in one file used to be
indistinguishable, and they score differently. Two units sharing a name in the same scope --
overloads, or a function defined twice -- get an ordinal on **every** member of the group:
`Repo.Add#1`, `Repo.Add#2`. Both, not just the second, because suffixing only the later one
would silently rename the first the day an overload is added. Class members were already
qualified; this extends the same rule to the half that lacked it.

**`File` is now relative to the working directory, with forward slashes.** It was absolute
and platform-separated, so identical source measured on two CI legs produced disjoint key
sets -- `C:\...\src\A.ps1` against `/home/.../src/A.ps1` -- and anything comparing runs
across them matched nothing while appearing to work. A file outside the root keeps its full
path, because a `../../` chain is no more portable and says less. The README had rendered
this relative all along.

If you have a stored baseline, it will not match after upgrading. That is the point: the
keys it holds could not distinguish units the tool could.

### Fixed

- **Running the analyzer by hand is now the same as passing it.**
  `tools/Invoke-PSCxAnalyzer.ps1` returned its findings and exited 0 whether or not it found any,
  so `$?` was not a verdict and the gate was the `if` around it -- in `ci.yml` and again in
  `publish.yml`, which guards the one irreversible action here. It throws now, like
  `Measure-PSCxCoverage.ps1` and `Test-PSCxRelease.ps1` beside it. `-PassThru` returns the
  findings without failing, for code scanning, which uploads them rather than gating on them and
  where an empty set is a meaningful upload that clears alerts for rules already fixed.

- **The gate could describe an unrelated failure as a file that did not parse.**
  `Test-PSComplexity` rebuilt its list of unreadable files by capturing `Measure-PSComplexity`'s
  error stream with `-ErrorAction SilentlyContinue`, so *any* error landed in the same variable
  and was reported as a syntax problem in a file. It now reads what was skipped, and why, as
  data. The symptom was reproduced during this change: a parameter-binding fault surfaced as
  "Refusing to vouch for 1 file(s) that did not parse".

- **A relative path now resolves against the root it was given, not against the working
  directory.** `Get-PSCxRelativePath` called `GetFullPath` on its `Path` argument directly, so
  a relative one silently resolved against wherever the shell happened to be standing. It gave
  the right answer only while its single caller passed an absolute path **and** a root equal to
  the current directory -- two conditions that both had to hold and neither of which was
  stated. Not reachable today; the sibling project shipped the same shape and it was a live
  hole there, because a config may name a file by full path.


- **CI now fails when `main` claims a version that has already shipped.** It once did: `main`
  stood at 0.2.0, 0.2.0 was on the gallery, and merged work sat under `[Unreleased]` with every
  gate green. Two people installing "0.2.0" -- one from the gallery, one from a clone -- got
  different code, and nothing in the repo could tell them apart. The release gate now asks the
  gallery, and faults only on the pair: a published version **and** unreleased entries above
  it. Either alone is a normal state. It checks the gallery is reachable **first** and refuses
  when it is not, because "never published" and "could not look" are the same empty answer and
  treating them alike is how a gate silently stops being able to fail.

- **The construct vocabulary is pinned, so a half-finished addition cannot ship green.** Three
  hardcoded type lists drive every number this module produces, and a leave-one-out sweep found
  most entries deletable with the whole suite green at 100% coverage: 5 of 7 cyclomatic types,
  4 of 8 cognitive types, and the entire `switch` decision-point block -- which made a 12-case
  switch score cyclomatic **1** instead of 13. The cause was blunt: `tests/` contained no
  `catch` and no `trap` at all, one `switch` fixture asserting cognitive only, and a `do-until`
  but no `do-while`. The mutation gate cannot reach this -- its operators are arithmetic and
  boolean, and none deletes a statement or touches a type name -- so "100% self-mutation" was
  true and said nothing about the vocabulary. Twenty reference cases now pin every entry;
  re-running the sweep against a green control leaves **28 of 29** entries failing when deleted.

- **Two units written on one line are two units again.** A unit was keyed by its name and its
  *line*, and a line is not unique: two overloads on one physical line shared a key, so their
  scores were **added** and the file reported a single unit that exists nowhere in the source.
  The pair reported one `Repo.Add` at cyclomatic 3 where there are two, each 2. Units are now
  keyed by the extent's start offset, unique per node however the source is laid out. The
  reported `Line` is unchanged and remains display data, not identity -- it moves whenever
  anything above a unit is edited.

### Internal

- **A new dependency edge between files in `src/` now has to be declared.** Every other gate is
  blind to direction -- a shortcut call reaches full coverage and survives self-mutation exactly
  as a well-layered one does -- so the graph was acyclic by habit rather than by check. An
  allowlist of file-to-file relationships now fails in both directions, asserts the graph is
  acyclic, and holds `Report.ps1` as a sink so a serialiser cannot start deciding what a number
  means. Each of its five assertions was checked by making it fail.

- **The one entry the vocabulary sweep could not pin now says why.** `FunctionMemberAst` sits in
  the unit-boundary list and removing it broke nothing -- the single exception in a leave-one-out
  sweep that fails on 28 of 29 entries. It turns out to be unreachable for a reason rather than
  by luck: every use of that list walks UP the parent chain, and PowerShell wraps a class member's
  body in its own `FunctionDefinitionAst`, so the body is always met first. Verified across
  methods, constructors, static constructors, static and hidden members, overrides and an empty
  body -- and for a parameter default and a `ValidateScript` attribute, both of which look like
  they sit on the member and are folded into the body.

  It stays, because the failure modes are not symmetric: keeping it costs nothing, and removing
  it would silently attribute a method's decisions to the script body. The invariant it leans on
  is now pinned by tests, so the day it stops holding is a red suite rather than a quiet
  re-attribution.

- **Every metric increment now records the construct that caused it and the line it is on.**
  Nineteen producers emitted an anonymous `{Key; Amount}` pair and the amounts were folded into
  a total, so *what* caused an increment and *where* were destroyed at the moment the increment
  was created rather than at the boundary. The rows carry both now; the maps stay projections
  over them, so summation happens exactly once and **no published number changes**. This is what
  #3 needs -- reporting which construct contributed each point asks the pipeline for information
  it used to throw away two layers below where the question is asked, which makes that an
  architectural change rather than an addition.

### Internal

- **Measurement has a noun.** `Get-PSCxScan` returns the complete measurement -- scope, units,
  and skips with their reasons -- and the two public commands are projections over it. Facts
  about the run were previously destroyed at emission, which is the same defect as summing an
  increment before recording what caused it, one layer up. It stays internal until a consumer
  publishes it; keeping the shape in one place is what stops a report, a changed-files run and
  a committed baseline each inventing their own.

### Added

- **A run can leave the process: `-ReportPath` and `-SarifPath`.** The gate gave a build one bit
  and the records were PowerShell objects, so anything that was not PowerShell -- a dashboard, a
  trend, a pull request annotation -- had to re-implement the serialisation. `Measure-PSComplexity
  -ReportPath` and `Test-PSComplexity -ReportPath` write a JSON report described by
  `schemas/v1/report.schema.json`, which now ships with the module; `Test-PSComplexity -SarifPath`
  writes a SARIF 2.1.0 log that GitHub code scanning renders against the diff.

  The report is the scan serialised, not a new shape. Two forms: a measurement report, and a gate
  report that adds the ceilings, the verdict, the breaches and every acceptance with its argument.
  A measurement report **cannot** carry a verdict -- the schema forbids `passed` without
  `thresholds`, because a command that applied no ceilings has no verdict to give. `metricVersion`,
  `scope` and `skipped` are required for the same reason: no number in the file can be read
  without what produced it and what it left out.

  SARIF raises one result per breached ceiling under two independently suppressible rule ids, and
  fingerprints on file and unit rather than on the line, which moves. An accepted unit raises
  nothing -- the gate excused it, and the JSON report is where that argument is recorded.

- **A number can be disagreed with: `Test-PSComplexity -Accept`.** The whole policy surface was
  two ceilings and a path, so the only answers to a unit that is genuinely, irreducibly complex
  were to lower the ceiling for everyone or stop measuring the file -- and the second is
  indistinguishable from never having looked. An acceptance names one unit, by file and unit
  together, and carries the argument for it.

  It is a **checkable claim, not a suppression**: the gate throws when one stops describing the
  run -- the unit was not measured, or is back within both ceilings, or carries no reason. A
  suppression that stops applying sits there excusing nothing while the next breach passes
  unnoticed; this fails the build that relies on it, on the run where it stopped being true.
  Every fault is reported at once rather than the first, and an accepted unit is still measured,
  because this is gate policy and not a measurement filter.

- **A score can say where it came from: `Measure-PSComplexity -Detailed`.** A unit reported as
  `Cognitive = 23` was correct and unactionable -- nothing distinguished one deeply-nested loop
  from twenty flat guards, and those call for opposite fixes. `-Detailed` attaches a
  `Contributions` list of `{ Line, Construct, Amount }` in line order, and the amounts **sum to
  the score**, asserted by a test -- which guards attribution, not scoring: both sides are
  computed from the same rows, so a row lost on the way to the list fails the check and a
  construct scored wrong does not. Confirmed in both directions rather than assumed. Read the amounts and not the
  count -- anything above `+1` is a structure plus the nesting charged for it, so the same total
  reached flat and reached nested look different and say different things. Default output is
  unchanged: no switch, no property, and the six published fields stay exactly as they were.

- **The README now says what the number does not say.** Two consequences of measuring per unit,
  written down as decisions rather than left to be discovered from the output and mistaken for
  bugs. The gate cannot tell decomposition from displacement: splitting identical control flow
  into helpers drops the maximum from 14/38 to 6/10 and the gate passes, and whether that made
  the code easier to read is a question the tool cannot answer. This module does the same thing
  to itself and now says so. And a nested named function contributes nothing to its parent where
  the same body as a script block contributes 3/5 -- a **deliberate departure from SonarSource**,
  which increments for nested declarations, recorded rather than left silent.

- **Every reference score is attributed to something outside this project.** The README claims
  the cognitive metric reproduces the SonarSource scores; the suite checked numbers the project
  had chosen itself, so a wrong interpretation would have had the suite agreeing with the bug --
  and the mutation gate agreeing too, because both only ever compare the code against itself.
  Each case now names its source: 11 taken from the specification, the PowerShell extensions the
  spec does not cover, and the vocabulary pins. A case added without attribution fails **by
  name**, so a number this project chose cannot sit among the reference scores looking like one
  of them -- including the two the specification calls the classic implementation errors, which
  are asserted by count as well as present.

- **Pinned dependencies are watched instead of only written down.** A weekly job checks each
  pinned module against the gallery and opens one tracking issue when any has moved on;
  Dependabot watches the action SHAs, which `pins.env` structurally cannot hold because `uses:`
  does not expand variables and a SHA cannot be read to learn whether something newer exists.
  A pin is a decision that was correct on the day it was made, and the failure is asymmetric --
  a stale pin never breaks the build, it just quietly stops protecting you. The PSMutant pin sat
  at 0.1.0 across two majors, one of which fixed a bug that scored **every** mutant killed, and
  CI was green throughout. An unreachable gallery is reported as **unknown** rather than as
  current, because a watcher that reads "could not look" as "nothing newer" has silently stopped
  being able to fail.


- **A scan says what it is reading.** `Measure-PSComplexity -Verbose` now names each file
  **before** parsing it, so a slow scan and a stuck one stop looking identical. The ordering is
  the feature: a line written afterwards names a file that is already finished, and a scan stuck
  on the next one would read exactly like a scan that completed. It matters because analysis is
  O(nodes x depth), so one deeply nested file can dominate a run -- and because
  `Test-PSComplexity` is the entry point people automate, so it runs against whole repositories
  where nobody is watching a terminal. The gate inherits it through the nested call; silent
  unless asked, because a gate that chatters by default gets its output filtered, and the filter
  takes the parse errors with it.


- **The construct vocabulary is closed against the parser.** The metrics recognise a
  hand-maintained allowlist spread over three places, and nothing compared it against what the
  parser can actually produce -- so a construct the module has never heard of contributed
  nothing and the unit containing it scored as straight-line code. The direction is what made
  it dangerous: an unrecognised construct can only lower a score, so the gate passed most
  easily on the code it understood least. Every one of the 66 concrete `Ast` types is now
  either handled by a metric or carries a written reason for not being; 42 exclusions, each
  with its argument. The next PowerShell release turns the suite red instead of quietly
  lowering everyone's numbers.


- **A score now says which metric produced it.** Records carry `MetricVersion`, an int that
  increments whenever a score can change for source that did not -- a narrower rule than the
  module version, so a fix that only affects messages, or a new field on the record, leaves it
  alone. It has already happened twice without being recorded: 0.3.0 taught the metric
  PowerShell's own flow constructs, and 0.4.0 stopped merging two units written on one line.
  Both were corrections, and both silently re-scored code nobody had touched. It starts at **1**
  with this release; earlier releases carry no version and are not comparable with these.
  Anything persisting or comparing scores should refuse to compare across two values rather than
  mix them -- which is what a committed baseline will need.

- The README's CI snippet now installs with **`-RequiredVersion`** rather than a floor. A gate
  decides whether a build passes, so without an exact version two machines on the same commit
  can legitimately disagree about whether it is green, and the one that upgraded first looks
  like the one that broke it.


- **The output record is now stated as the public contract and pinned by tests.** The five
  fields `Measure-PSComplexity` emits -- `File`, `Unit`, `Line`, `Cyclomatic`, `Cognitive` --
  are the module's API besides the two command names, and nothing asserted them, so adding,
  renaming or reordering one was a silent breaking change. Their names, order and types are
  now asserted exactly, for every record rather than the first; a sixth field fails the suite.
  Documented in the README and in `Get-Help`, including that `Line` is deliberately **not**
  an identity: it moves whenever anything above a unit is edited.

### Security

- `publish.yml` no longer interpolates the tag name into a PowerShell script. An Actions
  expression is pasted into the script as text before pwsh parses it, so a tag name
  containing a quote closed the string literal and ran as code -- in the one job holding
  the gallery API key. git accepts `v1.0";$x;"` as a ref name, and pushing a tag requires
  no review while pushing to main does. The name now arrives through an environment
  variable, which is read at run time and stays data whatever it contains.

### Internal

- The mutation gate moves from PSMutant 0.3.1 to **0.3.2**, so neither module gates on a
  version behind the one it ships beside. The score is unchanged; two of that release's
  guards -- a per-mutant budget shorter than the baseline suite, and a config path escaping
  the source root -- are inert here, because this config sets no timeout keys and no path
  leaves the root.

## [0.3.0] - 2026-08-22

### For consumers

BEHAVIOUR CHANGE - a gate that passed for you may now fail, in two unrelated ways, and both
are the point of the release. Read this before upgrading a pipeline you cannot watch.
FIRST, SCORES RISE for code that branches through PowerShell's own flow constructs.
ForEach-Object, Where-Object and their aliases, the && and || pipeline chains, and ?? and
??= were all measured as straight-line code, so a function branching only through them
reported cyclomatic 1 and cognitive 0. They are now scored as the loop, conditional, boolean
run and ternary they stand in for, and a pipeline body costs exactly what the keyword form
costs. Every SonarSource reference example still scores as published; the additions are
listed in the README with the rule each follows. If a unit sat just under your ceiling, it
may not any more.
SECOND, THE GATE NO LONGER REPORTS SUCCESS WITHOUT MEASURING ANYTHING, in three ways it
previously could. Scanning a directory without -Recurse resolved to zero files, so
Measure-PSComplexity ./src returned nothing for a folder full of code and Test-PSComplexity
./src -MaxCyclomatic 1 returned $true against units that all breached. A path containing [ or
] matched nothing, because -Path reads brackets as a wildcard character class, so a directory
named my[1]proj scored a confident, empty zero. And a file that failed to PARSE was skipped
with a warning and contributed no units, so a broken file passed the gate. Discovery now
filters on the file extension and resolves an existing path literally, Test-PSComplexity
throws rather than vouching for an empty selection, and it refuses a verdict when any file
could not be read. A pattern that names nothing on disk still falls through to wildcard
matching, so ./src/*.ps1 keeps working.
ALSO FIXED: naming one file by two inputs measured it twice and emitted every unit twice;
enum members with initialisers were reported as units, so an enum's complexity depended on
whether anyone numbered it; rows came back in hashtable order rather than source order, so
two runs over one unchanged file could differ; and Test-PSComplexity now accepts paths from
the pipeline, judging all of them rather than binding nothing.
WHAT TO DO: re-run against your codebase before upgrading and compare. A run that starts
failing after this upgrade is the honest one -- either it is measuring code it never opened
before, or it is scoring branches it could not previously see. Pin 0.2.0 if you need the
previous numbers exactly; every score here is greater than or equal to the one it produced.
### Changed
- **Scores rise for code that uses PowerShell's own flow constructs.** `ForEach-Object` and
  `Where-Object` (and the `%`, `?`, `foreach`, `where` aliases) now score as the loop and
  conditional they stand in for; `&&` and `||` as a boolean run, like `-and`/`-or`; `??` and
  `??=` as a ternary. Previously all of them scored as straight-line code, so a function
  branching only through them reported cyclomatic 1 / cognitive 0.

  Every SonarSource reference example still scores exactly as published. The metric is now
  described as implementing that specification **in full and extending it** for constructs
  the specification does not cover -- see the README table. If you need the specification's
  numbers and nothing more, pin `0.2.0`; every score here is greater than or equal to it.

### Fixed
- **`Test-PSComplexity` accepts paths from the pipeline**, and judges all of them.
  `Get-ChildItem ./modules | Test-PSComplexity` previously bound nothing at all; the command
  now collects every piped path and gates them together.
- **`OutputType` declares what a caller receives.** The streaming collectors claimed
  `[pscustomobject[]]` -- a single return value that is a collection -- where they emit
  records one at a time, and three `Ast.ps1` functions declared nothing.
- **A file that does not parse no longer passes the gate silently.** `Test-PSComplexity`
  now refuses to give a verdict when any file failed to parse: "no unit exceeded a ceiling"
  is trivially true of a file that produced no units, so a genuinely broken file used to
  score a pass. `Measure-PSComplexity` stays lenient -- it still returns every file it could
  read -- but reports the skip on the **error** stream rather than the warning stream, which
  CI logs routinely swallow.

  If you call `Measure-PSComplexity` with `$ErrorActionPreference = 'Stop'`, a file that
  fails to parse is now terminating where it previously warned. Pass
  `-ErrorAction SilentlyContinue` to keep the old behaviour, or `-ErrorVariable` to inspect
  what was skipped.
- **Rows are emitted in source order.** They came back in .NET hashtable order, which follows
  bucket layout rather than insertion or line position and is not required to be stable, so
  two runs over one unchanged file could differ. Units within a file now sort by start line,
  with the unit name breaking a same-line tie.
- **A file named by two inputs is measured once.** Passing a directory and a file inside it
  emitted every unit of that file twice, doubling its contribution to anything that counts
  rows. Deduplicated on the resolved path, case-insensitively.
- **Enum members are no longer reported as units.** An initialised member (`Red = 1`) is a
  `PropertyMemberAst` with a value, exactly like a class property, so it became a unit while
  a bare `Green` did not -- an enum's complexity depended on whether anyone numbered it.
- **A directory scanned without `-Recurse` measured nothing at all, and the gate passed.**
  `-Include` is ignored for a directory unless `-Recurse` is also given, so
  `Measure-PSComplexity ./src` returned zero units for a folder full of code and
  `Test-PSComplexity ./src -MaxCyclomatic 1 -MaxCognitive 1` returned `$true` against 27
  units that all breached. Discovery now filters on the file extension instead.
- **A path containing `[` or `]` matched nothing.** `-Path` treats brackets as a wildcard
  character class, so a real directory named `my[1]proj` scored a confident, empty zero. An
  existing path is now resolved literally; a path that names nothing on disk still falls
  through to wildcard matching, so patterns like `./src/*.ps1` keep working.
- **`Test-PSComplexity` returned `$true` after measuring nothing.** A gate pointed at a path
  with no PowerShell under it gave the same answer as a gate over code that was entirely
  within its ceilings, and nothing distinguished the two. It now throws, naming the path,
  and suggests `-Recurse` only when `-Recurse` was not given.
- The test that pinned non-recursive scanning asserted only that the nested unit was
  absent, which is equally true when discovery finds nothing -- so it certified the bug
  instead of catching it. It now asserts the flat unit is present in the same call.

### Added
- CI self-assessment: the **PSMutant** module mutation-tests PSComplexity's own metric
  logic against its reference-score suite, gated on the mutation score (~90%). The two
  Fortigi modules dogfood each other -- PSComplexity gates PSMutant's complexity, and
  PSMutant gates PSComplexity's test quality.
- The self-mutation gate is now set at **100%**: every mutant is killed, with none declared
  equivalent. From here a new survivor fails the build. (The count is deliberately not
  quoted: it moves with every operator change and a hand-maintained figure goes stale
  silently -- the gate prints it.)

### Fixed
- Top-level script code -- decisions and calls outside any function -- is now covered by
  tests. Both "no enclosing function" fallbacks in the AST layer were previously
  unreachable by the suite, because every fixture wrapped its logic in a function.
- A ternary's cyclomatic increment, the script body's reported start line, the parse-error
  message shown when a file is skipped, and the file-vs-directory filter in source
  discovery are all pinned; each could previously be changed without a test noticing.

### Internal
- Documentation claims the code does not support are corrected, each verified by running it
  rather than by reading: load order is inert, the emitted `File` is absolute, and the
  shipped `Get-Help` synopsis omitted class members for two releases. The self-complexity
  gate now calls the shipped `Test-PSComplexity` instead of re-deriving the comparison.
- **Every gate that judges a test run now checks that each test file actually ran.** A file
  with a parse error contributes zero tests and zero failures, so a run reported
  "passed / 0 failed" while an entire file never executed -- and each gate asked only about
  the failure count.
- The test estate moves to **Pester 6.1.0**, pinned in `ci.yml` and `publish.yml`, and every
  step now imports it with `-RequiredVersion` rather than letting the name resolve -- an
  unimported pin documents an intention, it does not enforce one.
- `tools/Test-PSCxPesterCompatibility.ps1` proves a **Pester 5** consumer can still gate on
  this module. The module has no Pester dependency, so the promise is cheap to keep and was
  previously not checked at all.
- The mutation-gate step moves from PSMutant 0.1.0 to 0.3.1.
- One committed analyzer script, `tools/Invoke-PSCxAnalyzer.ps1`, is now what all three
  gates run. They had three separate inline copies, and two of them filtered to Error and
  Warning while the required code-scanning check did not -- so an Information-severity
  finding failed nothing and blocked everything.
- Pinned versions move to `.github/pins.env`, loaded and asserted by each workflow.
  `ConvertToSARIF` had no version pin at all.
- Every workflow now declares a `concurrency` group, a `timeout-minutes` and a
  least-privilege `permissions` block, and pinned modules are cached. `publish.yml`
  deliberately does **not** cancel in progress: a half-finished publish is a gallery
  version that cannot be withdrawn.
- The publish path now requires the merge gate to have passed for the exact commit being
  released, on **both** matrix legs, and loads the staged package before pushing it:
  `tools/Test-PSCxPackage.ps1` imports it in a fresh process, measures a fixture, requires
  the gate to fail a strict ceiling, and requires it to refuse a path it measured nothing
  under.
- A coverage gate: `tools/Measure-PSCxCoverage.ps1`, enforced at 100% in CI. The figure was
  claimed in two places and measured by nobody, and the command count quoted in this file
  had been wrong for two releases.
- The suite is fully on the Pester 6 `Should-*` assertions, and `Should.DisableV5 = $true` is
  set in both workflows so the classic `Should -Be` form is an **error** rather than a style
  note. Verified that the setting actually fires, in both directions.
- The fixture inside `tools/Test-PSCxPesterCompatibility.ps1` deliberately keeps the classic
  syntax: it executes under Pester 5, where the `Should-*` commands do not exist.
- **The self-mutation gate now runs the three opt-in operators PSMutant runs on itself** --
  `ConditionalBoundary`, `ConditionForcing` and `ReturnValue`. The mutant count goes from 54
  to 122, and the previous 100% turns out to have covered less than half of what is
  reachable. Six survivors appeared immediately, every one of them structural logic the
  expression-only set could not see.
- Assertions over collections are exact counts rather than "at least one". Verified against a
  deliberately injected duplicate-row defect: six tests catch it that all passed before.

## [0.2.0] - 2026-08-19
### Added
- PowerShell class members are measured as units, reported as `Class.Member`. See the
  manifest release notes for the full entry; this heading was missing when 0.2.0 shipped.

## [0.1.0] - 2026-07-03
### Added
- `Measure-PSComplexity` - per-unit cyclomatic and cognitive complexity via the
  PowerShell AST (each function/filter, plus one `<script-body>` per file).
- `Test-PSComplexity` - CI gate returning `$false` (with a warning per offender) when
  any unit exceeds the cyclomatic or cognitive ceiling.
- Faithful SonarSource **cognitive** complexity: nesting-aware, boolean-run and
  labelled-jump and recursion increments, validated against reference scores
  (prime sieve = 7, switch = 1, recursive fibonacci = 3, `a -and b -or c` = 3).
- Cross-platform CI (Windows + Linux), PSScriptAnalyzer lint gate, self-complexity
  gate (the tool measures itself), code scanning, and a full-gated publish workflow.
