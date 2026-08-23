# The construct vocabulary, closed against the parser.
#
# The metrics recognise a hand-maintained allowlist spread over three places, and nothing
# compared those lists against what the parser can actually PRODUCE. The direction is what
# makes that dangerous: a construct the module has never heard of contributes nothing, so the
# unit containing it scores as straight-line code. A gate then passes most easily on the code
# it understood least, which is the failure that looks like success.
#
# This test fails when PowerShell gains a type. That is the point -- the next release turns
# the suite red instead of quietly lowering everyone's scores.

BeforeAll {
    $script:ExcludedWithReason = @{
        'ScriptBlockAst' = 'a container for blocks; the unit boundary, not a branch'
        'StatementBlockAst' = 'the body of something else -- whatever owns it is what decides'
        'NamedBlockAst' = 'begin/process/end are phases, not branches'
        'ParamBlockAst' = 'a declaration'
        'PipelineAst' = 'sequencing; the commands in it are scored individually'
        'CommandExpressionAst' = 'wraps an expression so it can sit in a pipeline'
        'ParenExpressionAst' = 'grouping, with no effect on control flow'
        'SubExpressionAst' = '$( ) evaluates its contents; those contents are scored on their own'
        'ArrayExpressionAst' = '@( ) is grouping, same as above'
        'ConstantExpressionAst' = 'a literal'
        'StringConstantExpressionAst' = 'a literal'
        'ExpandableStringExpressionAst' = 'a literal with interpolation; the interpolated parts are scored where they appear'
        'ArrayLiteralAst' = 'a literal'
        'HashtableAst' = 'a literal'
        'MemberExpressionAst' = 'property access, no branch'
        'IndexExpressionAst' = 'indexing, no branch'
        'BaseCtorInvokeMemberExpressionAst' = 'a base constructor call is unconditional'
        'ConvertExpressionAst' = 'a cast'
        'AttributedExpressionAst' = 'an attribute on an expression'
        'TypeConstraintAst' = 'a type annotation'
        'AttributeAst' = 'metadata'
        'NamedAttributeArgumentAst' = 'metadata'
        'ParameterAst' = 'a declaration'
        'CommandParameterAst' = 'an argument name'
        'AssignmentTarget' = 'the left side of an assignment; the assignment is scored, not its target'
        'UnaryExpressionAst' = '-not and friends invert a value without adding a path'
        'ReturnStatementAst' = 'an unconditional exit. SonarSource increments for a LABELLED jump, and a return is never labelled'
        'ThrowStatementAst' = 'an unconditional exit'
        'ExitStatementAst' = 'an unconditional exit'
        'TryStatementAst' = 'try itself is not a decision -- the CATCH is, and CatchClauseAst is scored'
        'FileRedirectionAst' = 'plumbing'
        'MergingRedirectionAst' = 'plumbing'
        'UsingExpressionAst' = '$using: marks a variable for another scope'
        'UsingStatementAst' = 'a module or namespace import'
        'DataStatementAst' = 'a restricted-language literal section'
        'ConfigurationDefinitionAst' = 'DSC, and a deliberate gap: a configuration is a declaration, so treating it as a unit would report numbers for something with no control flow'
        'DynamicKeywordStatementAst' = 'DSC'
        'BlockStatementAst' = 'DSC parallel/sequence blocks'
        'ErrorExpressionAst' = 'only produced for source that did not parse, which Measure-PSComplexity refuses before it reaches a metric'
        'ErrorStatementAst' = 'same: unparseable source is refused, not measured'
        'CompilerGeneratedMemberFunctionAst' = 'a synthesised default constructor. Not in the source, so scoring it would report a unit nobody wrote'
        'SequencePointAst' = 'a debugger artefact, never present in a tree from ParseFile'
    }

    $script:AllAstTypes = @(
        [System.Management.Automation.Language.Ast].Assembly.GetTypes() |
            Where-Object { $_.IsSubclassOf([System.Management.Automation.Language.Ast]) -and -not $_.IsAbstract } |
            ForEach-Object { $_.Name }
    )

    # Handled = named in the CODE of src/, comments stripped. Tokenised rather than grepped,
    # because a type mentioned only in a comment would otherwise count as handled -- the same
    # optimism this test exists to remove, one level up.
    $srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    $code = foreach ($f in Get-ChildItem $srcDir -Filter *.ps1) {
        $tokens = $null; $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
        ($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '
    }
    $joined = $code -join ' '
    $script:HandledTypes = @($script:AllAstTypes | Where-Object { $joined -match "\b$_\b" })
}

Describe 'the construct vocabulary is closed against the parser' {
    It 'classifies every Ast type the parser can emit' {
        # Joined into one string so a failure names the newcomer, rather than reporting a
        # count that differs by one.
        $unclassified = @($script:AllAstTypes |
                Where-Object { $_ -notin $script:HandledTypes -and -not $script:ExcludedWithReason.ContainsKey($_) })
        ($unclassified | Sort-Object) -join ', ' | Should-Be ''
    }

    It 'excludes nothing it actually handles' {
        # The other direction. An entry that is both handled and excluded means the list has
        # gone stale, and its reason now argues against something the code does -- worse than
        # no reason at all.
        $both = @($script:ExcludedWithReason.Keys | Where-Object { $_ -in $script:HandledTypes })
        ($both | Sort-Object) -join ', ' | Should-Be ''
    }

    It 'excludes nothing the parser cannot produce' {
        # A third staleness direction: an exclusion for a type that no longer exists reads as
        # a considered decision and is dead text.
        $ghosts = @($script:ExcludedWithReason.Keys | Where-Object { $_ -notin $script:AllAstTypes })
        ($ghosts | Sort-Object) -join ', ' | Should-Be ''
    }

    It 'gives every exclusion a reason' {
        $blank = @($script:ExcludedWithReason.GetEnumerator() |
                Where-Object { [string]::IsNullOrWhiteSpace($_.Value) } | ForEach-Object { $_.Key })
        ($blank | Sort-Object) -join ', ' | Should-Be ''
    }
}
