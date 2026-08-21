# Security policy

## Supported status

Switchboard is public MIT source with 17 ready modules. The current verification record is **147 tests in 22 suites**. A Developer ID certificate for Team `Q2X7X86GYR` is available; a public DMG or release is valid only when notarization and release-gate evidence accompany it.

## Security boundaries

Treat these areas as security-sensitive:

- The single background agent, bundled command payloads, and macOS Services.
- The manifest and per-component upgrade contract.
- Permission onboarding and helper identity, especially Accessibility and Mail Assistant's exact nested Full Disk Access helper.
- Local Read's permanent external command host and any account-connected read-only source.
- Reversible command, Service, scheduler, and old-app retirement transactions.
- GitHub manifest discovery, team and SHA-256 verification, nested update handoff, and rollback.
- Login registrations, privileged helpers, Finder extensions, and operations that alter installed or system state.

Switchboard does not request blanket Full Disk Access. Do not bypass a denial or identity change by granting a broader permission. Stop, record the result, and obtain an explicit decision.

## Migration safety

Every selected component is classified `migrate`, `retain`, or `alreadyRetired`. Existing legacy state wins once. Unresolved jobs remain active and visible. Scheduler and activation transactions keep recovery records. An old app must pass exact path and identity checks, trusted signature validation, archive verification, and replacement health before it is moved to Trash; the verified archive remains available for recovery.

## Update safety

The updater accepts only the fixed canonical target and a candidate whose manifest, expected version, architecture, Developer ID Team `Q2X7X86GYR`, signature, and SHA-256 all match. It keeps a verified recovery copy and supports rollback after interruption or failed verification. Release scripts must not be treated as evidence that notarization or public publication happened.

## Reporting a vulnerability

When repository Security Advisories are enabled, use a private advisory rather than a public issue. Include the affected module or migration state, safe reproduction steps, and observed impact. Redact secrets, credentials, private settings, account data, personal paths, local usernames, and copied runtime data before sending evidence.

## Disclosure

Coordinate a fix or mitigation before public disclosure when practical. Disclosure timing depends on severity, reproducibility, and whether a supported public build exists.
