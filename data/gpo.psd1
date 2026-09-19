# Group Policy objects (docs/04-gpo.md). Built by scripts/GroupPolicy/New-LabGpo.ps1,
# exported to gpo/ by Export-LabGpo.ps1 and restored by Import-LabGpo.ps1.
#
# Links: '@Domain' = domain root, '@DomainControllers' = Domain Controllers OU,
#        '@Root' = company root OU, otherwise an OU path below the root OU.
# Security templates: '{Group}' is replaced with *<SID of the domain group>,
#        '{RID:512}' with *<domain SID>-512. Well-known SIDs are written literally.
@{
    Gpos = @(
        @{
            Name             = 'C-Domain-PasswordPolicy'
            Comment          = 'Domain password and account lockout policy. See docs/04-gpo.md.'
            Links            = @('@Domain')
            LinkOrder        = 1
            SecurityTemplate = @{
                'System Access' = @{
                    MinimumPasswordLength = 14
                    PasswordHistorySize   = 24
                    MaximumPasswordAge    = -1
                    MinimumPasswordAge    = 1
                    PasswordComplexity    = 1
                    ClearTextPassword     = 0
                    LockoutBadCount       = 10
                    ResetLockoutCount     = 15
                    LockoutDuration       = 15
                }
            }
        }

        @{
            Name           = 'C-All-SecurityBaseline'
            Comment        = 'Security baseline for all computers, including Windows LAPS. See docs/04-gpo.md.'
            Links          = @('@Root', '@DomainControllers')
            RegistryValues = @(
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows NT\DNSClient'; ValueName = 'EnableMulticast'; Type = 'DWord'; Value = 0 }
                @{ Key = 'HKLM\System\CurrentControlSet\Control\Lsa'; ValueName = 'LmCompatibilityLevel'; Type = 'DWord'; Value = 5 }
                @{ Key = 'HKLM\System\CurrentControlSet\Control\Lsa'; ValueName = 'RunAsPPL'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\System\CurrentControlSet\Control\SecurityProviders\WDigest'; ValueName = 'UseLogonCredential'; Type = 'DWord'; Value = 0 }
                @{ Key = 'HKLM\System\CurrentControlSet\Services\LanmanWorkstation\Parameters'; ValueName = 'RequireSecuritySignature'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\System\CurrentControlSet\Services\LanmanServer\Parameters'; ValueName = 'RequireSecuritySignature'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'; ValueName = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\WindowsFirewall\DomainProfile'; ValueName = 'EnableFirewall'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\WindowsFirewall\PrivateProfile'; ValueName = 'EnableFirewall'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\WindowsFirewall\PublicProfile'; ValueName = 'EnableFirewall'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'; ValueName = 'BackupDirectory'; Type = 'DWord'; Value = 2 }
                @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'; ValueName = 'ADPasswordEncryptionEnabled'; Type = 'DWord'; Value = 1 }
                @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'; ValueName = 'PasswordComplexity'; Type = 'DWord'; Value = 4 }
                @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'; ValueName = 'PasswordLength'; Type = 'DWord'; Value = 20 }
                @{ Key = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'; ValueName = 'PasswordAgeDays'; Type = 'DWord'; Value = 30 }
            )
        }

        @{
            Name           = 'C-WS-WindowsUpdate'
            Comment        = 'Workstations install updates automatically at 03:00. See docs/04-gpo.md.'
            Links          = @('Computers')
            RegistryValues = @(
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'NoAutoUpdate'; Type = 'DWord'; Value = 0 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'AUOptions'; Type = 'DWord'; Value = 4 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'ScheduledInstallDay'; Type = 'DWord'; Value = 0 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'ScheduledInstallTime'; Type = 'DWord'; Value = 3 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'NoAutoRebootWithLoggedOnUsers'; Type = 'DWord'; Value = 1 }
            )
        }

        @{
            Name           = 'C-SRV-WindowsUpdate'
            Comment        = 'Servers download updates and notify; installation in a maintenance window. See docs/04-gpo.md.'
            Links          = @('Servers', '@DomainControllers')
            RegistryValues = @(
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'NoAutoUpdate'; Type = 'DWord'; Value = 0 }
                @{ Key = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; ValueName = 'AUOptions'; Type = 'DWord'; Value = 3 }
            )
        }

        @{
            Name             = 'C-WS-LocalAdmins'
            Comment          = 'Local Administrators on workstations and tier separation. See docs/04-gpo.md.'
            Links            = @('Computers/Workstations')
            SecurityTemplate = @{
                'Group Membership' = @{
                    '*S-1-5-32-544__Memberof' = ''
                    '*S-1-5-32-544__Members'  = '{GG-T2-Helpdesk},{RID:512}'
                }
                'Privilege Rights' = @{
                    SeDenyInteractiveLogonRight       = '{GG-T0-DomainAdmins},{GG-T1-ServerAdmins}'
                    SeDenyRemoteInteractiveLogonRight = '{GG-T0-DomainAdmins},{GG-T1-ServerAdmins}'
                }
            }
        }

        @{
            Name             = 'C-SRV-LocalAdmins'
            Comment          = 'Local Administrators on member servers and tier separation. See docs/04-gpo.md.'
            Links            = @('Servers')
            SecurityTemplate = @{
                'Group Membership' = @{
                    '*S-1-5-32-544__Memberof' = ''
                    '*S-1-5-32-544__Members'  = '{GG-T1-ServerAdmins},{RID:512}'
                }
                'Privilege Rights' = @{
                    SeDenyInteractiveLogonRight       = '{GG-T0-DomainAdmins},{GG-T2-Helpdesk}'
                    SeDenyRemoteInteractiveLogonRight = '{GG-T0-DomainAdmins},{GG-T2-Helpdesk}'
                }
            }
        }

        @{
            Name      = 'U-All-DriveMappings'
            Comment   = 'Drive mappings with item-level targeting by department group. See docs/04-gpo.md.'
            Links     = @('Users')
            DriveMaps = @(
                @{ Letter = 'P'; Path = '\\FS01\Public'; Label = 'Public'; Group = 'GG-AllStaff' }
                @{ Letter = 'G'; Path = '\\FS01\Management'; Label = 'Management'; Group = 'GG-Management' }
                @{ Letter = 'G'; Path = '\\FS01\Finance'; Label = 'Finance'; Group = 'GG-Finance' }
                @{ Letter = 'G'; Path = '\\FS01\HR'; Label = 'HR'; Group = 'GG-HR' }
                @{ Letter = 'G'; Path = '\\FS01\Sales'; Label = 'Sales'; Group = 'GG-Sales' }
                @{ Letter = 'G'; Path = '\\FS01\Marketing'; Label = 'Marketing'; Group = 'GG-Marketing' }
                @{ Letter = 'G'; Path = '\\FS01\Operations'; Label = 'Operations'; Group = 'GG-Operations' }
                @{ Letter = 'G'; Path = '\\FS01\IT'; Label = 'IT'; Group = 'GG-IT' }
            )
        }
    )
}
