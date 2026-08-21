# Changelog

All notable changes to PSComplexity are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow SemVer.

## [Unreleased]

## [0.2.1] - 2026-08-21
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
