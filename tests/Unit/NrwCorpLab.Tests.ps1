<#
.SYNOPSIS
    Unit tests for the pure functions of the NrwCorpLab module. Run in CI without a lab.
.EXAMPLE
    Invoke-Pester -Path ./tests/Unit
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/NrwCorpLab/NrwCorpLab.psd1') -Force

    # Non-ASCII test names are built from code points so that the file stays ASCII.
    $script:ae = [string][char]0x00E4
    $script:oe = [string][char]0x00F6
    $script:ue = [string][char]0x00FC
    $script:sz = [string][char]0x00DF
    $script:eAcute = [string][char]0x00E9
}

Describe 'ConvertTo-LabAsciiName' {
    It 'transliterates German umlauts and sharp s' {
        "M$($script:ue)ller" | ConvertTo-LabAsciiName | Should -Be 'mueller'
        "K$($script:oe)nig" | ConvertTo-LabAsciiName | Should -Be 'koenig'
        "J$($script:ae)ger" | ConvertTo-LabAsciiName | Should -Be 'jaeger'
        "Wei$($script:sz)" | ConvertTo-LabAsciiName | Should -Be 'weiss'
    }

    It 'removes other diacritics' {
        "Ren$($script:eAcute)" | ConvertTo-LabAsciiName | Should -Be 'rene'
    }

    It 'removes spaces and apostrophes but keeps hyphens' {
        "D'Angelo" | ConvertTo-LabAsciiName | Should -Be 'dangelo'
        'van der Berg' | ConvertTo-LabAsciiName | Should -Be 'vanderberg'
        'Anna-Lena' | ConvertTo-LabAsciiName | Should -Be 'anna-lena'
    }
}

Describe 'ConvertTo-LabSamAccountName' {
    It 'builds firstname.lastname' {
        ConvertTo-LabSamAccountName -GivenName "J$($script:ue)rgen" -Surname "M$($script:ue)ller" | Should -Be 'juergen.mueller'
    }

    It 'shortens the given name to its initial when longer than 20 characters' {
        ConvertTo-LabSamAccountName -GivenName 'Katharina' -Surname 'Schulze-Hoffmann' | Should -Be 'k.schulze-hoffmann'
    }

    It 'never exceeds 20 characters' {
        $name = ConvertTo-LabSamAccountName -GivenName 'Maximilian' -Surname 'Mustermann-Oberhausen'
        $name.Length | Should -BeLessOrEqual 20
    }

    It 'appends a counter on collision' {
        ConvertTo-LabSamAccountName -GivenName 'Thomas' -Surname 'Becker' -ExistingName 'thomas.becker' | Should -Be 'thomas.becker2'
        ConvertTo-LabSamAccountName -GivenName 'Thomas' -Surname 'Becker' -ExistingName 'thomas.becker', 'thomas.becker2' | Should -Be 'thomas.becker3'
    }

    It 'compares existing names case-insensitively' {
        ConvertTo-LabSamAccountName -GivenName 'Thomas' -Surname 'Becker' -ExistingName 'Thomas.Becker' | Should -Be 'thomas.becker2'
    }

    It 'keeps the counter within the length limit' {
        $existing = 'k.schulze-hoffmann'
        $name = ConvertTo-LabSamAccountName -GivenName 'Katharina' -Surname 'Schulze-Hoffmann' -ExistingName $existing
        $name | Should -Not -Be $existing
        $name.Length | Should -BeLessOrEqual 20
    }
}

Describe 'ConvertTo-LabAdminAccountName' {
    It 'builds t<tier>a-<initial><surname>' {
        ConvertTo-LabAdminAccountName -Tier 0 -GivenName 'Daniel' -Surname 'Krause' | Should -Be 't0a-dkrause'
        ConvertTo-LabAdminAccountName -Tier 2 -GivenName 'Oliver' -Surname "K$($script:oe)nig" | Should -Be 't2a-okoenig'
    }
}

Describe 'Get-LabRandomSecret' {
    It 'returns the requested length' {
        (Get-LabRandomSecret -Length 24).Text.Length | Should -Be 24
    }

    It 'contains upper, lower, digit and symbol' {
        foreach ($attempt in 1..20) {
            $text = (Get-LabRandomSecret -Length 12).Text
            $text | Should -MatchExactly '[A-Z]'
            $text | Should -MatchExactly '[a-z]'
            $text | Should -Match '[0-9]'
            $text | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'avoids look-alike characters' {
        $text = -join (1..50 | ForEach-Object { (Get-LabRandomSecret -Length 32).Text })
        $text | Should -Not -MatchExactly '[0O1lI]'
    }

    It 'returns a matching read-only SecureString' {
        $secret = Get-LabRandomSecret
        $secret.SecureString.IsReadOnly() | Should -BeTrue
        [System.Net.NetworkCredential]::new('', $secret.SecureString).Password | Should -BeExactly $secret.Text
    }

    It 'does not repeat' {
        (Get-LabRandomSecret).Text | Should -Not -Be (Get-LabRandomSecret).Text
    }
}

Describe 'ConvertTo-LabDistinguishedName' {
    BeforeAll {
        $script:domainDn = 'DC=ad,DC=nrwcorp,DC=internal'
    }

    It 'converts a nested path' {
        ConvertTo-LabDistinguishedName -Path 'Users/Finance' -RootOu 'NRW' -DomainDistinguishedName $script:domainDn |
            Should -Be 'OU=Finance,OU=Users,OU=NRW,DC=ad,DC=nrwcorp,DC=internal'
    }

    It 'returns the root OU for an empty path' {
        ConvertTo-LabDistinguishedName -Path '' -RootOu 'NRW' -DomainDistinguishedName $script:domainDn |
            Should -Be 'OU=NRW,DC=ad,DC=nrwcorp,DC=internal'
    }

    It 'converts a DNS domain name' {
        ConvertTo-LabDomainDistinguishedName -DomainName 'ad.nrwcorp.internal' | Should -Be $script:domainDn
    }
}

Describe 'Test-LabPathInGitRepository' {
    It 'detects the repository' {
        Test-LabPathInGitRepository -Path (Join-Path -Path $PSScriptRoot -ChildPath 'secrets.csv') | Should -BeTrue
    }

    It 'returns false outside a repository' {
        Test-LabPathInGitRepository -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'nrw-lab-test/secrets.csv') | Should -BeFalse
    }
}

Describe 'Get-LabAclSignature' {
    It 'ignores Synchronize and rule order' {
        $sid = [System.Security.Principal.SecurityIdentifier] 'S-1-5-32-545'
        $admins = [System.Security.Principal.SecurityIdentifier] 'S-1-5-32-544'
        $first = [System.Security.AccessControl.DirectorySecurity]::new()
        $first.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        $first.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        $second = [System.Security.AccessControl.DirectorySecurity]::new()
        $second.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
        $second.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'Modify, Synchronize', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))

        (Get-LabAclSignature -Acl $first) -join ';' | Should -Be ((Get-LabAclSignature -Acl $second) -join ';')
    }

    It 'detects different rights' {
        $sid = [System.Security.Principal.SecurityIdentifier] 'S-1-5-32-545'
        $modify = [System.Security.AccessControl.DirectorySecurity]::new()
        $modify.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'Modify', 'None', 'None', 'Allow'))
        $read = [System.Security.AccessControl.DirectorySecurity]::new()
        $read.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'ReadAndExecute', 'None', 'None', 'Allow'))

        (Get-LabAclSignature -Acl $modify) -join ';' | Should -Not -Be ((Get-LabAclSignature -Acl $read) -join ';')
    }
}

Describe 'Merge-LabGpoExtensionName' {
    BeforeAll {
        $script:security = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
        $script:registry = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
    }

    It 'adds an extension to an empty value' {
        Merge-LabGpoExtensionName -Current '' -Extension $script:security | Should -Be $script:security
    }

    It 'sorts extensions by CSE GUID' {
        Merge-LabGpoExtensionName -Current $script:security -Extension $script:registry | Should -Be ($script:registry + $script:security)
    }

    It 'is idempotent' {
        $once = Merge-LabGpoExtensionName -Current $script:registry -Extension $script:security
        Merge-LabGpoExtensionName -Current $once -Extension $script:security | Should -Be $once
    }

    It 'merges and sorts tool GUIDs of the same CSE' {
        $result = Merge-LabGpoExtensionName -Current '[{00000000-0000-0000-0000-000000000000}{BBBBBBBB-0000-0000-0000-000000000000}]' -Extension '[{00000000-0000-0000-0000-000000000000}{AAAAAAAA-0000-0000-0000-000000000000}]'
        $result | Should -Be '[{00000000-0000-0000-0000-000000000000}{AAAAAAAA-0000-0000-0000-000000000000}{BBBBBBBB-0000-0000-0000-000000000000}]'
    }
}

Describe 'ConvertTo-LabSecurityTemplate' {
    It 'renders header, sorted sections and keys' {
        $inf = ConvertTo-LabSecurityTemplate -Section @{
            'System Access'    = @{ PasswordHistorySize = 24; MinimumPasswordLength = 14 }
            'Group Membership' = @{ '*S-1-5-32-544__Memberof' = '' }
        }
        $lines = $inf -split "`r`n"
        $lines[0] | Should -Be '[Unicode]'
        $lines | Should -Contain 'signature="$CHICAGO$"'
        $lines.IndexOf('[Group Membership]') | Should -BeLessThan $lines.IndexOf('[System Access]')
        $lines.IndexOf('MinimumPasswordLength = 14') | Should -BeLessThan $lines.IndexOf('PasswordHistorySize = 24')
        $lines | Should -Contain '*S-1-5-32-544__Memberof ='
    }

    It 'is deterministic' {
        $section = @{ 'System Access' = @{ LockoutBadCount = 10; LockoutDuration = 15 } }
        ConvertTo-LabSecurityTemplate -Section $section | Should -BeExactly (ConvertTo-LabSecurityTemplate -Section $section)
    }
}

Describe 'ConvertTo-LabDrivesXml' {
    BeforeAll {
        $script:drives = @(
            [pscustomobject]@{ Letter = 'P'; Path = '\FS01\Public'; Label = 'Public'; GroupName = 'NRWCORP\GG-AllStaff'; GroupSid = 'S-1-5-21-1-2-3-1101' }
            [pscustomobject]@{ Letter = 'G'; Path = '\FS01\R&D'; Label = 'R&D'; GroupName = 'NRWCORP\GG-RnD'; GroupSid = 'S-1-5-21-1-2-3-1102' }
        )
    }

    It 'produces valid XML with one Drive per entry' {
        [xml] $xml = ConvertTo-LabDrivesXml -DriveMap $script:drives
        $xml.Drives.Drive.Count | Should -Be 2
    }

    It 'escapes XML special characters' {
        [xml] $xml = ConvertTo-LabDrivesXml -DriveMap $script:drives
        ($xml.Drives.Drive | Where-Object { $_.name -eq 'G:' }).Properties.path | Should -Be '\FS01\R&D'
    }

    It 'targets the drive to the group SID' {
        [xml] $xml = ConvertTo-LabDrivesXml -DriveMap $script:drives
        ($xml.Drives.Drive | Where-Object { $_.name -eq 'P:' }).Filters.FilterGroup.sid | Should -Be 'S-1-5-21-1-2-3-1101'
    }

    It 'is deterministic (stable uid)' {
        ConvertTo-LabDrivesXml -DriveMap $script:drives | Should -BeExactly (ConvertTo-LabDrivesXml -DriveMap $script:drives)
    }
}

Describe 'Resolve-LabGpoLinkTarget' {
    It 'resolves <Link>' -ForEach @(
        @{ Link = '@Domain'; Expected = 'DC=ad,DC=nrwcorp,DC=internal' }
        @{ Link = '@DomainControllers'; Expected = 'OU=Domain Controllers,DC=ad,DC=nrwcorp,DC=internal' }
        @{ Link = '@Root'; Expected = 'OU=NRW,DC=ad,DC=nrwcorp,DC=internal' }
        @{ Link = 'Computers/Workstations'; Expected = 'OU=Workstations,OU=Computers,OU=NRW,DC=ad,DC=nrwcorp,DC=internal' }
    ) {
        Resolve-LabGpoLinkTarget -Link $Link -RootOu 'NRW' -DomainDistinguishedName 'DC=ad,DC=nrwcorp,DC=internal' | Should -Be $Expected
    }
}
