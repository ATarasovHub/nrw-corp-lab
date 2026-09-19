<#
.SYNOPSIS
    Promotes DC02 to an additional domain controller with DNS and Global Catalog.

.DESCRIPTION
    Run 1 (server is not yet a domain controller):
    - verifies that the domain can be resolved through DNS (DC02 must point to DC01),
    - installs the AD DS and DNS roles including management tools,
    - promotes the server as replica DC in the given site, replicating from DC01,
    - stops before the reboot (or reboots when -Restart is given).

    Run 2 and later (server is a domain controller):
    - configures the DNS forwarders (they are per server and are not replicated),
    - reports replication failures reported by AD.

    Every step checks the current state first, so repeated runs change nothing.

.PARAMETER DomainName
    DNS name of the domain to join as domain controller.

.PARAMETER Credential
    Domain administrator credential used for the promotion.

.PARAMETER SafeModeAdministratorPassword
    DSRM password of this domain controller. Required only for the promotion run.

.PARAMETER SiteName
    AD site of the new domain controller.

.PARAMETER ReplicationSourceDC
    Domain controller used as the source for the initial replication.

.PARAMETER DnsForwarder
    Upstream DNS servers. Root hints are disabled.

.PARAMETER Restart
    Reboot automatically after the promotion.

.EXAMPLE
    $cred = Get-Credential -UserName 'NRWCORP\Administrator'
    $dsrm = Read-Host -AsSecureString -Prompt 'DSRM password'
    .\Add-ReplicaDomainController.ps1 -Credential $cred -SafeModeAdministratorPassword $dsrm -Restart

.EXAMPLE
    .\Add-ReplicaDomainController.ps1 -Credential $cred

    After the reboot: configures DNS forwarders and checks replication.
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9-]+(\.[a-z0-9-]+)+$')]
    [string] $DomainName = 'ad.nrwcorp.internal',

    [Parameter(Mandatory)]
    [pscredential] $Credential,

    [securestring] $SafeModeAdministratorPassword,

    [ValidateNotNullOrEmpty()]
    [string] $SiteName = 'NRW-Duesseldorf',

    [ValidateNotNullOrEmpty()]
    [string] $ReplicationSourceDC = 'DC01.ad.nrwcorp.internal',

    [ValidateNotNullOrEmpty()]
    [ipaddress[]] $DnsForwarder = @('10.10.20.1'),

    [switch] $Restart
)

$ErrorActionPreference = 'Stop'

$isDomainController = (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4

if (-not $isDomainController) {
    try {
        Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -DnsOnly | Out-Null
    } catch {
        throw "Cannot resolve domain controllers of $DomainName. Point this server's DNS to DC01 first. $_"
    }

    $missingFeatures = Get-WindowsFeature -Name AD-Domain-Services, DNS | Where-Object { -not $_.Installed }
    if ($missingFeatures -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install $($missingFeatures.Name -join ', ')")) {
        Install-WindowsFeature -Name $missingFeatures.Name -IncludeManagementTools | Out-Null
    }

    if (-not $SafeModeAdministratorPassword) {
        throw 'This server is not a domain controller yet. Pass -SafeModeAdministratorPassword to promote it.'
    }

    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Promote to domain controller of $DomainName")) {
        Import-Module -Name ADDSDeployment
        $dcParameters = @{
            DomainName                    = $DomainName
            Credential                    = $Credential
            SiteName                      = $SiteName
            ReplicationSourceDC           = $ReplicationSourceDC
            InstallDns                    = $true
            NoGlobalCatalog               = $false
            SafeModeAdministratorPassword = $SafeModeAdministratorPassword
            NoRebootOnCompletion          = $true
            Force                         = $true
        }
        Install-ADDSDomainController @dcParameters | Out-Null

        Write-Warning 'Promotion finished. Reboot the server and run this script again to finish the configuration.'
        if ($Restart) {
            Restart-Computer -Force
        }
    }
    return
}

Import-Module -Name ActiveDirectory, DnsServer

# DNS forwarders are a per-server setting and must be configured on every DC.
$forwarder = Get-DnsServerForwarder
$currentForwarders = @($forwarder.IPAddress | ForEach-Object { $_.IPAddressToString }) | Sort-Object
$desiredForwarders = @($DnsForwarder | ForEach-Object { $_.IPAddressToString }) | Sort-Object
$forwardersDiffer = [bool](Compare-Object -ReferenceObject @($currentForwarders) -DifferenceObject @($desiredForwarders))
if (($forwardersDiffer -or $forwarder.UseRootHint) -and
    $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Set DNS forwarders to $($desiredForwarders -join ', ')")) {
    Set-DnsServerForwarder -IPAddress $DnsForwarder -UseRootHint $false -Timeout 3
}

$failures = @(Get-ADReplicationFailure -Target $env:COMPUTERNAME -Credential $Credential)
if ($failures.Count -gt 0) {
    Write-Warning "$($failures.Count) replication failure(s) reported. Run 'repadmin /showrepl' for details."
}

[pscustomobject]@{
    DomainController    = $env:COMPUTERNAME
    Site                = (Get-ADDomainController -Identity $env:COMPUTERNAME).Site
    IsGlobalCatalog     = (Get-ADDomainController -Identity $env:COMPUTERNAME).IsGlobalCatalog
    DnsForwarders       = (Get-DnsServerForwarder).IPAddress.IPAddressToString -join ', '
    ReplicationFailures = $failures.Count
}
