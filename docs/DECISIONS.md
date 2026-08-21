# Switchboard decisions

This file records the product boundaries that reviewers and contributors should preserve.

## 1. One control center, explicit ownership

Switchboard owns 17 ready modules, one background agent, its bundled commands and Services, and its explicitly bundled helpers/extensions. Standalone products and their workers stay in their own DMGs. Safari apps stay separate. Third-party tools, forks, and general Apple Shortcuts stay separate. The two Mac brightness shortcuts are replaced by the native Mac Brightness module.

**Reason:** shared control and scheduling are useful; silently absorbing another product or account-connected tool makes permissions, updates, and recovery ambiguous.

## 2. Normal launch is visible; background launch is not

A normal launch opens setup/review and the control center. Login-item and explicit background launches stay hidden.

**Reason:** first-run migration needs a human decision, while login startup must not interrupt the desktop.

## 3. Legacy state wins once, through a per-component contract

The upgrade scanner reviews exact components and each contract declares `migrate`, `retain`, or `alreadyRetired`. Existing legacy settings/state are authoritative for the one import. One confirmation starts the selected work. Import behavior is module-owned because settings formats and semantics differ.

**Reason:** an explicit contract prevents accidental takeover and makes a partial upgrade explainable.

## 4. Permissions follow the actor

Permission onboarding is progressive and exact. Accessibility is attributed to Switchboard, nested Kinetics, or the Quit helper according to the actor. Mail Assistant Full Disk Access belongs to its exact nested helper. Local Read permissions belong to the permanent external command host. App Management appears only when an old app needs retirement. Administrator prompts occur only at the privileged action itself.

**Reason:** the user can grant the smallest permission to the process that actually needs it. Blanket Full Disk Access is not a setup prerequisite.

## 5. Replacement before retirement

Command and Service activation is reversible. Scheduler migration is journaled and recoverable. An old app is moved to Trash only after exact path and identity validation, trusted signature checks, a verified archive, and replacement capability health. Unresolved jobs remain active and visible.

**Reason:** an upgrade must fail closed and leave a restore path instead of creating a silent outage or data-loss event.

## 6. Kinetics keeps identity and proves health

Kinetics runs as a signed nested companion under the Switchboard agent. It preserves the existing preferences domain and keys. The migration-only LoginLauncher is inert and exists only for exact login identity continuity. A write-ahead handoff journal restores an interrupted pre-health stop. Retirement waits for five stable checks of Accessibility, the event tap, the exact process, a per-attempt nonce, and the continuous-agent heartbeat.

**Reason:** Kinetics is sensitive to duplicate event watchers and login races; identity continuity and live health are stronger evidence than a successful process launch.

## 7. Updates are verified before handoff

The updater verifies the GitHub manifest, expected version, Developer ID Team `Q2X7X86GYR`, architecture, signature, and SHA-256, then uses a verified recovery copy for rollback.

**Reason:** release metadata and downloaded bytes are untrusted until independently checked. A local implementation is not evidence of a public release.

## 8. Public release is a gated claim

The current verification record is **147 tests in 22 suites**. The Developer ID certificate is available. Publication requires the release checks, privacy/secret checks, Gatekeeper evidence, and explicit authorization; source files alone never prove that a release occurred.

**Reason:** contributors and users must be able to distinguish implemented release machinery from an artifact that has actually been published.

## Source map

- Ownership: `Sources/Switchboard/Resources/ModuleManifest.json`
- Upgrade dispositions and permissions: `Sources/Switchboard/Resources/UpgradeMigrationContract.json`
- Review and precedence: `Sources/Switchboard/Services/LegacyUpgradeScanner.swift`, `Sources/Switchboard/Models/ModuleStore.swift`
- Recovery and retirement: `Sources/Switchboard/Services/LegacySchedulerMigration.swift`, `Sources/Switchboard/Services/LegacyAppRetirement.swift`, `Sources/Switchboard/Services/OperationCoordinator.swift`
- Kinetics: `Sources/Switchboard/Modules/Kinetics/`, `Vendor/Kinetics/Sources/Kinetics/`
- Updates and release checks: `Sources/Switchboard/Services/UpdateInstaller.swift`, `Sources/Switchboard/Services/GitHubUpdateService.swift`, `scripts/publish-release.sh`
