# Security policy

## Supported status

Switchboard is an unreleased project with ready modules and no planned modules. Kinetics runs as a signed nested companion under Switchboard's one background agent; its inert migration-only LoginLauncher bundle is included for exact SMAppService identity but is never registered or launched. Smart Wake's core behavior and Copy Path are ready. A signed local installation and Warm Corners migration verification have passed, but there is no public DMG or public release supported today.

## Reporting a vulnerability

When repository Security Advisories are enabled, use a private advisory rather than a public issue. Include the affected module or migration state, safe reproduction steps, and observed impact.

Never post secrets, credentials, private settings, account data, personal paths, or copied runtime data in an issue, pull request, log, screenshot, or advisory. Redact evidence first.

## Protected areas

Treat these areas as security-sensitive and require focused review:

- The single Switchboard background agent and its bundled command payloads and macOS Services.
- Recoverable command, service, and scheduler migration, including rollback records. Generic migration does not delete legacy apps; Warm Corners specifically archives and moves its bridge app to Trash only after verified health.
- GitHub release discovery, download, hash verification, nested updater, and rollback installer.
- Privileged helpers, login registrations, and operations that can change installed or system state.
- Local-read connectors, Apple Mail access, and manifest ownership checks.

Do not bypass a permission denial or identity change by broadening access. Stop, record the result, and obtain an explicit decision before continuing.

## Disclosure expectations

Investigate private reports and coordinate a fix or mitigation before public disclosure when practical. Disclosure timing depends on severity, reproducibility, and whether a supported public build exists.
