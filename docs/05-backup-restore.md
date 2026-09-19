# 05 — Backup and Restore

Backups cover the two kinds of state that cannot be recreated safely from this repository:
Active Directory and file data. The automation is
[`Backup-LabEnvironment.ps1`](../scripts/Backup/Backup-LabEnvironment.ps1).

## Recovery objectives and scope

| Workload | Method | Frequency | Retention | RPO | RTO |
| -------- | ------ | --------- | --------- | --- | --- |
| DC01/DC02 | Windows Server Backup System State | daily | 14 daily + 3 monthly, off-host | 24 h | 4 h |
| DC01/DC02 | `ntdsutil` IFM with SYSVOL | after material AD/GPO changes | newest two sets | rebuild accelerator only | 2 h to add a replacement DC |
| FS01 | `wbadmin` data-volume + `-allCritical` backup | daily | 14 daily + 3 monthly, off-host | 24 h | 8 h |
| GPOs | `Backup-GPO` export in [`gpo/`](../gpo/) | after every GPO change | Git history | last commit | 30 min |

The target is a dedicated disk or protected backup share that is not attached to the same
failure domain as the VM storage. A production version would follow 3-2-1: three copies, on two
media types, with one immutable/offline copy. Proxmox snapshots are useful before a change but
are not backups: they share storage and do not provide application-aware AD recovery.

## Creating backups

Run locally in elevated PowerShell 7. A dedicated `E:` disk is used in these examples.

Terraform attaches this disk to DC01, DC02 and FS01 (`disk_sizes_gb.backup`, default 60 GB; on
FS01 it is the second extra disk after the share volume). Initialize it once. On FS01 run this
**after** `New-FileShares.ps1`, which claims the first raw disk for `S:`:

```powershell
Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Number | Select-Object -First 1 |
    Initialize-Disk -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter E -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel Backup -Confirm:$false
```

```powershell
# DC01 and DC02: System State plus an AD DS IFM set with SYSVOL
.\scripts\Backup\Backup-LabEnvironment.ps1 -BackupTarget E:

# FS01: S: plus every critical OS volume
.\scripts\Backup\Backup-LabEnvironment.ps1 -BackupTarget E:

# Inventory the Windows Server Backup versions
wbadmin get versions -backupTarget:E:
```

Role detection uses `Win32_ComputerSystem.DomainRole` for DCs and the hostname `FS01` for the file
server. `-Role` can override detection. Every run writes command logs and `backup-run.json` below
`E:\nrw-corp-lab\<host>\<timestamp>`. IFM files also get a SHA-256 manifest.

System State is the recoverable backup. The `ntdsutil` IFM set is deliberately additional: it
can seed a newly promoted DC without transferring the whole directory over the network, but it
cannot perform a System State recovery of a failed DC.

For Task Scheduler, use a group-managed service account in production. In the lab, create one
task per server after an interactive test:

```powershell
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\Lab\scripts\Backup\Backup-LabEnvironment.ps1 -BackupTarget E:'
$trigger = New-ScheduledTaskTrigger -Daily -At '01:30'
Register-ScheduledTask -TaskName 'NRW Lab Backup' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest
```

Monitor event logs `Microsoft-Windows-Backup/Operational` and failed task exit codes. Never put
credentials for a backup share in the script or repository.

## Restore runbooks

### A. File or folder from FS01

1. Identify a version with `wbadmin get versions -backupTarget:E:`.
2. Restore to an alternate empty volume first; do not overwrite production during a test.
3. Compare content and ACLs, then copy the validated item into place.

```powershell
$version = '09/19/2026-01:30'
wbadmin start recovery -version:$version -itemType:File -items:'S:\Shares\Finance\restore-canary.txt' -recoveryTarget:R: -backupTarget:E: -notRestoreAcl:$false -quiet
Get-FileHash R:\Shares\Finance\restore-canary.txt -Algorithm SHA256
(Get-Acl R:\Shares\Finance\restore-canary.txt).Sddl
```

### B. Non-authoritative DC recovery

Prefer rebuilding a lost DC and promoting it again while another healthy DC exists. Use System
State recovery when directory state itself must be recovered:

1. Isolate a clone from production and start Directory Services Repair Mode (DSRM).
2. List versions and run `wbadmin start systemstaterecovery -version:<version>
   -backupTarget:E: -quiet`.
3. Reboot normally. AD DS performs non-authoritative synchronization from the healthy DC.
4. Verify DNS, SYSVOL/NETLOGON, replication and the event logs before reconnecting services.

For an accidentally deleted object, remain in DSRM after System State recovery and use
`ntdsutil` **authoritative restore** on only the required object/subtree. Forest recovery is a
separate high-impact procedure and requires restoring the first writable DC in each domain; do
not improvise it from this short lab runbook.

### C. Replacement DC from IFM

Copy the newest verified IFM set locally to the replacement server, then pass it while promoting:

```powershell
Install-ADDSDomainController -DomainName ad.nrwcorp.internal -InstallationMediaPath C:\IFM -Credential (Get-Credential NRWCORP\Administrator)
```

IFM reduces initial replication; it does not make the new DC current. Allow replication to finish
and run the validation suite afterward.

## Documented restore test RT-01

The test is designed to be repeatable without risking the live lab. It must run on an isolated
Proxmox bridge with no route to the production lab network.

| Field | Record |
| ----- | ------ |
| Test ID | RT-01 |
| Scenario | FS01 file restore plus DC01 non-authoritative System State restore |
| Source backups | Most recent successful DC01 and FS01 runs; IDs copied from `wbadmin get versions` |
| Test systems | Clones named `RT-DC01` and `RT-FS01`, isolated VLAN |
| Evidence | `wbadmin` output, SHA-256 before/after, SDDL before/after, Pester validation XML |
| Pass criteria | Canary content and SDDL match; AD DS starts; SYSVOL/NETLOGON exist; DNS resolves; `repadmin /replsummary` has zero failures |
| Status | **Not executed yet — requires the deployed Proxmox lab and generated backups** |

### Execution record

1. On FS01 create `S:\Shares\Finance\restore-canary.txt`, record its SHA-256 and SDDL, run a
   backup, then delete the canary.
2. Clone DC01 and FS01 without memory state, attach copies of their backup disks, and connect only
   to the isolated recovery VLAN.
3. Restore the canary to `R:` using runbook A. Record the restored SHA-256 and SDDL.
4. Boot RT-DC01 into DSRM and perform runbook B. Boot normally after recovery.
5. On RT-DC01 run `dcdiag /test:Advertising /test:SysVolCheck /test:NetLogons /v`, resolve
   `_ldap._tcp.dc._msdcs.ad.nrwcorp.internal`, and confirm the `SYSVOL` and `NETLOGON` shares.
6. Add a disposable isolated partner DC (or reconnect a matching RT-DC02 clone), wait for
   convergence, and run `repadmin /replsummary`.
7. Run `Invoke-LabValidation.ps1 -OutputPath C:\TestResults\RT-01.xml` once phase 9 is deployed.
8. Replace the status above with date, operator, backup version IDs, duration, result and links to
   captured evidence. Log every deviation in [99 — Troubleshooting](99-troubleshooting.md).

This repository intentionally does not claim that RT-01 passed before the lab and backup media
exist. A recovery plan without a recorded successful execution is an unverified plan, not proof
of recoverability.

## Failure modes

- `wbadmin` rejects the target: ensure it is a dedicated mounted volume or reachable UNC path and
  is not among the backed-up volumes.
- A UNC target contains only one version: Windows Server Backup overwrites the previous remote
  image. Provide versioning on the backup appliance or use rotated local disks.
- `ntdsutil` says the destination is not empty: use a new timestamped directory; the script does
  this automatically.
- A backup completed but cannot be restored: mark it failed operationally. Only RT-01 turns a
  backup into verified recovery evidence.
