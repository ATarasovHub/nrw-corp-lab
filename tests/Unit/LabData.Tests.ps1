<#
.SYNOPSIS
    Validates the desired-state files in data/ against the design documents. Runs in CI.
.EXAMPLE
    Invoke-Pester -Path ./tests/Unit
#>
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/NrwCorpLab/NrwCorpLab.psd1') -Force
    $script:dataPath = Join-Path -Path $PSScriptRoot -ChildPath '../../data'
    $script:users = @(Get-LabDataFile -Name 'users.csv' -DataPath $script:dataPath)
    $script:groups = Get-LabDataFile -Name 'groups.psd1' -DataPath $script:dataPath
    $script:shares = Get-LabDataFile -Name 'shares.psd1' -DataPath $script:dataPath
    $script:ous = Get-LabDataFile -Name 'ou-structure.psd1' -DataPath $script:dataPath
}

Describe 'users.csv' {
    It 'passes Test-LabUserData' {
        Test-LabUserData -User $script:users -Department $script:groups.Departments | Should -BeNullOrEmpty
    }

    It 'contains 30 employees' {
        $script:users.Count | Should -Be 30
    }

    It 'matches the staffing table in docs/03-ad-design.md' {
        $expected = @{ Management = 2; Finance = 4; HR = 3; Sales = 7; Marketing = 4; Operations = 6; IT = 4 }
        foreach ($department in $expected.Keys) {
            @($script:users | Where-Object { $_.Department -eq $department }).Count | Should -Be $expected[$department] -Because "$department headcount"
        }
    }

    It 'produces unique logon names' {
        $taken = [System.Collections.Generic.List[string]]::new()
        foreach ($user in $script:users | Sort-Object -Property EmployeeId) {
            $taken.Add((ConvertTo-LabSamAccountName -GivenName $user.GivenName -Surname $user.Surname -ExistingName $taken.ToArray()))
        }
        ($taken | Sort-Object -Unique).Count | Should -Be $script:users.Count
        $taken | Should -Contain 'thomas.becker2'
        $taken | Should -Contain 'k.schulze-hoffmann'
    }

    It 'grants admin tiers only to IT staff' {
        $script:users | Where-Object { $_.AdminTiers } | ForEach-Object { $_.Department | Should -Be 'IT' }
    }
}

Describe 'shares.psd1' {
    It 'references only groups that Import-LabUsers.ps1 creates' {
        $known = [System.Collections.Generic.List[string]]::new()
        $script:groups.Departments | ForEach-Object { $known.Add("GG-$_"); $known.Add("GG-$_-Leads") }
        $known.Add($script:groups.AllStaffGroup)
        $script:groups.AdminGroups.Name | ForEach-Object { $known.Add($_) }
        $script:groups.OtherGroups.Name | ForEach-Object { $known.Add($_) }
        foreach ($share in $script:shares.Shares) {
            foreach ($group in @($share.ReadWrite) + @($share.ReadOnly)) {
                $group | Should -BeIn $known -Because "share $($share.Name)"
            }
        }
        $script:shares.FullControlGroup | Should -BeIn $known
    }

    It 'gives every department read-write access to its own share' {
        foreach ($department in $script:groups.Departments) {
            $share = $script:shares.Shares | Where-Object { $_.Name -eq $department }
            $share | Should -Not -BeNullOrEmpty -Because "department $department needs a share"
            $share.ReadWrite | Should -Contain "GG-$department"
        }
    }
}

Describe 'ou-structure.psd1' {
    It 'lists parents before children' {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($ou in $script:ous.OrganizationalUnits) {
            $parent = ($ou.Path -split '/' | Select-Object -SkipLast 1) -join '/'
            if ($parent) {
                $seen.Contains($parent) | Should -BeTrue -Because "$($ou.Path) needs its parent first"
            }
            [void] $seen.Add($ou.Path)
        }
    }

    It 'has an OU for every department and every group path' {
        $paths = $script:ous.OrganizationalUnits.Path
        foreach ($department in $script:groups.Departments) {
            $paths | Should -Contain "Users/$department"
        }
        $paths | Should -Contain $script:groups.RoleGroupPath
        $paths | Should -Contain $script:groups.ResourceGroupPath
        foreach ($adminGroup in $script:groups.AdminGroups) {
            $paths | Should -Contain $adminGroup.Path
        }
    }
}
