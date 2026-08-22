# Switchboard architecture

Switchboard is a manifest-driven menu-bar app for macOS 26 on Apple silicon. One background agent owns enabled scheduled jobs and module workers. The catalog currently contains 17 ready modules.

## Runtime layers

1. **App shell.** `Sources/Switchboard/main.swift` selects self-test, migration, background, or AppKit mode. `Sources/Switchboard/AppDelegate.swift` applies launch policy: normal launches show the control center; login and explicit background launches stay hidden.
2. **Control center.** `Sources/Switchboard/Views/` presents module status, setup/review, permission readiness, migration results, and updates.
3. **Manifest and state.** `Models/ModuleDefinition.swift` and `Models/ModuleStore.swift` decode the manifest, persist enabled module IDs, and route activation through the migration/status gate.
4. **Agent and payloads.** The single agent runs enabled jobs. Sanitized commands and macOS Services are copied from the bundle through reversible, ownership-checked activation transactions. The Copy Path Finder extension is bundled but remains an extension component.
5. **Separate products.** Standalone products and their workers remain in their own DMGs. Safari apps remain separate. Third-party tools and general Apple Shortcuts are outside this runtime; only the two Mac brightness shortcuts are replaced by native Switchboard behavior.

## First-run and state precedence

On every launch, `LegacyUpgradeScanner` builds an exact-component inventory. Existing legacy state and settings take precedence once; module contracts record what was imported, and `AutomaticUpgradeStatus` stores a private ledger covering every component. Migration starts automatically when its exact permission gates are ready. A login/background launch remains hidden, performs the same safe migration attempt, and leaves any user-approval blocker for the next visible onboarding session.

The review is intentionally explicit: every detected component is classified `migrate`, `retain`, or `alreadyRetired`. A retained or unresolved job stays active and visible. A component is never removed merely because another component in its module migrated.

## Permission architecture

`PermissionOnboardingService` turns the selected component contract into a progressive checklist. It tests or requests only the exact subject:

- Accessibility may belong to Switchboard, the nested Kinetics companion, or the Quit-on-Close helper.
- Mail Assistant Full Disk Access belongs to the exact nested Mail Assistant helper.
- Local Read permissions belong to the permanent external command host that executes those commands.
- App Management is listed only when an old app bundle is eligible for retirement.
- Finder extension and Safari Automation prompts are on demand.

There is no blanket Full Disk Access request. Administrator approval is deferred until a concrete install or other privileged action needs it.

## Migration transaction

Execution uses one global lock and a separate durable transaction per module. A module commits only after its own replacement passes an explicit operational probe, so a failure cannot retire a different module's legacy app.

`OperationCoordinator` serializes migration, restore, update, and helper changes. A selected component follows this shape:

1. Record intent and acquire the execution lock.
2. Validate exact identity and quiesce a running legacy app when needed.
3. Activate the Switchboard command, Service, scheduler, or companion through its reversible transaction.
4. Verify replacement capability health.
5. Retire only the components whose contract says `migrate`; retain unresolved or explicitly retained components.
6. Refresh the review and keep a visible result for every module.

Legacy scheduler migration snapshots exact LaunchAgents and cron entries, removes only the exact active entry, and persists a recovery record. Rollback restores the verified snapshot. Command and Service activation keeps an owned backup and restores it when disabled or when activation fails.

Old app retirement is contract-driven. `LegacyAppRetirement` requires the exact canonical path, bundle identity and executable, trusted signing identity, a digest-verified recovery archive, and a healthy replacement before moving the original app to Trash. The archive is retained as the restore source.

## Module-specific handoffs

Warm Corners uses a same-identity compatibility bridge. It quiesces the old watcher, imports authoritative settings, registers Switchboard's login item, verifies the replacement watcher and login state, and finalizes only after a rollback journal is complete.

Kinetics is a signed nested companion at `Contents/Resources/Companions/Kinetics.app`. The Switchboard agent owns its continuous job and passes the login mode. The migration-only LoginLauncher bundle exists solely to preserve exact login-item identity during recovery; it is inert and never registered or launched. `KineticsUpgradeHandoff` writes intent before stopping the old process, binds health to an unpredictable migration nonce, and restores the prior selection and old hidden process after an interrupted pre-health handoff. Kinetics keeps the legacy preferences domain and keys, then requires five consecutive Accessibility, event-tap, exact-process, and agent-heartbeat checks before retiring the old login registration. If a later interruption makes that retirement uncertain, Switchboard keeps the proven replacement selected instead of disabling both startup paths.

Smart Wake retains its privileged sleep guard when it still owns the user-state lease. Its unresolved iMessage job remains active and visible rather than being guessed into a migration.

## Updates

The update coordinator discovers a published GitHub release. The updater verifies the manifest, expected version, Developer ID Team `Q2X7X86GYR`, architecture, signature, and SHA-256 before handing off to the nested updater. A verified recovery copy supports rollback across crashes and failed installs. The implementation exists; notarization and public publication are not claimed until their release gates have evidence.

## Source map

| Concern | Source |
|---|---|
| Launch and UI | `Sources/Switchboard/main.swift`, `Sources/Switchboard/AppDelegate.swift`, `Sources/Switchboard/Views/` |
| Catalog and state | `Sources/Switchboard/Models/ModuleDefinition.swift`, `Sources/Switchboard/Models/ModuleStore.swift`, `Sources/Switchboard/Resources/ModuleManifest.json` |
| Contracts and review | `Sources/Switchboard/Models/UpgradeMigrationContract.swift`, `Sources/Switchboard/Resources/UpgradeMigrationContract.json`, `Sources/Switchboard/Services/LegacyUpgradeScanner.swift` |
| Activation and recovery | `Sources/Switchboard/Services/BundledCommandActivation.swift`, `Sources/Switchboard/Services/BundledServiceActivation.swift`, `Sources/Switchboard/Services/LegacySchedulerMigration.swift`, `Sources/Switchboard/Services/LegacyAppRetirement.swift` |
| Permissions and health | `Sources/Switchboard/Services/PermissionOnboardingService.swift`, `Sources/Switchboard/Services/ReplacementHealthService.swift`, `Sources/Switchboard/Services/KineticsUpgradeHandoff.swift` |
| Updates and validation | `Sources/Switchboard/Services/UpdateInstaller.swift`, `Sources/Switchboard/Services/GitHubUpdateService.swift`, `Sources/Switchboard/Services/SelfTest.swift` |
