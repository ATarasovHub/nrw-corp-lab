<#
.SYNOPSIS
    Analyzes one PowerShell file and reports a stable process exit code.

.DESCRIPTION
    PSScriptAnalyzer 1.25 can corrupt its command cache after an internal parallel-rule failure.
    CI invokes this helper in a fresh process per file, so one crash cannot affect later files.
    Exit codes: 0 = clean, 2 = findings, 3 = analyzer crash.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Path,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Settings
)

$ErrorActionPreference = 'Stop'
try {
    Import-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
    $results = @(Invoke-ScriptAnalyzer -Path $Path -Settings $Settings -ErrorAction Stop)
    if ($results.Count -eq 0) {
        exit 0
    }

    $results | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 4096
    foreach ($result in $results) {
        $file = [System.IO.Path]::GetRelativePath($PWD, $result.ScriptPath) -replace '\\', '/'
        Write-Output "::error file=$file,line=$($result.Line)::[$($result.RuleName)] $($result.Message)"
    }
    exit 2
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 3
}
