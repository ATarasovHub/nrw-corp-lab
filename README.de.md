# nrw-corp-lab

[![Lint](https://img.shields.io/badge/lint-PSScriptAnalyzer-blue)](.github/workflows/lint.yml)
[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-green.svg)](LICENSE)

[English](README.md) | **Deutsch**

Windows-Server-2025-/Active-Directory-Domain-Services-Lab für ein fiktives Unternehmen in NRW mit 30 Mitarbeitenden – vollständig als Code bereitgestellt.

> 🚧 In Arbeit – die folgenden Abschnitte sind Platzhalter.

## Überblick

## Dokumentation

Die technische Dokumentation ist auf Englisch.

| Dokument | Inhalt |
| -------- | ------ |
| [01 — Architecture](docs/01-architecture.md) | Topologie, Komponenten, Designentscheidungen |
| [02 — Network](docs/02-network.md) | VLANs, IP-Plan, DHCP, DNS, Firewall-Regeln |
| [03 — AD Design](docs/03-ad-design.md) | OU-Struktur, Namenskonventionen, AGDLP, Tiering |
| [Infrastructure](infra/README.md) | Packer-Templates, Terraform-VMs auf Proxmox VE |

## Architektur

## Funktionen

## Voraussetzungen

## Schnellstart

## Repository-Struktur

```text
.github/workflows/  CI (PSScriptAnalyzer)
data/               Eingabedaten (OUs, Gruppen, Benutzer)
docs/               Dokumentation und Diagramme
gpo/                Gruppenrichtlinien-Sicherungen / -Definitionen
infra/              Infrastructure as Code (VM-Bereitstellung)
scripts/            PowerShell-7-Bereitstellungsskripte
tests/              Pester-Tests
```

## Sicherheit

## Tests

## Roadmap

## Lizenz

[MIT](LICENSE)
