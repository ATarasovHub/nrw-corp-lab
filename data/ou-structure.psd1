# OU structure below the company root OU (docs/03-ad-design.md#ou-structure).
# Paths are slash-separated and relative to RootOu; parents must be listed before children.
@{
    RootOu                   = 'NRW'
    RootOuDescription        = 'NRW Corp GmbH - all company objects'

    # Redirect targets for the built-in CN=Users / CN=Computers containers (redirusr / redircmp).
    DefaultUserContainer     = 'Users/Staging'
    DefaultComputerContainer = 'Computers/Staging'

    OrganizationalUnits      = @(
        @{ Path = 'Admin'; Description = 'Administrative accounts and groups - Tier 0 admins only' }
        @{ Path = 'Admin/Tier0'; Description = 'Tier 0: domain controllers, AD, identity' }
        @{ Path = 'Admin/Tier0/Accounts'; Description = 't0a-* admin accounts' }
        @{ Path = 'Admin/Tier0/Groups'; Description = 'Tier 0 admin groups' }
        @{ Path = 'Admin/Tier1'; Description = 'Tier 1: member servers' }
        @{ Path = 'Admin/Tier1/Accounts'; Description = 't1a-* admin accounts' }
        @{ Path = 'Admin/Tier1/Groups'; Description = 'Tier 1 admin groups' }
        @{ Path = 'Admin/Tier2'; Description = 'Tier 2: workstations and helpdesk' }
        @{ Path = 'Admin/Tier2/Accounts'; Description = 't2a-* admin accounts' }
        @{ Path = 'Admin/Tier2/Groups'; Description = 'Tier 2 admin groups' }

        @{ Path = 'Users'; Description = 'Employee accounts' }
        @{ Path = 'Users/Management'; Description = 'Department: Management' }
        @{ Path = 'Users/Finance'; Description = 'Department: Finance' }
        @{ Path = 'Users/HR'; Description = 'Department: Human Resources' }
        @{ Path = 'Users/Sales'; Description = 'Department: Sales' }
        @{ Path = 'Users/Marketing'; Description = 'Department: Marketing' }
        @{ Path = 'Users/Operations'; Description = 'Department: Operations and Logistics' }
        @{ Path = 'Users/IT'; Description = 'Department: IT' }
        @{ Path = 'Users/Staging'; Description = 'Default location for new user objects' }

        @{ Path = 'Groups'; Description = 'Security groups' }
        @{ Path = 'Groups/Role'; Description = 'GG-* global groups: who you are' }
        @{ Path = 'Groups/Resource'; Description = 'DL-* domain local groups: what you can access' }

        @{ Path = 'Computers'; Description = 'Client computers' }
        @{ Path = 'Computers/Workstations'; Description = 'Employee workstations' }
        @{ Path = 'Computers/Admin'; Description = 'Privileged access workstations' }
        @{ Path = 'Computers/Staging'; Description = 'Default location for new computer objects' }

        @{ Path = 'Servers'; Description = 'Member servers' }
        @{ Path = 'Servers/FileServers'; Description = 'File servers' }
        @{ Path = 'Servers/LinuxServers'; Description = 'SSSD-joined Linux hosts' }
        @{ Path = 'Servers/MemberServers'; Description = 'Other member servers' }

        @{ Path = 'ServiceAccounts'; Description = 'Group Managed Service Accounts' }

        @{ Path = 'Disabled'; Description = 'Disabled objects awaiting deletion' }
        @{ Path = 'Disabled/Users'; Description = 'Leavers - kept 90 days before deletion' }
        @{ Path = 'Disabled/Computers'; Description = 'Decommissioned computers' }
    )
}
