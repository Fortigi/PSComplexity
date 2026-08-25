# PSComplexity — AI Assistant Development Guide

Cyclomatic and cognitive complexity for PowerShell, computed from the AST. Cognitive
complexity **implements the SonarSource metric in full, and extends it for PowerShell
constructs the specification does not cover** -- `ForEach-Object`, `Where-Object`, `&&`,
`||`, `??` -- each scored by the rule it most resembles. Every reference example still scores
exactly as published. This used to say "a faithful port"; that was accurate before the
extensions and is not now, and the README lists them. Ships `Measure-PSComplexity` (data) and `Test-PSComplexity` (CI gate).
Published to the PowerShell Gallery.

---

## The rule that matters most here

> **This is a code-quality tool, so its own numbers are the product. PSComplexity must
> hold itself to 100% line coverage and 100% self-mutation, and must pass its own
> complexity gate.**

A tool that fails a build for complexity has no standing if its own units are over the
ceiling, and a metric nobody has fault-tested is just arithmetic nobody has checked.
`psmutant.self.config.json` sets `thresholds.break` to **100**, and
`tests/SelfComplexity.Tests.ps1` runs the gate against `src/`.

Current state: **100% line coverage, 100% self-mutation, gate passes.** Keep it there —
a change that drops any of the three is not finished.

---

## Gates

CI (`.github/workflows/ci.yml`) runs:

| Gate | What it is |
|---|---|
| Lint | PSScriptAnalyzer, `-Severity Error, Warning` |
| Unit tests | whole `tests/` directory, 0 failures |
| Complexity | **its own** `Test-PSComplexity` against `src/`, 15 / 15 per unit |
| Self-mutation | PSMutant against `psmutant.self.config.json`, break = 100 |

Coverage is measured by one committed script, and it is enforced:

```powershell
./tools/Measure-PSCxCoverage.ps1        # fails below 100%
```

It is a script rather than a recipe in this file because a recipe cannot be run by CI: the
figures here were a claim nobody checked, and the count quoted in `CHANGELOG.md` had been
wrong for two releases. Do not quote a command count in prose — the script prints it.

`UseBreakpoints` is set as a **hedge, not a fix**. In PSMutant it is load-bearing, because a
nested Pester run tears down Pester 6's Profiler tracer and every file discovered afterwards
reports a plausible near-zero. Measured here both ways on the same suite, the two agree
exactly, because nothing in `tests/` starts a nested run. The setting costs a little speed
and means a future test that does start one cannot quietly halve the number.

**Pester version split**: CI pins 5.8.0, development happens on 6.1.0. This suite passes
under both. Tracked in **#10**.

---

## Layout

```
src/Ast.ps1                    unit discovery, attribution, nesting depth. Shared.
src/Cyclomatic.ps1             decision-point counting.
src/Cognitive.ps1              the SonarSource metric (B1 structural, B2 nesting, B3 level).
src/Measure-PSComplexity.ps1   the scan -- measurement as data -- and the two public
                               projections over it: Measure-PSComplexity, Test-PSComplexity.
```

**The mutation config maps each source file to specific test files.** `src/Cyclomatic.ps1`
maps only to `tests/Cyclomatic.Tests.ps1`; `src/Ast.ps1` maps to the Cognitive and Measure
suites. A test placed in the wrong file covers the code but **cannot kill its mutants**,
which has already happened once here — a ternary case landed in `Measure.Tests.ps1` and
the mutant survived a test that exercised it. Check `psmutant.self.config.json` before
choosing where a test goes.

## What a "unit" is

A unit is anything with a body that gets gated on its own: a function/filter, a class
method or constructor, an initialised class property, plus one synthetic `<script-body>`
per file. Class members report as `Class.Member@line`.

Two subtleties worth knowing before touching `Ast.ps1`:

- A class method's body is **itself** a `FunctionDefinitionAst`, nested inside the
  `FunctionMemberAst`. Both are body-owners, so they must resolve to the member or the
  same method is discovered twice — once unqualified.
- Do **not** use `.GetNewClosure()` on a predicate that references a `$script:` variable.
  A closure built inside a function loses the module scope and the variable comes back
  empty. The per-type loops in `Cyclomatic.ps1`/`Cognitive.ps1` *do* need their closure —
  they capture a local loop variable. Opposite requirements, a few lines apart.

## Conventions

- Branches: `feature/<name>` or `bugfixes/<name>`, PR into `main`. One issue per branch.
- **Version**: bump `ModuleVersion` in `PSComplexity.psd1` in the PR; `publish.yml`
  refuses to publish when the git tag and `ModuleVersion` disagree. Update `ReleaseNotes`
  in the same edit.
- **ASCII only** in `src/` and `tests/` — non-ASCII without a BOM trips
  `PSUseBOMForUnicodeEncodedFile` and fails lint.
- Reference scores are the contract: `tests/Cognitive.Tests.ps1` pins the SonarSource
  examples (prime sieve = 7, plain switch = 1, recursive fibonacci = 3,
  `if (a -and b -or c)` = 3). If a change moves one of those, the change is wrong until
  proven otherwise.

---

## Practices to preserve

Habits this repo already has. They are written down because they are cheap to lose in a hurry
and expensive to rebuild, and because each one has already earned its keep.

- **An acceptance is a checkable claim, and there must never be a plain suppression beside
  it.** `-Accept` names one unit by file AND unit, carries a written argument, and the gate
  THROWS when the claim stops describing the run: no such unit measured, the unit back within
  both ceilings, or no reason given. The value is entirely in the failure -- a suppression that
  stops applying sits there excusing nothing while the next breach of that unit passes
  unnoticed, which is how every suppression list ages into a mute button nobody dares delete.

  Two design points that are easy to undo. The gate **throws** rather than returning `$false`,
  because a stale acceptance is a fault in the policy and not a complaint about the code --
  returning `$false` sends someone to refactor a unit that is fine. And an accepted unit is
  still **measured**: this is gate policy, not a measurement filter, so a report or a baseline
  built on the same records still sees the unit and its number.

  There is deliberately no ambiguity arm, unlike the sibling project's equivalence
  declarations. A unit identity is unique within a file, so an exact File+Unit match is one or
  none by construction, and a rule that cannot fire looks exactly like a rule that passes. If
  unit identity ever stops being unique, that is the moment to add one.

- **The scan is the measurement; the published output is a projection of it.** `Get-PSCxScan`
  returns what was asked for, which units were found, and which files were skipped and why.
  `Measure-PSComplexity` renders the units to the pipeline and each skip to the error stream;
  `Test-PSComplexity` reads the skips as data. Both walk once, through `Get-PSCxPathScan`,
  which streams per-file scans so the streaming command does not have to buffer a tree to
  share the aggregate.

  Facts about the RUN have nowhere else to live, and a fact that exists only on the error
  stream has to be rebuilt by whoever needs it. The gate used to capture its own module's
  errors with `-ErrorAction SilentlyContinue` -- which swallowed every OTHER error into the
  same variable, so a parameter-binding failure reached the user described as a file that did
  not parse. That was observed during the change that introduced this, not imagined.

  It is the same shape as the rows underneath: emit the rich thing once, project it. A
  consumer that needs run-level facts extends the scan rather than inventing a second shape,
  which is what stops the first one shipped becoming the contract by accident. It is
  deliberately **internal** until something publishes it; when that happens, the cost to weigh
  is that one command would then have two output shapes, and a `| Where-Object` written
  against the record stream returns nothing under the other one.

- **The reference scores are the contract, not examples.** `tests/Cognitive.Tests.ps1` pins the
  SonarSource cases -- prime sieve 7, plain switch 1, recursive fibonacci 3,
  `if (a -and b -or c)` 3. If a change moves one of those, the change is wrong until proven
  otherwise. All eleven reference cases currently pass, including both of the ones the
  specification calls the classic implementation error.

  That is a claim about the SPECIFICATION's cases only. The metric also increments for
  constructs the specification does not cover -- `ForEach-Object`, `Where-Object`, `&&`,
  `||`, `??` -- which are listed in the README with the rule each is scored by. Those cases
  are pinned in the same file and are equally contractual; the difference is that moving one
  of them is a decision about PowerShell, while moving a reference case is a bug.

- **A test has to live in the file the mutation config maps to.** `psmutant.self.config.json`
  maps each source file to specific test files. A test in the wrong file covers the code and
  **cannot kill its mutants** -- that has already happened here once, with a ternary case that
  landed in `Measure.Tests.ps1` and left a mutant alive. Check the mapping before choosing
  where a test goes.

- **`Test-PSComplexity` is a thin predicate over `Measure-PSComplexity`, and should stay one.**
  It duplicates no measurement and re-parses nothing. The temptation is to make it return
  violation objects instead of a bool; resist it. Nothing in the backlog routes through it --
  the queued features all build over `Measure-PSComplexity`'s records. What is missing is a
  scan noun, not a richer verdict.

- **`Ast.ps1` is a layer, not a shared-helpers bucket.** Every function in it answers one
  question: what the parent chain looks like relative to a unit boundary. That is why
  `Get-PSCxNesting` belongs there even though only `Cognitive.ps1` calls it -- placement
  follows what a function consults, not who calls it.

- **Nothing in `src/` swallows an error.** There is no `try`, and no
  `-ErrorAction SilentlyContinue`. Keep it that way: the failure this project exists to catch
  is a number that was never measured being reported as a number that was, and a swallowed
  error is how that happens.

- **`.GetNewClosure()` on a predicate that reads a `$script:` variable breaks it silently.**
  A closure built inside a function loses module scope and the variable comes back empty --
  verified: adding it to `$isBodyOwner` in `Get-PSCxUnitTable` makes every function and method
  vanish, the gate returns `True`, and **no error is raised**. The suite does catch it.

  *The other half of what this file used to say is not true.* The per-type loops in
  `Cyclomatic.ps1` and `Cognitive.ps1` were documented as requiring their closure. Stripping it
  from both gives byte-identical output over 164 units and a green suite under two Pester
  versions. That negative was itself checked for vacuity -- renaming the loop variable so `$tn`
  is genuinely unresolvable collapses the score and breaks ten tests -- so the fixture does
  discriminate and the result means what it says.

## Practices to adopt

Gaps, stated as rules rather than as a backlog. Each points at its issue, and moves up to the
list above in the PR that closes it.

- **Discovery must be proven, not assumed** (#29, #34). `-Include` without `-Recurse` matches
  nothing, and `-Path` wildcard-parses a `[` in a directory name -- so a flat `./src` can
  measure zero files and report success. The test that should have caught it asserts only an
  absence and passes vacuously. When a test pins "X is excluded", it must also assert that
  something else was **included** in the same call, or it certifies whatever the code happens
  to do.

- **A gate must refuse to measure nothing** (#15). "No unit exceeded a ceiling" and "no unit
  existed" must never produce the same answer. `tests/SelfComplexity.Tests.ps1` already guards
  this before calling the gate, which is the tell: the check exists, in the test, rather than
  in the command every consumer calls.

- **A number that anyone persists needs a version** (#20). Scores already moved once under a
  minor bump with nothing recording it. A committed baseline compares two runs, so an
  unversioned metric re-baselines everything at once on upgrade -- silently.

- **An identity has to survive a commit and a machine** (#14). `Unit` is stable and not unique;
  `Unit` + `Line` is unique and moves whenever anything above it is edited; `File` is absolute
  and platform-separated while CI runs two OSes. Any feature that persists or compares records
  needs an identity with neither property.

- **The construct vocabulary must be pinned from both directions** (#32, #18). Nothing notices
  when PowerShell gains syntax the metric cannot see, and 5 of 7 cyclomatic types and 4 of 8
  cognitive types can be **deleted** with the suite still green. An unrecognised construct can
  only lower a score, so the gate passes most easily on the code it understands least.

- **Every gate is a committed script, not a snippet in a document** (#27). Coverage is claimed
  at 100% in this file and measured by nobody -- the recipe lives in prose, so measuring by
  hand and measuring in CI cannot even be compared. Hand-maintained figures in this repo have
  already drifted.

- **One analyzer invocation, called by both gates** (#19). The failing lint gate filters to
  Error and Warning over four paths; the required code-scanning check has no filter and scans
  everything. A finding in the gap is invisible to the gate that fails and visible to the one
  that blocks.

- **Anything the module says about itself is a claim someone should be able to check** (#28).
  Five statements in the docs are not true of the code, two of them provably: load order is
  inert, and the closure requirement above. Prefer a test to a sentence wherever one is
  possible.
