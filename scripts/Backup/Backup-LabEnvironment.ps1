<#
.SYNOPSIS
    Backs up a domain controller or the lab file server with Windows Server Backup.

.DESCRIPTION
    Installs Windows Server Backup when needed and selects the workload from the local server
    role (or -Role):

    - DomainController: creates a System State backup with wbadmin and an additional AD DS IFM
      set, including SYSVOL, with ntdsutil.
    - FileServer: creates a volume and bare-metal-capable backup of the file-data volume and all
      critical operating-system volumes.

    A timestamped evidence folder next to the WindowsImageBackup data contains command output,
    a JSON run record and SHA-256 hashes for the IFM set. The backup target must be a dedicated
    local volume or a UNC path; it must not be a volume included in the backup.

.PARAMETER BackupTarget
    Dedicated backup volume (for example E:) or UNC path. A remote share keeps only the newest
    Windows Server Backup version, so use a versioned repository or local backup disk for history.

.PARAMETER Role
    Workload to back up. Auto detects a domain controller from Win32_ComputerSystem.DomainRole;
    otherwise it accepts FS01 as the file server.

.PARAMETER FileServerVolume
    File-data volume included for the FileServer role.

.PARAMETER SkipIfm
    Skip the additional ntdsutil installation-media set on a domain controller. System State is
    still created and remains the authoritative backup for recovery.

.EXAMPLE
    .\Backup-LabEnvironment.ps1 -BackupTarget E:

.EXAMPLE
    .\Backup-LabEnvironment.ps1 -BackupTarget '\\backup01\nrw-lab$' -Role FileServer
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $BackupTarget,

    [ValidateSet('Auto', 'DomainController', 'FileServer')]
    [string] $Role = 'Auto',

    [ValidatePattern('^[A-Z]:$')]
    [string] $FileServerVolume = 'S:',

    [switch] $SkipIfm
)

$ErrorActionPreference = 'Stop'

function Invoke-LabNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $LogPath
    )

    $commandOutput = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $commandOutput | Tee-Object -FilePath $LogPath
    if ($exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode. See $LogPath."
    }
}

function Get-LabBackupRole {
    [OutputType([string])]
    param([string] $RequestedRole)

    if ($RequestedRole -ne 'Auto') {
        return $RequestedRole
    }

    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computerSystem.DomainRole -in 4, 5) {
        return 'DomainController'
    }
    if ($env:COMPUTERNAME -eq 'FS01') {
        return 'FileServer'
    }
    throw "Cannot detect a backup role for $env:COMPUTERNAME. Specify -Role explicitly."
}

function Get-LabTargetDrive {
    [OutputType([string])]
    param([string] $Target)

    if ($Target -match '^(?<Drive>[A-Za-z]):(?:\\)?$') {
        return ($Matches.Drive.ToUpperInvariant() + ':')
    }
    return $null
}

$selectedRole = Get-LabBackupRole -RequestedRole $Role
$targetDrive = Get-LabTargetDrive -Target $BackupTarget
if ($targetDrive -eq 'C:') {
    throw 'The backup target cannot be the operating-system volume C:.'
}
if ($selectedRole -eq 'FileServer' -and $targetDrive -eq $FileServerVolume) {
    throw "The backup target cannot be the source volume $FileServerVolume."
}
if ($targetDrive -and -not (Test-Path -LiteralPath "$targetDrive\" -PathType Container)) {
    throw "Backup target volume $targetDrive is not mounted."
}
if (-not $targetDrive -and -not $BackupTarget.StartsWith('\\')) {
    throw 'BackupTarget must be a drive root such as E: or a UNC path.'
}

$feature = Get-WindowsFeature -Name Windows-Server-Backup
if (-not $feature.Installed -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install Windows Server Backup')) {
    Install-WindowsFeature -Name Windows-Server-Backup -IncludeManagementTools | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evidenceRoot = Join-Path -Path $BackupTarget -ChildPath "nrw-corp-lab\$env:COMPUTERNAME\$stamp"
if ($PSCmdlet.ShouldProcess($evidenceRoot, 'Create backup evidence directory')) {
    New-Item -Path $evidenceRoot -ItemType Directory -Force | Out-Null
}

$backupArguments = if ($selectedRole -eq 'DomainController') {
    @('start', 'systemstatebackup', "-backupTarget:$BackupTarget", '-quiet')
} else {
    if (-not (Get-Volume -DriveLetter $FileServerVolume[0] -ErrorAction SilentlyContinue)) {
        throw "File-server source volume $FileServerVolume is not mounted."
    }
    @('start', 'backup', "-backupTarget:$BackupTarget", "-include:$FileServerVolume", '-allCritical', '-quiet')
}

$wbadminLog = Join-Path -Path $evidenceRoot -ChildPath 'wbadmin.log'
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Run wbadmin for role $selectedRole")) {
    Invoke-LabNativeCommand -FilePath 'wbadmin.exe' -ArgumentList $backupArguments -LogPath $wbadminLog
}

$ifmPath = $null
$ifmManifest = $null
if ($selectedRole -eq 'DomainController' -and -not $SkipIfm) {
    $ifmPath = Join-Path -Path $evidenceRoot -ChildPath 'ifm'
    $ntdsLog = Join-Path -Path $evidenceRoot -ChildPath 'ntdsutil.log'
    $ntdsArguments = @(
        'activate instance ntds'
        'ifm'
        "create sysvol full $ifmPath"
        'quit'
        'quit'
    )
    if ($PSCmdlet.ShouldProcess($ifmPath, 'Create AD DS IFM set with SYSVOL')) {
        Invoke-LabNativeCommand -FilePath 'ntdsutil.exe' -ArgumentList $ntdsArguments -LogPath $ntdsLog
        $ifmManifest = Join-Path -Path $evidenceRoot -ChildPath 'ifm-sha256.csv'
        Get-ChildItem -LiteralPath $ifmPath -File -Recurse |
            Get-FileHash -Algorithm SHA256 |
            Select-Object -Property Path, Hash |
            Export-Csv -LiteralPath $ifmManifest -NoTypeInformation -Encoding utf8
    }
}

$record = [ordered]@{
    SchemaVersion       = 1
    StartedAt           = (Get-Date).ToString('o')
    ComputerName        = $env:COMPUTERNAME
    Role                = $selectedRole
    BackupTarget        = $BackupTarget
    WbadminArguments    = $backupArguments
    WbadminLog          = $wbadminLog
    NtdsIfmPath         = $ifmPath
    NtdsIfmHashManifest = $ifmManifest
}
$recordPath = Join-Path -Path $evidenceRoot -ChildPath 'backup-run.json'
if ($PSCmdlet.ShouldProcess($recordPath, 'Write backup run record')) {
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding utf8
}

[pscustomobject] $record
