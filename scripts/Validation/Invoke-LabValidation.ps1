<#
.SYNOPSIS
    Runs the deployed-lab Pester validation suite from MGMT01.

.DESCRIPTION
    Runs tests/Integration against live AD DS, DNS, replication, DHCP, Group Policy and FS01.
    The runner writes a JUnit XML result for CI/evidence and exits with an error if a test fails.
    Run it as a tier-appropriate domain administrator from MGMT01 with the AD DS, DHCP and Group
    Policy RSAT modules installed and WinRM access to FS01.

.PARAMETER OutputPath
    JUnit XML destination. Parent directories are created automatically.

.PARAMETER Tag
    Optional Pester tags: Domain, Replication, DHCP, GPO or NTFS.

.EXAMPLE
    .\Invoke-LabValidation.ps1

.EXAMPLE
    .\Invoke-LabValidation.ps1 -Tag Domain,DHCP -OutputPath C:\TestResults\smoke.xml
#>
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../TestResults/integration-tests.xml'),

    [ValidateSet('Domain', 'Replication', 'DHCP', 'GPO', 'NTFS')]
    [string[]] $Tag
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../..')).Path
$testPath = Join-Path -Path $repoRoot -ChildPath 'tests/Integration'
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Path $resolvedOutput -Parent
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$previousRoot = $env:NRW_LAB_ROOT
$env:NRW_LAB_ROOT = $repoRoot
try {
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $testPath
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = $resolvedOutput
    if ($Tag) {
        $configuration.Filter.Tag = $Tag
    }

    $result = Invoke-Pester -Configuration $configuration
} finally {
    $env:NRW_LAB_ROOT = $previousRoot
}

if ($result.FailedCount -gt 0) {
    throw "Lab validation failed: $($result.FailedCount) failed, $($result.PassedCount) passed. Results: $resolvedOutput"
}

$result
