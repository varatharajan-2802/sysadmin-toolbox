# Sysadmin Toolbox

A collection of PowerShell scripts for day-to-day Windows Server, Active Directory,
and Microsoft 365 administration — built from real infrastructure work, not tutorials.

## What's here

| Folder | What it covers |
|---|---|
| [`active-directory/`](./active-directory) | Domain Controller health checks, replication, FSMO |
| `security/` | Mail flow rules, spoof detection, tenant hardening |
| `microsoft-365/` | License auditing, update compliance |
| `networking/` | Network diagram automation |

## Philosophy

Every script here is:
- **Read-only by default**, unless a script explicitly documents otherwise
- **Self-contained** — minimal external dependencies beyond what's noted per script
- **Written from real production troubleshooting** — including the bugs found and fixed along the way

## License

MIT — see [LICENSE](./LICENSE).
