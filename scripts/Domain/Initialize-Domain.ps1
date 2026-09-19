<#
.SYNOPSIS
    Creates the ad.nrwcorp.internal forest on DC01 and applies the post-promotion baseline.

.DESCRIPTION
    Converges DC01 towards the design in docs/03-ad-design.md. The script is meant to be run
    twice: once to promote the server, and once more after the mandatory reboot.

    Run 1 (server is not yet a domain controller):
    - installs the AD DS and DNS roles including management tools,
    - creates the forest with the requested forest and domain functional level,
    - stops before the reboot (or reboots when -Restart is given).

    Run 2 and later (server is a domain controller):
    - raises the domain and forest functional level if they are lower than requested,
    - configures the DNS forwarders (Unbound on RTR01) and disables root hints,
    - renames Default-First-Site-Name and creates the site subnets,
    - enables the AD Recycle Bin,
    - configures the PDC emulator to sync time from the PTB NTP servers.

    Every step checks the current state first, so repeated runs change nothing.

.PARAMETER DomainName
    DNS name of the new forest root domain.

.PARAMETER NetbiosName
    NetBIOS name of the domain.

.PARAMETER SafeModeAdministratorPassword
    DSRM password. Required only for the promotion run.

.PARAMETER FunctionalLevel
    Forest and domain functional level, e.g. Win2025.

.PARAMETER DnsForwarder
    Upstream DNS servers. Root hints are disabled so that DNS egress stays on RTR01.

.PARAMETER SiteName
    Name of the AD site (replaces Default-First-Site-Name).

.PARAMETER SiteSubnet
    Subnets associated with the site.

.PARAMETER TimeSource
    NTP servers used by the PDC emulator.

.PARAMETER Restart
    Reboot automatically after the promotion.

.EXAMPLE
    $dsrm = Read-Host -AsSecureString -Prompt 'DSRM password'
    .\Initialize-Domain.ps1 -SafeModeAdministratorPassword $dsrm -Restart

    Promotes DC01 and reboots. Run the script again after the reboot.

.EXAMPLE
    .\Initialize-Domain.ps1 -WhatIf

    Shows which post-promotion settings would change.
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9-]+(\.[a-z0-9-]+)+$')]
    [string] $DomainName = 'ad.nrwcorp.internal',

    [ValidateLength(1, 15)]
    [string] $NetbiosName = 'NRWCORP',

    [securestring] $SafeModeAdministratorPassword,

    [ValidateSet('Win2016', 'Win2025')]
    [string] $FunctionalLevel = 'Win2025',

    [ValidateNotNullOrEmpty()]
    [ipaddress[]] $DnsForwarder = @('10.10.20.1'),

    [ValidateNotNullOrEmpty()]
    [string] $SiteName = 'NRW-Duesseldorf',

    [ValidateNotNullOrEmpty()]
    [string[]] $SiteSubnet = @('10.10.10.0/24', '10.10.20.0/24', '10.10.30.0/24'),

    [ValidateNotNullOrEmpty()]
    [string[]] $TimeSource = @('ptbtime1.ptb.de', 'ptbtime2.ptb.de', 'ptbtime3.ptb.de'),

    [switch] $Restart
)

$ErrorActionPreference = 'Stop'

# Mode names as reported by Get-ADForest / Get-ADDomain.
$levelNames = @{
    Win2016 = @{ Forest = 'Windows2016Forest'; Domain = 'Windows2016Domain' }
    Win2025 = @{ Forest = 'Windows2025Forest'; Domain = 'Windows2025Domain' }
}

# DomainRole 4 = backup domain controller, 5 = primary domain controller.
$isDomainController = (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole -ge 4

if (-not $isDomainController) {
    $missingFeatures = Get-WindowsFeature -Name AD-Domain-Services, DNS | Where-Object { -not $_.Installed }
    if ($missingFeatures -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install $($missingFeatures.Name -join ', ')")) {
        Install-WindowsFeature -Name $missingFeatures.Name -IncludeManagementTools | Out-Null
    }

    if (-not $SafeModeAdministratorPassword) {
        throw 'This server is not a domain controller yet. Pass -SafeModeAdministratorPassword to promote it.'
    }

    if ($PSCmdlet.ShouldProcess($DomainName, "Create forest ($FunctionalLevel)")) {
        Import-Module -Name ADDSDeployment
        $forestParameters = @{
            DomainName                    = $DomainName
            DomainNetbiosName             = $NetbiosName
            ForestMode                    = $FunctionalLevel
            DomainMode                    = $FunctionalLevel
            InstallDns                    = $true
            SafeModeAdministratorPassword = $SafeModeAdministratorPassword
            NoRebootOnCompletion          = $true
            Force                         = $true
        }
        Install-ADDSForest @forestParameters | Out-Null

        Write-Warning 'Forest created. Reboot the server and run this script again to finish the configuration.'
        if ($Restart) {
            Restart-Computer -Force
        }
    }
    return
}

Import-Module -Name ActiveDirectory, DnsServer

# --- Functional levels (domain first: the forest level cannot exceed it) ----
$domain = Get-ADDomain
if ($domain.DomainMode.ToString() -ne $levelNames[$FunctionalLevel].Domain -and
    $PSCmdlet.ShouldProcess($domain.DNSRoot, "Raise domain functional level to $FunctionalLevel")) {
    Set-ADDomainMode -Identity $domain.DNSRoot -DomainMode $levelNames[$FunctionalLevel].Domain -Confirm:$false
}

$forest = Get-ADForest
if ($forest.ForestMode.ToString() -ne $levelNames[$FunctionalLevel].Forest -and
    $PSCmdlet.ShouldProcess($forest.Name, "Raise forest functional level to $FunctionalLevel")) {
    Set-ADForestMode -Identity $forest.Name -ForestMode $levelNames[$FunctionalLevel].Forest -Confirm:$false
}

# --- DNS forwarders ---------------------------------------------------------
$forwarder = Get-DnsServerForwarder
$currentForwarders = @($forwarder.IPAddress | ForEach-Object { $_.IPAddressToString }) | Sort-Object
$desiredForwarders = @($DnsForwarder | ForEach-Object { $_.IPAddressToString }) | Sort-Object
$forwardersDiffer = [bool](Compare-Object -ReferenceObject @($currentForwarders) -DifferenceObject @($desiredForwarders))
if (($forwardersDiffer -or $forwarder.UseRootHint) -and
    $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Set DNS forwarders to $($desiredForwarders -join ', ')")) {
    Set-DnsServerForwarder -IPAddress $DnsForwarder -UseRootHint $false -Timeout 3
}

# --- Site and subnets ------------------------------------------------------
if (-not (Get-ADReplicationSite -Filter "Name -eq '$SiteName'")) {
    $defaultSite = Get-ADReplicationSite -Filter "Name -eq 'Default-First-Site-Name'"
    if ($defaultSite -and $PSCmdlet.ShouldProcess('Default-First-Site-Name', "Rename site to $SiteName")) {
        Rename-ADObject -Identity $defaultSite.DistinguishedName -NewName $SiteName
    }
}

foreach ($subnet in $SiteSubnet) {
    if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$subnet'") -and
        $PSCmdlet.ShouldProcess($subnet, "Create subnet in site $SiteName")) {
        New-ADReplicationSubnet -Name $subnet -Site $SiteName
    }
}

# --- AD Recycle Bin --------------------------------------------------------
$recycleBin = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'"
if (-not $recycleBin.EnabledScopes -and $PSCmdlet.ShouldProcess($forest.Name, 'Enable AD Recycle Bin')) {
    Enable-ADOptionalFeature -Identity $recycleBin -Scope ForestOrConfigurationSet -Target $forest.Name -Confirm:$false
}

# --- Time source (PDC emulator only) ---------------------------------------
$pdcEmulator = (Get-ADDomain).PDCEmulator
if ($pdcEmulator -like "$env:COMPUTERNAME.*") {
    $desiredPeers = ($TimeSource | ForEach-Object { "$_,0x8" }) -join ' '
    $timeParameters = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
    if (($timeParameters.NtpServer -ne $desiredPeers -or $timeParameters.Type -ne 'NTP') -and
        $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Sync time from $($TimeSource -join ', ')")) {
        & w32tm.exe /config "/manualpeerlist:$desiredPeers" /syncfromflags:manual /reliable:yes /update | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "w32tm /config failed with exit code $LASTEXITCODE."
        }
        & w32tm.exe /resync /rediscover | Out-Null
    }
}

[pscustomobject]@{
    Domain        = (Get-ADDomain).DNSRoot
    DomainMode    = (Get-ADDomain).DomainMode
    ForestMode    = (Get-ADForest).ForestMode
    PDCEmulator   = $pdcEmulator
    DnsForwarders = (Get-DnsServerForwarder).IPAddress.IPAddressToString -join ', '
    Site          = $SiteName
    RecycleBinOn  = [bool](Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'").EnabledScopes
}
