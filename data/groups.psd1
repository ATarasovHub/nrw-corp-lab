# Group model (docs/03-ad-design.md#groups and #permission-model-agdlp).
# Department role groups (GG-<Department>, GG-<Department>-Leads) are generated from Departments.
# Resource groups (DL-FS-*) are generated from data/shares.psd1.
@{
    Departments       = @('Management', 'Finance', 'HR', 'Sales', 'Marketing', 'Operations', 'IT')

    RoleGroupPath     = 'Groups/Role'
    ResourceGroupPath = 'Groups/Resource'

    AllStaffGroup     = 'GG-AllStaff'

    # Tiered admin groups. MemberOfRid: well-known RIDs in the domain (512 = Domain Admins,
    # 525 = Protected Users); RIDs keep the data independent of the OS language.
    AdminGroups       = @(
        @{
            Name        = 'GG-T0-DomainAdmins'
            Tier        = 0
            Path        = 'Admin/Tier0/Groups'
            Description = 'Tier 0 administrators (DCs, AD, Group Policy)'
            MemberOfRid = @(512, 525)
        }
        @{
            Name        = 'GG-T1-ServerAdmins'
            Tier        = 1
            Path        = 'Admin/Tier1/Groups'
            Description = 'Tier 1 administrators (member servers)'
            MemberOfRid = @()
        }
        @{
            Name        = 'GG-T2-Helpdesk'
            Tier        = 2
            Path        = 'Admin/Tier2/Groups'
            Description = 'Tier 2 administrators (workstations, helpdesk)'
            MemberOfRid = @()
        }
    )

    # Additional groups without automatic membership.
    OtherGroups       = @(
        @{
            Name        = 'GG-LegacyServiceAccounts'
            Scope       = 'Global'
            Path        = 'Groups/Role'
            Description = 'Service accounts that cannot use a gMSA (target of PSO-ServiceAccounts)'
        }
    )
}
