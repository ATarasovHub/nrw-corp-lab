<#
.SYNOPSIS
    Restores the lab GPOs from gpo/backups and links them to their OUs.

.DESCRIPTION
    Disaster recovery and rebuild path for Group Policy. For every GPO in data/gpo.psd1 with a
    backup in gpo/backups/<GpoName>/:

    1. Builds a migration table that maps every domain security principal referenced in the
       backup (read from its gpreport.xml) to the principal with the same name in the current
       domain. A rebuilt domain has new SIDs, so security templates (restricted groups, user
       rights) would otherwise point to non-existent accounts.
    2. Import-GPO into the GPO with the same name (created if needed). Importing replaces all
       settings, so the result is identical on every run.
    3. Group Policy Preferences are not processed by migration tables: the group SIDs in
       Drives.xml item-level targeting are re-resolved by name and the GPO version is bumped.
    4. Creates the links defined in data/gpo.psd1.

.PARAMETER DataPath
    Directory that contains gpo.psd1 and ou-structure.psd1.

.PARAMETER BackupPath
    Folder with one sub-folder per GPO as written by Export-LabGpo.ps1.

.PARAMETER SkipLink
    Import settings only; do not create links.

.EXAMPLE
    .\Import-LabGpo.ps1

.EXAMPLE
    .\Import-LabGpo.ps1 -WhatIf
#>
#Requires -Version 7.4
#Requires -Modules ActiveDirectory, GroupPolicy
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $BackupPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../gpo/backups'),

    [switch] $SkipLink
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$gpoData = Get-LabDataFile -Name 'gpo.psd1' -DataPath $DataPath
$ouData = Get-LabDataFile -Name 'ou-structure.psd1' -DataPath $DataPath
$domain = Get-ADDomain
$drivesExtension = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'

function Build-MigrationTable {
    # Maps domain SIDs found in the backup report to same-named principals in this domain.
    [OutputType([string])]
    param([string] $BackupFolder, [string] $OutputFile)

    $mappings = [System.Collections.Generic.List[string]]::new()
    foreach ($report in Get-ChildItem -LiteralPath $BackupFolder -Recurse -Filter 'gpreport.xml') {
        [xml] $xml = [System.IO.File]::ReadAllText($report.FullName)
        foreach ($sidNode in $xml.SelectNodes("//*[local-name()='SID']")) {
            $sid = $sidNode.InnerText
            $nameNode = $sidNode.ParentNode.SelectSingleNode("*[local-name()='Name']")
            if ($sid -notmatch '^S-1-5-21-' -or -not $nameNode) {
                continue
            }
            $sam = ($nameNode.InnerText -split '\\')[-1]
            $target = Get-ADObject -Filter "sAMAccountName -eq '$sam'" -Properties groupType, objectClass
            if (-not $target) {
                Write-Warning "Principal $($nameNode.InnerText) from the backup does not exist in $($domain.DNSRoot)."
                continue
            }
            $type = switch ($target.objectClass) {
                'user' { 'User' }
                'computer' { 'Computer' }
                'group' {
                    # groupType bits: 2 = global, 4 = domain local, 8 = universal.
                    if ($target.groupType -band 4) { 'LocalGroup' } elseif ($target.groupType -band 8) { 'UniversalGroup' } else { 'GlobalGroup' }
                }
                default { 'Unknown' }
            }
            $mapping = "  <Mapping><Type>$type</Type><Source>$sid</Source><Destination>$($domain.NetBIOSName)\$sam</Destination></Mapping>"
            if (-not $mappings.Contains($mapping)) {
                $mappings.Add($mapping)
            }
        }
    }

    $content = @(
        '<?xml version="1.0" encoding="utf-16"?>'
        '<MigrationTable xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations/MigrationTable">'
        $mappings
        '</MigrationTable>'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($OutputFile, $content, [System.Text.UnicodeEncoding]::new($false, $true))
    $OutputFile
}

$summary = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($definition in $gpoData.Gpos) {
    $name = $definition.Name
    $folder = Join-Path -Path $BackupPath -ChildPath $name
    if (-not (Test-Path -LiteralPath $folder)) {
        Write-Warning "No backup for $name in $folder. Run Export-LabGpo.ps1 in a configured lab, or New-LabGpo.ps1."
        continue
    }

    if ($PSCmdlet.ShouldProcess($name, "Import from $folder")) {
        $migrationTable = Build-MigrationTable -BackupFolder $folder -OutputFile (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "$name.migtable")
        try {
            $gpo = Import-GPO -BackupGpoName $name -Path $folder -TargetName $name -CreateIfNeeded -MigrationTable $migrationTable
        } finally {
            Remove-Item -LiteralPath $migrationTable -Force -ErrorAction SilentlyContinue
        }

        # Re-resolve group SIDs in Group Policy Preferences drive maps by name.
        $drivesFile = "\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies\$($gpo.Id.ToString('B').ToUpperInvariant())\User\Preferences\Drives\Drives.xml"
        if (Test-Path -LiteralPath $drivesFile) {
            [xml] $drives = [System.IO.File]::ReadAllText($drivesFile)
            foreach ($filter in $drives.SelectNodes('//FilterGroup')) {
                $account = [System.Security.Principal.NTAccount] ("$($domain.NetBIOSName)\" + ($filter.name -split '\\')[-1])
                $filter.SetAttribute('name', $account.Value)
                $filter.SetAttribute('sid', $account.Translate([System.Security.Principal.SecurityIdentifier]).Value)
            }
            $null = Set-LabGpoSysvolFile -GpoId $gpo.Id -DomainName $domain.DNSRoot -RelativePath 'User\Preferences\Drives\Drives.xml' -Content $drives.OuterXml -Encoding UTF8 -Scope User -Extension $drivesExtension
        }
    }

    if (-not $SkipLink) {
        foreach ($link in $definition.Links) {
            $target = Resolve-LabGpoLinkTarget -Link $link -RootOu $ouData.RootOu -DomainDistinguishedName $domain.DistinguishedName
            $order = if ($definition.ContainsKey('LinkOrder')) { [int] $definition.LinkOrder } else { 0 }
            Set-LabGpoLink -Name $name -Target $target -Order $order
        }
    }

    $summary.Add([pscustomobject]@{ Gpo = $name; Source = $folder; Links = $definition.Links -join ', ' })
}

$summary
