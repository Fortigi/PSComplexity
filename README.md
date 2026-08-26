# PSComplexity

**Cyclomatic and cognitive complexity for PowerShell.**

Cyclomatic complexity counts control-flow branches (how many paths to test). **Cognitive
complexity** — the [SonarSource](https://www.sonarsource.com/docs/CognitiveComplexity.pdf)
metric — measures how hard code is to *understand*: it rewards flat code and penalises
nesting. PSComplexity computes both per unit (each function/filter, each class method,
constructor and initialised property, plus one `<script-body>` per file) straight from
the PowerShell AST, and ships a CI gate.

> To our knowledge PSComplexity is the first module on the PowerShell Gallery to offer a
> cognitive-complexity metric at all (cyclomatic exists only in the unmaintained
> PSCodeHealth). It **implements the SonarSource metric in full, and extends it for
> PowerShell constructs the specification does not cover** — every reference example scores
> exactly as published, see `tests/Cognitive.Tests.ps1`. The extensions are listed below.

## Install

```powershell
Install-Module PSComplexity -Scope CurrentUser   # PowerShell 7.2+
```

## Use

```powershell
Import-Module PSComplexity

# Report every unit, most complex first:
Measure-PSComplexity ./src -Recurse | Sort-Object Cognitive -Descending |
    Format-Table File, Unit, Line, Cyclomatic, Cognitive

# Gate a build (returns $false + a warning per offender):
if (-not (Test-PSComplexity ./src -Recurse -MaxCyclomatic 15 -MaxCognitive 15)) {
    throw 'Complexity gate failed'
}
```

`Measure-PSComplexity` accepts files or directories (pipeline-friendly) and emits objects:

```
File                    Unit                 Line Cyclomatic Cognitive
----                    ----                 ---- ---------- ---------
src/Foo.ps1             <script-body>           1          1         0
src/Foo.ps1             Get-Foo                12          8         9
src/Foo.ps1             Order.Process          31          5        10
```

A unit name identifies one unit. Class members are reported as `Class.Member`, a function
nested inside another as `Outer/Inner`, and units sharing a name in the same scope — two
overloads, or a function defined twice — carry an ordinal on **every** member of the group
(`Repo.Add#1`, `Repo.Add#2`). Suffixing only the second would silently rename the first the
day an overload is added. So two classes with a method of the same
name — or a class method and a function of that name — stay distinct, in the output and
in any per-unit baseline built from it. A class property is a unit only when it has an
initialiser: that is code which runs, and it belongs to the property rather than to the
enclosing script body.

## The two metrics

**Cyclomatic** = 1 + decision points (each `if`/`elseif`/`switch` clause, each
`for`/`foreach`/`while`/`do` loop, each `catch`/`trap`, each ternary, each `-and`/`-or`).

**Cognitive** (the SonarSource rules; the PowerShell extensions follow):

| Rule | Effect |
|---|---|
| B1 structural (+1 each) | `if`, `else`/`elseif`, `switch`, loops, `catch`/`trap`, ternary, a **labelled** `break`/`continue`, each maximal run of `-and`/`-or`, each direct recursive call |
| B2 nesting (+depth) | added to `if` (leading clause), `switch`, loops, `catch`/`trap`, ternary — **not** to `else`/`elseif`, boolean runs, labelled jumps, or recursion |
| B3 nesting level | raised by the structures above **and** by nested script-block lambdas (e.g. a `ForEach-Object { }` body) |

So a flat function scores 0; a `switch` scores 1 regardless of case count; a deeply
nested loop-in-loop-in-`if` grows fast — mirroring how hard it is to follow.

## API

| Command | Returns | Purpose |
|---|---|---|
| `Measure-PSComplexity -Path <files/dirs> [-Recurse] [-Detailed] [-ReportPath <file>]` | per-unit records | inspect / report |
| `Test-PSComplexity -Path <files/dirs> [-Recurse] [-MaxCyclomatic 15] [-MaxCognitive 15] [-Accept <declarations>] [-ReportPath <file>] [-SarifPath <file>]` | `[bool]` | CI gate (warns per offender) |

### The record is the API

`Measure-PSComplexity` emits one object per unit with exactly these fields, in this order:

| Field | Type | |
|---|---|---|
| `File` | `[string]` | path relative to the working directory, forward slashes; full path if outside it |
| `Unit` | `[string]` | function, method, or `<script-body>` |
| `Line` | `[int]` | where the unit starts |
| `Cyclomatic` | `[int]` | |
| `Cognitive` | `[int]` | |
| `MetricVersion` | `[int]` | which metric produced these numbers |

`MetricVersion` increments whenever a score can change for source that did not -- a narrower
rule than the module version, so a bug fix that only affects messages, or a new field on this
record, leaves it alone. It has happened twice: 0.3.0 taught the metric PowerShell's own flow
constructs, and 0.4.0 stopped merging two units written on one line. Both were corrections, and
both silently re-scored code nobody had touched. Anything that persists or compares scores should
refuse to compare across two values rather than mix them. It starts at **1** with 0.4.0; earlier
releases carry no version and are not comparable with these.

Those names, their order and their types are the public contract, and a test asserts them
exactly -- a sixth field fails the suite, so widening this is a decision rather than a side
effect. `Line` is deliberately **not** an identity: it moves whenever anything above a unit
is edited, so it says where a unit currently starts, not which unit it is.

### Where a score came from

A unit comes back as `Cognitive = 23`. That number is correct and, on its own, unactionable:
it does not say whether it is one deeply-nested loop or twenty flat guards, and those call for
opposite fixes. `-Detailed` adds a `Contributions` list holding every increment that made up
the total:

```powershell
# Thing.ps1
# 1  function Invoke-Thing {
# 2      param($a, $b)
# 3      & {
# 4          if ($a) {
# 5              if ($a -and $b) { 'x' }
# 6          }
# 7      }
# 8  }

$unit = Measure-PSComplexity ./Thing.ps1 -Detailed | Where-Object Unit -eq 'Invoke-Thing'
$unit.Contributions | Format-Table Line, Construct, Amount
```

```
Line Construct   Amount
---- ---------   ------
   4 if               2
   5 boolean-run      1
   5 if               3
```

`Cognitive = 6`, and the breakdown says where: the `if` on line 4 costs 2 rather than 1
because the `& { }` lambda already raised the nesting level, and the one on line 5 costs 3
for sitting inside it. Two `if`s and one `-and` would be 3 points written flat; the same
three constructs nested cost 6.

Read the **amounts**, not just the count. A `+1` is a structure; anything larger is that
structure plus its nesting depth, because nesting is what the B2 rule charges for. So four
`+1` rows and one `+4` row reach the same total and mean different things -- points spread flat
say the unit does too many things, points concentrated in one deep row say extract. That is
the distinction the bare total cannot make.

Three properties of the list are worth relying on:

- **The amounts sum to `Cognitive`**, and a test asserts it. Be precise about what that buys:
  the score and the breakdown are computed from the *same* rows, so the sum catches a row
  dropped or misattributed on the way to this list -- it cannot catch a construct scored wrong
  in the first place, because that moves both sides together. Verified both ways rather than
  assumed. Whether the scores themselves are right is the reference-score suite's job.
- **Rows are in line order**, so a unit reads top to bottom.
- **A decision-free unit gets an empty list, not a missing property.** Absent and empty are
  different answers, and iterating the property should not require telling them apart.

`Contributions` covers the **cognitive** score only; cyclomatic is a count of decision points
and its total is already its own explanation.

Nothing changes without the switch. The six fields above are what a default run emits, in that
order, and CI consumers that parse it are unaffected.

### Disagreeing with a number

Every complexity gate eventually meets a unit that is genuinely, irreducibly complex -- a
parser, a dispatch table, a state machine -- where the honest answer is "yes, and here is why
that is correct". Without a way to say so the only options are lowering the ceiling for
everyone or not measuring the file, and the second is indistinguishable from never having
looked.

`-Accept` is the third answer. Each entry names one unit and carries the argument for it:

```powershell
$accept = @(
    @{ File   = 'src/Parser.ps1'
       Unit   = 'Read-Token'
       Reason = 'table-driven lexer; splitting the table across helpers hides it' }
)

if (-not (Test-PSComplexity ./src -Recurse -Accept $accept)) { throw 'Complexity gate failed' }
```

**It is a checkable claim, not a suppression.** The gate **throws** when an acceptance stops
describing the run:

| The claim | What happened |
|---|---|
| no unit of that `File` + `Unit` was measured | renamed, moved, or outside the path being gated |
| the unit is within both ceilings | somebody fixed it and left the note behind |
| `Reason` is empty or whitespace | a declaration with no argument is a mute button |
| `File` or `Unit` missing | the claim does not say what it is about |

That is the whole difference from a suppression list. A suppression that stops applying goes
on sitting in the file, excusing nothing, and the next breach of that unit passes unnoticed --
so the list ages into a mute button nobody dares delete. An acceptance fails the build that
relies on it instead, on the run where it stopped being true.

Three properties worth relying on:

- **Every fault is reported at once**, not the first, so fixing a stale list costs one CI round
  trip rather than one per entry.
- **The key is `File` *and* `Unit`.** A gate keyed on the symbol alone would excuse every
  like-named unit in the tree, which is how suppression lists usually leak.
- **An accepted unit is still measured.** This is gate policy, not a measurement filter, so the
  unit keeps its record and its number -- a report or a baseline built on the same records still
  sees it. Hiding it would take the argument away along with the number it is about.

`File` must match the record's `File` exactly: relative to the working directory with forward
slashes, or the full path for a file outside it.

### Turning the gate on when you are already over the line

A repo with forty units above the ceiling has two options without a baseline, and neither
improves anything: set the ceiling so high it gates nothing, or leave the check off.

`-BaselineFile` is the third. It is a committed JSON file recording what each already-over-the-limit
unit scored, and it changes the answer to "we have forty violations" from *raise the threshold* to
**record them, then never add a forty-first**.

```powershell
# once, to record where you are starting from -- then commit the file
Test-PSComplexity ./src -Recurse -BaselineFile ./complexity-baseline.json -UpdateBaseline

# from then on, in CI
if (-not (Test-PSComplexity ./src -Recurse -BaselineFile ./complexity-baseline.json)) {
    throw 'Complexity gate failed'
}
```

Two rules, and the second is the one that makes it worth having:

- A unit **in** the baseline may not exceed its recorded score. It is allowed to stay ugly.
- A unit **not** in the baseline must be under the ceilings -- so new and touched code meets the
  real bar from day one, on the first run, with no grace period to negotiate.

The file looks like this:

```json
{
  "schemaVersion": 1,
  "metricVersion": 1,
  "generatedAt": "2026-08-25T09:12:44Z",
  "units": [
    { "file": "src/Parser.ps1", "unit": "Read-Token", "cyclomatic": 34, "cognitive": 41 }
  ]
}
```

**It ratchets, and it only ratchets down.** `-UpdateBaseline` refuses to record a unit worse than
the file already does, naming the units that regressed. Without that refusal, re-running the tool
would absorb whatever the gate had just caught, and the baseline would be a suppression list that
updates itself.

**It is a checkable claim, like an acceptance.** The gate **throws** when an entry stops describing
the run:

| The entry | What happened |
|---|---|
| names a unit that was not measured | renamed, moved, or outside the path being gated |
| names a unit now within both ceilings | it was fixed; the real bar covers it and the entry is fiction |
| records a number **larger** than reality | it improved -- lower the entry, or `-UpdateBaseline` |
| is also in `-Accept` | the acceptance already excuses it, so the entry permits nothing |
| appears twice | one of the two decides what is permitted and the other silently does nothing |
| `file` or `unit` missing | the entry does not say what it is about |

The third row is the ratchet tightening, and it is deliberately a failure rather than a shrug: a
baseline that keeps a number the code no longer needs has quietly stopped being a baseline.

**The key is `file` and `unit`, never a line.** A line number moves whenever anything above it is
edited, and the entry then goes stale although the unit did not change.

One identity is refused outright. Duplicate definitions in a single file are told apart by an
ordinal -- `Get-Thing#1`, `Get-Thing#2` -- and an ordinal **renumbers when a duplicate is inserted
above it**, so the entry would silently begin capping a different function. Rename one of the
duplicates; in PowerShell the later definition shadows the earlier at run time anyway, so one of
them is already dead code.

**A baseline recorded against a different `metricVersion` is refused rather than compared.** When
the metric changes, old scores are not larger or smaller -- they are answers to a different
question. `-UpdateBaseline` regenerates such a file wholesale, and the diff is where it gets
reviewed.

`-UpdateBaseline` writes no report and no SARIF: the verdict they would record is one the call
just manufactured by recording every breach.

### A report something else can read

Objects are right for a shell and awkward for everything else. `-ReportPath` writes the same
run as JSON, described by `schemas/v1/report.schema.json`, which ships with the module so a
consumer can validate a report without reading this repo's tests.

```powershell
Measure-PSComplexity ./src -Recurse -ReportPath ./reports/complexity.json
Test-PSComplexity   ./src -Recurse -ReportPath ./reports/gate.json -SarifPath ./reports/gate.sarif
```

The record stream is unchanged -- the report is written alongside it, never instead of it.

**Two shapes, and the difference is load-bearing.** A measurement report carries the units, the
scope that was asked for, the files that were skipped and why, a summary, and the metric version
that produced the numbers. A gate report adds the ceilings that applied, the verdict, the units
that breached, and every acceptance with its argument.

A measurement report **cannot** carry a verdict, and the schema is what makes that true rather
than a promise: `passed` is forbidden unless `thresholds` are present. `Measure-PSComplexity`
applies no ceilings, so a verdict beside its numbers would be an answer nobody computed.

Three fields are required for the same reason the summary exists at all:

| Required | Because |
|---|---|
| `metricVersion` | the metric has moved twice for source that did not change; a stored number that cannot be checked for comparability is a trend chart waiting to mislead |
| `scope` | an aggregate that cannot say what it covered is not an aggregate anyone can act on |
| `skipped` | a report that omits what it could not read describes a smaller job than the one it was asked to do |

`schemaVersion` changes when a field changes meaning or disappears, **never** when one is added
-- so the schema permits properties it has never seen, and a consumer validating against it
survives a release that records more.

### Inline on a pull request

`-SarifPath` writes a SARIF 2.1.0 log, which GitHub code scanning renders against the diff:

```yaml
- name: Complexity gate
  shell: pwsh
  run: |
      $ok = Test-PSComplexity ./src -Recurse -SarifPath ./complexity.sarif
      if (-not $ok) { Write-Host '::warning::complexity gate failed' }
- uses: github/codeql-action/upload-sarif@v3
  with:
      sarif_file: ./complexity.sarif
```

One result per breached ceiling, under two rule ids -- `PSCxCyclomatic` and `PSCxCognitive` --
so a unit over both produces two, and a team can suppress one metric without silencing the
other. Findings are fingerprinted on **file and unit, never on the line**: a line moves whenever
anything above the unit is edited, and a fingerprint built on it would close and reopen the same
finding on an unrelated change.

**An accepted unit produces no SARIF result.** The gate excused it, and asking a reviewer to act
on something already argued is noise. The argument is not lost -- the JSON report carries it
under `accepted`, which is where "what did this run excuse" is answered.

Only the gate writes SARIF. Without ceilings there is no such thing as a finding, so a SARIF file
from `Measure-PSComplexity` would be an empty results array claiming a clean bill of health.

## Use it in CI

```yaml
- shell: pwsh
  run: |
    Install-Module PSComplexity -RequiredVersion 0.4.0 -Force -Scope CurrentUser
    if (-not (Test-PSComplexity ./src -Recurse)) { throw 'Complexity gate failed' }
```

**`-RequiredVersion`, not a floor.** A gate decides whether a build passes, and this
module's metric has already moved twice for unchanged source. Without an exact version two
machines on the same commit can legitimately disagree about whether the build is green --
and the one that upgraded first looks like the one that broke it.

That pin is also what makes a committed baseline safe to compare against. A baseline records
which `metricVersion` produced its numbers and refuses to be read across a change to it, so an
unpinned upgrade turns into a clear refusal rather than a quietly wrong comparison -- but a
refusal still fails the build, and pinning is how you choose when to deal with it.

On a codebase already over the ceilings, add the baseline and nothing else changes about the
above:

```yaml
    if (-not (Test-PSComplexity ./src -Recurse -BaselineFile ./complexity-baseline.json)) {
        throw 'Complexity gate failed'
    }
```

## Development

```powershell
Invoke-Pester ./tests   # reference-score tests + end-to-end + self-complexity gate
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

All gates (lint, reference-score tests, self-complexity gate) run on **Windows and
Linux** in the required CI job and block the merge.

## What the number does not say

Two things follow from measuring **per unit**, and both are decisions rather than gaps. They
are written down because a reader who discovers them from the output will reasonably assume
one of them is a bug.

**The gate cannot tell decomposition from displacement.** A 20-line `Invoke-Deploy` scoring
14/38 fails at the default ceilings. Split the *identical* control flow into four private
helpers plus an orchestrator and the maximum drops to 6/10, the gate passes, and the file's
total cognitive falls from 38 to 21 -- a total that appears nowhere, because the output is
per unit and the gate is a maximum over units.

Whether that split made the code easier to read is a question the tool cannot answer. Often
it does; sometimes it only moves the branch somewhere else. Complexity exists per unit, so a
per-unit measure is the honest one, and this is the price of it. This module does the same
thing to itself and says so: `Cognitive.ps1`'s row collectors are split into small functions
partly so the metric clears its own gate, while `Get-PSCxCyclomaticRow` leaves the same shape
inline and is the joint-highest unit here.

A related consequence worth knowing before trusting a low score: a 60-line function assigning
sixty fields through a `$global:` accumulator scores **1/0** -- identical to
`function Get-Flat { $x }`. Neither metric measures length, coupling or state.

**A nested named function contributes nothing to its parent.** The same body written as a
script block contributes 3/5. That asymmetry is deliberate: a nested named function is
discovered as its own unit and gets its own row, so its complexity is measured -- just not
*there*. A script block has no unit of its own, so its complexity must land on the enclosing
function or vanish.

It is also the cheaper of the two displacement routes, since a hard branch moved into a
nested named function drops the parent under the ceiling without moving a line out of the
file. **This is a deliberate departure from SonarSource**, whose specification increments for
nested function *declarations* in languages that have them, for exactly that reason. Recorded
here rather than silently: every other reference score in this module matches the spec, and
the ones that do are attributed in the test suite.

## Notes / scope

- **PowerShell 7.2+ only** (Core). Windows PowerShell 5.1 is not supported.
- Cognitive complexity is computed via ancestor-based nesting analysis; it reproduces the
  SonarSource reference scores. Mutual (indirect) recursion is not counted — only direct
  self-recursion, matching the common implementation.

### PowerShell-specific increments

The SonarSource specification predates these constructs or was written for languages that
lack them, so it says nothing about how to score them. Each is scored by the rule it most
resembles, and the choice is stated here rather than left to be discovered from a number:

| Construct | Scored as | Why |
|---|---|---|
| `ForEach-Object`, `%` | a loop | It is PowerShell's second loop. A body written with it branches exactly as much as the `foreach` form, and scoring it lower rewarded a rewrite that changes nothing a reader would call a decomposition. |
| `Where-Object`, `?` | a conditional | Same argument: it is a filter, and a filter is a branch. |
| `&&`, `\|\|` | a boolean run | They are control flow between pipelines, not boolean operators — but a *run* of them costs 1, exactly as `-and`/`-or` does, so the shell idiom is never dearer than the expression it mirrors. |
| `??`, `??=` | a ternary | A choice between two values on a null test, which is what the ternary rule already covers. |

`foreach` and `where` are recognised as **aliases** of the two cmdlets. The keyword forms
parse to different AST nodes entirely, so there is no ambiguity.

If you need the specification's numbers exactly and nothing more, pin `0.2.0`; every score
here is greater than or equal to the one it produced.


## License

MIT © Fortigi
