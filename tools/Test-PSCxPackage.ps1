# Smoke-test a STAGED package before it becomes permanent.
#
# A gallery version cannot be withdrawn, only unlisted, and the staged folder was the one
# artifact nothing ever executed: it was assembled inside the publish step and pushed in the
# same breath, so nothing imported it, resolved its exports, or ran a single measurement
# against it.
#
# Four things are checked, and the fourth is the point:
#   1. the manifest is present and parses
#   2. every shipped src file is actually dot-sourced by the .psm1
#   3. the package imports in a FRESH process and both commands resolve
#   4. a real measurement over a throwaway fixture is correct AND still able to FAIL
[CmdletBinding()]
param([Parameter(Mandatory)] [string]$Path)

$ErrorActionPreference = 'Stop'
$stage = (Resolve-Path -LiteralPath $Path).Path

# --- 1. the manifest ---------------------------------------------------------------------
$manifestPath = Join-Path $stage 'PSComplexity.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No PSComplexity.psd1 in the staged package at $stage" }
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
Write-Output "  manifest: $($manifest.ModuleVersion)"

# --- 2. every shipped source file is loaded ----------------------------------------------
# Copy-Item ./src -Recurse ships every file; the .psm1 dot-sources an EXPLICIT list. A file
# in the first and not the second imports cleanly and is silently missing its functions,
# which cannot be fixed once published.
$psm1 = Get-Content -LiteralPath (Join-Path $stage 'PSComplexity.psm1') -Raw
$orphans = Get-ChildItem -LiteralPath (Join-Path $stage 'src') -Filter *.ps1 |
    Where-Object { $psm1 -notmatch [regex]::Escape($_.Name) } |
    ForEach-Object { $_.Name }
if ($orphans) {
    throw ("These files ship in the package but are never dot-sourced by PSComplexity.psm1: " +
        ($orphans -join ', '))
}
Write-Output "  all $((Get-ChildItem -LiteralPath (Join-Path $stage 'src') -Filter *.ps1).Count) shipped src files are dot-sourced"

# --- 3 and 4. import in a FRESH process and measure for real ------------------------------
# A fresh process, because importing here is indistinguishable from the repo copy already
# loaded in this session -- and "it worked on my machine, where the real one was loaded" is
# precisely how a broken package ships.
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) "pscx-pkg-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $fixture 'Sample.ps1') `
        'function Get-Sample { param($x) if ($x) { 1 } else { 2 } }' -Encoding utf8

    $child = {
        param($ManifestPath, $Fixture)
        $ErrorActionPreference = 'Stop'
        Import-Module $ManifestPath -Force

        foreach ($name in 'Measure-PSComplexity', 'Test-PSComplexity') {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "$name does not resolve from the package" }
        }

        # A flat directory with NO -Recurse. This exact call measured zero files before
        # 0.2.1, so the package that ships must not be able to do it again.
        $units = @(Measure-PSComplexity -Path $Fixture)
        if ($units.Count -lt 2) { throw "Measured $($units.Count) units; expected the function and the script body" }
        $sample = $units | Where-Object Unit -eq 'Get-Sample'
        if ($sample.Cyclomatic -ne 2) { throw "Get-Sample cyclomatic is $($sample.Cyclomatic), expected 2" }

        # The gate must PASS generous ceilings and FAIL strict ones. One outcome proves
        # nothing: a gate wired to return $true always satisfies the first half.
        if (-not (Test-PSComplexity -Path $Fixture)) { throw 'Gate failed code that is within the ceilings' }
        if (Test-PSComplexity -Path $Fixture -MaxCyclomatic 1 -MaxCognitive 1 -WarningAction SilentlyContinue) {
            throw 'Gate PASSED code that breaches the ceilings -- the shipped package cannot fail'
        }

        # And it must refuse to vouch for nothing, which is the other half of the same bug.
        #
        # The MESSAGE is asserted, not merely that something threw. This child runs with
        # ErrorActionPreference Stop, so the missing directory makes Get-ChildItem terminate
        # first -- a bare catch would be satisfied by that and would still pass with the
        # refusal removed. A directory that EXISTS and simply holds no PowerShell is the
        # case that isolates it.
        $empty = Join-Path $Fixture 'no-powershell-here'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $empty 'notes.txt') 'not powershell' -Encoding utf8
        $refusal = $null
        try { Test-PSComplexity -Path $empty } catch { $refusal = $_.Exception.Message }
        if ($refusal -notlike '*Measured no units*') {
            throw "Gate did not refuse a path it measured nothing under (got: $refusal)"
        }

        'ok'
    }

    $out = & (Get-Process -Id $PID).Path -NoProfile -Command "& { $child } '$manifestPath' '$fixture'"
    if ($LASTEXITCODE -ne 0 -or $out -notcontains 'ok') {
        throw "Staged package failed its smoke test: $($out -join ' ')"
    }
    Write-Output '  imported in a fresh process; measured, gated and refused correctly'
}
finally { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output 'Staged package smoke test passed.'
