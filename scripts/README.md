# Scripts

PowerShell 7 automation that turns the VMs created in [infra/](../infra/README.md) into the
environment described in [docs/](../docs/). Every script:

- is idempotent — re-running converges to the same state and never duplicates objects,
- supports `-WhatIf` and `-Confirm` (`[CmdletBinding(SupportsShouldProcess)]`),
- has comment-based help — `Get-Help .\Scripts\Domain\Initialize-Domain.ps1 -Full`,
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
