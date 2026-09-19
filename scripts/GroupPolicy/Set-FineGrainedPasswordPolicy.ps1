<#
.SYNOPSIS
    Creates and updates the fine-grained password policies (PSOs) from data/password-policies.psd1.

.DESCRIPTION
    The domain-wide password policy comes from the GPO C-Domain-PasswordPolicy. Password
    Settings Objects override it for specific groups:

    - PSO-Admins for the tiered admin groups (longer secrets, stricter lockout),
    - PSO-ServiceAccounts for legacy service accounts that cannot use a gMSA.

    Settings and subjects (the groups a PSO applies to) are converged: differing settings are
    updated, missing subjects added and subjects not listed in the data file removed.

.PARAMETER DataPath
    Directory that contains password-policies.psd1.

.EXAMPLE
    .\Set-FineGrainedPasswordPolicy.ps1

.EXAMPLE
    Get-ADUserResultantPasswordPolicy -Identity t0a-dkrause
#>
#Requires -Version 7.4
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$data = Get-LabDataFile -Name 'password-policies.psd1' -DataPath $DataPath
$timeSpanSettings = 'MinPasswordAge', 'MaxPasswordAge', 'LockoutDuration', 'LockoutObservationWindow'
$valueSettings = 'Precedence', 'Description', 'MinPasswordLength', 'PasswordHistoryCount', 'ComplexityEnabled', 'ReversibleEncryptionEnabled', 'LockoutThreshold'

foreach ($policy in $data.Policies) {
    $desired = @{}
    foreach ($setting in $valueSettings) {
        $desired[$setting] = $policy[$setting]
    }
    foreach ($setting in $timeSpanSettings) {
        $desired[$setting] = [timespan] $policy[$setting]
    }

    $existing = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($policy.Name)'"
    if (-not $existing) {
        if ($PSCmdlet.ShouldProcess($policy.Name, 'Create password settings object')) {
            New-ADFineGrainedPasswordPolicy -Name $policy.Name -ProtectedFromAccidentalDeletion $true @desired
        } else {
            continue
        }
    } else {
        $changes = @{}
        foreach ($setting in $desired.Keys) {
            if ([string] $existing.$setting -ne [string] $desired[$setting]) {
                $changes[$setting] = $desired[$setting]
            }
        }
        if ($changes.Count -gt 0 -and $PSCmdlet.ShouldProcess($policy.Name, "Update $($changes.Keys -join ', ')")) {
            Set-ADFineGrainedPasswordPolicy -Identity $existing @changes
        }
    }

    $currentSubjects = @(Get-ADFineGrainedPasswordPolicySubject -Identity $policy.Name | ForEach-Object { $_.SamAccountName })
    $missing = @($policy.Subjects | Where-Object { $_ -notin $currentSubjects })
    $extra = @($currentSubjects | Where-Object { $_ -notin $policy.Subjects })
    if ($missing.Count -gt 0 -and $PSCmdlet.ShouldProcess($policy.Name, "Apply to $($missing -join ', ')")) {
        Add-ADFineGrainedPasswordPolicySubject -Identity $policy.Name -Subjects $missing
    }
    if ($extra.Count -gt 0 -and $PSCmdlet.ShouldProcess($policy.Name, "Remove subjects $($extra -join ', ')")) {
        Remove-ADFineGrainedPasswordPolicySubject -Identity $policy.Name -Subjects $extra -Confirm:$false
    }
}

Get-ADFineGrainedPasswordPolicy -Filter * |
    Select-Object -Property Name, Precedence, MinPasswordLength, LockoutThreshold, @{
        Name       = 'AppliesTo'
        Expression = { (Get-ADFineGrainedPasswordPolicySubject -Identity $_.Name).SamAccountName -join ', ' }
    }
