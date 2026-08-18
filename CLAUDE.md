# PSComplexity — AI Assistant Development Guide

Cyclomatic and cognitive complexity for PowerShell, computed from the AST. Cognitive
complexity is a faithful port of the SonarSource metric, validated against its reference
examples. Ships `Measure-PSComplexity` (data) and `Test-PSComplexity` (CI gate).
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
| Lint | PSScriptAnalyzer, `-Severity Error, Warning` |
| Unit tests | whole `tests/` directory, 0 failures |
| Complexity | **its own** `Test-PSComplexity` against `src/`, 15 / 15 per unit |
| Self-mutation | PSMutant against `psmutant.self.config.json`, break = 100 |

Measuring coverage here is straightforward — whole-directory works, and both Pester
versions agree at 100% (they disagree on the analysed-command *denominator*, 201 vs 204,
which is worth remembering when quoting a figure):

```powershell
$c = New-PesterConfiguration
$c.Run.Path = 'tests'; $c.Run.PassThru = $true
$c.CodeCoverage.Enabled = $true; $c.CodeCoverage.Path = 'src'
(Invoke-Pester -Configuration $c).CodeCoverage.CoveragePercent
```

That simplicity is not luck: nothing here starts a nested Pester run. The sibling repo
PSMutant does, and its coverage is unmeasurable in places as a result. If you ever add
something that runs Pester from inside a test, expect the same problem.

**Pester version split**: CI pins 5.8.0, development happens on 6.1.0. This suite passes
under both. Tracked in **#10**.

---

## Layout

```
src/Ast.ps1                    unit discovery, attribution, nesting depth. Shared.
src/Cyclomatic.ps1             decision-point counting.
src/Cognitive.ps1              the SonarSource metric (B1 structural, B2 nesting, B3 level).
src/Measure-PSComplexity.ps1   public API: Measure-PSComplexity, Test-PSComplexity.
```

**The mutation config maps each source file to specific test files.** `src/Cyclomatic.ps1`
maps only to `tests/Cyclomatic.Tests.ps1`; `src/Ast.ps1` maps to the Cognitive and Measure
suites. A test placed in the wrong file covers the code but **cannot kill its mutants**,
which has already happened once here — a ternary case landed in `Measure.Tests.ps1` and
the mutant survived a test that exercised it. Check `psmutant.self.config.json` before
choosing where a test goes.

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
