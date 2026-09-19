# Live validation targets. The values identify disposable lab systems, not credentials.
@{
    DomainName              = 'ad.nrwcorp.internal'
    PrimaryDomainController = 'DC01'
    DomainControllers       = @('DC01', 'DC02')
    FileServer              = 'FS01'
    GpoComputer             = 'WS001'
    GpoUserEmployeeId       = 'E1001'
    ExpectedGpos            = @(
        'C-Domain-PasswordPolicy'
        'C-All-SecurityBaseline'
        'C-WS-WindowsUpdate'
        'C-WS-LocalAdmins'
        'U-All-DriveMappings'
    )
}
