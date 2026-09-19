# File shares and access matrix (docs/03-ad-design.md#share-access-matrix).
# For every share, Import-LabUsers.ps1 creates DL-FS-<Name>-RW/-RO/-FC and nests the listed
# GG-* groups; New-FileShares.ps1 grants NTFS permissions to exactly these DL-FS-* groups.
@{
    FileServer       = 'FS01'
    DataDriveLetter  = 'S'
    DataVolumeLabel  = 'Shares'
    ShareRoot        = 'S:\Shares'

    # Members of every DL-FS-<Name>-FC group.
    FullControlGroup = 'GG-T1-ServerAdmins'

    Shares           = @(
        @{ Name = 'Management'; ReadWrite = @('GG-Management'); ReadOnly = @(); QuotaGB = 10; Description = 'Management board' }
        @{ Name = 'Finance'; ReadWrite = @('GG-Finance'); ReadOnly = @('GG-Management'); QuotaGB = 20; Description = 'Finance and accounting' }
        @{ Name = 'HR'; ReadWrite = @('GG-HR'); ReadOnly = @('GG-Management'); QuotaGB = 10; Description = 'Human resources' }
        @{ Name = 'Sales'; ReadWrite = @('GG-Sales'); ReadOnly = @('GG-Management', 'GG-Marketing'); QuotaGB = 30; Description = 'Sales' }
        @{ Name = 'Marketing'; ReadWrite = @('GG-Marketing'); ReadOnly = @('GG-Management', 'GG-Sales'); QuotaGB = 50; Description = 'Marketing and design' }
        @{ Name = 'Operations'; ReadWrite = @('GG-Operations'); ReadOnly = @('GG-Management', 'GG-Sales'); QuotaGB = 20; Description = 'Operations, logistics and purchasing' }
        @{ Name = 'IT'; ReadWrite = @('GG-IT'); ReadOnly = @(); QuotaGB = 20; Description = 'IT department' }
        @{ Name = 'Public'; ReadWrite = @('GG-AllStaff'); ReadOnly = @(); QuotaGB = 20; Description = 'Company-wide exchange' }
    )

    Home             = @{
        Root         = 'S:\Home'
        ShareName    = 'Home$'
        Drive        = 'H:'
        QuotaGB      = 5
        UserGroup    = 'GG-AllStaff'
        TemplateName = 'NRW Home 5 GB'
    }
}
