# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull, do the most-requested thing first,
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track
progress here: a second status list drifts from the first, which is the exact failure this
project exists to find in other people's code.

Snapshot 2026-08-25, with **0.4.0 prepared and unreleased**. 8 issues open. The snapshot
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

## The constraint that is left

```
#2 baseline  --->  #7 diff-scoped. #7 must say which units were in scope AND compare them
                   against something. Scope exists; the comparison does not.
```

That is the whole of it. #2's four prerequisites -- a portable identity, a metric version, an
exception concept, and a scan -- have all landed, and #5 added the fifth thing it wanted without
being asked for it: a published format to persist.

Two things follow that are worth stating out loud:

- **#2 is the most-wanted item and is now genuinely next.** It has been "not yet" for a long time
  for good reasons, and none of them are true any more. What is left is its own decisions: what a
  baseline file looks like, and what a ratchet does when the metric version moves under it.
- **#2 is the first thing here that PERSISTS a key.** Everything before it could be reshaped in a
  minor release. After it, a wrong key costs a major version and a migration, so the shape
  deserves the time the prerequisites bought.

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
| 1 | **#2** committed baseline | identity, MetricVersion, the scan, a published report format | the file's shape, and what a ratchet does when the metric version moves |
| 2 | **#7** diff-scoped | `Scope` on the scan, and #2's comparison | how "changed" is determined, and by whom |

#5 has landed and took the deferred decision from the scan with it: the report format is a
contract, `schemas/v1/report.schema.json` ships with the module, and `Get-PSCxScan` itself stays
internal until something needs it exported.

---

## Guards

Not features and not cost. Each one is a thing that would otherwise be true only by luck.

  - **#102** -- the layering test. This repo set its own trigger for it: reconsider when a module
    both exported commands consume lives in its own file. `src/Report.ps1` is that file, so the
    condition has fired. Every other gate here is blind to DIRECTION -- a shortcut call reaches
    full coverage and survives self-mutation exactly as a well-layered one does. Cheap to write
    while the edges are few and obviously correct.

  - **#101** -- nothing checks the suite is order-independent, and the two orders this project
    uses disagree: `Invoke-Pester ./tests` is alphabetical, the mutation baseline runs the mapped
    suites in config order. It cost the sibling project three CI rounds when a file cleared an
    environment variable an earlier file had not. No known dependency here today, which is a fact
    about the tests as they stand rather than a property anything enforces.

## CI and release

One committed analyzer script all three callers run -- and it **throws**, so running it by hand
is the same as passing it. Pins in `.github/pins.env` with a weekly watcher and Dependabot for
the action SHAs. An enforced 100% coverage gate, concurrency groups, timeouts, least-privilege
permissions, a publish that requires the CI conclusion for its exact commit on **both** matrix
legs, a release-consistency check that generates the manifest notes from the CHANGELOG, and a
staged-package smoke test that loads the artifact before it becomes permanent.

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

  - **#96** -- `src/Ast.ps1` is mapped to two covering suites and pays for both on every one of
    its 57 mutants: 29% of the set, an estimated 45% of the run. It is why this repo costs 4.3s
    per mutant against the sibling's 1.8s. It stopped being theoretical the day the self-mutation
    step walked through a 20-minute job timeout; the budget is now 40, which is the stopgap and
    not the answer.

  - **#36**, **#37** -- `Get-PSCxUnitTable` rebuilt three times per file, two of them waste; and
    analysis is O(nodes x depth), so a deeply nested file costs orders of magnitude more per byte
    than ordinary code. Neither matters at current scale -- measured, 37 KB and 401 units in
    1.65s. Do them when #7 makes per-file cost matter.

The general fix for the first is the sibling's per-mutant test selection, which runs only the
test files that execute the mutated line. That is verdict-preserving by construction, unlike
dropping operators or sampling -- both of which shorten a run and leave the score reading 100%
over less.

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
