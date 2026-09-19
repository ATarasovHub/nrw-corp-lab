# DHCP design (docs/02-network.md#dhcp). Windows DHCP serves the corporate client VLAN only:
# MGMT and SERVERS are static, GUEST is served by OPNsense on RTR01.
@{
    PrimaryServer = 'DC01'
    PartnerServer = 'DC02'

    Failover      = @{
        Name                = 'DC01-DC02'
        LoadBalancePercent  = 50
        MaxClientLeadTime   = '01:00:00'
        StateSwitchInterval = '01:00:00'
    }

    DnsSettings   = @{
        DynamicUpdates             = 'Always'
        DeleteDnsRROnLeaseExpiry   = $true
        UpdateDnsRRForOlderClients = $true
    }

    Scopes        = @(
        @{
            Name          = 'CLIENTS'
            Description   = 'VLAN 30 - employee workstations (relayed by RTR01)'
            VlanId        = 30
            ScopeId       = '10.10.30.0'
            SubnetMask    = '255.255.255.0'
            # Range includes the reservation block; the exclusion keeps it out of the dynamic pool.
            StartRange    = '10.10.30.50'
            EndRange      = '10.10.30.199'
            Exclusions    = @(
                @{ StartRange = '10.10.30.50'; EndRange = '10.10.30.99' }
            )
            LeaseDuration = '8.00:00:00'
            Router        = '10.10.30.1'
            DnsServer     = @('10.10.20.11', '10.10.20.12')
            DnsDomain     = 'ad.nrwcorp.internal'
            # MAC addresses are passed to New-DhcpScopes.ps1 via -ReservationMacAddress.
            Reservations  = @(
                @{ Name = 'PRN01'; IPAddress = '10.10.30.50'; Description = 'Network printer, ground floor' }
                @{ Name = 'PRN02'; IPAddress = '10.10.30.51'; Description = 'Network printer, 1st floor' }
            )
        }
    )
}
