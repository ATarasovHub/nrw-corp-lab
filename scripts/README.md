# Scripts

PowerShell 7 automation that turns the VMs created in [infra/](../infra/README.md) into the
environment described in [docs/](../docs/). Every script:

- is idempotent — re-running converges to the same state and never duplicates objects,
- supports `-WhatIf` and `-Confirm` (`[CmdletBinding(SupportsShouldProcess)]`),
- has comment-based help — `Get-Help .\scripts\Domain\Initialize-Domain.ps1 -Full`,
- takes secrets only as `SecureString` / `PSCredential` parameters.

## How to Run

Scripts run **on the target server** in an elevated PowerShell 7 session (`pwsh`), from a copy of
this repository. From MGMT01 or your workstation:

```powershell
$session = New-PSSession -ComputerName 10.10.20.11 -Credential (Get-Credential)
Copy-Item -ToSession $session -Path .\scripts, .\data -Destination C:\Lab -Recurse -Force
Enter-PSSession $session
pwsh   # scripts require PowerShell 7
Set-Location C:\Lab
```

Before the domain exists, WinRM to a workgroup server needs the IP in `TrustedHosts` on the client:
`Set-Item WSMan:\localhost\Client\TrustedHosts -Value '10.10.20.*' -Concatenate`.

## Run Order

### Phase 3 — Domain controllers

| Step | Where | Command |
| ---- | ----- | ------- |
| 1 | DC01 | `.\scripts\Domain\Initialize-Domain.ps1 -SafeModeAdministratorPassword (Read-Host -AsSecureString) -Restart` |
| 2 | DC01 | after reboot: `.\scripts\Domain\Initialize-Domain.ps1` |
| 3 | DC01 | `.\scripts\Domain\Set-DnsConfiguration.ps1` |
| 4 | DC02 | `.\scripts\Domain\Add-ReplicaDomainController.ps1 -Credential (Get-Credential NRWCORP\Administrator) -SafeModeAdministratorPassword (Read-Host -AsSecureString) -Restart` |
| 5 | DC02 | after reboot: `.\scripts\Domain\Add-ReplicaDomainController.ps1 -Credential (Get-Credential NRWCORP\Administrator)` |

Check: `repadmin /replsummary` on DC01 shows 0 failures; `Resolve-DnsName ad.nrwcorp.internal` returns
both DCs.

### Phase 4 — OUs, users and groups

Desired state lives in [data/](../data/): `ou-structure.psd1`, `groups.psd1`, `shares.psd1`, `users.csv`.

| Step | Where | Command |
| ---- | ----- | ------- |
| 1 | DC01 | `.\scripts\Directory\New-AdOuStructure.ps1` |
| 2 | DC01 | `.\scripts\Directory\Import-LabUsers.ps1 -WhatIf` — review, then run without `-WhatIf` |
| 3 | FS01, MGMT01 | `.\scripts\Domain\Join-LabDomain.ps1 -Credential (Get-Credential NRWCORP\Administrator) -OrganizationalUnit 'Servers/FileServers' -Restart` (MGMT01: `Computers/Admin`) |

`Import-LabUsers.ps1` writes the initial secrets of new accounts to
`~\nrw-corp-lab-secretsinitial-credentials.csv` (ACL: current user, SYSTEM, Administrators only) and
refuses to write inside a git repository. All users must change their secret at first logon.

Re-running is safe: users are matched by `employeeID`. Change `users.csv` and run again to see
updates, department moves and leavers (removed rows → disabled and moved to `Disabled/Users`).

### Phase 5 — DHCP

| Step | Where | Command |
| ---- | ----- | ------- |
| 1 | DC01 | `.\scripts\Network\New-DhcpScopes.ps1 -FailoverSharedSecret (Read-Host -AsSecureString) -ReservationMacAddress @{ PRN01 = '00-15-5D-xx-xx-xx' }` |
| 2 | Proxmox | set `start_clients = true` in `terraform.tfvars`, `terraform apply` — clients boot and get a lease |
| 3 | WS001/WS002 | `.\scripts\Domain\Join-LabDomain.ps1 -Credential (Get-Credential NRWCORP\Administrator) -OrganizationalUnit 'Computers/Workstations' -Restart` |

Requires the DHCP relay on RTR01 (VLAN 30 → 10.10.20.11, 10.10.20.12). Check:
`Get-DhcpServerv4Failover -ComputerName DC01` shows state `Normal`; `Get-DhcpServerv4Lease -ScopeId 10.10.30.0`.

### Phase 6 — File server

| Step | Where | Command |
| ---- | ----- | ------- |
| 1 | FS01 | `.\scripts\FileServer\New-FileShares.ps1 -WhatIf` — review, then run without `-WhatIf` |

Prerequisites: FS01 joined to the domain (phase 4), groups created by `Import-LabUsers.ps1`, data
disk attached (Terraform `disk_sizes_gb.fs_data`). Check: `Get-SmbShare`, `Get-FsrmQuota`,
`(Get-Acl S:\Shares\Finance).Access`.

### Phase 7 — Group Policy

| Step | Where | Command |
| ---- | ----- | ------- |
| 1 | DC01 | `.\scripts\GroupPolicy\Set-FineGrainedPasswordPolicy.ps1` |
| 2 | DC01 | `.\scripts\GroupPolicy\New-LabGpo.ps1 -WhatIf` — review, then run without `-WhatIf` |
| 3 | DC01 | `.\scripts\GroupPolicy\Export-LabGpo.ps1` — then commit `gpo/` |
| — | DC01 | rebuild/restore instead of step 2: `.\scripts\GroupPolicy\Import-LabGpo.ps1` |

Check on a client: `gpupdate /force`, `gpresult /r`, drive `G:` maps to the department share.
Details: [docs/04-gpo.md](../docs/04-gpo.md).
