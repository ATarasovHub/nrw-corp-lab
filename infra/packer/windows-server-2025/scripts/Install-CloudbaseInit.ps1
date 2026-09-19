<#
.SYNOPSIS
    Installs Cloudbase-Init and deploys the lab configuration.

.DESCRIPTION
    Cloudbase-Init is the Windows counterpart of cloud-init. It reads the Proxmox cloud-init
    drive (ConfigDrive v2) on the first boot of every clone and applies hostname, static IP,
    DNS servers and the Administrator password passed in by Terraform.

    Steps:
    1. Download and install the Cloudbase-Init MSI (skipped if the service already exists).
    2. Copy the *.conf files from ConfigurationPath to the Cloudbase-Init conf directory.
    3. Copy LocalScripts\*.ps1 from ConfigurationPath to the Cloudbase-Init LocalScripts directory.

    Steps 2 and 3 overwrite existing files, so re-running the script converges to the same state.

    Runs on Windows PowerShell 5.1 (the provisioner shell during the Packer build).

.PARAMETER ConfigurationPath
    Directory containing cloudbase-init.conf, cloudbase-init-unattend.conf and a LocalScripts folder.

.PARAMETER InstallerUri
    Download URL of the Cloudbase-Init MSI.

.PARAMETER Sha256
    Optional SHA256 hash of the MSI. The installation is aborted if the hash does not match.

.EXAMPLE
    .\Install-CloudbaseInit.ps1 -ConfigurationPath 'C:\Windows\Temp\packer\cloudbase-init'
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $ConfigurationPath,

    [ValidateNotNullOrEmpty()]
    [uri] $InstallerUri = 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi',

    [ValidatePattern('^([A-Fa-f0-9]{64})?$')]
    [string] $Sha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installRoot = Join-Path -Path $env:ProgramFiles -ChildPath 'Cloudbase Solutions\Cloudbase-Init'

if (-not (Get-Service -Name 'cloudbase-init' -ErrorAction SilentlyContinue)) {
    $msiPath = Join-Path -Path $env:TEMP -ChildPath 'CloudbaseInitSetup_x64.msi'

    if ($PSCmdlet.ShouldProcess($InstallerUri, 'Download Cloudbase-Init MSI')) {
        Invoke-WebRequest -Uri $InstallerUri -OutFile $msiPath -UseBasicParsing

        if ($Sha256) {
            $actualHash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
            if ($actualHash -ne $Sha256) {
                Remove-Item -LiteralPath $msiPath -Force
                throw "SHA256 mismatch for $InstallerUri. Expected $Sha256, got $actualHash."
            }
        }
    }

    if ($PSCmdlet.ShouldProcess('Cloudbase-Init', 'Install')) {
        $arguments = @(
            '/i', "`"$msiPath`"", '/qn', '/norestart',
            'RUN_SERVICE_AS_LOCAL_SYSTEM=1', 'LOGGINGSERIALPORTNAME=""'
        )
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) {
            throw "Cloudbase-Init installation failed with exit code $($process.ExitCode)."
        }
        Remove-Item -LiteralPath $msiPath -Force
    }
} else {
    Write-Verbose 'Cloudbase-Init is already installed. Updating configuration only.'
}

$targets = @(
    @{ Source = Join-Path -Path $ConfigurationPath -ChildPath '*.conf'; Destination = Join-Path -Path $installRoot -ChildPath 'conf' }
    @{ Source = Join-Path -Path $ConfigurationPath -ChildPath 'LocalScripts\*.ps1'; Destination = Join-Path -Path $installRoot -ChildPath 'LocalScripts' }
)

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target.Destination, "Copy $($target.Source)")) {
        New-Item -Path $target.Destination -ItemType Directory -Force | Out-Null
        Copy-Item -Path $target.Source -Destination $target.Destination -Force
    }
}
