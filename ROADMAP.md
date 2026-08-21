# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull, do the most-requested thing first,
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track
progress here: a second status list drifts from the first, which is the exact failure this
project exists to find in other people's code.

Snapshot 2026-08-21. 33 issues open.

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
a SCAN above the unit: what was looked at,  ---> #6 parse errors, #7 diff-scoped, #5 summary
  skipped, in scope, under which thresholds
a unit IDENTITY that survives a commit      ---> #2 baseline, #7, and #5 the moment it pins a shape
  and a machine
```

Both levels are destroyed at the moment of creation rather than at the boundary. That is not
four problems; it is one design fact seen from four sides, and it is why the record shape has
to be decided before any feature is built on it.

## The constraints that force the order

```
#29 discovery      ---> everything. A scan that measures nothing makes every other number a
                        statement about the empty set
#15 empty verdict  ---> same, from the output side
#34 vacuous test   ---> #29. The test that should have caught it certifies it instead

#14 identity   ]
#16 increment  ]--> #2 baseline, #3 attribution, #5 report, #7 diff-scoped
#17 scan noun  ]    all four read or persist a record the current shape cannot express

#20 metric version ---> #2. A baseline compares two runs; if the metric moved between them,
#21 exceptions     ---> #2. it re-baselines everything at once, or mutes without an argument
```

Three things follow that are worth stating out loud:

- **#2 is the most-wanted item and should not be first.** A committed baseline is the natural
  next feature and it depends on four things that do not exist: a stable identity, a metric
  version, an exception concept, and a scan. Building it first means building it twice.
- **#3 is not a small issue.** It reads as "also report which construct" -- an afternoon. It is
  a change to the intermediate representation: increments are summed at emission, twelve
  producers deep, so the information it asks for is destroyed two layers below where the
  question is asked. Size it as structural work or it will be scheduled as an afternoon.
- **The gate currently cannot fail in three separate ways.** #29, #15 and #34 are not three
  bugs of similar weight to the rest of the list; until they are fixed, every number this
  project publishes about itself is a claim about a set that may be empty.

---

## Wave A -- make the numbers real

Nothing else on this list means anything while a scan can measure nothing and report success.
All three are small, and they are the only items here where "fix it this week" is the honest
recommendation.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#29**, **#34** | `-Include` without `-Recurse` matches nothing, and `-Path` wildcard-parses a `[` in a directory name. Together: a flat `./src` measures zero files and passes. #34 is the test that asserts only an absence and so certifies the bug -- fix it in the same PR, and run it against the current resolver first to watch it fail. |
| 2 | **#15** | The verdict side of the same hole: `$true` after measuring zero units. One branch. Do it even if nothing else on this roadmap moves. |
| 3 | **#13** | The self-mutation gate pins PSMutant 0.1.0, two releases behind the fix for a silent fake 100%. The pin bump is one line; adopting the opt-in operators is real work and belongs in Wave C. |

## Wave B -- decide the record shape

The expensive-to-reverse decisions, and the reason to take them before any feature: #5 says to
"treat its shape as an interface and pin it in a test", and after that a wrong key costs a
major version.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#14** | Unit identity is neither unique (two nested `Get-Inner`s collide) nor portable (`File` is absolute and platform-separated, and CI runs two OSes). #2 and #7 both assume otherwise **in their own text**. One function, because `Get-PSCxUnitName` centralises naming. |
| 2 | **#17**, **#16** | The two missing levels. Take them together: they are the same decision about what a record is, and deciding one without the other produces a shape that has to move again. |
| 3 | **#20**, **#21** | Metric version and the exception concept. Both are cheap now and expensive after #2 ships a bare snapshot -- a committed baseline with no version re-baselines silently on upgrade, and with no exception concept it is a mute button rather than an agreement. |

**#22 is not a position here.** It is a decision to record, not work: complexity exists per
unit, extraction lowers the score by design, and the README over-claims by calling the number
a measure of how hard code is to understand. Settle it in whichever PR touches the README --
before #5 publishes a report shape that implies an answer.

## Wave C -- make the metric honest

| Order | Issue | Why here |
|---|---|---|
| 1 | **#30** | `&&`, `||` and `??` are invisible: a function branching only through them scores 1/0 where the `if` rewrite scores 10/16. A missing map entry, not missing machinery -- but every score for modern PowerShell rises, so it is a major version and wants deciding, not slipping in. |
| 2 | **#32**, **#18** | Nothing pins the vocabulary from either side: 5 of 7 cyclomatic and 4 of 8 cognitive types can be deleted with the suite green (#32), and nothing notices when PowerShell adds one (#18). Same test file, opposite directions. |
| 3 | **#4** | Pin the metric against the SonarSource examples. All eleven reference cases currently pass, including both "classic implementation errors" -- so this is a pinning gap, not a correctness bug, and it is cheaper after #16 makes increments addressable. |

## Wave D -- the features everyone actually wants

Only reachable once B is decided. In this order because each one's prerequisites are the
previous one's output.

**#5** machine-readable report, then **#3** per-construct attribution, then **#2** committed
baseline, then **#7** diff-scoped measurement. #6 (a parse error is a silent warning) lands
with #17, because it is the visible symptom of a type with no vocabulary for failure.

---

## CI and release -- do these alongside, not in sequence

None blocks anything on the critical path, and they cluster: several touch the same files, so
they are cheaper as one or two PRs than as nine.

- **#31**, **#33**, **#38** -- the publish path. No permissions block on two workflows against
  a `write` default; `github.ref_name` interpolated into a pwsh string, so a crafted tag runs
  code in the job holding the Gallery key; and nothing requires a second person for the one
  irreversible action in the project. Take these together -- same file, same theme, and the
  combination is the actual exposure: push access becomes the publish credential.
- **#23**, **#24** -- the staged package is never loaded before it ships, and nothing checks
  the CHANGELOG against `ModuleVersion`. Both guard the irreversible step. Note there is
  already one instance in the repo: `0.2.0` shipped with no `0.2.0` heading.
- **#19**, **#26**, **#35** -- the two analyzer gates disagree about severity and paths, pins
  are inline across three workflows, and ConvertToSARIF is not pinned at all. One committed
  script both gates call fixes the first and makes the rest obvious.
- **#25** -- concurrency, timeouts, cache. Cheap. Note `publish.yml` wants the opposite
  `cancel-in-progress` to the others, for the reason its sibling repo records.
- **#27** -- 100% coverage is claimed in CLAUDE.md and gated nowhere.

## Low-coupling fillers

- **#36**, **#37** -- `Get-PSCxUnitTable` rebuilt three times per file, two of them waste; and
  analysis is O(nodes x depth). Neither matters at current scale -- measured, 37 KB and 401
  units in 1.65s, and PSScriptAnalyzer over a comparable corpus is several times slower. Do
  them when #7 makes per-file cost matter, or when a deeply nested file makes someone notice.
- **#28** -- five documentation claims the code does not support, including two proven false
  by running: load order is inert (all 24 permutations give one hash), and `.GetNewClosure()`
  on the per-type loops is not required. Do it as one pass, and test the two testable ones.
- **#10** -- move to Pester 6.1.0. Independent of everything above.

---

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
