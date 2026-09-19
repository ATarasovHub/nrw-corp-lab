<#
.SYNOPSIS
    Generates an RSoP report and verifies that the designed GPOs apply to a real user/computer.
#>
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }, ActiveDirectory, GroupPolicy

BeforeAll {
    $script:repoRoot = if ($env:NRW_LAB_ROOT) { $env:NRW_LAB_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
    Import-Module -Name (Join-Path $script:repoRoot 'scripts/NrwCorpLab/NrwCorpLab.psd1') -Force
    $script:validation = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/validation.psd1')
    $users = @(Import-Csv -LiteralPath (Join-Path $script:repoRoot 'data/users.csv'))
    $testUser = $users | Where-Object { $_.EmployeeId -eq $script:validation.GpoUserEmployeeId }
    if (-not $testUser) {
        throw "Employee $($script:validation.GpoUserEmployeeId) does not exist in data/users.csv."
    }
    $samAccountName = ConvertTo-LabSamAccountName -GivenName $testUser.GivenName -Surname $testUser.Surname
    $netbios = (Get-ADDomain -Identity $script:validation.DomainName).NetBIOSName
    $script:gpoUser = "$netbios\$samAccountName"
    $script:reportPath = Join-Path ([System.IO.Path]::GetTempPath()) "nrw-lab-rsop-$([guid]::NewGuid()).xml"
}

AfterAll {
    Remove-Item -LiteralPath $script:reportPath -Force -ErrorAction SilentlyContinue
}

Describe 'Group Policy application' -Tag 'GPO' {
    It 'applies the expected computer and user policies in RSoP' {
        Get-GPResultantSetOfPolicy -Computer $script:validation.GpoComputer -User $script:gpoUser -ReportType Xml -Path $script:reportPath
        Test-Path -LiteralPath $script:reportPath | Should -BeTrue

        [xml] $report = [System.IO.File]::ReadAllText($script:reportPath)
        $appliedNames = @($report.SelectNodes("//*[local-name()='GPO']/*[local-name()='Name']") |
                Where-Object { -not $_.SelectSingleNode("ancestor::*[local-name()='DeniedGPOs']") } |
                ForEach-Object { $_.InnerText })
        foreach ($expected in $script:validation.ExpectedGpos) {
            $appliedNames | Should -Contain $expected -Because "$expected must apply to $($script:validation.GpoComputer) / $($script:gpoUser)"
        }
    }
}
