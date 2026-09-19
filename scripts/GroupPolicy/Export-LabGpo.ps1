<#
.SYNOPSIS
    Exports the lab GPOs with Backup-GPO into gpo/backups and HTML reports into gpo/reports.

.DESCRIPTION
    For every GPO defined in data/gpo.psd1:

    - Backup-GPO into a temporary folder, then replaces gpo/backups/<GpoName>/ so that the
      repository always holds exactly one current backup per GPO (no pile-up of backup IDs),
    - Get-GPOReport as HTML into gpo/reports/<GpoName>.html for review on GitHub.

    Commit the result to version the GPOs. Backups contain SIDs and names of lab groups but no
    secrets. Import-LabGpo.ps1 restores them into a (rebuilt) domain.

.PARAMETER DataPath
    Directory that contains gpo.psd1.

.PARAMETER OutputPath
    Root of the GPO export (contains backups/ and reports/).

.EXAMPLE
    .\Export-LabGpo.ps1

.EXAMPLE
    .\Export-LabGpo.ps1 -OutputPath C:\Temp\gpo-export
#>
#Requires -Version 7.4
#Requires -Modules GroupPolicy
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../gpo')
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$gpoData = Get-LabDataFile -Name 'gpo.psd1' -DataPath $DataPath
$backupRoot = Join-Path -Path $OutputPath -ChildPath 'backups'
$reportRoot = Join-Path -Path $OutputPath -ChildPath 'reports'

foreach ($definition in $gpoData.Gpos) {
    $name = $definition.Name
    if (-not (Get-GPO -Name $name -ErrorAction SilentlyContinue)) {
        Write-Warning "GPO $name does not exist. Run New-LabGpo.ps1 first."
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($name, "Export to $backupRoot")) {
        continue
    }

    $staging = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nrw-gpo-$([guid]::NewGuid())"
    New-Item -Path $staging -ItemType Directory | Out-Null
    try {
        $backup = Backup-GPO -Name $name -Path $staging -Comment "Exported by Export-LabGpo.ps1 on $(Get-Date -Format 'yyyy-MM-dd')"
        $target = Join-Path -Path $backupRoot -ChildPath $name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        Get-ChildItem -LiteralPath $staging | Move-Item -Destination $target

        New-Item -Path $reportRoot -ItemType Directory -Force | Out-Null
        Get-GPOReport -Name $name -ReportType Html -Path (Join-Path -Path $reportRoot -ChildPath "$name.html")

        [pscustomobject]@{ Gpo = $name; BackupId = $backup.Id; Path = $target }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
