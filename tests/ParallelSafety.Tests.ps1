# The property that makes `workers: 3` in psmutant.self.config.json safe, held rather than
# remembered (#188).
#
# Every self-mutation worker is a runspace in ONE process, so they share the environment and
# they share $PID. A test that WRITES an environment variable, or names a fixture after the
# process id, races the same test running against another mutant -- and a verdict decided by
# another worker's state is a kill or a survival that does not reproduce serially. The gate's
# acceptance (same mutant count, same verdicts as a serial run) then stops holding, silently.
#
# tools/Test-PSCxOrderIndependence.ps1 does not cover this. It compares the environment before
# and after a run, so it sees a variable a test LEAKS -- and not one written, used and restored
# in an AfterEach, which is the polite way to write such a test and still a race here.
#
# Reading the environment is fine and common (`-Skip:($env:GITHUB_ACTIONS -ne 'true')`), so the
# scan is over the parsed tree, not the text: a write and a read of $env:X are different nodes.

BeforeAll {
    $script:testsDir = $PSScriptRoot

    # Commands that change an item or its content, under their names and common aliases. Only
    # their use on an env: path is a write to the environment.
    $script:writeCommands = @(
        'Set-Item', 'New-Item', 'Remove-Item', 'Clear-Item', 'Rename-Item', 'Move-Item', 'Copy-Item',
        'Set-Content', 'Add-Content', 'Clear-Content',
        'si', 'ni', 'ri', 'rm', 'del', 'erase', 'rd', 'rmdir', 'cli', 'rni', 'ren', 'mi', 'move', 'mv',
        'cpi', 'copy', 'cp', 'ac', 'clc'
    )

    function Get-ProcessStateUse {
        # Each use of shared process state in one tree, as "<line>: <what>".
        param([Parameter(Mandatory)] $Ast)
        foreach ($n in $Ast.FindAll({ param($x) $null -ne $x }, $true)) {
            $line = $n.Extent.StartLineNumber
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                # `[string]$env:X = 1` puts a conversion around the variable.
                $left = $n.Left
                if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $left.VariablePath.DriveName -eq 'env') {
                    "${line}: writes $($left.Extent.Text)"
                }
            }
            elseif ($n -is [System.Management.Automation.Language.VariableExpressionAst]) {
                if ($n.VariablePath.UserPath -eq 'PID') { "${line}: reads `$PID" }
            }
            elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
                if ($n.Static -and $n.Member.Value -eq 'SetEnvironmentVariable') { "${line}: calls SetEnvironmentVariable" }
                if ($n.Member.Value -eq 'GetCurrentProcess') { "${line}: calls GetCurrentProcess" }
            }
            elseif ($n -is [System.Management.Automation.Language.MemberExpressionAst]) {
                if ($n.Static -and $n.Member.Value -eq 'ProcessId') { "${line}: reads ProcessId" }
            }
            elseif ($n -is [System.Management.Automation.Language.CommandAst] -and
                $script:writeCommands -contains $n.GetCommandName()) {
                $envArg = @($n.CommandElements | Select-Object -Skip 1 |
                        Where-Object { $_.Extent.Text -match '^[''"]?env:' })
                if ($envArg.Count -gt 0) { "${line}: $($n.GetCommandName()) on $($envArg[0].Extent.Text)" }
            }
        }
    }

    function Get-PlantedUse {
        param([Parameter(Mandatory)] [string]$Code)
        return @(Get-ProcessStateUse -Ast ([System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)))
    }
}

Describe 'shared process state in tests/' {
    It 'is never written or keyed on by a test, so three mutation workers cannot race' {
        # Named by file and line, because the useful question on a red build is "which test".
        $found = foreach ($f in Get-ChildItem $script:testsDir -Filter *.ps1 -Recurse) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($use in Get-ProcessStateUse -Ast $ast) { "$($f.Name):$use" }
        }
        (@($found) -join '; ') | Should-Be ''
    }

    It 'scans files that exist' {
        # A scan over no files passes every time; this file is itself one of them.
        @(Get-ChildItem $script:testsDir -Filter *.ps1 -Recurse).Name | Should-ContainCollection 'ParallelSafety.Tests.ps1'
    }
}

Describe 'Get-ProcessStateUse -- a scan that cannot fire proves nothing' {
    It 'finds <Name>' -ForEach @(
        @{ Name = 'an environment write'; Code = '$env:PSCX_X = 1'; Expected = '1: writes $env:PSCX_X' }
        @{ Name = 'a braced environment write'; Code = '${env:PSCX X} = 1'; Expected = '1: writes ${env:PSCX X}' }
        @{ Name = 'a compound environment write'; Code = '$env:PATH += ":/x"'; Expected = '1: writes $env:PATH' }
        @{ Name = 'a typed environment write'; Code = '[string]$env:PSCX_X = 1'; Expected = '1: writes $env:PSCX_X' }
        @{ Name = 'a $PID fixture'; Code = '$f = "fixture-$PID.ps1"'; Expected = '1: reads $PID' }
        @{ Name = 'a bare $PID'; Code = 'Join-Path $dir $PID'; Expected = '1: reads $PID' }
        @{ Name = 'SetEnvironmentVariable'; Code = '[Environment]::SetEnvironmentVariable(''X'', ''1'')'; Expected = '1: calls SetEnvironmentVariable' }
        @{ Name = 'the process id through .NET'; Code = '[Environment]::ProcessId'; Expected = '1: reads ProcessId' }
        @{ Name = 'the current process'; Code = '[System.Diagnostics.Process]::GetCurrentProcess().Id'; Expected = '1: calls GetCurrentProcess' }
        @{ Name = 'Set-Item on env:'; Code = 'Set-Item env:PSCX_X 1'; Expected = '1: Set-Item on env:PSCX_X' }
        @{ Name = 'Remove-Item on a quoted env: path'; Code = 'Remove-Item ''env:PSCX_X'''; Expected = '1: Remove-Item on ''env:PSCX_X''' }
        @{ Name = 'an alias on env:'; Code = 'rm env:PSCX_X'; Expected = '1: rm on env:PSCX_X' }
        @{ Name = 'a named path parameter'; Code = 'New-Item -Path env:PSCX_X -Value 1'; Expected = '1: New-Item on env:PSCX_X' }
        @{ Name = 'a write on a later line'; Code = "`$a = 1`n`$env:PSCX_X = 1"; Expected = '2: writes $env:PSCX_X' }
    ) {
        (Get-PlantedUse $Code) -join '; ' | Should-Be $Expected
    }

    It 'does not flag <Name>' -ForEach @(
        @{ Name = 'reading the environment'; Code = 'if ($env:CI) { 1 }' }
        @{ Name = 'a read passed as a skip condition'; Code = 'It x -Skip:($env:GITHUB_ACTIONS -ne ''true'') { }' }
        @{ Name = 'an ordinary assignment'; Code = '$x = $env:HOME' }
        @{ Name = 'a variable merely named like the id'; Code = '$PIDFile = 1; $myPID = 2' }
        @{ Name = 'GetEnvironmentVariable'; Code = '[Environment]::GetEnvironmentVariable(''X'')' }
        @{ Name = 'Set-Item on a file'; Code = 'Set-Item ./env.txt 1' }
        @{ Name = 'Set-Content on a file named env'; Code = 'Set-Content ./env:x 1' }
        @{ Name = 'Get-Item on env:'; Code = 'Get-Item env:PATH' }
        @{ Name = 'the string env: inside a value'; Code = 'Set-Content $f ''$env:X = 1''' }
        @{ Name = 'a $PID written inside single quotes'; Code = '$text = ''fixture-$PID''' }
    ) {
        (Get-PlantedUse $Code) -join '; ' | Should-Be ''
    }
}
