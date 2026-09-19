# Deployment evidence

Only screenshots of **completed results** belong here. Installer pages, command entry, progress
bars and fabricated/mock images do not prove the design works.

The repository has not been connected to a deployed Proxmox lab in this development environment,
so the evidence remains pending instead of being invented. After deployment, capture 5–8 PNGs at
native resolution, redact usernames/IPs only when necessary, and keep the following stable names:

| File | Capture on | Result that must be visible |
| ---- | ---------- | --------------------------- |
| `01-proxmox-topology.png` | Proxmox | running RTR01, DC01, DC02, FS01, MGMT01, WS001/2 and LNX01 |
| `02-ad-ou-users.png` | MGMT01 / ADAC | `NRW` OU tree and representative department/admin objects |
| `03-dhcp-failover-leases.png` | MGMT01 | `Normal` failover and active VLAN 30 leases |
| `04-gpo-rsop.png` | MGMT01 | RSoP for WS001/user with baseline, update, local-admin and drive policies |
| `05-file-shares-acl.png` | MGMT01 or FS01 | shares/quotas plus one protected ACL showing FC/RW/RO groups |
| `06-pester-validation.png` | MGMT01 | complete integration suite with zero failed tests |
| `07-backup-restore-test.png` | isolated recovery lab | successful RT-01 restore evidence, not merely backup completion |

When the files exist, add a compact gallery to both root README files. Do not include backup
paths containing credentials, initial-password CSVs, API tokens, Terraform state, or unredacted
personal data. Record the capture date and matching commit below.

| Capture date | Commit | Lab version | Notes |
| ------------ | ------ | ----------- | ----- |
| pending | pending | pending | Waiting for first deployed-lab validation and RT-01 |
