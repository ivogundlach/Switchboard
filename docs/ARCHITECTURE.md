# Switchboard architecture

Switchboard is a menu-bar app with a manifest-driven module catalog for macOS 26 on Apple silicon. One background agent runs enabled schedules and workers.

## App shell and catalog

`Sources/Switchboard/main.swift` handles self-test or starts the AppKit app. `AppDelegate.swift` owns setup. `Views/` owns the menu-bar interface. `Models/ModuleDefinition.swift` defines module ownership and availability; `Models/ModuleStore.swift` loads the manifest and routes every enable or relaunch through the migration/status gate.

There are 17 ready modules and no planned or pilot modules. Warm Corners has a production same-identity handoff and recoverable retirement transaction. Kinetics is a signed nested companion at `Contents/Resources/Companions/Kinetics.app`; the Switchboard agent owns its one continuous runtime job and passes `--login`. A separate inert migration-only LoginLauncher bundle is placed at the outer app's `Contents/Library/LoginItems` path for exact SMAppService identity continuity, but it is never registered or launched. Smart Wake's privileged sleep guard remains separately retained because it consumes the existing user-state lease; iMessage remains unresolved and is not migrated.

Standalone products and their workers remain in their own bundles and DMGs. Safari apps remain separate. Third-party utilities and general Apple Shortcuts are outside this catalog.

## Agent, payloads, and Services

The single Switchboard background agent schedules enabled work. The app bundle carries sanitized command payloads, macOS Services, and the Copy Path Finder Sync extension. Activation is serialized and ownership-checked; it never silently absorbs a standalone worker or Safari app.

## Migration and recovery

`Services/OperationCoordinator.swift` allows one managed update, migration, restore, module transition, or helper change at a time. Command and service migration records an ordered transaction, preserves recovery data, verifies the replacement, and supports rollback. Generic `LegacySchedulerMigration` retires only legacy LaunchAgents and exact cron entries, with recovery. Kinetics separately retires its legacy login registration. No generic app-bundle retirement exists yet, so the existing Copy Path host app remains.

Settings preservation uses same-identity/canonical-state reuse when available or a module-specific migration; there is no universal importer. Warm Corners verifies the old bridge identity and settings hash, registers Switchboard's login item before handoff, journals rollback state, quiesces the old login item and watcher, imports authoritative bytes, starts Switchboard hidden, verifies both event monitors, then archives and moves the bridge app to Trash. Incomplete transactions reconcile before normal AppKit startup.

## Updates

The update services discover a published GitHub release, download the signed manifest and DMG, verify the release, DMG, team, and SHA-256 values, launch the nested updater, and restore the previous version from a verified recovery copy when rollback is needed. The GitHub updater and release script are implemented. The Developer ID Application certificate for Team `Q2X7X86GYR` is locally available, and disposable full nested-app signing, secure-timestamp, and strict verification passed; notarization and publishing have not been run, so no public DMG or release exists. Public publication still requires notarization, Gatekeeper, privacy checks, and explicit release authorization.

## Self-test

`Services/SelfTest.swift` and the manifest validator check resources, schema, unique IDs, ready/planned availability, ownership boundaries, bundled commands and Services, runtime jobs, the nested Kinetics companion/helper, and migration inventories. The updater is verified by its focused tests. The current suite has **107 tests in 18 suites**.
