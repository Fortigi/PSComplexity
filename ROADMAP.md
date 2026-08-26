# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull, do the most-requested thing first,
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track
progress here: a second status list drifts from the first, which is the exact failure this
project exists to find in other people's code.

Snapshot 2026-08-26, with **0.4.0 prepared and unreleased**. 5 issues open.

Since the last snapshot the whole **Guards** section closed, and **#2** with it -- the committed
baseline, which was the first thing here to persist a key. Removed rather than ticked, per the rule
below; what is worth keeping is in `CLAUDE.md`, where somebody about to add an edge, a test file or
a mutated source file will actually meet it.

**#2 changed what this file says about cost, and the numbers below are now measured rather than
estimated.** Building it took the self-mutation gate from 14.5 to 34 minutes, past a job budget of
40, and finding out why produced a better answer than the one queued here. The snapshot
reflects what has **merged**; work with a pull request open still holds its ordering entry
below, because an entry removed on the strength of an open PR is a status claim in disguise.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design. Removal is the one exception, because it is
one-way and cannot drift the way a checklist would. Wave letters keep their original letters
as earlier ones disappear, so "Wave A" in an existing commit or PR still resolves.

---

## The fact that used to order everything is spent

This section has been rewritten twice, and it is now retired rather than edited a third time,
because what it described is done.

It said the module had exactly **one noun** -- a flat stream of per-unit records -- and that
every open request was asking for one of the two levels that did not exist. All three exist now,
and the last of them is published:

```
an INCREMENT below the unit   every row carries the construct that caused it and the line it
                              sits on; -Detailed publishes them per unit

a RECORD at the unit          six fields, their order and types pinned by a test; an identity
                              unique within a file and equal on both CI legs; a MetricVersion
                              that moves only when a score can change for source that did not

a SCAN above the unit         what was in scope, which units were found, which files were
                              skipped and why -- serialised by schemas/v1/report.schema.json,
                              which ships with the module
```

**What remains is no longer structural.** Two features read those levels, and everything else
open is cost, parity, or a guard. The ordering below is correspondingly shorter and weaker, and
that is the right shape for a backlog that has run out of foundations to lay.

The one structural claim still worth keeping: **a level is destroyed the moment it is folded, not
at the boundary where the question is asked.** That is why attribution had to precede the report
and the scan had to precede the baseline. Anything new that folds -- a file-level aggregate, a
summary statistic, a trend -- inherits the rule.

## The constraint is spent

The one ordering arrow this file still carried has been satisfied:

```
#2 baseline  --->  #7 diff-scoped. #7 must say which units were in scope AND compare them
                   against something. Scope existed; the comparison did not. Now it does.
```

**Nothing here blocks anything else any more.** Every remaining item is independent, so what to do
next is a question about value rather than order -- which is the first time that has been true of
this file, and the reason it is now mostly a record of what was decided rather than a sequence.

Two things #2 settled are worth keeping, because #7 inherits both:

- **The key is `file` + `unit`, never a line.** A line moves whenever anything above it is edited.
  A unit name carrying an ordinal (`Get-Thing#2`, how duplicate definitions are told apart) is
  refused outright: ordinals renumber when a duplicate is inserted above them, so an entry keyed
  that way silently begins describing a different function. Measured, not assumed.
- **Persisting a key costs a major version to get wrong**, which is why that decision took the time
  the prerequisites bought. #7 does not get to re-open it; it compares runs using the identity #2
  established.

---

## Waves A, B and C -- gone

Removed rather than ticked. Discovery, the empty verdict, the vacuous test that certified it, the
metric's blindness to PowerShell's own flow constructs, the reference-score attributions, the
vocabulary pins, the record contract, unit identity, the metric version, the increment
attribution, the scan, and the exception concept.

One entry left Wave B without being work, and it is worth knowing where it went: the
`FunctionMemberAst` boundary entry that no leave-one-out sweep could pin. It is unreachable
because PowerShell wraps a class member's body in its own `FunctionDefinitionAst`, so the body is
always met first -- and that invariant is now pinned by tests, so the day it stops holding is a
red suite rather than a quiet re-attribution.

## Wave D -- the features everyone actually wants

| Order | Issue | What it needs that now exists | What it still decides |
|---|---|---|---|
| 1 | **#7** diff-scoped | `Scope` on the scan, #2's comparison, and its key | how "changed" is determined, and by whom |

**#2 has landed and settled the expensive half of #7's decision.** The key is `file` + `unit`, never
a line, and a unit whose name carries an ordinal is refused outright -- ordinals renumber when a
duplicate definition is inserted above them, so an entry keyed that way silently begins describing a
different function. #7 compares runs; it inherits that identity rather than choosing one.

What #7 still owns is narrower than it looks: how "changed" is determined, and by whom. A diff is
not a fact this module can compute -- it needs a base to compare against, and the honest options
(a committed baseline, a git ref, a caller-supplied list) differ in who is responsible when the base
is wrong.

---

## CI and release

One committed analyzer script all three callers run -- and it **throws**, so running it by hand
is the same as passing it. Pins in `.github/pins.env` with a weekly watcher and Dependabot for
the action SHAs. An enforced 100% coverage gate, concurrency groups, timeouts, least-privilege
permissions, a publish that requires the CI conclusion for its exact commit on **both** matrix
legs, a release-consistency check that generates the manifest notes from the CHANGELOG, and a
staged-package smoke test that loads the artifact before it becomes permanent. The suite also has
to give the same answer reversed, and to leave the environment as it found it -- the two orders this
project runs its own tests in used to differ with nothing checking they agreed.

Two negatives worth keeping, because both look like protection and are not:

- A `tag_name_pattern` ruleset is accepted by the API and **never evaluated**. Verified by
  pushing a violating tag with that rule as the only active one.
- `Find-Module` returns nothing both when a version is unpublished and when the gallery is
  unreachable. Anything that asks the gallery must check reachability first, or "could not look"
  reads as "nothing there".

What is left:

  - **#56** -- the parity tracker against the sibling. Most rows are closed; keep it until the
    last one is, then delete it rather than leaving a tracker of nothing.

## Cost

  - **#96** -- `src/Ast.ps1` is mapped to two covering suites and pays for both on all 57 of its
    mutants. Still true, and **no longer the largest term**. Measured while building #2:

    | | |
    |---|---|
    | `tests/Measure.Tests.ps1` | **18s** -- it measures real source |
    | `tests/Report.Tests.ps1` | 2.1s |
    | `tests/Cognitive.Tests.ps1` | 4.6s |
    | `tests/Policy.Tests.ps1`, `tests/BaselineFile.Tests.ps1` | ~1s each |

    The gate costs *mutants x suite*, so the dominant term is that one 18-second suite and every
    file pointing at it -- `Measure-PSComplexity.ps1` alone, not `Ast.ps1`, is the bigger half.
    Proven by the lever rather than argued: moving `Policy.ps1`'s 125 mutants off it took them from
    **19 minutes to 59 seconds**, and moving two more functions out took another eight minutes off
    the whole run.

    So the cheapest real fix is not per-mutant test selection but **a covering suite that does not
    measure real source**, which is a refactor of `Measure.Tests.ps1` and of what
    `Measure-PSComplexity.ps1` still contains. Test selection (the sibling's #141) remains the
    general answer and is still worth having; it is no longer the first thing to try.

    The budget went 20 -> 40 when this first walked through a timeout, and 40 -> 60 when #2 landed.
    Measured on the runner afterwards: the Linux leg takes **24m34s**. Raising a timeout is not a
    speed fix -- it stops a slow gate reading as a wedged runner, which holds a required check
    pending and blocks every merge behind it.

  - **#36**, **#37** -- `Get-PSCxUnitTable` rebuilt three times per file, two of them waste; and
    analysis is O(nodes x depth), so a deeply nested file costs orders of magnitude more per byte
    than ordinary code. Neither matters at current scale -- measured, 37 KB and 401 units in
    1.65s. Do them when #7 makes per-file cost matter.

Test selection is verdict-preserving **by construction** -- a test that never runs the mutated line
cannot tell the mutant from the original -- unlike dropping operators or sampling, which shorten a
run by making the score mean less. That distinction is why the two cheap-looking levers stay
refused however long the gate gets.

## Deliberately not doing

Recorded so they are not rediscovered as good ideas. Each was considered and rejected with a
reason.

- **Merging the three construct lists into one constant.** They agree element-for-element today,
  and their differences are roles rather than drift: `ScriptBlockExpressionAst` is nesting-only
  (correct per Sonar B3) and `SwitchStatementAst` is handled separately by Cyclomatic because it
  counts per clause. One list is exactly as blind to a new construct as three.
- **Making `Test-PSComplexity` return violation objects instead of `[bool]`.** The thin-predicate
  split is right, documented, and duplicates no measurement. This entry used to say "what is
  missing is a scan noun, not a richer verdict" -- the scan exists now, `Test-PSComplexity`
  consumes it, and `-ReportPath` gives the richer answer a home that is not the verdict. That
  strengthens the entry rather than retiring it.
- **A second AST walk for attribution.** Cheapest to write, and the only option that can produce
  two answers to the same question.
- **Content-hash unit identity for #2.** It survives moves and renames but changes whenever the
  unit is edited at all -- precisely when a ratchet needs to compare.
- **Gating on a file-level aggregate.** It would punish legitimate decomposition, and no published
  definition of either metric is file-level. See "What the number does not say" in the README,
  which states that per-unit measurement cannot tell decomposition from displacement.
- **Publishing the scan before something consumes it.** A shape with no consumer is a guess, and
  an exported guess is a contract. #5 was the consumer, and it published the report format rather
  than the object -- which is the narrower promise and the one worth making.
