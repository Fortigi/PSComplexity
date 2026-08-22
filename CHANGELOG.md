# Changelog

All notable changes to PSComplexity are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

## [0.2.1] - 2026-08-21

### For consumers

FIXED - this release fixes two separate ways the gate reported success without measuring
anything, and if either affected you, your builds have been passing on evidence that was
never gathered. First: scanning a DIRECTORY without -Recurse resolved to zero files.
-Include is ignored for a directory unless -Recurse is also given, so Measure-PSComplexity
./src returned nothing for a folder full of code, and Test-PSComplexity ./src
-MaxCyclomatic 1 returned $true against units that all breached. Second: a path containing
[ or ] matched nothing, because -Path reads brackets as a wildcard character class, so a
real directory named my[1]proj scored a confident, empty zero. Discovery now filters on the
file extension and resolves an existing path literally; a pattern that names nothing on
disk still falls through to wildcard matching, so ./src/*.ps1 keeps working. AND, so that
neither can be silent again, Test-PSComplexity now THROWS when it measured no units instead
of returning $true - nothing breached a ceiling and nothing was measured must never be the
same answer. WHAT TO DO: if you gate a flat directory, re-run before upgrading and compare.
A run that starts failing after this upgrade is the honest one.

### Fixed
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
- The self-mutation gate is now set at **100%**: coverage is 100% (167/167 commands) and
  every one of the 41 mutants is killed, with no mutant declared equivalent. From here a
  new survivor fails the build.

### Fixed
- Top-level script code -- decisions and calls outside any function -- is now covered by
  tests. Both "no enclosing function" fallbacks in the AST layer were previously
  unreachable by the suite, because every fixture wrapped its logic in a function.
- A ternary's cyclomatic increment, the script body's reported start line, the parse-error
  message shown when a file is skipped, and the file-vs-directory filter in source
  discovery are all pinned; each could previously be changed without a test noticing.

### Internal
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
