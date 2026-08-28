# The dependency direction between files in src/, as a checked allowlist.
#
# Every other gate here is blind to DIRECTION. A shortcut call from Report.ps1 back into Ast.ps1,
# or from Cognitive.ps1 into Measure-PSComplexity.ps1, reaches full coverage and survives
# self-mutation exactly as a well-layered call does. Nothing fails. The graph is acyclic today
# because nobody has added a shortcut, not because anything would catch one.
#
# This file was deliberately NOT written while the graph had no interior node: with five files
# and every arrow pointing at a sink, a cycle was not reachable and an allowlist would have been
# ceremony. The condition for revisiting was recorded in advance -- a module that both exported
# commands consume, living in its own file -- and src/Report.ps1 met it.
#
# Two things this test does NOT have to work around, unlike the sibling project's version:
#
#   - src/ contains no here-strings, so there is no code the parser cannot see.
#   - src/ dispatches nothing through a variable (`& $fn`), so every callee is resolvable.
#
# Both are worth re-checking if either ever appears, because each one hides an edge in a way
# that looks exactly like not having one.

BeforeAll {
    $script:srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'

    # One entry per file-to-file RELATIONSHIP, not per call site. Adding a call between two files
    # that already have an edge is free; adding the first one is a decision.
    $script:allowedEdges = @(
        # Ast.ps1 is the shared foundation: which units exist, which one owns a node, how deeply
        # it is nested. Both metrics ask it those questions and it asks them nothing back. This
        # arrow must never reverse -- an Ast layer that knew what a cognitive point was would
        # make the metric impossible to change without changing discovery.
        'Cognitive.ps1 -> Ast.ps1'
        'Cyclomatic.ps1 -> Ast.ps1'

        # The scan turns paths into measured units, so it is the one thing that talks to all
        # three metric files. It used to be part of the composition root; splitting it out moved
        # these three edges down a level, which is the shape the layout always described.
        'Scan.ps1 -> Ast.ps1'
        'Scan.ps1 -> Cognitive.ps1'
        'Scan.ps1 -> Cyclomatic.ps1'

        # The composition root. It owns most of the graph on purpose: it is wiring, so it is
        # allowed to know about everything, and nothing is allowed to know about it. It no longer
        # reaches a metric directly -- it asks the scan.
        'Measure-PSComplexity.ps1 -> Scan.ps1'

        # Serialisation is downstream of measurement and must stay a sink. A report layer that
        # reached back into Ast.ps1 or a metric would be deciding what a number MEANS while
        # claiming only to write it down -- and the report is the artefact a consumer trusts.
        'BaselineFile.ps1 -> Policy.ps1'
        'BaselineFile.ps1 -> Report.ps1'
        'Measure-PSComplexity.ps1 -> BaselineFile.ps1'
        'Measure-PSComplexity.ps1 -> Policy.ps1'
        'Measure-PSComplexity.ps1 -> Report.ps1'
    )

    function Get-SrcAst {
        $out = @{}
        foreach ($f in Get-ChildItem $script:srcDir -Filter *.ps1) {
            $out[$f.Name] = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        }
        return $out
    }

    function Get-FileEdge {
        param($Asts)
        # Which file defines each function, then which file calls it. A call inside the file
        # that defines it is not an edge.
        $definedBy = @{}
        foreach ($name in $Asts.Keys) {
            foreach ($fn in $Asts[$name].FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $definedBy[$fn.Name] = $name
            }
        }
        $edges = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($name in $Asts.Keys) {
            foreach ($c in $Asts[$name].FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $called = $c.GetCommandName()
                if ($called -and $definedBy.ContainsKey($called) -and $definedBy[$called] -ne $name) {
                    [void]$edges.Add("$name -> $($definedBy[$called])")
                }
            }
        }
        return $edges
    }
}

Describe 'the dependency graph in src/' {
    It 'has no file-to-file edge that is not declared' {
        # The message names the offender rather than reporting a count, because the useful
        # question on a red build is "which edge did I add", and the answer is either "add it to
        # the list deliberately" or "that call belongs somewhere else".
        $undeclared = @((Get-FileEdge -Asts (Get-SrcAst)) | Where-Object { $_ -notin $script:allowedEdges })
        ($undeclared -join '; ') | Should-Be ''
    }

    It 'declares no edge that no longer exists' {
        # The other direction, and it matters for the same reason a stale acceptance does: a list
        # describing relationships the code dropped is a document nobody can trust, and it
        # silently readmits an edge later.
        $actual = Get-FileEdge -Asts (Get-SrcAst)
        $stale = @($script:allowedEdges | Where-Object { $_ -notin $actual })
        ($stale -join '; ') | Should-Be ''
    }

    It 'is acyclic' {
        # The property the allowlist protects, and one the allowlist alone cannot give: two edges
        # each reasonable on their own review make a cycle between them, and nobody reviewing the
        # second is looking at the first.
        $edges = Get-FileEdge -Asts (Get-SrcAst)
        $out = @{}
        foreach ($e in $edges) {
            $parts = $e -split ' -> '
            if (-not $out.ContainsKey($parts[0])) { $out[$parts[0]] = [System.Collections.Generic.List[string]]::new() }
            $out[$parts[0]].Add($parts[1])
        }
        # Repeatedly drop files that depend on nothing still present. Anything left when no more
        # can be dropped is inside a cycle.
        $remaining = [System.Collections.Generic.List[string]]::new()
        (Get-SrcAst).Keys | ForEach-Object { $remaining.Add($_) }
        $progress = $true
        while ($progress) {
            $progress = $false
            foreach ($file in @($remaining)) {
                $deps = @()
                if ($out.ContainsKey($file)) { $deps = @($out[$file] | Where-Object { $remaining -contains $_ }) }
                if ($deps.Count -eq 0) {
                    [void]$remaining.Remove($file)
                    $progress = $true
                }
            }
        }
        ($remaining -join ', ') | Should-Be ''
    }

    It 'keeps Report.ps1 a sink' {
        # Stated separately from the allowlist because it is the reason this file exists now. The
        # allowlist would permit a Report.ps1 edge the moment somebody added one and updated the
        # list; this says the direction is a design decision, not a bookkeeping entry.
        #
        # A serialiser that reached back into measurement would be deciding what a number means
        # while claiming only to write it down.
        $fromReport = @((Get-FileEdge -Asts (Get-SrcAst)) | Where-Object { $_ -like 'Report.ps1 -> *' })
        ($fromReport -join '; ') | Should-Be ''
    }
}

Describe 'module state in src/' {
    It 'never reads a $script: variable from the file that did not write it' {
        # Locality: a constant one file writes while another reads leaves neither readable on its
        # own, and it is an edge no call-graph check can see. The sibling project had two such
        # reads and removed them in opposite directions -- one default moved to its reader, the
        # other stayed and its resolver came to it. This is what stops a third appearing here.
        $asts = Get-SrcAst
        $writtenIn = @{}
        foreach ($name in $asts.Keys) {
            foreach ($a in $asts[$name].FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $a.Left.VariablePath.UserPath -like 'script:*') {
                    $writtenIn[$a.Left.VariablePath.UserPath] = $name
                }
            }
        }
        $foreign = foreach ($name in $asts.Keys) {
            foreach ($v in $asts[$name].FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $path = $v.VariablePath.UserPath
                if ($path -like 'script:*' -and $writtenIn.ContainsKey($path) -and $writtenIn[$path] -ne $name) {
                    "$name reads `$$path from $($writtenIn[$path])"
                }
            }
        }
        (@($foreign) -join '; ') | Should-Be ''
    }
}

Describe 'what keeps the two compatibility gates independent' {
    It 'names no Pester command anywhere in src/' {
        # The two compatibility gates vary one axis each and neither varies both.
        # Test-PSCxPowerShellCompatibility.ps1 asserts DIRECTLY rather than through Pester, and
        # Test-PSCxPesterCompatibility.ps1 varies Pester while holding PowerShell fixed. Both rest
        # on a single property of this module: it never calls Pester, so "works under Pester N" and
        # "works on PowerShell M" cannot interact through our code, and the product of the two
        # matrices -- 72 combinations -- is redundant rather than merely expensive.
        #
        # The day src/ calls a Pester command, that stops being true and the product becomes real
        # work. Nothing else would say so: both gates would keep passing, because each one holds
        # the other axis still. This assertion is the whole reason the cheap arrangement is honest.
        $pester = @((Get-Module Pester).ExportedCommands.Keys)
        # Read from the loaded Pester rather than written out here, so the list cannot go stale as
        # Pester grows. Asserted non-empty first: an empty set makes every file below pass, which
        # is the vacuous green this file exists to refuse.
        $pester.Count | Should-BeGreaterThan 20

        # Parsed, not grepped. "Pester" appears in the prose of several headers, and a comment
        # naming a command is not a call -- the distinction this test turns on.
        $srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
        $calls = foreach ($f in Get-ChildItem -LiteralPath $srcDir -Filter *.ps1) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = $c.GetCommandName()
                if ($name -and $pester -contains $name) { "$($f.Name): $name" }
            }
        }
        (@($calls) -join '; ') | Should-Be ''
    }
}

# Deliberately not here: a "one Write-Host" assertion like the sibling's. That project excludes
# PSAvoidUsingWriteHost repo-wide because its gate scripts print for a living, so a test is the
# only thing that can hold the line. Here the rule is NOT excluded and src/ contains no
# Write-Host at all, so PSScriptAnalyzer already fails the build -- and a second gate over the
# same property is one more thing to keep in step for no extra coverage.
