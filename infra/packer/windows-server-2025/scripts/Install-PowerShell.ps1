<#
.SYNOPSIS
    Installs PowerShell 7 from the official GitHub release MSI.

.DESCRIPTION
    Downloads the PowerShell MSI for the requested version and installs it silently.
    The lab automation in scripts/ requires PowerShell 7, so every template ships with it.

    The script is skipped if pwsh.exe of the requested version is already installed.
    If a SHA256 hash is supplied, the download is verified before installation.

    Runs on Windows PowerShell 5.1 (the provisioner shell during the Packer build).

.PARAMETER Version
    PowerShell version to install, e.g. 7.4.6.

.PARAMETER Sha256
    Optional SHA256 hash of the MSI. The installation is aborted if the hash does not match.

.EXAMPLE
    .\Install-PowerShell.ps1 -Version 7.4.6

.EXAMPLE
    .\Install-PowerShell.ps1 -Version 7.4.6 -Sha256 '<hash from the GitHub release page>'
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,

    [ValidatePattern('^([A-Fa-f0-9]{64})?$')]
    [string] $Sha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$pwshPath = Join-Path -Path $env:ProgramFiles -ChildPath 'PowerShell\7\pwsh.exe'
if (Test-Path -LiteralPath $pwshPath) {
    $installedVersion = (Get-Item -LiteralPath $pwshPath).VersionInfo.ProductVersion
    if ($installedVersion -like "$Version*") {
        Write-Verbose "PowerShell $Version is already installed. Nothing to do."
        return
    }
}

$uri = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/PowerShell-$Version-win-x64.msi"
$msiPath = Join-Path -Path $env:TEMP -ChildPath "PowerShell-$Version-win-x64.msi"

if ($PSCmdlet.ShouldProcess($uri, 'Download PowerShell MSI')) {
    Invoke-WebRequest -Uri $uri -OutFile $msiPath -UseBasicParsing

    if ($Sha256) {
        $actualHash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
        if ($actualHash -ne $Sha256) {
            Remove-Item -LiteralPath $msiPath -Force
            throw "SHA256 mismatch for $uri. Expected $Sha256, got $actualHash."
        }
    }
}

if ($PSCmdlet.ShouldProcess("PowerShell $Version", 'Install')) {
    $arguments = @(
        '/i', "`"$msiPath`"", '/quiet', '/norestart',
        'ADD_PATH=1', 'REGISTER_MANIFEST=1', 'ENABLE_PSREMOTING=0',
        'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0', 'USE_MU=0', 'ENABLE_MU=0'
    )
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "PowerShell installation failed with exit code $($process.ExitCode)."
    }
    Remove-Item -LiteralPath $msiPath -Force
}
