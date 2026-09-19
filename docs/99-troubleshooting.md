# 99 — Troubleshooting

Start with the narrowest failing layer and preserve evidence before changing state. Record new
issues in the log at the end of this document; do not turn one-off console fixes into undocumented
configuration drift.

## Fast triage

```powershell
# Network and DNS
Test-NetConnection DC01 -Port 53
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.nrwcorp.internal -Type SRV

# AD and replication
dcdiag /e /q
repadmin /replsummary
Get-ADReplicationFailure -Scope Forest

# DHCP, policy and file server
Get-DhcpServerv4Failover -ComputerName DC01
gpresult /r
Test-WSMan FS01

# Project-level evidence
.\scripts\Validation\Invoke-LabValidation.ps1
```

If several layers fail, fix routing/DNS/time first. AD authentication, Group Policy, DHCP dynamic
DNS and WinRM all depend on them.

## Packer waits forever for WinRM

**Symptoms:** the VM installs Windows, but Packer times out waiting for WinRM or cannot discover
an address.

**Check:** confirm the build NIC is on a DHCP-enabled network, QEMU Guest Agent is running, and
the generated ISO contains the VirtIO drivers. In the Proxmox console inspect
`C:\Windows\Temp\packer-*` and the Cloudbase-Init/Packer bootstrap logs.

**Fix:** use VirtIO ISO 0.1.266 or newer, keep the temporary HTTPS listener reachable from the
Packer host, and verify the template VM has not inherited a stale static address. Do not leave
Basic authentication enabled after the build; `Disable-PackerWinRM.ps1` removes it on clone boot.

## Terraform cannot upload cloud-init snippets

**Symptoms:** `terraform apply` fails on a snippet file or Proxmox says the datastore does not
support `snippets`.

**Check:** `datastore_files` must name file-based storage with `iso,snippets` content enabled;
the SSH key in `ssh-agent` must reach the configured Proxmox node.

**Fix:** enable `snippets` on the datastore, correct `proxmox_ssh_username`, reload the SSH key,
then rerun `terraform plan`. Do not put an SSH private key in `terraform.tfvars`.

## A server cannot find or join the domain

**Symptoms:** `The specified domain either does not exist or could not be contacted`, Kerberos
errors, or `Join-LabDomain.ps1` fails.

**Check:** the member's DNS servers must be `10.10.20.11` and `.12`, not RTR01 or a public DNS
resolver. Verify the SRV record and that time differs by less than five minutes:

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.nrwcorp.internal -Type SRV
w32tm /stripchart /computer:DC01 /samples:5 /dataonly
```

**Fix:** correct DNS and NTP first, then retry the idempotent join script. Adding a hosts-file
entry may hide DNS failure and is not an acceptable fix.

## A DC starts with broken DNS or replication

**Symptoms:** only one DC locator record, replication error 1722/1256, missing SYSVOL/NETLOGON,
or clients authenticate only while one DC is online.

**Check:** each DC must point to its partner first and loopback second. Run `dcdiag /test:DNS /e
/v`, `repadmin /showrepl * /errorsonly`, inspect Directory Service and DFS Replication logs, and
confirm TCP 135 plus dynamic RPC 49152–65535 is allowed between required segments.

**Fix:** restore DNS client order with `Set-DnsConfiguration.ps1`, repair routing/firewall, then
force topology recalculation with `repadmin /kcc`. Do not restore or delete AD database files while
a healthy replication partner exists; rebuilding/re-promoting the failed DC is normally safer.

## DHCP failover is not `Normal` or clients get no lease

**Symptoms:** states `CommunicationInterrupted`, `PartnerDown` or `Recover`; WS001 uses APIPA; the
validation suite reports no active dynamic lease.

**Check:** verify RTR01 relays VLAN 30 broadcasts to both `10.10.20.11` and `.12`, UDP 67/68 is
allowed, both DHCP servers are authorized, clocks agree, and the scope is in the failover
relationship.

```powershell
Get-DhcpServerInDC
Get-DhcpServerv4Failover -ComputerName DC01 | Format-List *
Get-DhcpServerv4Lease -ComputerName DC01 -ScopeId 10.10.30.0
```

**Fix:** repair connectivity/authorization, then run `New-DhcpScopes.ps1` again so it converges
configuration and replicates the scope. Use `ipconfig /release` and `/renew` on a client only after
the servers are healthy.

## A GPO is linked but not applied

**Symptoms:** mapped drives, Windows Update or local-admin settings are absent; RSoP validation
fails.

**Check:** use `gpresult /h C:\Temp\gp.html` on WS001 and an RSoP XML from MGMT01. Check the
computer/user OU, security filtering, denied GPOs and SYSVOL reachability. `U-All-DriveMappings`
also needs the user to be in `GG-AllStaff` and the appropriate department group.

**Fix:** rerun `New-LabGpo.ps1` (or `Import-LabGpo.ps1` after a rebuild), then `gpupdate /force`.
Do not edit Default Domain Policy or fix a drive mapping by assigning NTFS access directly.

## GPO import contains unresolved groups after a rebuild

**Symptoms:** Restricted Groups or user rights show old SIDs; drive-map item targeting never
matches.

**Check:** read the migration warnings from `Import-LabGpo.ps1` and confirm all GG/DL groups were
created before import.

**Fix:** run `New-AdOuStructure.ps1` and `Import-LabUsers.ps1`, then import again. The script builds
a migration table for security templates and separately rewrites GPP drive-map SIDs because GPP
is not covered by migration tables.

## Share access is denied or too broad

**Symptoms:** a department cannot open its share, another department can, or NTFS validation
reports extra/inherited ACEs.

**Check:** follow AGDLP in both directions: user → `GG-Department` → `DL-FS-Share-RW/RO` → NTFS.
Remember that a new group membership requires a fresh Kerberos token (sign out/in or purge tickets).

```powershell
Get-ADPrincipalGroupMembership sabine.koch | Select-Object Name
Get-ADGroupMember DL-FS-Finance-RW
(Get-Acl S:\Shares\Finance).Access
```

**Fix:** correct `data/shares.psd1` or AD role membership and rerun `Import-LabUsers.ps1` plus
`New-FileShares.ps1`. Never add a user or global group directly to an ACL.

## RSoP or NTFS validation fails with access/remoting errors

**Symptoms:** `Get-GPResultantSetOfPolicy` reports RPC/access denied, or `Invoke-Command FS01`
fails although the configuration is correct.

**Check:** run from MGMT01 with the AD/DHCP/GPMC RSAT features, Pester 5.5+, a tier-appropriate
administrator account and working WinRM. Confirm the firewall permits MGMT → CLIENTS/SERVERS RPC
and WinRM.

**Fix:** restore RSAT/WinRM prerequisites and rerun. Do not weaken GPO security filtering or NTFS
permissions merely to make a test account pass.

## Windows Server Backup rejects the target

**Symptoms:** `wbadmin` says the location is invalid, the target is included in the backup, or an
UNC target has only the newest version.

**Check:** DC/FS backups must use a dedicated mounted volume or a reachable protected UNC path;
never `C:` and never FS01's `S:`. Windows Server Backup intentionally keeps only one image on a
remote share unless the storage system versions it.

**Fix:** attach/rotate a separate disk or enable appliance-side versioning. Use `wbadmin get
versions -backupTarget:E:` after each run and execute RT-01 from
[05 — Backup and Restore](05-backup-restore.md). A successful backup event alone does not prove a
successful restore.

## CI shows an intermittent PSScriptAnalyzer crash

**Symptoms:** PSScriptAnalyzer 1.25 throws `NullReferenceException` without identifying a code
finding.

**Cause/status:** this was observed while the project was developed. A crash can corrupt the
analyzer's internal command cache, so an in-process retry is insufficient. CI pins the last stable
release, PSScriptAnalyzer 1.24.0, until the 1.25 regression is fixed; a real finding is never
ignored.

**Action:** confirm the job imported 1.24.0. If that pinned version crashes, capture the
module/PowerShell versions and named file from CI and open an upstream reproducer; do not suppress
analyzer rules globally.

## Incident log

Add entries while deploying. Keep secrets, raw backup contents and credentials out of Git.

| Date | Host/layer | Symptom | Root cause | Durable fix | Evidence |
| ---- | ---------- | ------- | ---------- | ----------- | -------- |
| 2026-09-19 | CI | PSScriptAnalyzer intermittently crashed and poisoned later files | Analyzer 1.25 parallel-rule/command-cache regression | Pin CI to stable 1.24.0 and keep per-file diagnostics | commits `855e18b`, `b9d6b12`, `5cc56c7`; phase-10 CI follow-up |
| pending | recovery lab | RT-01 not executed | Deployment and backup media required | Run the isolated procedure and update the record | [RT-01](05-backup-restore.md#documented-restore-test-rt-01) |
