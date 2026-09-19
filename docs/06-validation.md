# 06 — Validation

Unit tests validate desired-state data in CI. Integration tests prove that the deployed lab
actually behaves as designed. The single entry point is
[`Invoke-LabValidation.ps1`](../scripts/Validation/Invoke-LabValidation.ps1).

## Prerequisites

Run from MGMT01 in elevated PowerShell 7 with a tier-appropriate domain admin account:

```powershell
Install-WindowsFeature RSAT-AD-PowerShell, GPMC, RSAT-DHCP
Install-Module Pester -MinimumVersion 5.5.0 -Scope AllUsers
Test-WSMan FS01
```

WS001 must be running, domain joined and holding an active lease. The GPO test uses WS001 and
employee E1001; these explicit probe targets live in [`data/validation.psd1`](../data/validation.psd1).
They are configuration, not secrets.

## Run

```powershell
# Full validation and JUnit evidence
.\scripts\Validation\Invoke-LabValidation.ps1

# Fast infrastructure smoke test
.\scripts\Validation\Invoke-LabValidation.ps1 -Tag Domain,Replication,DHCP

# Recovery-test evidence path
.\scripts\Validation\Invoke-LabValidation.ps1 -OutputPath C:\TestResults\RT-01.xml
```

The full suite checks:

| Test | Evidence |
| ---- | -------- |
| Domain | AD query succeeds; DNS publishes at least two `_ldap._tcp.dc._msdcs` SRV records |
| Replication | `repadmin /replsummary` exits successfully and `Get-ADReplicationFailure` returns none |
| DHCP | failover is `Normal`; scope matches desired state; a live dynamic lease is inside the pool and outside exclusions |
| GPO | `Get-GPResultantSetOfPolicy` contains every expected computer/user GPO for WS001 and E1001 |
| NTFS | AGDLP group nesting matches `shares.psd1`; every share has a protected, exact ACL with FC/RW/RO rights |

Integration tests are intentionally not run by public GitHub Actions: the runner has no route or
credentials to the private lab. Commit the JUnit result or screenshots only after removing host
details that should not be public; raw backup and security logs stay outside Git.

## Interpreting failures

- Domain or replication: run `dcdiag /e /v`, inspect Directory Service/DNS logs, then see
  [99 — Troubleshooting](99-troubleshooting.md).
- DHCP: confirm WS001 is on VLAN 30 and RTR01 relays to both DCs; renew with `ipconfig /renew`.
- GPO: run `gpupdate /force` on WS001 and `gpresult /h C:\Temp\gp.html` before changing policy.
- NTFS: do not patch an ACE manually. Fix `shares.psd1` or group membership and rerun
  `New-FileShares.ps1` / `Import-LabUsers.ps1` so desired state remains the source of truth.
