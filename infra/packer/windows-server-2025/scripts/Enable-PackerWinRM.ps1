<#
.SYNOPSIS
    Enables a temporary WinRM HTTPS listener for the Packer communicator.

.DESCRIPTION
    Runs during the first logon of the Packer build (from autounattend.xml).

    - Sets public network profiles to Private (WinRM refuses to start firewall rules otherwise).
    - Enables PowerShell remoting (HTTP listener on 5985, used later by the lab automation).
    - Creates a self-signed certificate and an HTTPS listener on the given port.
    - Enables Basic authentication, which Packer needs for the local Administrator.

    Unencrypted traffic stays disabled: Packer connects over HTTPS only. The HTTPS listener,
    certificate, firewall rule and Basic authentication are removed on the first boot of every
    clone by Disable-PackerWinRM.ps1 (run by Cloudbase-Init).

    Runs on Windows PowerShell 5.1 because PowerShell 7 is not yet installed at this stage.

.PARAMETER Port
    TCP port of the HTTPS listener.

.PARAMETER CertificateFriendlyName
    Friendly name used to find the build certificate again (idempotency and cleanup).

.EXAMPLE
    .\Enable-PackerWinRM.ps1

    Creates the HTTPS listener on port 5986.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 65535)]
    [int] $Port = 5986,

    [ValidateNotNullOrEmpty()]
    [string] $CertificateFriendlyName = 'Packer WinRM'
)

$ErrorActionPreference = 'Stop'
$firewallRuleName = 'Packer-WinRM-HTTPS'

foreach ($connectionProfile in Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }) {
    if ($PSCmdlet.ShouldProcess($connectionProfile.Name, 'Set network category to Private')) {
        Set-NetConnectionProfile -InterfaceIndex $connectionProfile.InterfaceIndex -NetworkCategory Private
    }
}

if ($PSCmdlet.ShouldProcess('WinRM', 'Enable PowerShell remoting')) {
    Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
}

$certificate = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.FriendlyName -eq $CertificateFriendlyName -and $_.NotAfter -gt (Get-Date) } |
    Select-Object -First 1

if (-not $certificate -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Create self-signed WinRM certificate')) {
    $certificate = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -FriendlyName $CertificateFriendlyName -NotAfter (Get-Date).AddDays(7)
}

$httpsListener = Get-ChildItem -Path WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' }

if (-not $httpsListener -and $certificate -and $PSCmdlet.ShouldProcess("HTTPS:$Port", 'Create WinRM listener')) {
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $certificate.Thumbprint -Port $Port -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess('WinRM service', 'Enable Basic authentication')) {
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
}

if (-not (Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($firewallRuleName, 'Create firewall rule')) {
    New-NetFirewallRule -Name $firewallRuleName -DisplayName 'Packer WinRM (HTTPS-In)' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
}

if ($PSCmdlet.ShouldProcess('WinRM', 'Set service to start automatically and restart')) {
    Set-Service -Name WinRM -StartupType Automatic
    Restart-Service -Name WinRM
}
