<#
.SYNOPSIS
    Deploys the departmental file shares and home directories on FS01.

.DESCRIPTION
    Converges FS01 to data/shares.psd1 (docs/03-ad-design.md#share-access-matrix):

    1. Installs the File Server and File Server Resource Manager roles and the AD module.
    2. Initializes the data disk (first RAW disk, GPT, NTFS) as the shares volume.
    3. For every departmental share:
       - creates the folder with an explicit, non-inherited NTFS ACL: SYSTEM and Administrators
         full control, DL-FS-<Share>-FC full control, -RW modify, -RO read & execute,
       - shares it with Everyone / Full Control and access-based enumeration: effective access
         is decided by NTFS only (single point of truth),
       - applies an FSRM hard quota with an event-log warning at 85 %.
    4. Home directories:
       - hidden share Home$ with a restrictive root ACL (list/traverse only),
       - one folder per member of GG-AllStaff with Modify for the owner,
       - FSRM auto-apply quota template,
       - homeDirectory \\FS01\Home$\<sAMAccountName> and homeDrive H: in AD (the same value
         ADUC stores when you enter \\FS01\Home$\%username%).

    ACLs are compared as a whole and rewritten only when they differ. Existing data is never
    deleted; home folders of users that left are reported, not removed.

.PARAMETER DataPath
    Directory that contains shares.psd1.

.PARAMETER SkipHomeDirectories
    Do not create home directories and do not change homeDirectory/homeDrive in AD.

.EXAMPLE
    .\New-FileShares.ps1

.EXAMPLE
    .\New-FileShares.ps1 -WhatIf
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [switch] $SkipHomeDirectories
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

$data = Get-LabDataFile -Name 'shares.psd1' -DataPath $DataPath
if ($env:COMPUTERNAME -ne $data.FileServer) {
    throw "Run this script on $($data.FileServer). This computer is $env:COMPUTERNAME."
}

# --- 1. Roles --------------------------------------------------------------
$missingFeatures = Get-WindowsFeature -Name FS-FileServer, FS-Resource-Manager, RSAT-AD-PowerShell | Where-Object { -not $_.Installed }
if ($missingFeatures -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install $($missingFeatures.Name -join ', ')")) {
    Install-WindowsFeature -Name $missingFeatures.Name -IncludeManagementTools | Out-Null
}
Import-Module -Name ActiveDirectory, FileServerResourceManager, SmbShare

$netbios = (Get-ADDomain).NetBIOSName
$everyone = ([System.Security.Principal.SecurityIdentifier] 'S-1-1-0').Translate([System.Security.Principal.NTAccount]).Value
$inheritAll = [System.Security.AccessControl.InheritanceFlags] 'ContainerInherit, ObjectInherit'
$inheritNone = [System.Security.AccessControl.InheritanceFlags]::None

function Resolve-LabSid {
    param([string] $Name)
    try {
        ([System.Security.Principal.NTAccount] $Name).Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
        throw "Cannot resolve '$Name'. Run Import-LabUsers.ps1 first. $_"
    }
}

function Build-DesiredAcl {
    # Builds a protected (non-inherited) ACL: SYSTEM and Administrators full control plus the given rules.
    [OutputType([System.Security.AccessControl.DirectorySecurity])]
    param([object[]] $Rule)

    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier] 'S-1-5-32-544')
    $base = @(
        @{ Sid = [System.Security.Principal.SecurityIdentifier] 'S-1-5-18'; Rights = 'FullControl'; Inheritance = $inheritAll }
        @{ Sid = [System.Security.Principal.SecurityIdentifier] 'S-1-5-32-544'; Rights = 'FullControl'; Inheritance = $inheritAll }
    )
    foreach ($entry in $base + $Rule) {
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($entry.Sid, [System.Security.AccessControl.FileSystemRights] $entry.Rights, $entry.Inheritance, 'None', 'Allow')
        $acl.AddAccessRule($accessRule)
    }
    $acl
}

function Set-DirectoryAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Path, [System.Security.AccessControl.DirectorySecurity] $Acl)

    $current = Get-Acl -LiteralPath $Path
    $differs = ((Get-LabAclSignature -Acl $current) -join ';') -ne ((Get-LabAclSignature -Acl $Acl) -join ';')
    if (($differs -or -not $current.AreAccessRulesProtected) -and $PSCmdlet.ShouldProcess($Path, 'Set NTFS permissions')) {
        Set-Acl -LiteralPath $Path -AclObject $Acl
    }
}

function Set-LabSmbShare {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Name, [string] $Path, [string] $Description)

    $share = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if (-not $share) {
        if ($PSCmdlet.ShouldProcess("\\$env:COMPUTERNAME\$Name", 'Create SMB share (Everyone: Full, ABE)')) {
            New-SmbShare -Name $Name -Path $Path -Description $Description -FullAccess $everyone -FolderEnumerationMode AccessBased | Out-Null
        }
        return
    }

    if ($share.Path -ne $Path) {
        Write-Warning "Share $Name points to $($share.Path), expected $Path. Not changed automatically."
    }
    if (($share.FolderEnumerationMode -ne 'AccessBased' -or $share.Description -ne $Description) -and
        $PSCmdlet.ShouldProcess($Name, 'Enable access-based enumeration and update description')) {
        Set-SmbShare -Name $Name -FolderEnumerationMode AccessBased -Description $Description -Force
    }

    $access = @(Get-SmbShareAccess -Name $Name)
    foreach ($entry in $access | Where-Object { $_.AccountName -ne $everyone }) {
        if ($PSCmdlet.ShouldProcess($Name, "Revoke share access for $($entry.AccountName)")) {
            Revoke-SmbShareAccess -Name $Name -AccountName $entry.AccountName -Force | Out-Null
        }
    }
    $everyoneFull = $access | Where-Object { $_.AccountName -eq $everyone -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow' }
    if (-not $everyoneFull -and $PSCmdlet.ShouldProcess($Name, 'Grant Everyone full share access')) {
        Grant-SmbShareAccess -Name $Name -AccountName $everyone -AccessRight Full -Force | Out-Null
    }
}

function Build-QuotaThreshold {
    # In-memory CIM objects only; nothing is written until New-FsrmQuota / New-FsrmQuotaTemplate.
    param([string] $Subject)
    $action = New-FsrmAction -Type Event -EventType Warning -Body "[Quota Threshold]% of the quota for [Quota Path] is in use ($Subject)."
    New-FsrmQuotaThreshold -Percentage 85 -Action $action
}

# --- 2. Data volume --------------------------------------------------------
$volume = Get-Volume -FileSystemLabel $data.DataVolumeLabel -ErrorAction SilentlyContinue
if (-not $volume) {
    $disk = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object -Property Number | Select-Object -First 1
    if (-not $disk) {
        throw "No volume labeled '$($data.DataVolumeLabel)' and no uninitialized disk found. Attach the data disk (Terraform: disk_sizes_gb.fs_data)."
    }
    if ($PSCmdlet.ShouldProcess("Disk $($disk.Number) ($([math]::Round($disk.Size / 1GB)) GB)", "Initialize as $($data.DataDriveLetter): '$($data.DataVolumeLabel)'")) {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $data.DataDriveLetter |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $data.DataVolumeLabel -Confirm:$false | Out-Null
    }
} elseif ($volume.DriveLetter -ne $data.DataDriveLetter) {
    throw "Volume '$($data.DataVolumeLabel)' has drive letter $($volume.DriveLetter), expected $($data.DataDriveLetter)."
}

# --- 3. Departmental shares ------------------------------------------------
foreach ($share in $data.Shares) {
    $path = Join-Path -Path $data.ShareRoot -ChildPath $share.Name
    if (-not (Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Create folder')) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $path)) {
        continue
    }

    $rules = @(
        @{ Sid = Resolve-LabSid -Name "$netbios\DL-FS-$($share.Name)-FC"; Rights = 'FullControl'; Inheritance = $inheritAll }
        @{ Sid = Resolve-LabSid -Name "$netbios\DL-FS-$($share.Name)-RW"; Rights = 'Modify'; Inheritance = $inheritAll }
        @{ Sid = Resolve-LabSid -Name "$netbios\DL-FS-$($share.Name)-RO"; Rights = 'ReadAndExecute'; Inheritance = $inheritAll }
    )
    Set-DirectoryAcl -Path $path -Acl (Build-DesiredAcl -Rule $rules)
    Set-LabSmbShare -Name $share.Name -Path $path -Description $share.Description

    $quotaSize = [uint64] $share.QuotaGB * 1GB
    $quota = Get-FsrmQuota -Path $path -ErrorAction SilentlyContinue
    if (-not $quota) {
        if ($PSCmdlet.ShouldProcess($path, "Create $($share.QuotaGB) GB hard quota")) {
            New-FsrmQuota -Path $path -Size $quotaSize -Description "Share $($share.Name)" -Threshold (Build-QuotaThreshold -Subject $share.Name) | Out-Null
        }
    } elseif ($quota.Size -ne $quotaSize -and $PSCmdlet.ShouldProcess($path, "Resize quota to $($share.QuotaGB) GB")) {
        Set-FsrmQuota -Path $path -Size $quotaSize | Out-Null
    }
}

# --- 4. Home directories ---------------------------------------------------
if ($SkipHomeDirectories) {
    return Get-SmbShare | Where-Object { -not $_.Special } | Select-Object -Property Name, Path, FolderEnumerationMode
}

$homeConfig = $data.Home
if (-not (Test-Path -LiteralPath $homeConfig.Root) -and $PSCmdlet.ShouldProcess($homeConfig.Root, 'Create folder')) {
    New-Item -Path $homeConfig.Root -ItemType Directory -Force | Out-Null
}

$userGroupSid = Resolve-LabSid -Name "$netbios\$($homeConfig.UserGroup)"
$listOnly = [System.Security.AccessControl.FileSystemRights] 'Traverse, ListDirectory, ReadAttributes, ReadExtendedAttributes, ReadPermissions'
if (Test-Path -LiteralPath $homeConfig.Root) {
    Set-DirectoryAcl -Path $homeConfig.Root -Acl (Build-DesiredAcl -Rule @(@{ Sid = $userGroupSid; Rights = $listOnly; Inheritance = $inheritNone }))
    Set-LabSmbShare -Name $homeConfig.ShareName -Path $homeConfig.Root -Description 'Home directories (mapped as H:)'
}

$templateSize = [uint64] $homeConfig.QuotaGB * 1GB
$template = Get-FsrmQuotaTemplate -Name $homeConfig.TemplateName -ErrorAction SilentlyContinue
if (-not $template) {
    if ($PSCmdlet.ShouldProcess($homeConfig.TemplateName, "Create $($homeConfig.QuotaGB) GB quota template")) {
        New-FsrmQuotaTemplate -Name $homeConfig.TemplateName -Size $templateSize -Threshold (Build-QuotaThreshold -Subject 'home directory') | Out-Null
    }
} elseif ($template.Size -ne $templateSize -and $PSCmdlet.ShouldProcess($homeConfig.TemplateName, "Resize to $($homeConfig.QuotaGB) GB")) {
    Set-FsrmQuotaTemplate -Name $homeConfig.TemplateName -Size $templateSize -UpdateDerived | Out-Null
}
if ((Test-Path -LiteralPath $homeConfig.Root) -and -not (Get-FsrmAutoQuota -Path $homeConfig.Root -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($homeConfig.Root, "Auto-apply quota template '$($homeConfig.TemplateName)'")) {
    New-FsrmAutoQuota -Path $homeConfig.Root -Template $homeConfig.TemplateName | Out-Null
}

$homeUsers = @(Get-ADGroupMember -Identity $homeConfig.UserGroup -Recursive | Where-Object { $_.objectClass -eq 'user' })
foreach ($member in $homeUsers) {
    $sam = $member.SamAccountName
    $path = Join-Path -Path $homeConfig.Root -ChildPath $sam
    if (-not (Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Create home folder')) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $path) {
        Set-DirectoryAcl -Path $path -Acl (Build-DesiredAcl -Rule @(@{ Sid = $member.SID; Rights = 'Modify'; Inheritance = $inheritAll }))
    }

    $unc = "\\$($data.FileServer)\$($homeConfig.ShareName)\$sam"
    $user = Get-ADUser -Identity $member.SID -Properties HomeDirectory, HomeDrive
    if (($user.HomeDirectory -ne $unc -or $user.HomeDrive -ne $homeConfig.Drive) -and $PSCmdlet.ShouldProcess($sam, "Set home directory $unc ($($homeConfig.Drive))")) {
        Set-ADUser -Identity $user -HomeDirectory $unc -HomeDrive $homeConfig.Drive
    }
}

$activeNames = @($homeUsers.SamAccountName)
Get-ChildItem -LiteralPath $homeConfig.Root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $activeNames } |
    ForEach-Object { Write-Warning "Home folder without active user (not deleted): $($_.FullName)" }

Get-SmbShare | Where-Object { -not $_.Special -or $_.Name -eq $homeConfig.ShareName } | Select-Object -Property Name, Path, FolderEnumerationMode
