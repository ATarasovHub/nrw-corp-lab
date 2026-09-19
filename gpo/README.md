# Group Policy Exports

Versioned exports of the lab GPOs. Design and rationale: [docs/04-gpo.md](../docs/04-gpo.md).

```text
gpo/
├── backups/<GpoName>/{BackupId}/   Backup-GPO output, one current backup per GPO
└── reports/<GpoName>.html          Get-GPOReport, readable on GitHub
```

## Workflow

| Step | Command (on DC01) |
| ---- | ----------------- |
| Build GPOs from `data/gpo.psd1` | `.\scripts\GroupPolicy\New-LabGpo.ps1` |
| Export to this folder | `.\scripts\GroupPolicy\Export-LabGpo.ps1` |
| Commit | `git add gpo && git commit -m "chore(gpo): export GPOs"` |
| Restore into a rebuilt domain | `.\scripts\GroupPolicy\Import-LabGpo.ps1` |

`backups/` and `reports/` are created by the first export in a running lab. A backup can only be
produced by `Backup-GPO` against a real domain, so the folders are empty until then — until the
first export, `New-LabGpo.ps1` builds the GPOs directly from the data file.

Backups contain names and SIDs of lab groups and the settings shown in docs/04-gpo.md; they
contain no passwords or other secrets.
