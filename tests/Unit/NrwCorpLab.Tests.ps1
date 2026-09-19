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
