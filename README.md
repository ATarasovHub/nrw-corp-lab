# nrw-corp-lab

[![Lint](https://img.shields.io/badge/CI-PSScriptAnalyzer%20%7C%20Pester-blue)](.github/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**English** | [Deutsch](README.de.md)

Windows Server 2025 / Active Directory Domain Services lab for a fictional 30-employee company in NRW, deployed entirely as code.

> 🚧 Work in progress — sections below are placeholders.

## Overview

## Documentation

| Document | Content |
| -------- | ------- |
| [01 — Architecture](docs/01-architecture.md) | Topology, component inventory, design decisions |
| [02 — Network](docs/02-network.md) | VLANs, IP plan, DHCP, DNS, firewall policy |
| [03 — AD Design](docs/03-ad-design.md) | OU structure, naming conventions, AGDLP, tiering |
| [04 — Group Policy](docs/04-gpo.md) | GPOs, links, rationale per setting, export/restore |
| [05 — Backup and Restore](docs/05-backup-restore.md) | System State, file-server backup and tested restore runbook |
| [Infrastructure](infra/README.md) | Packer templates, Terraform VMs on Proxmox VE |

## Architecture

## Features

## Prerequisites

## Quick Start

## Repository Structure

```text
.github/workflows/  CI (PSScriptAnalyzer)
data/               Input data (OUs, groups, users)
docs/               Documentation and diagrams
gpo/                Group Policy backups / definitions
infra/              Infrastructure as code (VM provisioning)
scripts/            PowerShell 7 deployment scripts
tests/              Pester tests
```

## Security

## Testing

## Roadmap

## License

[MIT](LICENSE)
