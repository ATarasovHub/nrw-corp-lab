@{
    # All default rules are enabled; the project policy is zero findings of any severity.
    Severity     = @('Error', 'Warning', 'Information')

    ExcludeRules = @()

    Rules        = @{
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('7.4')
        }

        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }

        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
            # Allow hashtable alignment required by PSAlignAssignmentStatement.
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        # Command and parameter casing is checked in a separate pass with
        # .github/PSScriptAnalyzerCasingSettings.psd1: in PSScriptAnalyzer 1.24/1.25 the command
        # lookup races with other rules running in parallel (NullReferenceException in
        # CommandInfo.Parameters). Keywords and operators are safe to check here.
        PSUseCorrectCasing         = @{
            Enable        = $true
            CheckCommands = $false
            CheckKeyword  = $true
            CheckOperator = $true
        }

        PSAvoidUsingCmdletAliases  = @{
            Enable = $true
        }
    }
}
