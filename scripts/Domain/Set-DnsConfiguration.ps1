<#
.SYNOPSIS
    Creates reverse lookup zones and configures aging and scavenging on the AD-integrated zones.

.DESCRIPTION
    Implements the DNS design from docs/02-network.md:

    - one AD-integrated reverse lookup zone per lab subnet,
    - secure dynamic updates only on all managed zones,
    - aging on all managed zones (no-refresh and refresh interval, default 7 days each),
    - scavenging enabled on exactly one server (default DC01), to keep deletions predictable.

    Zone settings are stored in AD and replicate to all DNS servers, so the script needs to run
    only once, on the scavenging server. Every step checks the current state first.

.PARAMETER ReverseZoneNetworkId
    Subnets in CIDR notation that get a reverse lookup zone. Only /24 subnets are supported.

.PARAMETER ReplicationScope
    AD replication scope of the reverse zones.

.PARAMETER NoRefreshInterval
    Aging no-refresh interval.

.PARAMETER RefreshInterval
    Aging refresh interval.

.PARAMETER ScavengingServer
    The only server on which scavenging is enabled.

.EXAMPLE
    .\Set-DnsConfiguration.ps1

.EXAMPLE
    .\Set-DnsConfiguration.ps1 -ReverseZoneNetworkId '10.10.30.0/24' -WhatIf
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
#Requires -Modules DnsServer, ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.0/24$')]
    [string[]] $ReverseZoneNetworkId = @('10.10.10.0/24', '10.10.20.0/24', '10.10.30.0/24'),

    [ValidateSet('Domain', 'Forest')]
    [string] $ReplicationScope = 'Domain',

    [timespan] $NoRefreshInterval = (New-TimeSpan -Days 7),

    [timespan] $RefreshInterval = (New-TimeSpan -Days 7),

    [ValidateNotNullOrEmpty()]
    [string] $ScavengingServer = 'DC01'
)

$ErrorActionPreference = 'Stop'

$domain = Get-ADDomain
$managedZones = [System.Collections.Generic.List[string]]::new()
$managedZones.Add($domain.DNSRoot)
$managedZones.Add("_msdcs.$($domain.DNSRoot)")

# --- Reverse lookup zones --------------------------------------------------
foreach ($networkId in $ReverseZoneNetworkId) {
    $octets = ($networkId -split '/')[0] -split '\.'
    $zoneName = '{0}.{1}.{2}.in-addr.arpa' -f $octets[2], $octets[1], $octets[0]
    $managedZones.Add($zoneName)

    if (-not (Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue) -and
        $PSCmdlet.ShouldProcess($zoneName, "Create AD-integrated reverse zone ($ReplicationScope)")) {
        Add-DnsServerPrimaryZone -NetworkId $networkId -ReplicationScope $ReplicationScope -DynamicUpdate Secure
    }
}

# --- Secure updates and aging ----------------------------------------------
foreach ($zoneName in $managedZones) {
    $zone = Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue
    if (-not $zone) {
        # Only possible with -WhatIf, when the zone has not been created.
        continue
    }

    if ($zone.DynamicUpdate -ne 'Secure' -and $PSCmdlet.ShouldProcess($zoneName, 'Allow secure dynamic updates only')) {
        Set-DnsServerPrimaryZone -Name $zoneName -DynamicUpdate Secure
    }

    $aging = Get-DnsServerZoneAging -Name $zoneName
    $agingDiffers = (-not $aging.AgingEnabled) -or ($aging.NoRefreshInterval -ne $NoRefreshInterval) -or ($aging.RefreshInterval -ne $RefreshInterval)
    if ($agingDiffers -and $PSCmdlet.ShouldProcess($zoneName, "Enable aging ($($NoRefreshInterval.Days)d/$($RefreshInterval.Days)d)")) {
        Set-DnsServerZoneAging -Name $zoneName -Aging $true -NoRefreshInterval $NoRefreshInterval -RefreshInterval $RefreshInterval
    }
}

# --- Scavenging (one server only) ------------------------------------------
if ($env:COMPUTERNAME -eq $ScavengingServer) {
    $scavengingInterval = $NoRefreshInterval
    $scavenging = Get-DnsServerScavenging
    if ((-not $scavenging.ScavengingState -or $scavenging.ScavengingInterval -ne $scavengingInterval) -and
        $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Enable scavenging every $($scavengingInterval.Days) days")) {
        Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval $scavengingInterval
    }
} else {
    Write-Warning "Scavenging is only enabled on $ScavengingServer; this server is $env:COMPUTERNAME."
}

Get-DnsServerZone |
    Where-Object { $_.ZoneName -in $managedZones } |
    Select-Object -Property ZoneName, IsReverseLookupZone, ReplicationScope, DynamicUpdate, @{
        Name       = 'AgingEnabled'
        Expression = { (Get-DnsServerZoneAging -Name $_.ZoneName).AgingEnabled }
    }
