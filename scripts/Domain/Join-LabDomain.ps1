<#
.SYNOPSIS
    Joins this computer to the lab domain and places it in the correct OU.

.DESCRIPTION
    Used for FS01, MGMT01, the Windows clients and other member servers. The DCs join the
    domain through their promotion instead.

    If the computer is already a member of the domain, nothing is changed.

.PARAMETER DomainName
    DNS name of the domain.

.PARAMETER Credential
    Account allowed to join computers to the domain.

.PARAMETER OrganizationalUnit
    Target OU as lab path below the root OU, e.g. Servers/FileServers or Computers/Workstations.

.PARAMETER RootOu
    Name of the company root OU.

.PARAMETER Restart
    Reboot after joining (required for the membership to take effect).

.EXAMPLE
    .\Join-LabDomain.ps1 -Credential (Get-Credential NRWCORP\Administrator) -OrganizationalUnit 'Servers/FileServers' -Restart

.EXAMPLE
    .\Join-LabDomain.ps1 -Credential $cred -OrganizationalUnit 'Computers/Workstations' -Restart
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9-]+(\.[a-z0-9-]+)+$')]
    [string] $DomainName = 'ad.nrwcorp.internal',

    [Parameter(Mandatory)]
    [pscredential] $Credential,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9 _-]+(/[A-Za-z0-9 _-]+)*$')]
    [string] $OrganizationalUnit,

    [ValidateNotNullOrEmpty()]
    [string] $RootOu = 'NRW',

    [switch] $Restart
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computerSystem.PartOfDomain -and $computerSystem.Domain -eq $DomainName) {
    Write-Verbose "$env:COMPUTERNAME is already a member of $DomainName."
    return
}
if ($computerSystem.PartOfDomain) {
    throw "$env:COMPUTERNAME is a member of $($computerSystem.Domain). Remove it from that domain first."
}

$domainDn = ConvertTo-LabDomainDistinguishedName -DomainName $DomainName
$ouDn = ConvertTo-LabDistinguishedName -Path $OrganizationalUnit -RootOu $RootOu -DomainDistinguishedName $domainDn

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Join $DomainName in $ouDn")) {
    Add-Computer -DomainName $DomainName -Credential $Credential -OUPath $ouDn -Force
    if ($Restart) {
        Restart-Computer -Force
    } else {
        Write-Warning 'Joined the domain. Restart the computer to complete the join.'
    }
}
