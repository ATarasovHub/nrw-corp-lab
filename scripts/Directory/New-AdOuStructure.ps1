<#
.SYNOPSIS
    Creates the company OU structure from data/ou-structure.psd1 and redirects the default containers.

.DESCRIPTION
    Converges the OU tree below the company root OU (default: NRW) to the definition in
    data/ou-structure.psd1:

    - creates missing OUs with "Protect from accidental deletion",
    - updates descriptions and re-enables the deletion protection if it was removed,
    - warns about OUs that exist in AD but not in the data file (they are never deleted),
    - redirects the built-in CN=Users and CN=Computers containers to the staging OUs
      (redirusr.exe / redircmp.exe), so that Group Policy applies to new objects.

.PARAMETER DataPath
    Directory that contains ou-structure.psd1.

.PARAMETER SkipContainerRedirect
    Do not redirect the default user and computer containers.

.EXAMPLE
    .\New-AdOuStructure.ps1

.EXAMPLE
    .\New-AdOuStructure.ps1 -WhatIf
#>
#Requires -Version 7.4
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [switch] $SkipContainerRedirect
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$data = Get-LabDataFile -Name 'ou-structure.psd1' -DataPath $DataPath
$domain = Get-ADDomain

function Get-OuDistinguishedName {
    param([string] $Path)
    ConvertTo-LabDistinguishedName -Path $Path -RootOu $data.RootOu -DomainDistinguishedName $domain.DistinguishedName
}

function Set-LabOrganizationalUnit {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string] $Name,
        [string] $ParentPath,
        [string] $Description
    )

    $distinguishedName = "OU=$Name,$ParentPath"
    $ou = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$distinguishedName)" -Properties Description, ProtectedFromAccidentalDeletion

    if (-not $ou) {
        if ($PSCmdlet.ShouldProcess($distinguishedName, 'Create OU')) {
            New-ADOrganizationalUnit -Name $Name -Path $ParentPath -Description $Description -ProtectedFromAccidentalDeletion $true
        }
        return 'Created'
    }

    $changes = @{}
    if ($ou.Description -ne $Description) {
        $changes['Description'] = $Description
    }
    if (-not $ou.ProtectedFromAccidentalDeletion) {
        $changes['ProtectedFromAccidentalDeletion'] = $true
    }
    if ($changes.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($distinguishedName, "Update $($changes.Keys -join ', ')")) {
            Set-ADOrganizationalUnit -Identity $ou @changes
        }
        return 'Updated'
    }
    'Unchanged'
}

$results = [System.Collections.Generic.List[pscustomobject]]::new()

$rootResult = Set-LabOrganizationalUnit -Name $data.RootOu -ParentPath $domain.DistinguishedName -Description $data.RootOuDescription
$results.Add([pscustomobject]@{ OrganizationalUnit = $data.RootOu; Result = $rootResult })

foreach ($entry in $data.OrganizationalUnits) {
    $segments = $entry.Path -split '/'
    $parentPath = Get-OuDistinguishedName -Path (($segments | Select-Object -SkipLast 1) -join '/')
    $result = Set-LabOrganizationalUnit -Name $segments[-1] -ParentPath $parentPath -Description $entry.Description
    $results.Add([pscustomobject]@{ OrganizationalUnit = $entry.Path; Result = $result })
}

# Report OUs that exist but are not defined in the data file.
$rootDn = Get-OuDistinguishedName -Path ''
$desiredDns = @($data.OrganizationalUnits | ForEach-Object { Get-OuDistinguishedName -Path $_.Path }) + $rootDn
if (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$rootDn)") {
    Get-ADOrganizationalUnit -SearchBase $rootDn -Filter * |
        Where-Object { $_.DistinguishedName -notin $desiredDns } |
        ForEach-Object { Write-Warning "OU not defined in ou-structure.psd1: $($_.DistinguishedName)" }
}

# Redirect the built-in containers so that new objects receive Group Policy.
if (-not $SkipContainerRedirect) {
    $redirects = @(
        @{ Tool = 'redirusr.exe'; Current = $domain.UsersContainer; Target = Get-OuDistinguishedName -Path $data.DefaultUserContainer }
        @{ Tool = 'redircmp.exe'; Current = $domain.ComputersContainer; Target = Get-OuDistinguishedName -Path $data.DefaultComputerContainer }
    )
    foreach ($redirect in $redirects) {
        if ($redirect.Current -ne $redirect.Target -and $PSCmdlet.ShouldProcess($redirect.Target, "Redirect default container ($($redirect.Tool))")) {
            & $redirect.Tool $redirect.Target | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "$($redirect.Tool) failed with exit code $LASTEXITCODE."
            }
        }
    }
}

$results
