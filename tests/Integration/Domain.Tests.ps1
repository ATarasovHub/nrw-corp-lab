<#
.SYNOPSIS
    Validates AD DS discovery, DNS and replication in the deployed lab.
#>
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }, ActiveDirectory

BeforeAll {
    $script:repoRoot = if ($env:NRW_LAB_ROOT) { $env:NRW_LAB_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
    $script:validation = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/validation.psd1')
}

Describe 'Active Directory health' -Tag 'Domain', 'Replication' {
    It 'answers domain discovery and publishes a DC locator record' {
        $domain = Get-ADDomain -Identity $script:validation.DomainName -Server $script:validation.PrimaryDomainController
        $domain.DNSRoot | Should -Be $script:validation.DomainName

        $locator = Resolve-DnsName "_ldap._tcp.dc._msdcs.$($script:validation.DomainName)" -Type SRV -ErrorAction Stop
        @($locator | Where-Object { $_.Type -eq 'SRV' }).Count | Should -BeGreaterOrEqual $script:validation.DomainControllers.Count
    }

    It 'finds every designed domain controller' {
        $actual = @(Get-ADDomainController -Filter * -Server $script:validation.PrimaryDomainController).HostName
        foreach ($controller in $script:validation.DomainControllers) {
            $actual | Should -Contain "$controller.$($script:validation.DomainName)" -Because "$controller must advertise as a DC"
        }
    }

    It 'has no replication errors in repadmin or the AD replication API' {
        $repadminOutput = & repadmin.exe /replsummary /bysrc /bydest
        $LASTEXITCODE | Should -Be 0 -Because ($repadminOutput -join [Environment]::NewLine)

        $failures = @(Get-ADReplicationFailure -Scope Forest -Target $script:validation.PrimaryDomainController)
        $failures | Should -BeNullOrEmpty -Because 'repadmin success must agree with the AD replication API'
    }
}
