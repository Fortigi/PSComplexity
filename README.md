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
C:\proj\src\Foo.ps1     <script-body>           1          1         0
C:\proj\src\Foo.ps1     Get-Foo                12          8         9
C:\proj\src\Foo.ps1     Order.Process          31          5        10
```

Class members are reported as `Class.Member`, so two classes with a method of the same
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
| `Measure-PSComplexity -Path <files/dirs> [-Recurse]` | per-unit records | inspect / report |
| `Test-PSComplexity -Path <files/dirs> [-Recurse] [-MaxCyclomatic 15] [-MaxCognitive 15]` | `[bool]` | CI gate (warns per offender) |

## Use it in CI

```yaml
- shell: pwsh
  run: |
    Install-Module PSComplexity -Force -Scope CurrentUser
    if (-not (Test-PSComplexity ./src -Recurse)) { throw 'Complexity gate failed' }
```

## Development

```powershell
Invoke-Pester ./tests   # reference-score tests + end-to-end + self-complexity gate
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

All gates (lint, reference-score tests, self-complexity gate) run on **Windows and
Linux** in the required CI job and block the merge.

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
