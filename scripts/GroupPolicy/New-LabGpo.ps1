<#
.SYNOPSIS
    Builds the lab Group Policy objects from data/gpo.psd1 and links them to their OUs.

.DESCRIPTION
    Converges every GPO defined in data/gpo.psd1 (rationale: docs/04-gpo.md):

    - creates the GPO if it does not exist and disables the unused half (computer or user),
    - registry-based settings via Set-GPRegistryValue (only values that differ are written),
    - security settings (password policy, restricted groups, user rights) as GptTmpl.inf,
    - Group Policy Preferences drive maps as Drives.xml with item-level targeting by group,
    - links on the domain, the Domain Controllers OU or lab OUs (with link order if defined).

    Files in SYSVOL are only rewritten when their content changes; in that case the GPO version
    is incremented in AD and GPT.INI so that clients pick up the change.

    The script also prepares Windows LAPS (schema extension and self-permission on the computer
    OUs), which the security baseline relies on. Run it on DC01 as a Tier 0 administrator.

.PARAMETER DataPath
    Directory that contains gpo.psd1 and ou-structure.psd1.

.PARAMETER SkipLapsPreparation
    Do not extend the schema for Windows LAPS and do not set the computer self-permissions.

.EXAMPLE
    .\New-LabGpo.ps1

.EXAMPLE
    .\New-LabGpo.ps1 -WhatIf
#>
#Requires -Version 7.4
#Requires -Modules ActiveDirectory, GroupPolicy
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [switch] $SkipLapsPreparation
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$gpoData = Get-LabDataFile -Name 'gpo.psd1' -DataPath $DataPath
$ouData = Get-LabDataFile -Name 'ou-structure.psd1' -DataPath $DataPath
$domain = Get-ADDomain

$securityExtension = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
$drivesExtension = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}][{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'

function Resolve-TemplateValue {
    # Replaces {Group} with *<SID> and {RID:n} with *<domain SID>-n.
    param([string] $Value)
    [regex]::Replace($Value, '\{([^}]+)\}', {
            param($match)
            $token = $match.Groups[1].Value
            if ($token -match '^RID:(\d+)$') {
                return "*$($domain.DomainSID.Value)-$($Matches[1])"
            }
            $group = Get-ADGroup -Filter "SamAccountName -eq '$token'"
            if (-not $group) {
                throw "Group '$token' referenced in gpo.psd1 does not exist. Run Import-LabUsers.ps1 first."
            }
            "*$($group.SID.Value)"
        })
}

# --- Windows LAPS prerequisites --------------------------------------------
if (-not $SkipLapsPreparation) {
    $schemaNc = (Get-ADRootDSE).schemaNamingContext
    if (-not (Get-ADObject -SearchBase $schemaNc -Filter "lDAPDisplayName -eq 'msLAPS-Password'") -and
        $PSCmdlet.ShouldProcess($schemaNc, 'Extend schema for Windows LAPS')) {
        Update-LapsADSchema -Confirm:$false
    }
    foreach ($path in 'Computers', 'Servers') {
        $ou = ConvertTo-LabDistinguishedName -Path $path -RootOu $ouData.RootOu -DomainDistinguishedName $domain.DistinguishedName
        if ($PSCmdlet.ShouldProcess($ou, 'Allow computers to update their LAPS password')) {
            Set-LapsADComputerSelfPermission -Identity $ou | Out-Null
        }
    }
}

# --- GPOs ------------------------------------------------------------------
$summary = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($definition in $gpoData.Gpos) {
    $name = $definition.Name
    $changes = [System.Collections.Generic.List[string]]::new()

    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        if (-not $PSCmdlet.ShouldProcess($name, 'Create GPO')) {
            continue
        }
        $gpo = New-GPO -Name $name -Comment $definition.Comment
        $changes.Add('created')
    } elseif ($gpo.Description -ne $definition.Comment -and $PSCmdlet.ShouldProcess($name, 'Update comment')) {
        $gpo.Description = $definition.Comment
        $changes.Add('comment')
    }

    # A GPO configures either computer or user settings; the other half is disabled.
    $isUserPolicy = $definition.ContainsKey('DriveMaps')
    $desiredStatus = if ($isUserPolicy) { 'ComputerSettingsDisabled' } else { 'UserSettingsDisabled' }
    if ($gpo.GpoStatus.ToString() -ne $desiredStatus -and $PSCmdlet.ShouldProcess($name, "Set status $desiredStatus")) {
        $gpo.GpoStatus = $desiredStatus
        $changes.Add('status')
    }

    foreach ($setting in @($definition.RegistryValues)) {
        if (-not $setting) {
            continue
        }
        $current = Get-GPRegistryValue -Name $name -Key $setting.Key -ValueName $setting.ValueName -ErrorAction SilentlyContinue
        if ((-not $current -or [string] $current.Value -ne [string] $setting.Value -or $current.Type.ToString() -ne $setting.Type) -and
            $PSCmdlet.ShouldProcess($name, "Set $($setting.Key)\$($setting.ValueName) = $($setting.Value)")) {
            Set-GPRegistryValue -Name $name -Key $setting.Key -ValueName $setting.ValueName -Type $setting.Type -Value $setting.Value | Out-Null
            $changes.Add($setting.ValueName)
        }
    }

    if ($definition.ContainsKey('SecurityTemplate')) {
        $sections = @{}
        foreach ($section in $definition.SecurityTemplate.Keys) {
            $sections[$section] = @{}
            foreach ($key in $definition.SecurityTemplate[$section].Keys) {
                $sections[$section][$key] = Resolve-TemplateValue -Value ([string] $definition.SecurityTemplate[$section][$key])
            }
        }
        $inf = ConvertTo-LabSecurityTemplate -Section $sections
        $written = Set-LabGpoSysvolFile -GpoId $gpo.Id -DomainName $domain.DNSRoot -RelativePath 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf' -Content $inf -Encoding Unicode -Scope Machine -Extension $securityExtension
        if ($written) {
            $changes.Add('security template')
        }
    }

    if ($isUserPolicy) {
        $driveMaps = foreach ($drive in $definition.DriveMaps) {
            $group = Get-ADGroup -Filter "SamAccountName -eq '$($drive.Group)'"
            if (-not $group) {
                throw "Group '$($drive.Group)' for drive $($drive.Letter): does not exist. Run Import-LabUsers.ps1 first."
            }
            [pscustomobject]@{
                Letter    = $drive.Letter
                Path      = $drive.Path
                Label     = $drive.Label
                GroupName = "$($domain.NetBIOSName)\$($drive.Group)"
                GroupSid  = $group.SID.Value
            }
        }
        $xml = ConvertTo-LabDrivesXml -DriveMap $driveMaps
        $written = Set-LabGpoSysvolFile -GpoId $gpo.Id -DomainName $domain.DNSRoot -RelativePath 'User\Preferences\Drives\Drives.xml' -Content $xml -Encoding UTF8 -Scope User -Extension $drivesExtension
        if ($written) {
            $changes.Add('drive maps')
        }
    }

    foreach ($link in $definition.Links) {
        $target = Resolve-LabGpoLinkTarget -Link $link -RootOu $ouData.RootOu -DomainDistinguishedName $domain.DistinguishedName
        $order = if ($definition.ContainsKey('LinkOrder')) { [int] $definition.LinkOrder } else { 0 }
        Set-LabGpoLink -Name $name -Target $target -Order $order
    }

    $summary.Add([pscustomobject]@{
            Gpo     = $name
            Changes = if ($changes.Count -gt 0) { $changes -join ', ' } else { 'none' }
            Links   = $definition.Links -join ', '
        })
}

$summary
