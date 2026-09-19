<#
.SYNOPSIS
    Validates AGDLP group nesting and FS01 ACLs against data/shares.psd1.
#>
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }, ActiveDirectory

BeforeAll {
    $script:repoRoot = if ($env:NRW_LAB_ROOT) { $env:NRW_LAB_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
    $script:validation = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/validation.psd1')
    $script:shares = Import-PowerShellDataFile -LiteralPath (Join-Path $script:repoRoot 'data/shares.psd1')
}

Describe 'File share permission matrix' -Tag 'NTFS' {
    It 'nests exactly the documented role groups into each resource group' {
        foreach ($share in $script:shares.Shares) {
            $matrix = @{
                "DL-FS-$($share.Name)-FC" = @($script:shares.FullControlGroup)
                "DL-FS-$($share.Name)-RW" = @($share.ReadWrite)
                "DL-FS-$($share.Name)-RO" = @($share.ReadOnly)
            }
            foreach ($resourceGroup in $matrix.Keys) {
                $actual = @(Get-ADGroupMember -Identity $resourceGroup | Select-Object -ExpandProperty SamAccountName | Sort-Object)
                $expected = @($matrix[$resourceGroup] | Sort-Object)
                $actual | Should -Be $expected -Because "$resourceGroup implements the documented AGDLP matrix"
            }
        }
    }

    It 'has protected ACLs with exactly the resource groups and rights from the matrix' {
        foreach ($share in $script:shares.Shares) {
            $path = Join-Path -Path $script:shares.ShareRoot -ChildPath $share.Name
            $remoteAcl = Invoke-Command -ComputerName $script:validation.FileServer -ScriptBlock {
                $acl = Get-Acl -LiteralPath $using:path
                [pscustomobject]@{
                    Protected = $acl.AreAccessRulesProtected
                    Rules     = @($acl.Access | ForEach-Object {
                            [pscustomobject]@{
                                Sid       = $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                                Rights    = [int] $_.FileSystemRights
                                Type      = [string] $_.AccessControlType
                                Inherited = $_.IsInherited
                            }
                        })
                }
            }

            $fullControlSid = (Get-ADGroup -Identity "DL-FS-$($share.Name)-FC").SID.Value
            $readWriteSid = (Get-ADGroup -Identity "DL-FS-$($share.Name)-RW").SID.Value
            $readOnlySid = (Get-ADGroup -Identity "DL-FS-$($share.Name)-RO").SID.Value
            $expected = @{
                'S-1-5-18'      = [int] [System.Security.AccessControl.FileSystemRights]::FullControl
                'S-1-5-32-544'  = [int] [System.Security.AccessControl.FileSystemRights]::FullControl
                $fullControlSid = [int] [System.Security.AccessControl.FileSystemRights]::FullControl
                $readWriteSid   = [int] [System.Security.AccessControl.FileSystemRights]::Modify
                $readOnlySid    = [int] [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
            }

            $remoteAcl.Protected | Should -BeTrue -Because "$path must not inherit unexpected permissions"
            @($remoteAcl.Rules).Count | Should -Be $expected.Count -Because "$path must contain no extra ACEs"
            foreach ($sid in $expected.Keys) {
                $rule = @($remoteAcl.Rules | Where-Object { $_.Sid -eq $sid })
                $rule.Count | Should -Be 1 -Because "$path needs exactly one ACE for $sid"
                $rule[0].Type | Should -Be 'Allow'
                $rule[0].Inherited | Should -BeFalse
                $rule[0].Rights | Should -Be $expected[$sid] -Because "$sid needs exactly the documented rights on $path"
            }
        }
    }
}
