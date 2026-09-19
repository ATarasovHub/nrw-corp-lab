@{
    RootModule           = 'NrwCorpLab.psm1'
    ModuleVersion        = '0.7.0'
    GUID                 = '4f3a2c1e-7b8d-4e6f-9a0b-1c2d3e4f5a6b'
    Author               = 'taras'
    CompanyName          = 'nrw-corp-lab'
    Copyright            = '(c) 2026 taras. MIT License.'
    Description          = 'Shared helpers for the nrw-corp-lab AD DS automation.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'ConvertTo-LabAsciiName'
        'ConvertTo-LabSamAccountName'
        'ConvertTo-LabAdminAccountName'
        'Get-LabRandomSecret'
        'ConvertTo-LabDistinguishedName'
        'ConvertTo-LabDomainDistinguishedName'
        'Get-LabDataFile'
        'Test-LabUserData'
        'Test-LabPathInGitRepository'
        'Protect-LabFile'
        'Get-LabAclSignature'
        'Set-LabAdGroup'
        'Set-LabAdGroupMember'
        'Merge-LabGpoExtensionName'
        'ConvertTo-LabSecurityTemplate'
        'ConvertTo-LabDrivesXml'
        'Resolve-LabGpoLinkTarget'
        'Set-LabGpoLink'
        'Set-LabGpoSysvolFile'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'Lab')
            ProjectUri = 'https://github.com/ATarasovHub/nrw-corp-lab'
            LicenseUri = 'https://github.com/ATarasovHub/nrw-corp-lab/blob/main/LICENSE'
        }
    }
}
