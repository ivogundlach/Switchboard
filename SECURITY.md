# Security policy

## Supported status

Switchboard is an unreleased pilot. **Warm Corners** is the only current pilot module, and no public DMG or production installation is supported yet.

## Reporting a vulnerability

When the repository has GitHub Security Advisories enabled, use a private GitHub Security Advisory rather than a public issue for a suspected vulnerability. Include a clear description, affected component or module state, reproduction steps that do not expose real data, and the impact you observed.

Never post secrets, credentials, private settings, account data, or personal paths in an issue, pull request, log, screenshot, or advisory. Redact them before sharing evidence.

## Protected areas

Treat these areas as security-sensitive and require focused review:

- Warm Corners migration, import, rollback, and recovery artifacts.
- Privileged helpers, LaunchAgents, and any operation that can change installed or system state.
- Signing, update, release, and distribution logic.
- Local-read connectors and Apple Mail access.
- Manifest ownership and availability checks that prevent a standalone worker or Safari app from being absorbed accidentally.

Do not bypass a permission denial or identity change by broadening access. Stop, record the result, and obtain an explicit decision before continuing.

## Disclosure expectations

The maintainer will acknowledge a private report, investigate the affected release state, and coordinate a fix or mitigation before public disclosure when practical. Disclosure timing depends on severity, reproducibility, and whether a supported public build exists.
