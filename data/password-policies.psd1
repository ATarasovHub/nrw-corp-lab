# Fine-grained password policies (docs/03-ad-design.md#password-policy, docs/04-gpo.md).
# The domain-wide policy is the GPO C-Domain-PasswordPolicy (data/gpo.psd1).
# MaxPasswordAge '0.00:00:00' means the password never expires (NIST SP 800-63B, BSI).
@{
    Policies = @(
        @{
            Name                        = 'PSO-Admins'
            Precedence                  = 10
            Description                 = 'Tiered admin accounts: longer secrets, stricter lockout'
            MinPasswordLength           = 20
            PasswordHistoryCount        = 24
            MinPasswordAge              = '1.00:00:00'
            MaxPasswordAge              = '0.00:00:00'
            ComplexityEnabled           = $true
            ReversibleEncryptionEnabled = $false
            LockoutThreshold            = 5
            LockoutDuration             = '00:30:00'
            LockoutObservationWindow    = '00:30:00'
            Subjects                    = @('GG-T0-DomainAdmins', 'GG-T1-ServerAdmins', 'GG-T2-Helpdesk')
        }
        @{
            Name                        = 'PSO-ServiceAccounts'
            Precedence                  = 20
            Description                 = 'Legacy service accounts that cannot use a gMSA: very long secrets, no lockout'
            MinPasswordLength           = 30
            PasswordHistoryCount        = 24
            MinPasswordAge              = '0.00:00:00'
            MaxPasswordAge              = '0.00:00:00'
            ComplexityEnabled           = $true
            ReversibleEncryptionEnabled = $false
            LockoutThreshold            = 0
            LockoutDuration             = '00:30:00'
            LockoutObservationWindow    = '00:30:00'
            Subjects                    = @('GG-LegacyServiceAccounts')
        }
    )
}
