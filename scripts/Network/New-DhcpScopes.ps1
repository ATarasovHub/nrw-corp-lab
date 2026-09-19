<#
.SYNOPSIS
    Deploys Windows DHCP on DC01 and DC02 with scopes, reservations and load-balance failover.

.DESCRIPTION
    Converges both DHCP servers to data/dhcp.psd1 (docs/02-network.md#dhcp):

    1. Installs the DHCP role on the primary and partner server.
    2. Creates the DHCP security groups and marks the post-install configuration as done.
    3. Authorizes both servers in Active Directory.
    4. Configures dynamic DNS updates (optionally with a dedicated DNS update credential, which
       Microsoft recommends when DHCP runs on a domain controller).
    5. Creates or updates scopes on the primary server: range, lease duration, exclusions,
       options 003 (router), 006 (DNS servers) and 015 (DNS domain name), reservations.
    6. Creates the failover relationship (load balance 50/50) or adds missing scopes to it, and
       replicates the scope configuration to the partner.

    Run the script on the primary server (DC01) as a domain administrator.

.PARAMETER DataPath
    Directory that contains dhcp.psd1.

.PARAMETER ReservationMacAddress
    Hashtable of reservation name to MAC address, e.g. @{ PRN01 = '00-15-5D-01-02-03' }.
    Reservations without a MAC address are skipped with a warning.

.PARAMETER FailoverSharedSecret
    Shared secret for the failover relationship. Required only when the relationship is created.

.PARAMETER DnsUpdateCredential
    Optional dedicated account that the DHCP servers use for dynamic DNS registrations.

.EXAMPLE
    $secret = Read-Host -AsSecureString -Prompt 'Failover shared secret'
    .\New-DhcpScopes.ps1 -FailoverSharedSecret $secret -ReservationMacAddress @{ PRN01 = '00-15-5D-0A-1E-32' }

.EXAMPLE
    .\New-DhcpScopes.ps1 -WhatIf
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [hashtable] $ReservationMacAddress = @{},

    [securestring] $FailoverSharedSecret,

    [pscredential] $DnsUpdateCredential
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$data = Get-LabDataFile -Name 'dhcp.psd1' -DataPath $DataPath
$domain = Get-ADDomain
$servers = @($data.PrimaryServer, $data.PartnerServer)
$primary = "$($data.PrimaryServer).$($domain.DNSRoot)"
$partner = "$($data.PartnerServer).$($domain.DNSRoot)"
$scopeChanged = $false

foreach ($name in $ReservationMacAddress.Keys) {
    if ($ReservationMacAddress[$name] -notmatch '^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$') {
        throw "Invalid MAC address for reservation ${name}: $($ReservationMacAddress[$name])"
    }
}

# --- 1. Role installation --------------------------------------------------
foreach ($server in $servers) {
    $feature = Get-WindowsFeature -Name DHCP -ComputerName $server
    if (-not $feature.Installed -and $PSCmdlet.ShouldProcess($server, 'Install DHCP role')) {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools -ComputerName $server | Out-Null
    }
}

Import-Module -Name DhcpServer

# --- 2. Security groups and post-install flag ------------------------------
if (-not (Get-ADGroup -Filter "Name -eq 'DHCP Administrators'") -and
    $PSCmdlet.ShouldProcess($domain.DNSRoot, 'Create DHCP Administrators and DHCP Users groups')) {
    Add-DhcpServerSecurityGroup -ComputerName $primary
}

foreach ($server in $servers) {
    $configured = Invoke-Command -ComputerName $server -ScriptBlock {
        (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -ErrorAction SilentlyContinue).ConfigurationState -eq 2
    }
    if (-not $configured -and $PSCmdlet.ShouldProcess($server, 'Mark DHCP post-install configuration as complete and restart DHCP')) {
        Invoke-Command -ComputerName $server -ScriptBlock {
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2
            Restart-Service -Name DHCPServer
        }
    }
}

# --- 3. Authorization in AD ------------------------------------------------
$authorized = @(Get-DhcpServerInDC | ForEach-Object { $_.DnsName })
foreach ($fqdn in $primary, $partner) {
    if ($fqdn -notin $authorized -and $PSCmdlet.ShouldProcess($fqdn, 'Authorize DHCP server in AD')) {
        $address = (Resolve-DnsName -Name $fqdn -Type A -DnsOnly | Select-Object -First 1).IPAddress
        Add-DhcpServerInDC -DnsName $fqdn -IPAddress $address
    }
}

# --- 4. Dynamic DNS --------------------------------------------------------
foreach ($fqdn in $primary, $partner) {
    $dns = Get-DhcpServerv4DnsSetting -ComputerName $fqdn
    $desiredDns = $data.DnsSettings
    $dnsDiffers = @($desiredDns.Keys | Where-Object { [string] $dns.$_ -ne [string] $desiredDns[$_] }).Count -gt 0
    if ($dnsDiffers -and $PSCmdlet.ShouldProcess($fqdn, 'Configure dynamic DNS updates')) {
        Set-DhcpServerv4DnsSetting -ComputerName $fqdn @desiredDns
    }

    if ($DnsUpdateCredential) {
        $current = Get-DhcpServerDnsCredential -ComputerName $fqdn
        $desiredUser = $DnsUpdateCredential.GetNetworkCredential().UserName
        if ($current.UserName -ne $desiredUser -and $PSCmdlet.ShouldProcess($fqdn, "Use $desiredUser for DNS registrations")) {
            Set-DhcpServerDnsCredential -ComputerName $fqdn -Credential $DnsUpdateCredential
        }
    }
}

# --- 5. Scopes on the primary server ---------------------------------------
foreach ($scope in $data.Scopes) {
    $leaseDuration = [timespan] $scope.LeaseDuration
    $existing = Get-DhcpServerv4Scope -ComputerName $primary -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue

    if (-not $existing) {
        if ($PSCmdlet.ShouldProcess($scope.ScopeId, "Create scope $($scope.Name)")) {
            Add-DhcpServerv4Scope -ComputerName $primary -Name $scope.Name -Description $scope.Description -StartRange $scope.StartRange -EndRange $scope.EndRange -SubnetMask $scope.SubnetMask -LeaseDuration $leaseDuration -State Active
            $scopeChanged = $true
        } else {
            continue
        }
    } elseif ($existing.StartRange.ToString() -ne $scope.StartRange -or $existing.EndRange.ToString() -ne $scope.EndRange -or
        $existing.LeaseDuration -ne $leaseDuration -or $existing.Name -ne $scope.Name -or $existing.State -ne 'Active') {
        if ($PSCmdlet.ShouldProcess($scope.ScopeId, 'Update scope range, lease duration and name')) {
            Set-DhcpServerv4Scope -ComputerName $primary -ScopeId $scope.ScopeId -Name $scope.Name -Description $scope.Description -StartRange $scope.StartRange -EndRange $scope.EndRange -LeaseDuration $leaseDuration -State Active
            $scopeChanged = $true
        }
    }

    $exclusions = @(Get-DhcpServerv4ExclusionRange -ComputerName $primary -ScopeId $scope.ScopeId)
    foreach ($exclusion in $scope.Exclusions) {
        $present = $exclusions | Where-Object { $_.StartRange.ToString() -eq $exclusion.StartRange -and $_.EndRange.ToString() -eq $exclusion.EndRange }
        if (-not $present -and $PSCmdlet.ShouldProcess($scope.ScopeId, "Exclude $($exclusion.StartRange)-$($exclusion.EndRange)")) {
            Add-DhcpServerv4ExclusionRange -ComputerName $primary -ScopeId $scope.ScopeId -StartRange $exclusion.StartRange -EndRange $exclusion.EndRange
            $scopeChanged = $true
        }
    }

    # Options 003 router, 006 DNS servers, 015 DNS domain name.
    $options = @{}
    Get-DhcpServerv4OptionValue -ComputerName $primary -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue |
        ForEach-Object { $options[[int] $_.OptionId] = @($_.Value) -join ',' }
    $optionsDiffer = ($options[3] -ne $scope.Router) -or ($options[6] -ne ($scope.DnsServer -join ',')) -or ($options[15] -ne $scope.DnsDomain)
    if ($optionsDiffer -and $PSCmdlet.ShouldProcess($scope.ScopeId, 'Set options 003, 006, 015')) {
        # -Force skips the reachability check of the DNS servers.
        Set-DhcpServerv4OptionValue -ComputerName $primary -ScopeId $scope.ScopeId -Router $scope.Router -DnsServer $scope.DnsServer -DnsDomain $scope.DnsDomain -Force
        $scopeChanged = $true
    }

    foreach ($reservation in $scope.Reservations) {
        $mac = $ReservationMacAddress[$reservation.Name]
        if (-not $mac) {
            Write-Warning "No MAC address for reservation $($reservation.Name) ($($reservation.IPAddress)). Pass it via -ReservationMacAddress."
            continue
        }
        $mac = ($mac -replace ':', '-').ToLowerInvariant()

        $current = Get-DhcpServerv4Reservation -ComputerName $primary -IPAddress $reservation.IPAddress -ErrorAction SilentlyContinue
        if ($current -and $current.ClientId -ne $mac -and $PSCmdlet.ShouldProcess($reservation.IPAddress, "Replace reservation (MAC changed to $mac)")) {
            Remove-DhcpServerv4Reservation -ComputerName $primary -IPAddress $reservation.IPAddress
            $current = $null
        }
        if (-not $current -and $PSCmdlet.ShouldProcess($reservation.IPAddress, "Reserve for $($reservation.Name) ($mac)")) {
            Add-DhcpServerv4Reservation -ComputerName $primary -ScopeId $scope.ScopeId -IPAddress $reservation.IPAddress -ClientId $mac -Name $reservation.Name -Description $reservation.Description
            $scopeChanged = $true
        }
    }
}

# --- 6. Failover -----------------------------------------------------------
$scopeIds = @($data.Scopes | ForEach-Object { $_.ScopeId })
$failover = Get-DhcpServerv4Failover -ComputerName $primary -Name $data.Failover.Name -ErrorAction SilentlyContinue

if (-not $failover) {
    if (-not $FailoverSharedSecret) {
        throw 'The failover relationship does not exist yet. Pass -FailoverSharedSecret to create it.'
    }
    if ($PSCmdlet.ShouldProcess("$primary <-> $partner", "Create load-balance failover $($data.Failover.Name)")) {
        $failoverParameters = @{
            ComputerName        = $primary
            Name                = $data.Failover.Name
            PartnerServer       = $partner
            ScopeId             = $scopeIds
            LoadBalancePercent  = $data.Failover.LoadBalancePercent
            MaxClientLeadTime   = [timespan] $data.Failover.MaxClientLeadTime
            AutoStateTransition = $true
            StateSwitchInterval = [timespan] $data.Failover.StateSwitchInterval
            SharedSecret        = [System.Net.NetworkCredential]::new('', $FailoverSharedSecret).Password
        }
        Add-DhcpServerv4Failover @failoverParameters
        $scopeChanged = $false
    }
} else {
    $missingScopes = @($scopeIds | Where-Object { $_ -notin @($failover.ScopeId | ForEach-Object { $_.ToString() }) })
    if ($missingScopes.Count -gt 0 -and $PSCmdlet.ShouldProcess($data.Failover.Name, "Add scope(s) $($missingScopes -join ', ')")) {
        Add-DhcpServerv4FailoverScope -ComputerName $primary -Name $data.Failover.Name -ScopeId $missingScopes
    }
    if ($scopeChanged -and $PSCmdlet.ShouldProcess($partner, 'Replicate scope configuration to failover partner')) {
        Invoke-DhcpServerv4FailoverReplication -ComputerName $primary -Name $data.Failover.Name -Force | Out-Null
    }
}

foreach ($fqdn in $primary, $partner) {
    Get-DhcpServerv4Scope -ComputerName $fqdn -ErrorAction SilentlyContinue |
        Select-Object -Property @{ Name = 'Server'; Expression = { $fqdn } }, ScopeId, Name, StartRange, EndRange, State
}
