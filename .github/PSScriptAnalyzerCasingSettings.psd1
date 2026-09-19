# Second analyzer pass: command and parameter casing only (see PSScriptAnalyzerSettings.psd1).
# Running PSUseCorrectCasing alone avoids the parallel-rule race in PSScriptAnalyzer 1.24/1.25.
@{
    IncludeRules = @('PSUseCorrectCasing')
    Rules        = @{
        PSUseCorrectCasing = @{
            Enable        = $true
            CheckCommands = $true
            CheckKeyword  = $false
            CheckOperator = $false
        }
    }
}
