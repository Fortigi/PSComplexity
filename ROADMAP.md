# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull, do the most-requested thing first,
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track
progress here: a second status list drifts from the first, which is the exact failure this
project exists to find in other people's code.

Snapshot 2026-08-23, after **0.3.0 shipped**. 25 issues open.

Everything that release contained is gone from this file rather than ticked, per the rule
below: discovery, the empty verdict, the vacuous test, the metric's blindness to PowerShell's
own flow constructs, parse errors, duplicate rows, enum labels, row order, pipeline binding,
the documentation claims, and the whole CI and publish cluster. What is left is genuinely
left.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design. Removal is the one exception, because it is
one-way and cannot drift the way a checklist would. Wave letters keep their original letters
as earlier ones disappear, so "Wave A" in an existing commit or PR still resolves.

---

## The one fact that orders everything

**The module has exactly one noun.** `Measure-PSComplexity` emits a flat stream of
`{File; Unit; Line; Cyclomatic; Cognitive}` and `Test-PSComplexity` returns one bit. Every
open feature request is asking for one of the **two nouns that do not exist**, or for an
identity the one noun does not carry:

```
a located, named INCREMENT below the unit   ---> #3 attribution, #5 SARIF, the sharper form of #4
a SCAN above the unit: what was looked at,  ---> #7 diff-scoped, #5 summary, #73 progress
  skipped, in scope, under which thresholds
a unit IDENTITY that survives a commit      ---> #2 baseline, #7, and #5 the moment it pins a shape
  and a machine
```

Both levels are destroyed at the moment of creation rather than at the boundary. That is not
four problems; it is one design fact seen from four sides, and it is why the record shape has
to be decided before any feature is built on it.

## The constraints that force the order

The three that used to head this block -- discovery, the empty verdict, and the vacuous test
that certified it -- shipped in 0.3.0. Every number this project publishes about itself is
now a claim about a set that was actually measured, which is the precondition the rest of
this file quietly assumed.

```
#14 identity   ]
#16 increment  ]--> #2 baseline, #3 attribution, #5 report, #7 diff-scoped
#17 scan noun  ]    all four read or persist a record the current shape cannot express

#20 metric version ---> #2. A baseline compares two runs; if the metric moved between them,
#21 exceptions     ---> #2. it re-baselines everything at once, or mutes without an argument

#42 record pinned  ---> #2, #3, #5, #7. Four features widen a five-field object that no test
                                        describes. Free now, a breaking change the moment a
                                        consumer persists one. (#43, stable order, shipped:
                                        rows come back in source order.)
```

Three things follow that are worth stating out loud:

- **#2 is the most-wanted item and should not be first.** A committed baseline is the natural
  next feature and it depends on four things that do not exist: a stable identity, a metric
  version, an exception concept, and a scan. Building it first means building it twice.
- **#3 is not a small issue.** It reads as "also report which construct" -- an afternoon. It is
  a change to the intermediate representation: increments are summed at emission, twelve
  producers deep, so the information it asks for is destroyed two layers below where the
  question is asked. Size it as structural work or it will be scheduled as an afternoon.
- **#20 is now overdue rather than queued.** The metric MOVED in 0.3.0: scores rose for every
  codebase that uses `ForEach-Object`, `&&` or `??`. Nothing in a score records which metric
  produced it, so a consumer comparing a figure from before against one from after cannot tell
  which half of the difference is their own code. Survivable while nothing persisted a score;
  #2 turns it into a silent re-baseline of everything at once.

---

## Wave A -- gone

Shipped in 0.3.0 and removed rather than ticked. One item did not ship with it and moves down
to the fillers: **#46**, three guard *applications* that delete clean with the suite green,
including the Sonar labelled-jump rule. Covering a predicate is not covering its call, and
neither gate can see the difference.

## Wave B -- decide the record shape

The expensive-to-reverse decisions, and the reason to take them before any feature: #5 says to
"treat its shape as an interface and pin it in a test", and after that a wrong key costs a
major version.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#42** | Pin the five-field record before anything reads it. One test, and it stops being free the moment #2 commits a file or #5 publishes one. First in this wave precisely because it looks too small to schedule. (#43, deterministic order, shipped in 0.3.0 -- half of this item is already done.) |
| 2 | **#14** | Unit identity is neither unique (two nested `Get-Inner`s collide) nor portable (`File` is absolute and platform-separated, and CI runs two OSes). #2 and #7 both assume otherwise **in their own text**. One function, because `Get-PSCxUnitName` centralises naming. |
| 3 | **#20** | Promoted. The metric already moved once, in 0.3.0, with nothing recording that it did -- so two scores from either side of that release are not comparable and nothing says so. Every further metric change has the same cost, and #2 makes it a silent re-baseline of a committed file. |
| 4 | **#17**, **#16** | The two missing levels. Take them together: they are the same decision about what a record is, and deciding one without the other produces a shape that has to move again. |
| 5 | **#21** | The exception concept: today nobody can disagree with a number. Cheap now, and after #2 ships a bare snapshot a declaration is a mute button rather than an agreement. |

**#22 and #47 are not positions here.** Both are decisions to record, not work: complexity exists per
unit, extraction lowers the score by design, and the README over-claims by calling the number
a measure of how hard code is to understand. Settle it in whichever PR touches the README --
before #5 publishes a report shape that implies an answer. #47 is the same argument in
miniature -- a nested named function adds nothing to its parent where the same body as a script
block adds 3/5 -- and it is the cheaper displacement route, so settle it alongside.

## Wave C -- make the metric honest

| Order | Issue | Why here |
|---|---|---|
**#30 and #41 shipped in 0.3.0** -- the metric now scores `ForEach-Object`, `Where-Object`,
`&&`, `||`, `??` and `??=`, and a pipeline body costs what the keyword form costs. What is
left in this wave is what stops that vocabulary drifting again.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#32**, **#18** | Nothing pins the vocabulary from either side: 5 of 7 cyclomatic and 4 of 8 cognitive types can be deleted with the suite green (#32), and nothing notices when PowerShell adds one (#18). Same test file, opposite directions. |
| 2 | **#4** | Pin the metric against the SonarSource examples. All eleven reference cases currently pass, including both "classic implementation errors" -- so this is a pinning gap, not a correctness bug, and it is cheaper after #16 makes increments addressable. |

## Wave D -- the features everyone actually wants

Only reachable once B is decided. In this order because each one's prerequisites are the
previous one's output.

**#5** machine-readable report, then **#3** per-construct attribution, then **#2** committed
baseline, then **#7** diff-scoped measurement. (#6, a parse error as a silent warning, shipped
in 0.3.0 -- the gate now refuses a verdict for a file it could not read. #17 still owes the
scan the vocabulary to say so in a REPORT rather than only on the error stream.)

---

## CI and release -- most of this shipped

The cluster is largely gone. One committed analyzer script both gates call, pins in
`.github/pins.env`, an enforced 100% coverage gate, concurrency groups, timeouts and
least-privilege permissions on all three workflows, `.gitattributes`, a publish that requires
the CI conclusion for its exact commit on **both** matrix legs, a release-consistency check
that generates the manifest notes from the CHANGELOG, and a staged-package smoke test that
loads the artifact before it becomes permanent. All of it ran for real on the 0.3.0 tag.

What is left:

- **#33**, **#38** -- the publish path's two remaining holes, and they compound:
  `github.ref_name` is interpolated into a pwsh string, so a crafted tag runs code in the job
  holding the Gallery key, and nothing requires a second person for the one irreversible
  action here. Push access is the publish credential. #38 is a repository setting rather than
  code, and for a single-maintainer project it is a decision to record either way.
- **#35** -- `ConvertToSARIF` is pinned now; what is left is watching whether any pin has gone
  stale, which is #54's job.
- **#50**, **#54** -- nothing fails when `main` claims a version already on the gallery, and
  nothing watches the pins or the `uses:` SHAs. Both are about drift that announces itself to
  nobody. Do them with whatever touches the release path next.
- **#56** -- the parity tracker. Most rows are closed; keep it until the last one is.
- **#73** -- `Test-PSComplexity` is silent until it finishes, so a slow scan and a stuck one
  look the same. Small, and it pairs naturally with #37.

## Low-coupling fillers

- **#36**, **#37** -- `Get-PSCxUnitTable` rebuilt three times per file, two of them waste; and
  analysis is O(nodes x depth). Neither matters at current scale -- measured, 37 KB and 401
  units in 1.65s, and PSScriptAnalyzer over a comparable corpus is several times slower. Do
  them when #7 makes per-file cost matter, or when a deeply nested file makes someone notice.
  #37 is also the reason #73 matters: uneven cost is what makes a silent scan look stuck.
- **#46** -- three guard applications delete clean with the suite green. The mutation gate now
  runs the full operator set, so it would catch a new one; these predate that and are still
  unproven at their call sites.
- **#47** -- a decision to record, not work: a nested named function adds nothing to its
  parent where the same body as a script block adds 3/5. The cheaper displacement route, so
  settle it beside #22.
- **#22** -- the other decision to record: complexity exists per unit, so extraction lowers
  the score by design and the gate cannot tell decomposition from displacement. Settle it in
  whichever PR touches the README, before #5 publishes a report shape that implies an answer.

## Deliberately not doing

Recorded so they are not rediscovered as good ideas. Each was considered and rejected with a
reason.

- **A layering/allowlist test.** Five edges and no interior node: `Ast.ps1` has out-degree 0,
  the two metrics have one caller each, `Measure-PSComplexity` has none. A graph with no
  interior node cannot grow a non-obvious cycle. Add it when #5 or #2 creates a module both
  exported commands consume -- that is the trigger, not a line count.
- **Merging the three construct lists into one constant.** They agree element-for-element
  today, and their differences are roles rather than drift: `ScriptBlockExpressionAst` is
  nesting-only (correct per Sonar B3) and `SwitchStatementAst` is handled separately by
  Cyclomatic because it counts per clause. One list is exactly as blind to a new construct as
  three. The fix is #32 and #18, not the merge.
- **Making `Test-PSComplexity` return violation objects instead of `[bool]`.** The
  thin-predicate-over-`Measure` split is right, documented, duplicates no measurement, and
  matches the `Test-*` convention. Nothing in the queue routes through it -- #2, #3, #5 and #7
  all build over `Measure-PSComplexity`'s records. What is missing is a scan noun, not a
  richer verdict.
- **A second AST walk for attribution.** Cheapest to write, and the only option that can
  produce two answers to the same question.
- **Content-hash unit identity for #2.** It survives moves and renames but changes whenever the
  unit is edited at all -- precisely when a ratchet needs to compare.
- **Gating on a file-level aggregate.** It would punish legitimate decomposition, and no
  published definition of either metric is file-level. See #22.
