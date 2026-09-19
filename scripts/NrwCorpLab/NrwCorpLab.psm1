#Requires -Version 7.4
# Shared helpers for the nrw-corp-lab scripts. Pure functions (naming, secrets, DN handling)
# are covered by unit tests in tests/Unit; AD-dependent functions resolve their cmdlets at runtime.

Set-StrictMode -Version Latest

function ConvertTo-LabAsciiName {
    <#
    .SYNOPSIS
        Converts a personal name into a lowercase ASCII token for account names.
    .DESCRIPTION
        Transliterates German umlauts and sharp s (ae, oe, ue, ss), strips other diacritics,
        removes spaces and apostrophes and keeps hyphens (docs/03-ad-design.md).
    .PARAMETER Name
        Given name or surname.
    .EXAMPLE
        ConvertTo-LabAsciiName -Name 'Schulze-Hoffmann'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Name
    )

    process {
        $text = $Name.Trim().ToLowerInvariant()
        $text = $text.Replace([string][char]0x00E4, 'ae').Replace([string][char]0x00F6, 'oe').Replace([string][char]0x00FC, 'ue').Replace([string][char]0x00DF, 'ss')

        $builder = [System.Text.StringBuilder]::new()
        foreach ($character in $text.Normalize([System.Text.NormalizationForm]::FormD).ToCharArray()) {
            if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                [void] $builder.Append($character)
            }
        }

        $builder.ToString() -replace '[^a-z0-9-]', ''
    }
}

function ConvertTo-LabSamAccountName {
    <#
    .SYNOPSIS
        Derives a unique sAMAccountName (firstname.lastname) following the lab naming convention.
    .DESCRIPTION
        1. Transliterate and clean both name parts.
        2. If longer than MaxLength, shorten the given name to its initial.
        3. On collision with ExistingName, append 2, 3, ... while staying within MaxLength.
    .PARAMETER GivenName
        Given name as stored in HR data (umlauts allowed).
    .PARAMETER Surname
        Surname as stored in HR data (umlauts allowed).
    .PARAMETER ExistingName
        sAMAccountNames that are already taken (compared case-insensitively).
    .PARAMETER MaxLength
        Maximum length. 20 is the sAMAccountName limit for user objects.
    .EXAMPLE
        ConvertTo-LabSamAccountName -GivenName 'Thomas' -Surname 'Becker' -ExistingName 'thomas.becker'
        # thomas.becker2
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $GivenName,

        [Parameter(Mandatory)]
        [string] $Surname,

        [AllowEmptyCollection()]
        [string[]] $ExistingName = @(),

        [ValidateRange(8, 64)]
        [int] $MaxLength = 20
    )

    $given = ConvertTo-LabAsciiName -Name $GivenName
    $family = ConvertTo-LabAsciiName -Name $Surname
    if (-not $given -or -not $family) {
        throw "Cannot derive an account name from '$GivenName $Surname'."
    }

    $base = "$given.$family"
    if ($base.Length -gt $MaxLength) {
        $base = "$($given[0]).$family"
    }
    if ($base.Length -gt $MaxLength) {
        $base = $base.Substring(0, $MaxLength)
    }

    $candidate = $base
    $counter = 2
    while ($ExistingName -contains $candidate) {
        $suffix = [string] $counter
        $candidate = $base.Substring(0, [Math]::Min($base.Length, $MaxLength - $suffix.Length)) + $suffix
        $counter++
    }
    $candidate
}

function ConvertTo-LabAdminAccountName {
    <#
    .SYNOPSIS
        Derives the tiered admin account name t<tier>a-<initial><surname>.
    .PARAMETER Tier
        Administrative tier (0, 1 or 2).
    .PARAMETER GivenName
        Given name of the administrator.
    .PARAMETER Surname
        Surname of the administrator.
    .EXAMPLE
        ConvertTo-LabAdminAccountName -Tier 0 -GivenName 'Daniel' -Surname 'Krause'
        # t0a-dkrause
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 2)]
        [int] $Tier,

        [Parameter(Mandatory)]
        [string] $GivenName,

        [Parameter(Mandatory)]
        [string] $Surname
    )

    $given = ConvertTo-LabAsciiName -Name $GivenName
    $family = (ConvertTo-LabAsciiName -Name $Surname) -replace '-', ''
    $name = "t${Tier}a-$($given[0])$family"
    if ($name.Length -gt 20) {
        $name = $name.Substring(0, 20)
    }
    $name
}

function Get-LabRandomSecret {
    <#
    .SYNOPSIS
        Generates a random initial secret for a new account.
    .DESCRIPTION
        Uses a cryptographic random number generator. The result contains at least one upper-case
        letter, lower-case letter, digit and symbol and avoids look-alike characters (0/O, 1/l/I).
        Returns the value both as SecureString (for AD cmdlets) and as text (for the one-time
        credential report handed to the employee).
    .PARAMETER Length
        Number of characters.
    .EXAMPLE
        $secret = Get-LabRandomSecret -Length 20
        New-ADUser ... -AccountPassword $secret.SecureString
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(12, 128)]
        [int] $Length = 16
    )

    $classes = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
        '!#%+-=?@_'
    )
    $all = -join $classes

    $characters = [System.Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }
    while ($characters.Count -lt $Length) {
        $characters.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }

    # Fisher-Yates shuffle so the guaranteed characters are not always at the start.
    for ($index = $characters.Count - 1; $index -gt 0; $index--) {
        $swap = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($index + 1)
        $temporary = $characters[$index]
        $characters[$index] = $characters[$swap]
        $characters[$swap] = $temporary
    }

    $secure = [securestring]::new()
    foreach ($character in $characters) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()

    [pscustomobject]@{
        Text         = -join $characters
        SecureString = $secure
    }
}

function ConvertTo-LabDistinguishedName {
    <#
    .SYNOPSIS
        Converts a lab OU path such as 'Users/Finance' into a distinguished name.
    .PARAMETER Path
        Slash-separated OU path below the root OU. Empty means the root OU itself.
    .PARAMETER RootOu
        Name of the company root OU.
    .PARAMETER DomainDistinguishedName
        Distinguished name of the domain, e.g. DC=ad,DC=nrwcorp,DC=internal.
    .EXAMPLE
        ConvertTo-LabDistinguishedName -Path 'Users/Finance' -RootOu 'NRW' -DomainDistinguishedName 'DC=ad,DC=nrwcorp,DC=internal'
        # OU=Finance,OU=Users,OU=NRW,DC=ad,DC=nrwcorp,DC=internal
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Path = '',

        [Parameter(Mandatory)]
        [string] $RootOu,

        [Parameter(Mandatory)]
        [string] $DomainDistinguishedName
    )

    $segments = @($Path -split '/' | Where-Object { $_ })
    [array]::Reverse($segments)
    $parts = @($segments | ForEach-Object { "OU=$_" }) + "OU=$RootOu" + $DomainDistinguishedName
    $parts -join ','
}

function ConvertTo-LabDomainDistinguishedName {
    <#
    .SYNOPSIS
        Converts a DNS domain name into its distinguished name.
    .PARAMETER DomainName
        DNS name, e.g. ad.nrwcorp.internal.
    .EXAMPLE
        ConvertTo-LabDomainDistinguishedName -DomainName 'ad.nrwcorp.internal'
        # DC=ad,DC=nrwcorp,DC=internal
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DomainName
    )

    ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
}

function Get-LabDataFile {
    <#
    .SYNOPSIS
        Loads a desired-state file from the data/ directory.
    .DESCRIPTION
        *.psd1 files are read with Import-PowerShellDataFile, *.csv files with Import-Csv (UTF-8).
    .PARAMETER Name
        File name inside the data directory, e.g. ou-structure.psd1 or users.csv.
    .PARAMETER DataPath
        Data directory. Defaults to the repository's data/ folder.
    .EXAMPLE
        $ous = Get-LabDataFile -Name 'ou-structure.psd1'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [string] $DataPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../data')
    )

    $file = Join-Path -Path $DataPath -ChildPath $Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Data file not found: $file"
    }

    switch ([System.IO.Path]::GetExtension($file)) {
        '.psd1' { Import-PowerShellDataFile -LiteralPath $file }
        '.csv' { Import-Csv -LiteralPath $file -Encoding utf8 }
        default { throw "Unsupported data file type: $file" }
    }
}

function Test-LabUserData {
    <#
    .SYNOPSIS
        Validates the rows of data/users.csv and returns a list of problems (empty = valid).
    .PARAMETER User
        Rows from users.csv.
    .PARAMETER Department
        Allowed department names (from data/groups.psd1).
    .EXAMPLE
        $problems = Test-LabUserData -User (Get-LabDataFile users.csv) -Department $groups.Departments
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $User,

        [Parameter(Mandatory)]
        [string[]] $Department
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $requiredColumns = 'EmployeeId', 'GivenName', 'Surname', 'Department', 'Title', 'IsLead', 'AdminTiers'

    if ($User.Count -eq 0) {
        $problems.Add('users.csv contains no rows.')
        return $problems.ToArray()
    }

    $columns = $User[0].PSObject.Properties.Name
    foreach ($column in $requiredColumns | Where-Object { $_ -notin $columns }) {
        $problems.Add("Missing column '$column'.")
    }
    if ($problems.Count -gt 0) {
        return $problems.ToArray()
    }

    $duplicates = $User | Group-Object -Property EmployeeId | Where-Object { $_.Count -gt 1 }
    foreach ($duplicate in $duplicates) {
        $problems.Add("EmployeeId '$($duplicate.Name)' is used $($duplicate.Count) times.")
    }

    foreach ($row in $User) {
        if ($row.EmployeeId -notmatch '^E\d{4}$') {
            $problems.Add("EmployeeId '$($row.EmployeeId)' does not match E + 4 digits.")
        }
        if ($row.Department -notin $Department) {
            $problems.Add("$($row.EmployeeId): unknown department '$($row.Department)'.")
        }
        if ($row.IsLead -notin 'true', 'false') {
            $problems.Add("$($row.EmployeeId): IsLead must be true or false.")
        }
        if ($row.AdminTiers -and $row.AdminTiers -notmatch '^[012](;[012])*$') {
            $problems.Add("$($row.EmployeeId): AdminTiers must look like '0;1;2'.")
        }
        foreach ($column in 'GivenName', 'Surname', 'Title') {
            if ([string]::IsNullOrWhiteSpace($row.$column)) {
                $problems.Add("$($row.EmployeeId): $column is empty.")
            }
        }
    }

    foreach ($group in $User | Group-Object -Property Department) {
        $leads = @($group.Group | Where-Object { $_.IsLead -eq 'true' }).Count
        if ($leads -ne 1) {
            $problems.Add("Department '$($group.Name)' has $leads leads (expected 1).")
        }
    }

    $problems.ToArray()
}

function Test-LabPathInGitRepository {
    <#
    .SYNOPSIS
        Returns $true if the path is inside a git working tree.
    .DESCRIPTION
        Used to refuse writing secrets (initial credentials, backups) into the repository.
    .PARAMETER Path
        File or directory path. It does not need to exist.
    .EXAMPLE
        Test-LabPathInGitRepository -Path 'C:\Lab\nrw-corp-lab\secrets.csv'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $directory = [System.IO.Path]::GetFullPath($Path)
    while ($directory) {
        if (Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath '.git')) {
            return $true
        }
        $directory = [System.IO.Path]::GetDirectoryName($directory)
    }
    $false
}

function Protect-LabFile {
    <#
    .SYNOPSIS
        Restricts a file or directory to the current user, SYSTEM and local Administrators.
    .DESCRIPTION
        Disables ACL inheritance and replaces all entries. Used for files that contain secrets.
    .PARAMETER Path
        File or directory to protect.
    .EXAMPLE
        Protect-LabFile -Path "$HOME\nrw-corp-lab-secrets"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $item = Get-Item -LiteralPath $Path
    $isDirectory = $item -is [System.IO.DirectoryInfo]
    $acl = if ($isDirectory) { [System.Security.AccessControl.DirectorySecurity]::new() } else { [System.Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)

    $inheritance = if ($isDirectory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    $principals = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )
    foreach ($principal in $principals) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', $inheritance, 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Restrict ACL to current user, SYSTEM and Administrators')) {
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

function Get-LabAclSignature {
    <#
    .SYNOPSIS
        Returns a sorted, comparable representation of the explicit access rules of an ACL.
    .DESCRIPTION
        One string per explicit rule: SID|rights|inheritance|propagation|type. The Synchronize
        right is ignored because Windows adds it implicitly to allow rules. Used to decide whether
        an ACL must be rewritten and to verify ACLs in the Pester tests.
    .PARAMETER Acl
        File or directory security descriptor, e.g. from Get-Acl.
    .EXAMPLE
        Get-LabAclSignature -Acl (Get-Acl -Path 'S:\Shares\Finance')
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Security.AccessControl.FileSystemSecurity] $Acl
    )

    $synchronize = [int] [System.Security.AccessControl.FileSystemRights]::Synchronize
    $rules = $Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
    $signature = foreach ($rule in $rules) {
        $rights = [int] $rule.FileSystemRights -band (-bnot $synchronize)
        '{0}|{1}|{2}|{3}|{4}' -f $rule.IdentityReference.Value, $rights, [int] $rule.InheritanceFlags, [int] $rule.PropagationFlags, $rule.AccessControlType
    }
    [string[]] $sorted = $signature | Sort-Object
    $sorted
}

function Set-LabAdGroup {
    <#
    .SYNOPSIS
        Ensures that a security group exists in the given OU with the given scope and description.
    .PARAMETER Name
        Group name (also used as sAMAccountName).
    .PARAMETER Path
        Distinguished name of the target OU.
    .PARAMETER GroupScope
        Global, DomainLocal or Universal.
    .PARAMETER Description
        Purpose of the group.
    .EXAMPLE
        Set-LabAdGroup -Name 'GG-Finance' -Path $ou -GroupScope Global -Description 'Finance staff'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet('Global', 'DomainLocal', 'Universal')]
        [string] $GroupScope,

        [string] $Description = ''
    )

    $group = Get-ADGroup -Filter "SamAccountName -eq '$Name'" -Properties Description
    if (-not $group) {
        if ($PSCmdlet.ShouldProcess($Name, "Create $GroupScope group in $Path")) {
            New-ADGroup -Name $Name -SamAccountName $Name -GroupCategory Security -GroupScope $GroupScope -Path $Path -Description $Description
        }
        return
    }

    if ($group.GroupScope.ToString() -ne $GroupScope) {
        Write-Warning "Group $Name has scope $($group.GroupScope), expected $GroupScope. Change it manually; scope changes can require an intermediate step."
    }
    if ($group.Description -ne $Description -and $PSCmdlet.ShouldProcess($Name, 'Update description')) {
        Set-ADGroup -Identity $group -Description $Description
    }
    $parent = $group.DistinguishedName -replace '^CN=.+?(?<!\\),', ''
    if ($parent -ne $Path -and $PSCmdlet.ShouldProcess($Name, "Move to $Path")) {
        Move-ADObject -Identity $group -TargetPath $Path
    }
}

function Set-LabAdGroupMember {
    <#
    .SYNOPSIS
        Converges the direct members of a group to the desired list of distinguished names.
    .DESCRIPTION
        Adds missing members. With -Authoritative, also removes members that are not desired;
        use this only for groups whose membership is fully managed by the lab data.
    .PARAMETER Identity
        Group name.
    .PARAMETER Member
        Desired member distinguished names.
    .PARAMETER Authoritative
        Remove members that are not in the desired list.
    .EXAMPLE
        Set-LabAdGroupMember -Identity 'GG-Finance' -Member $financeUsers -Authoritative
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Identity,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Member,

        [switch] $Authoritative
    )

    $escaped = $Identity -replace "'", "''"
    $group = Get-ADGroup -Filter "SamAccountName -eq '$escaped'" -Properties member
    if (-not $group) {
        if ($WhatIfPreference) {
            Write-Verbose "Group $Identity does not exist yet (WhatIf). Skipping membership."
            return
        }
        throw "Group not found: $Identity"
    }
    $current = @($group.member)
    $toAdd = @($Member | Where-Object { $_ -notin $current })
    $toRemove = if ($Authoritative) { @($current | Where-Object { $_ -notin $Member }) } else { @() }

    if ($toAdd.Count -gt 0 -and $PSCmdlet.ShouldProcess($Identity, "Add $($toAdd.Count) member(s)")) {
        Add-ADGroupMember -Identity $group -Members $toAdd
    }
    if ($toRemove.Count -gt 0 -and $PSCmdlet.ShouldProcess($Identity, "Remove $($toRemove.Count) member(s)")) {
        Remove-ADGroupMember -Identity $group -Members $toRemove -Confirm:$false
    }
}
