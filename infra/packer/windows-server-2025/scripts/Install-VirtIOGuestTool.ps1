<#
.SYNOPSIS
    Installs the VirtIO drivers and the QEMU guest agent from the virtio-win ISO.

.DESCRIPTION
    Runs during the first logon of the Packer build (from autounattend.xml). Searches all
    file system drives for virtio-win-guest-tools.exe and installs it silently. The QEMU
    guest agent is required by the Packer Proxmox builder to discover the VM's IP address.

    Runs on Windows PowerShell 5.1 because PowerShell 7 is not yet installed at this stage.
    The script is skipped if the QEMU guest agent service already exists.

.PARAMETER InstallerName
    File name of the guest tools installer on the virtio-win ISO.

.EXAMPLE
    .\Install-VirtIOGuestTool.ps1

    Installs the guest tools from the first drive that contains the installer.

.EXAMPLE
    .\Install-VirtIOGuestTool.ps1 -WhatIf

    Shows what would be installed without changing the system.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string] $InstallerName = 'virtio-win-guest-tools.exe'
)

$ErrorActionPreference = 'Stop'

if (Get-Service -Name 'QEMU-GA' -ErrorAction SilentlyContinue) {
    Write-Verbose 'QEMU guest agent is already installed. Nothing to do.'
    return
}

$installer = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path -Path $_.Root -ChildPath $InstallerName } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if (-not $installer) {
    throw "Installer '$InstallerName' not found on any drive. Is the virtio-win ISO attached?"
}

if ($PSCmdlet.ShouldProcess($installer, 'Install VirtIO guest tools')) {
    $process = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    # 3010 = success, reboot required.
    if ($process.ExitCode -notin 0, 3010) {
        throw "VirtIO guest tools installation failed with exit code $($process.ExitCode)."
    }
    Start-Service -Name 'QEMU-GA'
}
