<#
.SYNOPSIS
    Removes the temporary WinRM configuration used by Packer.

.DESCRIPTION
    Executed by Cloudbase-Init (LocalScriptsPlugin) on the first boot of every VM cloned from
    the template. Reverts everything Enable-PackerWinRM.ps1 set up for the build:

    - deletes the WinRM HTTPS listener,
    - deletes the self-signed build certificate,
    - deletes the Packer firewall rule,
    - disables Basic authentication and unencrypted traffic.

    The default HTTP listener (5985, Kerberos/Negotiate) stays enabled for domain administration.
    Every step checks the current state first, so the script is safe to run repeatedly.

    Runs on Windows PowerShell 5.1 because Cloudbase-Init invokes powershell.exe.

.PARAMETER CertificateFriendlyName
    Friendly name of the build certificate created by Enable-PackerWinRM.ps1.

.EXAMPLE
    .\Disable-PackerWinRM.ps1
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string] $CertificateFriendlyName = 'Packer WinRM'
)

$ErrorActionPreference = 'Stop'
$firewallRuleName = 'Packer-WinRM-HTTPS'

$httpsListener = Get-ChildItem -Path WSMan:\localhost\Listener |
    Where-Object { $_.Keys -contains 'Transport=HTTPS' }
foreach ($listener in $httpsListener) {
    if ($PSCmdlet.ShouldProcess($listener.Name, 'Remove WinRM HTTPS listener')) {
        Remove-Item -Path $listener.PSPath -Recurse -Force
    }
}

$certificates = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.FriendlyName -eq $CertificateFriendlyName }
foreach ($certificate in $certificates) {
    if ($PSCmdlet.ShouldProcess($certificate.Thumbprint, 'Remove build certificate')) {
        Remove-Item -Path $certificate.PSPath -Force
    }
}

if ((Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($firewallRuleName, 'Remove firewall rule')) {
    Remove-NetFirewallRule -Name $firewallRuleName
}

$settings = @{
    'WSMan:\localhost\Service\Auth\Basic'       = $false
    'WSMan:\localhost\Service\AllowUnencrypted' = $false
}
foreach ($path in $settings.Keys) {
    $current = (Get-Item -Path $path).Value
    if ($current -ne $settings[$path].ToString() -and $PSCmdlet.ShouldProcess($path, "Set to $($settings[$path])")) {
        Set-Item -Path $path -Value $settings[$path]
    }
}
