<#
.SYNOPSIS
    Creates and updates employees, admin accounts and groups from data/ and nests them by AGDLP.

.DESCRIPTION
    Converges AD to the desired state in data/users.csv, data/groups.psd1 and data/shares.psd1
    (docs/03-ad-design.md):

    Groups
    - GG-<Department> and GG-<Department>-Leads per department, GG-AllStaff (nests all
      department groups), tiered admin groups and other groups from groups.psd1.
    - DL-FS-<Share>-RW / -RO / -FC per share in shares.psd1, with the GG-* groups from the
      access matrix as members (AGDLP: Accounts -> Global -> Domain Local -> Permission).

    Users
    - employeeID is the stable key: existing users are updated (attributes, OU, name), never
      duplicated. Logon names follow the naming convention (firstname.lastname, transliterated,
      max. 20 characters, numeric suffix on collision).
    - Separate admin accounts (t0a-/t1a-/t2a-) for every tier listed in AdminTiers.
    - Managers are set from the department leads.
    - Employees missing from users.csv are treated as leavers: disabled and moved to
      Disabled/Users. Admin accounts no longer listed are disabled.

    Membership of all generated groups is authoritative: members not defined by the data files
    are removed. Built-in groups (Domain Admins, Protected Users) are only ever added to.

    New accounts get a random initial secret and must change it at first logon. Secrets are
    appended to a CSV report outside the repository whose ACL allows only the current user,
    SYSTEM and Administrators. The script refuses to write the report into a git working tree.

.PARAMETER DataPath
    Directory with users.csv, groups.psd1, shares.psd1 and ou-structure.psd1.

.PARAMETER ReportPath
    CSV file that receives the initial secrets of newly created accounts.

.PARAMETER SecretLength
    Length of initial secrets for employee accounts.

.PARAMETER AdminSecretLength
    Length of initial secrets for admin accounts.

.PARAMETER Company
    Value of the company attribute.

.PARAMETER City
    Value of the l (city) attribute.

.PARAMETER SkipLeaverProcessing
    Do not disable users and admin accounts that are missing from users.csv.

.EXAMPLE
    .\Import-LabUsers.ps1

    Creates all objects and writes initial secrets to ~\nrw-corp-lab-secrets\initial-credentials.csv.

.EXAMPLE
    .\Import-LabUsers.ps1 -WhatIf

    Shows all changes without touching AD.
#>
#Requires -Version 7.4
#Requires -Modules ActiveDirectory
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data'),

    [ValidateNotNullOrEmpty()]
    [string] $ReportPath = (Join-Path -Path $HOME -ChildPath 'nrw-corp-lab-secrets/initial-credentials.csv'),

    [ValidateRange(12, 128)]
    [int] $SecretLength = 16,

    [ValidateRange(16, 128)]
    [int] $AdminSecretLength = 24,

    [string] $Company = 'NRW Corp GmbH',

    [string] $City = 'Duesseldorf',

    [switch] $SkipLeaverProcessing
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../NrwCorpLab/NrwCorpLab.psd1') -Force

if (Test-LabPathInGitRepository -Path $ReportPath) {
    throw "Refusing to write secrets into a git repository: $ReportPath"
}

# --- Load and validate data ------------------------------------------------
$ouData = Get-LabDataFile -Name 'ou-structure.psd1' -DataPath $DataPath
$groupData = Get-LabDataFile -Name 'groups.psd1' -DataPath $DataPath
$shareData = Get-LabDataFile -Name 'shares.psd1' -DataPath $DataPath
$users = @(Get-LabDataFile -Name 'users.csv' -DataPath $DataPath | Sort-Object -Property EmployeeId)

$problems = @(Test-LabUserData -User $users -Department $groupData.Departments)
if ($problems.Count -gt 0) {
    throw "users.csv is invalid:`n - $($problems -join "`n - ")"
}

$domain = Get-ADDomain
$actions = [System.Collections.Generic.List[pscustomobject]]::new()
$newCredentials = [System.Collections.Generic.List[pscustomobject]]::new()

function Get-OuDistinguishedName {
    param([string] $Path)
    ConvertTo-LabDistinguishedName -Path $Path -RootOu $ouData.RootOu -DomainDistinguishedName $domain.DistinguishedName
}

function Get-GroupDistinguishedName {
    param([string] $Name)
    $group = Get-ADGroup -Filter "SamAccountName -eq '$Name'"
    if ($group) { $group.DistinguishedName }
}

function Get-UniqueCommonName {
    # Returns "Firstname Lastname", or "Firstname Lastname (sam)" if the CN is taken in the OU.
    param([string] $DisplayName, [string] $SamAccountName, [string] $Path)
    $escaped = $DisplayName -replace "'", "''"
    $taken = Get-ADObject -Filter "Name -eq '$escaped'" -SearchBase $Path -SearchScope OneLevel -ErrorAction SilentlyContinue
    if ($taken) { "$DisplayName ($SamAccountName)" } else { $DisplayName }
}

function Add-Action {
    param([string] $Action, [string] $Object, [string] $Detail = '')
    $actions.Add([pscustomobject]@{ Action = $Action; Object = $Object; Detail = $Detail })
}

# --- Groups ----------------------------------------------------------------
$roleOu = Get-OuDistinguishedName -Path $groupData.RoleGroupPath
$resourceOu = Get-OuDistinguishedName -Path $groupData.ResourceGroupPath

foreach ($department in $groupData.Departments) {
    Set-LabAdGroup -Name "GG-$department" -Path $roleOu -GroupScope Global -Description "Employees of department $department"
    Set-LabAdGroup -Name "GG-$department-Leads" -Path $roleOu -GroupScope Global -Description "Team leads of department $department"
}
Set-LabAdGroup -Name $groupData.AllStaffGroup -Path $roleOu -GroupScope Global -Description 'All employees (nests all department groups)'

foreach ($adminGroup in $groupData.AdminGroups) {
    Set-LabAdGroup -Name $adminGroup.Name -Path (Get-OuDistinguishedName -Path $adminGroup.Path) -GroupScope Global -Description $adminGroup.Description
}
foreach ($otherGroup in $groupData.OtherGroups) {
    Set-LabAdGroup -Name $otherGroup.Name -Path (Get-OuDistinguishedName -Path $otherGroup.Path) -GroupScope $otherGroup.Scope -Description $otherGroup.Description
}

$permissionNames = @{ RW = 'Modify'; RO = 'Read & execute'; FC = 'Full control' }
foreach ($share in $shareData.Shares) {
    foreach ($level in 'RW', 'RO', 'FC') {
        $description = "$($permissionNames[$level]) on \\$($shareData.FileServer)\$($share.Name)"
        Set-LabAdGroup -Name "DL-FS-$($share.Name)-$level" -Path $resourceOu -GroupScope DomainLocal -Description $description
    }
}

# --- Employee accounts -----------------------------------------------------
$takenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
Get-ADUser -Filter * | ForEach-Object { [void] $takenNames.Add($_.SamAccountName) }

$employeeDn = @{}
$userProperties = 'EmployeeID', 'GivenName', 'Surname', 'DisplayName', 'Title', 'Department', 'Company', 'City', 'Enabled'

foreach ($row in $users) {
    $targetOu = Get-OuDistinguishedName -Path "Users/$($row.Department)"
    $displayName = "$($row.GivenName) $($row.Surname)"
    $existing = Get-ADUser -Filter "EmployeeID -eq '$($row.EmployeeId)'" -Properties $userProperties

    if ($existing -and $existing.GivenName -ceq $row.GivenName -and $existing.Surname -ceq $row.Surname) {
        $sam = $existing.SamAccountName
    } else {
        $others = @($takenNames | Where-Object { -not $existing -or $_ -ne $existing.SamAccountName })
        $sam = ConvertTo-LabSamAccountName -GivenName $row.GivenName -Surname $row.Surname -ExistingName $others
    }
    $upn = "$sam@$($domain.DNSRoot)"

    $attributes = @{
        GivenName   = $row.GivenName
        Surname     = $row.Surname
        DisplayName = $displayName
        Title       = $row.Title
        Department  = $row.Department
        Company     = $Company
        City        = $City
    }

    if (-not $existing) {
        $commonName = Get-UniqueCommonName -DisplayName $displayName -SamAccountName $sam -Path $targetOu
        $secret = Get-LabRandomSecret -Length $SecretLength
        if ($PSCmdlet.ShouldProcess($sam, "Create user in Users/$($row.Department)")) {
            $created = New-ADUser -Name $commonName -SamAccountName $sam -UserPrincipalName $upn -EmployeeID $row.EmployeeId -Path $targetOu -AccountPassword $secret.SecureString -Enabled $true -ChangePasswordAtLogon $true -PassThru @attributes
            $employeeDn[$row.EmployeeId] = $created.DistinguishedName
            $newCredentials.Add([pscustomobject]@{ Created = (Get-Date -Format 's'); SamAccountName = $sam; UserPrincipalName = $upn; DisplayName = $displayName; InitialSecret = $secret.Text })
        }
        [void] $takenNames.Add($sam)
        Add-Action -Action 'Created' -Object $sam -Detail $row.Department
        continue
    }

    $changes = @{}
    foreach ($key in $attributes.Keys) {
        if ([string] $existing.$key -cne [string] $attributes[$key]) {
            $changes[$key] = $attributes[$key]
        }
    }
    if ($existing.SamAccountName -ne $sam) {
        $changes['SamAccountName'] = $sam
        $changes['UserPrincipalName'] = $upn
        [void] $takenNames.Add($sam)
    }
    if ($changes.Count -gt 0 -and $PSCmdlet.ShouldProcess($existing.SamAccountName, "Update $($changes.Keys -join ', ')")) {
        Set-ADUser -Identity $existing @changes
        Add-Action -Action 'Updated' -Object $sam -Detail ($changes.Keys -join ', ')
    }

    if (-not $existing.Enabled -and $PSCmdlet.ShouldProcess($sam, 'Re-enable returning employee')) {
        Enable-ADAccount -Identity $existing
        Add-Action -Action 'Enabled' -Object $sam
    }

    if ($existing.Name -ne $displayName -and $existing.Name -notlike "$displayName (*)") {
        $currentParent = $existing.DistinguishedName -replace '^CN=.+?(?<!\\),', ''
        $newName = Get-UniqueCommonName -DisplayName $displayName -SamAccountName $sam -Path $currentParent
        if ($PSCmdlet.ShouldProcess($existing.Name, "Rename to $newName")) {
            Rename-ADObject -Identity $existing -NewName $newName
            Add-Action -Action 'Renamed' -Object $sam -Detail $newName
        }
    }

    $current = Get-ADUser -Identity $existing.ObjectGUID
    $currentParent = $current.DistinguishedName -replace '^CN=.+?(?<!\\),', ''
    if ($currentParent -ne $targetOu -and $PSCmdlet.ShouldProcess($sam, "Move to Users/$($row.Department)")) {
        Move-ADObject -Identity $current -TargetPath $targetOu
        Add-Action -Action 'Moved' -Object $sam -Detail $row.Department
    }
    $employeeDn[$row.EmployeeId] = (Get-ADUser -Identity $existing.ObjectGUID).DistinguishedName
}

# --- Admin accounts --------------------------------------------------------
$adminDn = @{ 0 = [System.Collections.Generic.List[string]]::new(); 1 = [System.Collections.Generic.List[string]]::new(); 2 = [System.Collections.Generic.List[string]]::new() }
$desiredAdminKeys = [System.Collections.Generic.HashSet[string]]::new()

foreach ($row in $users | Where-Object { $_.AdminTiers }) {
    foreach ($tier in ($row.AdminTiers -split ';' | ForEach-Object { [int] $_ })) {
        [void] $desiredAdminKeys.Add("$($row.EmployeeId)|$tier")
        $adminOu = Get-OuDistinguishedName -Path "Admin/Tier$tier/Accounts"
        $displayName = "$($row.GivenName) $($row.Surname) (Tier $tier admin)"
        $existing = Get-ADUser -Filter "EmployeeID -eq '$($row.EmployeeId)' -and SamAccountName -like 't${tier}a-*'" -Properties Enabled, AccountNotDelegated

        if (-not $existing) {
            $base = ConvertTo-LabAdminAccountName -Tier $tier -GivenName $row.GivenName -Surname $row.Surname
            $sam = $base
            $counter = 2
            while ($takenNames.Contains($sam)) {
                $sam = "$($base.Substring(0, [Math]::Min($base.Length, 19)))$counter"
                $counter++
            }
            $secret = Get-LabRandomSecret -Length $AdminSecretLength
            if ($PSCmdlet.ShouldProcess($sam, "Create Tier $tier admin account")) {
                $created = New-ADUser -Name $displayName -SamAccountName $sam -UserPrincipalName "$sam@$($domain.DNSRoot)" -GivenName $row.GivenName -Surname $row.Surname -DisplayName $displayName -Description "Tier $tier admin account of $($row.GivenName) $($row.Surname)" -EmployeeID $row.EmployeeId -Path $adminOu -AccountPassword $secret.SecureString -Enabled $true -ChangePasswordAtLogon $true -AccountNotDelegated $true -PassThru
                $adminDn[$tier].Add($created.DistinguishedName)
                $newCredentials.Add([pscustomobject]@{ Created = (Get-Date -Format 's'); SamAccountName = $sam; UserPrincipalName = "$sam@$($domain.DNSRoot)"; DisplayName = $displayName; InitialSecret = $secret.Text })
            }
            [void] $takenNames.Add($sam)
            Add-Action -Action 'Created' -Object $sam -Detail "Tier $tier admin"
            continue
        }

        if (-not $existing.Enabled -and $PSCmdlet.ShouldProcess($existing.SamAccountName, 'Enable admin account')) {
            Enable-ADAccount -Identity $existing
            Add-Action -Action 'Enabled' -Object $existing.SamAccountName
        }
        if (-not $existing.AccountNotDelegated -and $PSCmdlet.ShouldProcess($existing.SamAccountName, 'Mark as sensitive, cannot be delegated')) {
            Set-ADUser -Identity $existing -AccountNotDelegated $true
        }
        $adminDn[$tier].Add($existing.DistinguishedName)
    }
}

# --- Leavers ---------------------------------------------------------------
if (-not $SkipLeaverProcessing) {
    $employeeIds = @($users.EmployeeId)
    $usersRoot = Get-OuDistinguishedName -Path 'Users'
    $disabledOu = Get-OuDistinguishedName -Path 'Disabled/Users'

    if (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$usersRoot)") {
        $leavers = Get-ADUser -SearchBase $usersRoot -Filter "EmployeeID -like '*'" -Properties EmployeeID |
            Where-Object { $_.EmployeeID -notin $employeeIds }
        foreach ($leaver in $leavers) {
            if ($PSCmdlet.ShouldProcess($leaver.SamAccountName, 'Disable leaver and move to Disabled/Users')) {
                Disable-ADAccount -Identity $leaver
                Set-ADUser -Identity $leaver -Description "Leaver - disabled by Import-LabUsers on $(Get-Date -Format 'yyyy-MM-dd')"
                Move-ADObject -Identity $leaver -TargetPath $disabledOu
                Add-Action -Action 'Disabled' -Object $leaver.SamAccountName -Detail 'Leaver'
            }
        }
    }

    $adminRoot = Get-OuDistinguishedName -Path 'Admin'
    if (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$adminRoot)") {
        $staleAdmins = Get-ADUser -SearchBase $adminRoot -Filter "EmployeeID -like '*' -and Enabled -eq 'True'" -Properties EmployeeID |
            Where-Object { $_.SamAccountName -match '^t(\d)a-' -and -not $desiredAdminKeys.Contains("$($_.EmployeeID)|$($Matches[1])") }
        foreach ($staleAdmin in $staleAdmins) {
            if ($PSCmdlet.ShouldProcess($staleAdmin.SamAccountName, 'Disable admin account no longer listed in users.csv')) {
                Disable-ADAccount -Identity $staleAdmin
                Add-Action -Action 'Disabled' -Object $staleAdmin.SamAccountName -Detail 'Admin role removed'
            }
        }
    }
}

# --- Group membership (AGDLP) ----------------------------------------------
foreach ($department in $groupData.Departments) {
    $rows = @($users | Where-Object { $_.Department -eq $department })
    $members = @($rows | ForEach-Object { $employeeDn[$_.EmployeeId] } | Where-Object { $_ })
    $leads = @($rows | Where-Object { $_.IsLead -eq 'true' } | ForEach-Object { $employeeDn[$_.EmployeeId] } | Where-Object { $_ })
    Set-LabAdGroupMember -Identity "GG-$department" -Member $members -Authoritative
    Set-LabAdGroupMember -Identity "GG-$department-Leads" -Member $leads -Authoritative
}

$departmentGroups = @($groupData.Departments | ForEach-Object { Get-GroupDistinguishedName -Name "GG-$_" } | Where-Object { $_ })
Set-LabAdGroupMember -Identity $groupData.AllStaffGroup -Member $departmentGroups -Authoritative

foreach ($adminGroup in $groupData.AdminGroups) {
    Set-LabAdGroupMember -Identity $adminGroup.Name -Member @($adminDn[[int] $adminGroup.Tier]) -Authoritative

    $adminGroupDn = Get-GroupDistinguishedName -Name $adminGroup.Name
    foreach ($rid in $adminGroup.MemberOfRid) {
        $builtInGroup = Get-ADGroup -Identity "$($domain.DomainSID.Value)-$rid"
        if ($adminGroupDn) {
            Set-LabAdGroupMember -Identity $builtInGroup.SamAccountName -Member @($adminGroupDn)
        }
    }
}

$fullControlDn = @(Get-GroupDistinguishedName -Name $shareData.FullControlGroup | Where-Object { $_ })
foreach ($share in $shareData.Shares) {
    $readWrite = @($share.ReadWrite | ForEach-Object { Get-GroupDistinguishedName -Name $_ } | Where-Object { $_ })
    $readOnly = @($share.ReadOnly | ForEach-Object { Get-GroupDistinguishedName -Name $_ } | Where-Object { $_ })
    Set-LabAdGroupMember -Identity "DL-FS-$($share.Name)-RW" -Member $readWrite -Authoritative
    Set-LabAdGroupMember -Identity "DL-FS-$($share.Name)-RO" -Member $readOnly -Authoritative
    Set-LabAdGroupMember -Identity "DL-FS-$($share.Name)-FC" -Member $fullControlDn -Authoritative
}

# --- Managers --------------------------------------------------------------
$leadByDepartment = @{}
foreach ($row in $users | Where-Object { $_.IsLead -eq 'true' }) {
    $leadByDepartment[$row.Department] = $row.EmployeeId
}

foreach ($row in $users) {
    $userDn = $employeeDn[$row.EmployeeId]
    if (-not $userDn) {
        continue
    }

    $managerId = if ($row.IsLead -ne 'true') {
        $leadByDepartment[$row.Department]
    } elseif ($row.Department -ne 'Management') {
        $leadByDepartment['Management']
    }
    $managerDn = if ($managerId) { $employeeDn[$managerId] }

    $currentManager = (Get-ADUser -Identity $userDn -Properties Manager).Manager
    if ($currentManager -ne $managerDn -and $PSCmdlet.ShouldProcess($userDn, "Set manager to $managerDn")) {
        if ($managerDn) {
            Set-ADUser -Identity $userDn -Manager $managerDn
        } else {
            Set-ADUser -Identity $userDn -Clear manager
        }
    }
}

# --- Credential report -----------------------------------------------------
if ($newCredentials.Count -gt 0) {
    $reportDirectory = Split-Path -Path $ReportPath -Parent
    if (-not (Test-Path -LiteralPath $reportDirectory)) {
        New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
        Protect-LabFile -Path $reportDirectory
    }
    $newCredentials | Export-Csv -LiteralPath $ReportPath -Append -NoTypeInformation -Encoding utf8
    Protect-LabFile -Path $ReportPath
    Write-Warning "Initial secrets for $($newCredentials.Count) new account(s) were written to $ReportPath. Hand them over securely, then delete the file."
}

$actions
