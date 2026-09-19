<#
.SYNOPSIS
    Validates DHCP failover, scope configuration and an observed client lease.
#>
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }, DhcpServer

BeforeAll {
    $script:repoRoot = if ($env:NRW_LAB_ROOT) { $env:NRW_LAB_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
    $script:validation = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/validation.psd1')
    $script:dhcp = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/dhcp.psd1')

    function ConvertTo-UInt32Address {
        [OutputType([uint32])]
        param([Parameter(Mandatory)][ipaddress] $Address)

        $bytes = $Address.GetAddressBytes()
        [Array]::Reverse($bytes)
        [BitConverter]::ToUInt32($bytes, 0)
    }
}

Describe 'DHCP service' -Tag 'DHCP' {
    It 'keeps the configured failover relationship in Normal state' {
        $relationship = Get-DhcpServerv4Failover -ComputerName $script:dhcp.PrimaryServer |
            Where-Object { $_.Name -eq $script:dhcp.Failover.Name }
        $relationship | Should -Not -BeNullOrEmpty
        $relationship.State | Should -Be 'Normal'
        $relationship.PartnerServer | Should -Match "^$([regex]::Escape($script:dhcp.PartnerServer))(\.|$)"
    }

    It 'serves each scope and has an active dynamic lease inside its pool' {
        foreach ($definition in $script:dhcp.Scopes) {
            $scope = Get-DhcpServerv4Scope -ComputerName $script:dhcp.PrimaryServer -ScopeId $definition.ScopeId
            $scope.State | Should -Be 'Active' -Because "scope $($definition.Name) must serve clients"
            $scope.StartRange.IPAddressToString | Should -Be $definition.StartRange
            $scope.EndRange.IPAddressToString | Should -Be $definition.EndRange

            $leases = @(Get-DhcpServerv4Lease -ComputerName $script:dhcp.PrimaryServer -ScopeId $definition.ScopeId |
                    Where-Object { $_.AddressState -eq 'Active' })
            $leases.Count | Should -BeGreaterThan 0 -Because "a client must have obtained an address from $($definition.Name)"

            $start = ConvertTo-UInt32Address -Address $definition.StartRange
            $end = ConvertTo-UInt32Address -Address $definition.EndRange
            foreach ($lease in $leases) {
                $address = ConvertTo-UInt32Address -Address $lease.IPAddress
                $address | Should -BeGreaterOrEqual $start
                $address | Should -BeLessOrEqual $end
                foreach ($exclusion in $definition.Exclusions) {
                    $excludedStart = ConvertTo-UInt32Address -Address $exclusion.StartRange
                    $excludedEnd = ConvertTo-UInt32Address -Address $exclusion.EndRange
                    ($address -ge $excludedStart -and $address -le $excludedEnd) | Should -BeFalse -Because "$($lease.IPAddress) must not be dynamically leased from an exclusion"
                }
            }
        }
    }
}
