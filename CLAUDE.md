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
| CI parity | `tools/Test-PSCxCiParity.ps1` — the capabilities this repo and PSMutant both promise, checked over `.github/workflows/` |
| PowerShell compatibility | `tools/Test-PSCxPowerShellCompatibility.ps1` — one leg per supported minor, 7.0 upward. Linux only |
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

**Pester version split**: the suite is written for and tested against **6.1.0**, which is what
`.github/pins.env` sets as `PESTER_VERSION` and what CI and `publish.yml` both run. It uses the
`Should-Be` assertion family, so it does not run on Pester 5 at all.

That is a statement about this repo's OWN suite, not about what a consumer needs. **PSComplexity
is usable from Pester >= 5.0.0**: it is an ordinary module with two commands, and a consumer
gating on it does so from inside their own Pester run, which is not this one.
`tools/Test-PSCxPesterCompatibility.ps1` proves that separately against every version in
`PESTER_COMPAT_VERSIONS`, which is why several other Pesters are installed in CI -- it separates
"this Pester cannot run OUR suite" from "this module is broken for a Pester 5 consumer".

**The tested range is now the supported range**: one leg per minor from **5.0.0 to 6.1.0**, twelve
in all, about four seconds each. It used to be one version, 5.7.1, and the floor the manifest
promises had never once been executed.

**One leg per MINOR, and the middle is not interpolation.** Floor-plus-latest was the first plan
and is not enough: `New-PesterConfiguration` arrived in 5.1.0, which is invisible at both ends of
the range and fatal in between. Anything landing mid-range has that shape. `5.0.0` exactly rather
than the newest 5.0.x, because the floor is the number consumers are told.

**Pointed at 5.0.0, the old gate said the module was broken -- and it was the gate.** It built its
configuration with `New-PesterConfiguration`, so under 5.0.0 the command was missing, PowerShell
autoloaded a newer Pester by name, and the assemblies collided; the error named versions and never
mentioned this module. It now invokes through `Invoke-Pester -Path <file> -PassThru`, the oldest
surface Pester 5 has and identical on every version through 6.1.0 -- which is also what a consumer
writes, so the gate exercises the path it describes.

**A control that THROWS is an environment failure and must be caught as one.** The control exists
to tell "this Pester cannot run here" from "this module is broken", and the script reported that
correctly whenever the control *returned*. A throw went straight past it to the generic exit-code
check, which blames the module for any non-zero exit. Guard the call, not just its result.

Every leg is tried and every fault collected rather than stopping at the first, and an empty list
is refused: a compatibility gate over zero versions passes every time. A test asserts a leg exists
for every minor in the range, so narrowing the promise by deleting one fails the suite.

This entry read "CI pins 5.8.0, development happens on 6.1.0" -- the two the wrong way round,
and a version that is pinned nowhere. Tracked in **#10**.

---

## Layout

```
src/Ast.ps1                    unit discovery, attribution, nesting depth. Shared. Pure: it
                               parses and walks, and never touches a disk -- which is what lets
                               tests/Ast.Tests.ps1 cover it in two seconds.
src/Cyclomatic.ps1             decision-point counting.
src/Cognitive.ps1              the SonarSource metric (B1 structural, B2 nesting, B3 level).
src/Policy.ps1                 which units are excused from the ceilings, and on what terms:
                               acceptances, baselines, and the ONE unit-identity key both use.
                               Pure.
src/BaselineFile.ps1           the baseline file: read it, refuse it, write it back. The I/O
                               half of the policy, kept apart so the deciding half stays pure.
src/Scan.ps1                   the scan: paths in, measured units out, as data. Owns the
                               metric version, and is the only file that talks to all three
                               metric files.
src/Measure-PSComplexity.ps1   the two public projections over the scan: Measure-PSComplexity
                               and Test-PSComplexity. Wiring, and nothing else.
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
suites rather than sitting in `Measure-PSComplexity.ps1`, and why `src/Ast.ps1` has
`tests/Ast.Tests.ps1`. Measured, not assumed: Policy's 125 mutants cost **19 minutes** against the
measuring suite and **59 seconds** against a pure one; moving the two baseline-file functions out
took another eight minutes off; and Ast's 57 mutants went from **~22s each** -- it was mapped to
*two* suites and paid for both -- to a suite that runs in 2 seconds.

**The obvious cheaper fix for Ast was tried first and is provably wrong, which is worth knowing
before anyone proposes it again.** Simply dropping the second suite gives 84% and **50** mutants
where there were 57: with fewer covered lines, `coveredLinesOnly` produces fewer candidates. A
smaller set scoring the same is precisely the failure this project exists to find in other people's
code. So the acceptance test for moving a file to a cheaper suite is **two** numbers, not one --
the same mutant COUNT and the same verdicts. A score alone cannot tell the two apart.

The eight mutants only the expensive suite had been killing were all in the naming and identity
functions, which the cheap sibling suite never exercised because it tests scores rather than names.
That is the general shape: when one suite covers something only incidentally, moving to a cheaper
one means writing the assertions that were never written. The end-to-end
proofs did not move -- `Measure.Tests.ps1` still drives all of it through `Test-PSComplexity`,
because covering a function is not covering its application and neither gate can tell the
difference. They are simply not what each mutant pays for.

Before adding a file to `mutate`, run it alone with a scratch config and look at the seconds. The
whole gate has to fit inside its CI job alongside everything else, and it reached 34 minutes once
during this work.

**Profile before choosing which half to make cheaper.** The obvious reading of an 18-second suite
is that its fixtures are expensive; measured, `tests/Measure.Tests.ps1` spends **16.7s in test
bodies against 2.3s of setup**, so sharing fixtures would have bought two seconds. The cost is 134
tests each measuring real source, which is what those tests are for. Moving mutants off the suite
is the lever; making the suite cheaper is not.

**An assertion about a SEPARATOR is a platform assumption.** `Should-NotBeLikeString
"*$([System.IO.Path]::DirectorySeparatorChar)*"` passed here and failed on the Linux leg, where
that character IS `/` and the correct answer is full of them. The claim it reached for -- that the
code replaces the platform separator rather than a literal backslash -- is a **no-op on Linux** and
not observable there at all, which is the same reason a hard-coded backslash once survived every
mutant while looking tested. Assert the exact string instead; it says the observable half on both
platforms and is stronger anyway.

**Splitting a file moves whatever now sits first in it into the header's shadow.** A `<# #>` block
immediately before `function` IS that function's comment-based help. `Measure-PSComplexity.ps1`
carried one harmlessly for as long as an internal function sat first; splitting the scan out put a
PUBLIC command there and three help tests failed on the same run. File headers in `src/` are `#`
line comments for exactly this reason -- check the top of a file after moving anything out of it.

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

**Who decides what "changed" is, is the decision #7 owned.** `-ChangedFile` takes a list; there
is deliberately no `-ChangedSince <ref>`. A diff is not a fact this module can compute -- it needs
a base, and every way that goes wrong goes wrong in the CALLER's environment: a shallow clone where
the ref was never fetched, a detached HEAD, a merge base that is not what the reviewer sees.
Resolving it here would turn those into a complexity tool refusing to run, several layers from the
shell where they can be fixed. It also keeps this module free of an external process, which it has
never had.

The guard that earns its place is the **empty list**: a `git diff` that fails prints nothing and
exits 0, and taken at face value that is a confident pass over zero units. So an empty
`-ChangedFile` is refused, while a run whose changed files simply hold no PowerShell passes and
says so -- those are different situations and only one of them indicates a broken pipeline.

A filtered run emits a notice because a passing gate is otherwise silent, and `scope.changedFile`
in the report is `null` for a whole-tree run rather than `[]`: absent and empty are different
answers, and only absent may be read as a measurement of everything under `path`.

**The unit table is built once per file and passed down.** `Get-PSCxUnitTable` is a full `FindAll`
traversal that invokes a PowerShell predicate for every node, and it used to run three times
against the same AST in one pass -- once for the line numbers and once inside each metric map. The
maps now take it as a **mandatory** parameter: an optional one with a fallback would be a branch
whose two arms produce identical output, which no test could distinguish from its own absence.

**That same pass also buckets every node by TYPE, and the metrics read the buckets.** Each
collector used to call `Ast.FindAll(scriptblock, $true)`, which walks every node and invokes a
PowerShell predicate for each one -- and the per-type loops did it once per type name, so
`Get-PSCxCogBlockRow` alone walked the whole tree eight times. Measured on a 1,159-node file:
**34 full traversals per file, 52 with `-Detailed`**, about 39,400 predicate invocations. The
index pass already visited every node and already knew each one's type; it simply did not write
it down. Recording it costs one dictionary write per node and takes the count to **2**.

Three things about it are easy to undo and were each paid for:

- **Exact-type and assignable lookups are spelled separately.** `Get-PSCxNodeByTypeName` answers
  `GetType().Name -eq`; `Get-PSCxNodeByKind` answers `-is`. They agree today for every type in the
  vocabulary -- the only Ast subclass, `BaseCtorInvokeMemberExpressionAst`, is not reachable
  through `FindAll` in PowerShell 7.6, which the suite pins -- and they stop agreeing the day that
  changes. One spelling for both would pick a winner nobody decided on.
- **`Initialize-` rebuilds; `Confirm-` is the idempotent entry point.** The bucket readers ask on
  every query and need the guard; `Get-PSCxUnitBoundary` and `Get-PSCxNesting` ask only on a miss
  and need the rebuild, because their memo tests plant a value and prove a rebuild would overwrite
  it. Guarding the rebuild itself turned that into an early return and **resurrected two mutants
  that used to die**.
- **The type-keyed tables are CLEARED when a second tree is indexed.** Boundary, nesting and name
  are keyed by node reference, so two trees can share them harmlessly. A bucket keyed by type
  cannot: appended to rather than replaced, it hands back the previous file's nodes. The suite
  caught exactly that -- a fixture reporting an `if` from the file before it.

The union path sorts on the recorded walk position rather than on an extent offset, because a node
and the node it CONTAINS can start at the same offset and pre-order puts the container first. There
is no single-bucket shortcut: a PowerShell function unrolls a returned list into a fresh array
anyway, so the shortcut was a branch nothing could observe.

**A node's unit and nesting depth come from ONE pre-order pass, not from walking up.** Both are
defined against a node's parent -- `boundary(n)` is the parent's boundary unless the parent is a
body owner, `nesting(n)` is the parent's nesting plus one if the parent raises it -- so a single
descent computes them for every node. `FindAll` walks in document order and a parent always
precedes its children, which is what lets it be a flat loop rather than a recursion; a recursion
would risk the stack on exactly the deeply nested file this exists for.

The upward walk is gone rather than kept as a second path. Two ways to answer one question is how
they come to disagree, and the walk was the quadratic half: twelve call sites asked once per matched
node.

**The nesting half of that is easy to get wrong in a way tests do not catch.** Memoising the upward
walk was tried first: boundary answers along a chain are all equal, so caching them on the way up is
correct, but nesting answers *decrease* going up. Cached on the way up they come out one too high
for every node except the one asked about -- which reported cognitive **200 where the answer was
20100**, with all 558 tests passing, because the suite pins shapes and small fixtures rather than
totals over a deep one. Anything touching this needs a before/after comparison of real totals, not
a green suite.

**Measure a performance claim by interleaving, and check the direction before believing it.** The
issue behind this reported ~18%. Two wall-clock A/B attempts here disagreed about the SIGN -- the
change looked 32% slower when its process ran second and 6% faster when it ran first -- because
whichever side ran later paid for whatever else the machine was doing. Interleaved CPU time over
three pairs gave a consistent **~8%**, with byte-identical output every run. The lesson is not the
number; it is that a single ordered A/B can report the opposite of the truth.

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
  and an allowlist would have been ceremony. The condition for revisiting was recorded in advance
  -- a module that both exported commands consume, living in its own file -- and `src/Report.ps1`
  met it. Writing it while the edges are few and obviously correct is the
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

- **The two repositories' CI is compared by a rule set, not by memory.** This module and PSMutant
  gate each other, which makes it easy to assume their pipelines are comparable. They were not --
  thirteen capabilities apart at once, and *nothing compared them*, because each workflow reads
  perfectly well on its own and a gap is only visible from outside either repo.

  `tools/Test-PSCxCiParity.ps1` checks `.github/workflows/` against the shared rules in
  `tools/ParityDecisions.ps1`: every job carries a `timeout-minutes`, every workflow a concurrency
  group and a `permissions` block, `publish.yml` never cancels in progress, every action pinned to a
  SHA with the version in a trailing comment, no version written out where `pins.env` should be
  read, no lint spelled inline, every Pester configuration disabling the classic `Should` syntax,
  and `ci.yml` running a matrix over both operating systems with `fail-fast: false`.

  **The rules are stated as shape, never by file name**, so `ParityDecisions.ps1` is byte-identical
  in both repos apart from the command prefix. That is the whole mechanism: **diffing the two copies
  IS the comparison**, and declining a rule becomes a deletion somebody has to argue for in a diff
  rather than a silence. Add a rule here and the sibling fails it until it adopts or declines it.

  It reads **comment-stripped** text, which is not fussiness: PSMutant's `code-scanning.yml` spends
  six lines of prose on `Invoke-ScriptAnalyzer` explaining why it does *not* call it, and a grep
  reads that as an inline lint gate. It is text rather than parsed YAML because PowerShell ships no
  YAML parser, and pinning one would add a dependency to the gate that watches the dependencies.

  The rule set found a real gap on its first run: PSMutant's `publish.yml` ran the suite with the
  classic `Should` syntax still legal while its `ci.yml` forbade it -- a publish-time gate weaker
  than the merge gate, which is the direction that matters.

- **A declared floor is exercised, or it is not a floor.** Two of them here, and they are separate
  gates on purpose: `tools/Test-PSCxPesterCompatibility.ps1` proves a consumer can gate on this
  module from inside every supported Pester, and `tools/Test-PSCxPowerShellCompatibility.ps1` proves
  the module loads and computes the same answers on every supported PowerShell.

  **Do not cross them.** The product would be 12 x 6 legs to answer two questions, and it would
  confound the second: Pester 6.1.0 does not load on PowerShell 7.0, so a PowerShell leg driven
  through Pester fails the floor for a reason that is not about this module. Nothing in `src/` calls
  a Pester API, which is what makes the direct assertions possible.

  **One leg per MINOR, and the middle is not interpolation.** `New-PesterConfiguration` arrived in
  Pester 5.1.0 -- invisible at both ends of the range and fatal in between. The floor is tested at
  the exact version promised, not the newest patch of that minor, because the floor is the number
  consumers are told. A test ties the manifest's own `PowerShellVersion` to the list, so raising the
  floor without adding a leg fails the suite.

  **Compare against the current host, not against numbers written in the gate.** A leg must
  reproduce what this host measured from the same fixture. Hardcoded scores would pin the metric a
  second time -- `tests/Cognitive.Tests.ps1` already does that against the published examples -- and
  would need editing whenever the metric legitimately changes, which is exactly when a compatibility
  gate should keep working.

  **An unobtainable runtime is not a module failure.** Every one of these gates separates "this
  version could not be obtained or started" from "this module is wrong under it", because the whole
  family exists to stop the second accusation being made from the first's evidence.

- **`Write-Output` inside a value-returning function joins its return value.** `PSAvoidUsingWriteHost`
  is deliberately not excluded here, so every `tools/` script prints through the pipeline -- and a
  helper that prints progress AND returns a path hands the caller both, concatenated. The symptom
  names a command that is a whole English sentence, and points at the call site rather than the
  print.

  Progress belongs to the caller, whose output nobody captures. Swept the eight scripts in `tools/`
  for functions that both `Write-Output` and `return` a value: there is exactly one such pattern and
  it was fixed on the run that found it, so the negative is confirmed rather than assumed -- and the
  sweep was checked against a planted case first, because a scan that cannot fire proves nothing.

- **A claim about the framework is checkable in ten seconds, so check it before paying for it.**
  The AST index passed `ReferenceEqualityComparer` explicitly, with a comment saying the default
  comparer "would conflate" two structurally identical nodes. It would not: `Ast` overrides neither
  `Equals` nor `GetHashCode`, so `EqualityComparer<object>.Default` is identity already. One probe
  settles it -- `GetMethod('Equals').DeclaringType` is `System.Object`, and both comparers keep two
  identical trees apart.

  The cost of not checking was a **version of PowerShell**: that type is .NET 5, so the module's real
  floor was 7.1 rather than 7.0, in exchange for nothing. The declared floor is what a consumer is
  told; the real floor is whatever the newest API in `src/` needs, and they drift apart silently
  because nothing runs on the declared one.

  **The floor is still asserted rather than proven**, and the obvious proof was tried and rejected:
  `PSUseCompatibleTypes` against a 7.0 profile reports clean on `[System.DateOnly]`, `[System.Half]`
  and `Get-Error` alike, so a clean result from it says nothing. A real proof needs a CI leg that
  runs on the oldest supported host. Until then, when you add a `[Type]` to `src/`, check what
  framework version it arrived in.

  What replaced the comparer is the guard that was always the real one: `tests/Ast.Tests.ps1` keeps
  two structurally identical trees apart. Verified it can fail -- swap the caches for a comparer
  that calls everything equal and the second tree answers with the first tree's unit.

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

- **A gate must refuse a path it could not read, not just a run that measured nothing** (#15).
  These are two rules and both are reachable, which is why they are sequenced in one place --
  `Get-PSCxScanFault`. Every path wrong measures nothing and is answered by the COUNT rule, which
  carries the `-Recurse` hint; SOME paths wrong measures plenty and is answered by the PATH rule.
  Reversed, the count rule could never fire, and a rule that cannot fire looks exactly like a rule
  that keeps passing.

  The second one closed a real hole, and it was this project's own failure aimed inward:
  `Test-PSComplexity @('./src/Ast.ps1', '/nope')` returned **`$true`**. A unit count cannot see a
  mistyped path standing next to a good one, and the underlying `Get-ChildItem` error was
  attributed to `Get-ChildItem`, named a line inside `src/Scan.ps1`, and never reached the
  caller's `-ErrorVariable` -- so all a consumer saw was a green gate.

  `Get-PSCxSourceFile` now returns empty for a path that is neither a literal nor a wildcard match
  rather than letting `Get-ChildItem` raise, and the walk records the fact. **The two reasons are
  kept apart because the two consumers differ**: a path that is not there is a mistake and
  `Measure-PSComplexity` reports it; a path that IS there and holds no PowerShell is an ordinary
  empty outcome, and a measurement command that refused one would fail every legitimately empty
  run -- terminally, under `ErrorActionPreference = Stop`, which is what `Measure-PSCxCoverage.ps1`
  sets. The gate refuses both, because a ceiling applied to nothing is not a gate.

- **An I/O failure is not a parse error, and `ParseFile` will tell you which it was.**
  `Parser::ParseFile` reports a missing file, a directory, a permission denial and a file deleted
  mid-scan through the SAME `[ref]$errors` out-parameter as a syntax error -- it does not throw, so
  no `try` is needed and none was added. What it does carry is `ErrorId`, and `FileReadError`
  separates the two cleanly. Discriminate on that, never on the message text, which is prose and
  may be localised.

  Calling every skip a "parse error" sent the reader to inspect syntax that was perfectly correct,
  and the gate's own advice compounded it -- *"Fix the syntax"* for a file that was merely gone. It
  now says *"could not measure"* and *"Fix the fault named"*, and each skip says which it was. This
  is the same misdiagnosis the scan was built to end, one layer further down.

- **The two public commands take a path by VALUE and by PROPERTY NAME, with `FullName` aliased.**
  `Get-ChildItem | Measure-PSComplexity` appeared to work all along, but bound by coercion -- a
  `FileInfo` has no `Path` property, so it reached the parameter through `ToString()`. Anything
  carrying its path as a property, which is the ordinary shape for an object a caller builds,
  selects or filters, bound to nothing and measured **nothing, silently**.

  `PSPath` is deliberately NOT aliased. It is provider-qualified
  (`Microsoft.PowerShell.Core\FileSystem::/x`), and `[System.IO.Path]::GetFullPath` in
  `Get-PSCxRelativePath` would turn that into a path no other run could match against -- which is
  the identity bug 0.4.0 existed to fix, reintroduced through a different door.

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

- **The metric maps take ROWS, not an Ast.** "The map is a projection of the rows" is then
  structural rather than a claim about a private local, and it is what lets one row set feed two
  projections: `-Detailed` used to collect the cognitive rows a second time for the contributions,
  which was eighteen more traversals of a tree that had just produced them. `Get-PSCxFileScan`
  collects each row set once and hands it on.

- **`Test-PSComplexity` is a thin predicate over `Measure-PSComplexity`, and should stay one.**
  It duplicates no measurement and re-parses nothing. The temptation is to make it return
  violation objects instead of a bool; resist it. Nothing in the backlog routes through it --
  the queued features all build over `Measure-PSComplexity`'s records. What is missing is a
  scan noun, not a richer verdict.

- **The construct vocabulary is closed against the parser, in both directions** (#32, #18).
  `tests/Vocabulary.Tests.ps1` asserts that every Ast type the parser can emit is either scored or
  excluded with a written reason, so PowerShell gaining syntax turns the suite red rather than
  quietly lowering everyone's scores. The direction is what makes it matter: an unrecognised
  construct can only LOWER a score, so without it the gate passes most easily on the code it
  understands least.

  This was listed as a gap here long after it was closed, with the measurement that motivated it
  -- "5 of 7 cyclomatic types and 4 of 8 cognitive types can be deleted with the suite still
  green". Re-measured: **15 of 15** deletions are now caught, 1 to 9 failing tests each. Delete a
  type from a collector list and run the mapped suite; that is the whole check, and it takes a
  minute.

- **`Ast.ps1` is a layer, not a shared-helpers bucket.** Every function in it answers one
  question: what the parent chain looks like relative to a unit boundary. That is why
  `Get-PSCxNesting` belongs there even though only `Cognitive.ps1` calls it -- placement
  follows what a function consults, not who calls it.

- **Nothing in `src/` swallows an error.** There is no `-ErrorAction SilentlyContinue`, and the
  single `try` -- in `Read-PSCxDocument` -- re-throws with the path attached rather than
  continuing. Keep it that way: the failure this project exists to catch is a number that was
  never measured being reported as a number that was, and a swallowed error is how that happens.

  This entry used to say "there is no `try`", which was false and in a way that mattered: read as
  a ban on the keyword it argues against catching-and-rethrowing, which is the one shape that
  makes an error MORE specific. The rule is about swallowing, not about syntax.

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

- **Every gate is a committed script, not a snippet in a document** (#27). Coverage is claimed
  at 100% in this file and measured by nobody -- the recipe lives in prose, so measuring by
  hand and measuring in CI cannot even be compared. Hand-maintained figures in this repo have
  already drifted.

- **Anything the module says about itself is a claim someone should be able to check** (#28).
  Five statements in the docs are not true of the code, two of them provably: load order is
  inert, and the closure requirement above. Prefer a test to a sentence wherever one is
  possible.
