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
| Lint | `tools/Invoke-PSCxAnalyzer.ps1` — **every severity**, and it throws. The same script code scanning and publish run |
| Unit tests | whole `tests/` directory, 0 failures |
| Order independence | `tools/Test-PSCxOrderIndependence.ps1` -- the same suite again, reversed, plus an environment comparison |
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
src/Policy.ps1                 which units are excused from the ceilings, and on what terms:
                               acceptances, baselines, and the ONE unit-identity key both use.
                               Pure.
src/BaselineFile.ps1           the baseline file: read it, refuse it, write it back. The I/O
                               half of the policy, kept apart so the deciding half stays pure.
src/Measure-PSComplexity.ps1   the scan -- measurement as data -- and the two public
                               projections over it: Measure-PSComplexity, Test-PSComplexity.
src/Report.ps1                 the two published formats -- our JSON report and SARIF -- and
                               the two functions that touch a file.
schemas/v1/report.schema.json  the report format. Ships in the package; a consumer validates
                               against it without reading this repo.
```

**A covering suite must be CHEAP, not only complete, and the cost is measured rather than
guessed.** Every mutant of a file re-runs that file's covering suite, so the gate costs
*mutants x suite*. `tests/Measure.Tests.ps1` takes 18 seconds because it measures real source,
and that is the right price for what it proves -- but it is the wrong price to pay 100+ times.

That is why `src/Policy.ps1` and `src/BaselineFile.ps1` exist as separate files with their own
suites rather than sitting in `Measure-PSComplexity.ps1`. Measured, not assumed: Policy's 125
mutants cost **19 minutes** against the measuring suite and **59 seconds** against a pure one,
and moving the two baseline-file functions out took another eight minutes off. The end-to-end
proofs did not move -- `Measure.Tests.ps1` still drives all of it through `Test-PSComplexity`,
because covering a function is not covering its application and neither gate can tell the
difference. They are simply not what each mutant pays for.

Before adding a file to `mutate`, run it alone with a scratch config and look at the seconds. The
whole gate has to fit inside a 40-minute CI job alongside everything else, and it reached 34
minutes once during this work.

**A `_`-prefixed comment key is exempt only at the TOP level of the config.** Inside the `tests`
object it is read as a mutate path, and the run dies looking for a file named after your comment.
Found the hard way.

**The mutation config maps each source file to specific test files.** `src/Cyclomatic.ps1`
maps only to `tests/Cyclomatic.Tests.ps1`; `src/Ast.ps1` maps to the Cognitive and Measure
suites. A test placed in the wrong file covers the code but **cannot kill its mutants**,
which has already happened once here — a ternary case landed in `Measure.Tests.ps1` and
the mutant survived a test that exercised it. Check `psmutant.self.config.json` before
choosing where a test goes.

**`Policy.ps1` holds acceptance and baseline together because they share a key.** An acceptance
is a *decision* -- a written argument that excuses a unit outright. A baseline is a *ratchet* --
no argument, caps a unit at what it already scored, and exists so the gate is adoptable on a
codebase that is already red. Different promises, so they fail differently. What they must never
differ on is what "the same unit" means: two key builders would each be right on their own terms
and disagree in exactly the case nobody tests.

That key is `Get-PSCxPolicyKey`, and it is **not** `Get-PSCxUnitKey` in `Ast.ps1`, which keys an
AST node during a walk. The two collided when this file was split out -- the module loaded and
every measurement failed -- so if you add a third key, check the name first.

**Unit identity is unique but not stable, and only the baseline cares.** Duplicate definitions in
one file are told apart by an ordinal (`Get-Thing#1`, `#2`), which renumbers when a duplicate is
inserted above it -- measured: inserting a third `Get-Thing` at the top moves the unit that was
`#1` to `#2`, and `#1` then names a function nobody recorded. An acceptance keyed that way is
re-read by whoever edits the file; a baseline is committed once and reviewed rarely, so a baseline
entry with an ordinal in it is **refused** rather than approximated. A line number is no better
and worse in the ordinary case, where it churns on every edit above the unit.

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

- **A published format makes the dangerous shape unrepresentable, not merely undocumented.**
  `schemas/v1/report.schema.json` forbids `passed` unless `thresholds` are present, so a
  measurement report cannot carry a verdict nobody computed; and it requires `metricVersion`,
  `scope` and `skipped`, so no number in it can be read without what it excluded. Copied from
  the sibling project, which forbids a mutation score in a recheck report for the same reason.

  Four traps come with it, all already paid for elsewhere. **Validate the FILE, not a parsed
  object** -- `ConvertFrom-Json` re-types the ISO-8601 `generatedAt` into a `[datetime]`.
  **`Test-Json` silently ignores `not`**, so a forbidden property is written as
  `"passed": false` in a `properties` block; the obvious spelling is a rule that can never
  fire. **Prefer a type union to `oneOf`**, which reports a failure in every branch. And
  **`additionalProperties` stays true** for the report, because `schemaVersion` moves only when
  a field changes meaning or disappears -- the exact field list is pinned in a test instead, so
  widening is a decision rather than a side effect.

  **A data file the tests read must be in `sandboxSubtrees`.** The mutation sandbox copies only
  what that list names, so `schemas` is there beside `src` and `tests`. Leave it out and the
  baseline goes red before a single mutant is tried, with an error naming a missing path rather
  than the missing subtree -- which is a long way from the cause.

  **`ConvertTo-Json` truncates past its depth SILENTLY**, leaving valid JSON with a .NET type
  name where a value belongs. That shipped here once: every SARIF location read
  `System.Collections.Specialized.OrderedDictionary`. `Save-PSCxDocument` now refuses to write a
  document containing such a marker, because raising the depth fixes today's document and the
  next nested field reintroduces it.

- **A new file-to-file edge in `src/` is a decision, and `tests/Layering.Tests.ps1` makes you
  make it.** Every other gate is blind to DIRECTION: a shortcut call from `Report.ps1` back into
  `Ast.ps1` reaches full coverage and survives self-mutation exactly as a well-layered one does.
  The graph is acyclic because nobody has added a shortcut, not because anything caught one.

  The allowlist holds one entry per file-to-file **relationship**, not per call site, so adding a
  call between files that already have an edge is free and adding the first is deliberate. It
  fails in **both** directions -- an undeclared edge fails, and so does a declared edge the code
  no longer has, because a list describing dropped relationships is one nobody can trust and it
  silently readmits an edge later. It also asserts the graph is **acyclic**, which the allowlist
  alone cannot give: two edges each reasonable on their own review make a cycle between them, and
  nobody reviewing the second is looking at the first.

  Two directions are design decisions rather than bookkeeping. `Ast.ps1` is the shared foundation
  and knows nothing about metrics; `Report.ps1` is a **sink**, asserted separately, because a
  serialiser that reached back into measurement would be deciding what a number MEANS while
  claiming only to write it down.

  This file was deliberately not written earlier. With no interior node a cycle was unreachable
  and an allowlist would have been ceremony; `ROADMAP.md` recorded the condition for revisiting
  and `src/Report.ps1` met it. Writing it while the edges are few and obviously correct is the
  cheap moment -- ratifying a graph nobody remembers agreeing to is the expensive one.

  There is no "one Write-Host" assertion like the sibling's, and that is deliberate:
  `PSAvoidUsingWriteHost` is not excluded here, so PSScriptAnalyzer already fails the build. A
  second gate over the same property is one more thing to keep in step for no extra coverage.

- **One committed analyzer script, and running it IS passing it.** All three callers -- the
  lint step in `ci.yml`, the same check in `publish.yml`, and the required `code-scanning.yml`
  -- run `tools/Invoke-PSCxAnalyzer.ps1`, so they cannot analyse different paths, different
  settings or, as they did until #19, different severities. There is **no `-Severity` filter**:
  rules are excluded by name in `PSScriptAnalyzerSettings.psd1`, with a reason, where a severity
  filter mutes a whole band nobody decided about.

  **It throws on a finding**, so the exit code is the answer. It did not always: it returned
  findings and exited 0 either way, the verdict lived in two workflow steps, and running it by
  hand was therefore not the same as passing it. `-PassThru` returns the findings without
  failing, for code scanning, which uploads them rather than gating on them -- an empty set
  there is a meaningful upload that clears alerts for rules already fixed. The decision itself
  is `Get-PSCxLintFault` in `ReleaseDecisions.ps1`, with tests, like every other gate decision.

  **`Write-Output`, never `Write-Host`, in `tools/`.** `PSAvoidUsingWriteHost` is not excluded
  here and every other script in `tools/` prints that way. The sibling project made the opposite
  choice -- it excludes the rule because its gate scripts print for a living -- so this is the
  one part of its design not to copy across. Porting it failed this gate on its own first run.

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

- **The suite runs in two orders here, and both are checked.** `Invoke-Pester ./tests` discovers
  files alphabetically; the mutation baseline runs the mapped covering suites in the order
  `psmutant.self.config.json` lists them. Those orders differ, so a developer running the suite by
  hand and the gate running it never see the same sequence -- and an order-dependent suite is green
  in one and red in the other. That is not hypothetical: the sibling spent three CI rounds finding
  a variable one file cleared in an `AfterEach` and never restored.

  `tools/Test-PSCxOrderIndependence.ps1` runs the suite **reversed** and compares the environment
  before and after. The two halves fail on opposite ends of the same problem, which is why both are
  there: the reversed run catches a dependency by its **symptom** and is a probe rather than a
  proof -- one more permutation, not all of them -- while the environment comparison catches the
  **cause** and is direction-blind, firing on the file that leaks whether or not anything reads it
  yet. Only the second half would have caught the sibling's instance.

  **Two other kinds of state were tried and rejected, and the measurements are in the script.** The
  working directory cannot fire, because Pester restores it around a run -- verified with a test
  that wanders off with `Set-Location` and still leaves the location unchanged. Global variables
  fire on a *clean* suite, because Pester promotes every `-ForEach` case table to global scope, so
  keeping them would mean an allowlist that grows with the tests it is watching. A check that
  cannot fire and a check that always fires are the same defect wearing different clothes; neither
  was written and left in.

  The failure message names keys and **never values**. An environment variable holds tokens as
  often as it holds flags, and this message is printed into a build log anyone can read.

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

- **Anything the module says about itself is a claim someone should be able to check** (#28).
  Five statements in the docs are not true of the code, two of them provably: load order is
  inert, and the closure requirement above. Prefer a test to a sentence wherever one is
  possible.
