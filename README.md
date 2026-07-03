# PSComplexity

**Cyclomatic and cognitive complexity for PowerShell.**

Cyclomatic complexity counts control-flow branches (how many paths to test). **Cognitive
complexity** — the [SonarSource](https://www.sonarsource.com/docs/CognitiveComplexity.pdf)
metric — measures how hard code is to *understand*: it rewards flat code and penalises
nesting. PSComplexity computes both per unit (each function/filter, plus one
`<script-body>` per file) straight from the PowerShell AST, and ships a CI gate.

> To our knowledge PSComplexity is the first module on the PowerShell Gallery to offer a
> faithful cognitive-complexity metric (cyclomatic exists only in the unmaintained
> PSCodeHealth). The cognitive scores are validated against the SonarSource reference
> examples — see `tests/Cognitive.Tests.ps1`.

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
File        Unit                 Line Cyclomatic Cognitive
----        ----                 ---- ---------- ---------
src\Foo.ps1 Get-Foo                12          8         9
src\Foo.ps1 <script-body>          1           1         0
```

## The two metrics

**Cyclomatic** = 1 + decision points (each `if`/`elseif`/`switch` clause, each
`for`/`foreach`/`while`/`do` loop, each `catch`/`trap`, each ternary, each `-and`/`-or`).

**Cognitive** (SonarSource, faithful):

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

## License

MIT © Fortigi
