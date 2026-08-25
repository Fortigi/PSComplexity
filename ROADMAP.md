# Sequencing

The issue tracker records **what** to do. Nothing recorded the **order**, and several queued
issues are prerequisites for others -- so the natural pull, do the most-requested thing first,
is the one ordering that makes the rest more expensive.

This file records **ordering rationale only**. Status lives in the issues. Do not track
progress here: a second status list drifts from the first, which is the exact failure this
project exists to find in other people's code.

Snapshot 2026-08-25, with **0.4.0 prepared and unreleased**. 10 issues open. The snapshot
reflects what has **merged**; work with a pull request open still holds its ordering entry
below, because an entry removed on the strength of an open PR is a status claim in disguise.

Completed waves are **removed rather than ticked**. A plan that lists finished work is a worse
plan, and this file holds no status by design. Removal is the one exception, because it is
one-way and cannot drift the way a checklist would. Wave letters keep their original letters
as earlier ones disappear, so "Wave A" in an existing commit or PR still resolves.

---

## The one fact that orders everything

This section used to say the module has exactly one noun, and that every open request was
asking for one of the two that did not exist. Two of the three levels now exist, so the fact
that orders the rest has changed shape and is worth restating rather than quietly editing.

```
an INCREMENT below the unit   BUILT -- every row carries the construct that caused it and the
                              line it sits on, and -Detailed publishes them per unit

a RECORD at the unit          BUILT -- six fields, their order and their types pinned by a
                              test; an identity unique within a file and equal on both CI
                              legs; a MetricVersion that moves only when a score can change
                              for source that did not

a SCAN above the unit         BUILT, and deliberately unpublished -- what was in scope, which
                              units were found, which files were skipped and why
```

**What is left is no longer a missing level.** It is one concept (#21), the decision of when
to publish the scan, and the four features that read these three levels. That is a materially
easier position than the one this file was written in, and the ordering below reflects it.

The remaining structural claim is narrower and still true: **a level is destroyed the moment
it is folded, not at the boundary where the question is asked.** That is why attribution had
to precede the report, and why the scan had to precede the baseline. Anything new that folds
information -- a file-level aggregate, a summary statistic -- inherits the same rule.

## The constraints that force the order

```
#21 exceptions ---> #2 baseline. A snapshot with no way to disagree with a number is a mute
                    button: the first person who cannot accept a unit edits the baseline, and
                    nothing records that an argument was ever made.

#5 report      ---> the decision to PUBLISH the scan. It is the first consumer, so it is the
                    point where an internal shape becomes a contract. Take that decision in
                    #5, not before and not by accident.

#2 baseline    ---> #7 diff-scoped. #7 needs to say which units were in scope AND compare them
                    against something; scope exists now, the comparison does not.
```

Three things follow that are worth stating out loud:

- **#2 is still the most-wanted item and still should not be first.** Its prerequisites used
  to number four; three of them have shipped. What remains is #21, and the argument is
  unchanged: build the baseline first and you build it twice.
- **The scan is built and not exported, and that is a position rather than an omission.**
  Publishing it means one command with two output shapes, where a pipeline written against the
  record stream returns nothing under the other one. That price is worth paying when something
  needs it and not before, and #5 is the something.
- **#3 is gone from this file, and its lesson is not.** It read as "also report which
  construct" -- an afternoon -- and was a change to the intermediate representation twelve
  producers deep. Size the remaining features by what they fold, not by what they print.

---

## Wave A -- gone

Shipped in 0.3.0 and removed rather than ticked.

## Wave B -- finish the record shape

The expensive-to-reverse decisions. Most of this wave has landed: the record's fields, their
order and their types are asserted exactly, a unit has a portable identity, every record
carries a MetricVersion, and the increments underneath carry their construct and line. All of
it landed **before** anything persists a key, which is the ordering this wave existed to
protect.

| Order | Issue | Why here |
|---|---|---|
| 1 | **#17** | The scan: what was looked at, what was skipped and why, what was in scope. The last of the three levels, and the one every Wave D feature reads. |
| 2 | **#21** | The exception concept. Cheap now; after #2 ships a bare snapshot, a declaration is a mute button rather than an agreement, and there is no later moment at which it gets cheaper. |

**#83** travels with this wave without being part of it: a boundary-list entry that changes no
observable answer when removed. Recorded rather than removed on a guess, because "changes no
answer I can find" and "changes no answer" are not the same claim.

**The two decisions this wave owed the README are recorded and gone from here.** That the gate
cannot tell decomposition from displacement, and that a nested named function adds nothing to
its parent where the same body as a script block adds 3/5 -- a deliberate departure from
SonarSource -- are now stated in the README as properties of a per-unit metric. They were
removed from this file rather than ticked, and they landed before #5 publishes a report shape
that would imply an answer to either.

## Wave C -- gone

Closed. The metric scores PowerShell's own flow constructs, all 66 concrete Ast types are
classified as handled or reasoned about, twenty reference cases pin every entry in all three
type lists, and every reference score names its source so a number this project chose cannot
sit among them looking like one from the specification.

## Wave D -- the features everyone actually wants

Only reachable once B is decided. In this order because each one's prerequisites are the
previous one's output.

| Order | Issue | What it needs that now exists | What it still decides |
|---|---|---|---|
| 1 | **#5** report | the scan, and increments that know their construct and line | whether the scan becomes public, and in what serialised shape |
| 2 | **#2** baseline | identity, MetricVersion, the scan | #21 first; and what a ratchet does when the metric version moves |
| 3 | **#7** diff-scoped | `Scope` on the scan | how "changed" is determined, and by whom |

The ordering is not preference. #5 is first because it is the cheapest thing that consumes the
scan end to end, so it proves the shape while the shape is still free to change. #2 is second
because it is the first thing that **persists** a key, after which changing one costs a major
version. #7 is last because it is the only one whose input is another tool's output.

---

## Gate integrity

Separated from the CI cluster because it is a different kind of claim. These are the scripts
that decide whether every other number here is true, and a gate that has quietly stopped being
able to fail looks exactly like a green build.

  - **#85** -- `Invoke-PSCxAnalyzer.ps1` reports findings on the output stream and exits 0, so
    running it by hand checks nothing and only the workflow's own `throw` makes it a gate. It
    is not hypothetical: a hand-run "clean" was reported from its exit code more than once
    while findings were sitting in the output, and CI caught what the local run had said was
    fine. The sibling repo has the same defect filed against the same shape of script.

## CI and release -- most of this shipped

One committed analyzer script both gates call, pins in `.github/pins.env`, an enforced 100%
coverage gate, concurrency groups, timeouts and least-privilege permissions on all three
workflows, a publish that requires the CI conclusion for its exact commit on **both** matrix
legs, a release-consistency check that generates the manifest notes from the CHANGELOG, a
staged-package smoke test that loads the artifact before it becomes permanent, and two pin
watchers -- a weekly job for module versions and Dependabot for the action SHAs, which
`pins.env` structurally cannot hold because `uses:` does not expand variables.

Two negatives worth keeping, because both look like protection and are not:

- A `tag_name_pattern` ruleset is accepted by the API and **never evaluated**. Verified by
  pushing a violating tag with that rule as the only active one.
- `Find-Module` returns nothing both when a version is unpublished and when the gallery is
  unreachable. Anything that asks the gallery must check reachability first, or "could not
  look" is read as "nothing there".

What is left:

  - **#56** -- the parity tracker against the sibling repo. Most rows are closed; keep it
    open until the last one is, then delete it rather than leaving a tracker of nothing.

## Low-coupling fillers

- **#36**, **#37** -- `Get-PSCxUnitTable` rebuilt three times per file, two of them waste; and
  analysis is O(nodes x depth), so a deeply nested file costs orders of magnitude more per byte
  than ordinary code. Neither matters at current scale -- measured, 37 KB and 401 units in
  1.65s, and PSScriptAnalyzer over a comparable corpus is several times slower. Do them when #7
  makes per-file cost matter, or when a deeply nested file makes someone notice.

  #37 is also why naming each file before measuring it mattered: uneven per-file cost is
  exactly what makes a scan that is working look stuck.

## Deliberately not doing

Recorded so they are not rediscovered as good ideas. Each was considered and rejected with a
reason.

- **A layering/allowlist test.** The file graph is five edges wide and has never grown a
  shortcut. Reconsider when a module both exported commands consume lives in its **own file** --
  the scan is such a module, but it sits in `Measure-PSComplexity.ps1` beside its callers, so
  the file graph is unchanged. That move is the trigger, not a line count.
- **Merging the three construct lists into one constant.** They agree element-for-element
  today, and their differences are roles rather than drift: `ScriptBlockExpressionAst` is
  nesting-only (correct per Sonar B3) and `SwitchStatementAst` is handled separately by
  Cyclomatic because it counts per clause. One list is exactly as blind to a new construct as
  three.
- **Making `Test-PSComplexity` return violation objects instead of `[bool]`.** The
  thin-predicate split is right, documented, and duplicates no measurement. This entry used to
  say "what is missing is a scan noun, not a richer verdict" -- the scan now exists, and
  `Test-PSComplexity` consumes it, which strengthens the entry rather than retiring it: the
  richer answer has a home that is not the verdict.
- **A second AST walk for attribution.** Cheapest to write, and the only option that can
  produce two answers to the same question.
- **Content-hash unit identity for #2.** It survives moves and renames but changes whenever the
  unit is edited at all -- precisely when a ratchet needs to compare.
- **Gating on a file-level aggregate.** It would punish legitimate decomposition, and no
  published definition of either metric is file-level. See "What the number does not say" in
  the README, which now states that per-unit measurement cannot distinguish the two.
- **Publishing the scan before something consumes it.** A shape with no consumer is a guess,
  and an exported guess is a contract. #5 is the consumer; take the decision there.
