<#
.SYNOPSIS
    Generalizes the build VM with sysprep so it can be converted into a template.

.DESCRIPTION
    Last provisioning step of the Packer build. Removes build leftovers, then runs
    sysprep /generalize /oobe /quit with the Unattend.xml shipped by Cloudbase-Init, so that
    every clone runs Cloudbase-Init during the specialize pass.

    /quit (instead of /shutdown) returns control to Packer, which then shuts the VM down via
    ACPI and converts it into a template. The script waits until Windows reports the image
    state IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE and fails otherwise.

    If the image is already generalized, the script does nothing.

    Runs on Windows PowerShell 5.1 (the provisioner shell during the Packer build).

.PARAMETER UnattendPath
    Answer file passed to sysprep. Defaults to the one installed by Cloudbase-Init.

.PARAMETER CleanupPath
    Optional directory with build leftovers that is deleted before sysprep runs.

.PARAMETER TimeoutMinutes
    Maximum time to wait for sysprep to finish.

.EXAMPLE
    .\Invoke-Sysprep.ps1 -CleanupPath 'C:\Windows\Temp\packer'
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $UnattendPath = (Join-Path -Path $env:ProgramFiles -ChildPath 'Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml'),

    [string] $CleanupPath,

    [ValidateRange(1, 120)]
    [int] $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

$stateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
$generalizedState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'

if ((Get-ItemProperty -Path $stateKey).ImageState -eq $generalizedState) {
    Write-Verbose 'The image is already generalized. Nothing to do.'
    return
}

if ($CleanupPath -and (Test-Path -LiteralPath $CleanupPath) -and
    $PSCmdlet.ShouldProcess($CleanupPath, 'Remove build leftovers')) {
    Remove-Item -LiteralPath $CleanupPath -Recurse -Force
}

$sysprep = Join-Path -Path $env:SystemRoot -ChildPath 'System32\Sysprep\sysprep.exe'
$arguments = @('/generalize', '/oobe', '/quit', '/quiet', '/mode:vm', "/unattend:`"$UnattendPath`"")

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Generalize with sysprep')) {
    $process = Start-Process -FilePath $sysprep -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "sysprep exited with code $($process.ExitCode). See C:\Windows\System32\Sysprep\Panther\setuperr.log."
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-ItemProperty -Path $stateKey).ImageState -ne $generalizedState) {
        if ((Get-Date) -gt $deadline) {
            throw "sysprep did not reach $generalizedState within $TimeoutMinutes minutes."
        }
        Start-Sleep -Seconds 10
    }
    Write-Verbose 'Image generalized. Packer will now shut down the VM.'
}
