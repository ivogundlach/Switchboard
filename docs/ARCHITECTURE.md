# Switchboard architecture

Switchboard is a menu-bar app with a manifest-driven module catalog for macOS 26 on Apple silicon. One background agent runs enabled schedules and workers.

## App shell and catalog

`Sources/Switchboard/main.swift` handles self-test or starts the AppKit app. `AppDelegate.swift` owns setup. `Views/` owns the menu-bar interface. `Models/ModuleDefinition.swift` defines module ownership and availability; `Models/ModuleStore.swift` loads the manifest and routes every enable or relaunch through the migration/status gate.

Ready modules are Warm Corners, Audio Disconnect Guard, Quit on Close, Mac Brightness, Mail Assistant, AutoInstall DMG, Copy Safari URL, Local Read Connectors, Memory System, Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, and Advanced Commands. Planned modules are Kinetics, Smart Wake, and Copy Path. Planned entries are not enabled features.

Standalone products and their workers remain in their own bundles and DMGs. Safari apps remain separate. Third-party utilities and general Apple Shortcuts are outside this catalog.

## Agent, payloads, and Services

The single Switchboard background agent schedules enabled work. The app bundle carries sanitized command payloads and macOS Services. Activation is serialized and ownership-checked; it never silently absorbs a standalone worker or Safari app.

## Migration and recovery

`Services/OperationCoordinator.swift` allows one managed update, migration, restore, module transition, or helper change at a time. Command, service, and scheduler migration records an ordered transaction, preserves recovery data, verifies the replacement, and supports rollback. The current migration path does not delete legacy items.

Warm Corners additionally requires verified legacy-watcher quiescence before importing settings. It snapshots the exact settings bytes, verifies a round trip, and fails closed with rollback if a step fails.

## Updates

The update services discover a published GitHub release, download the signed manifest and DMG, verify the SHA-256 hash, launch the nested updater, and restore the previous version from a verified recovery copy when rollback is needed.

## Self-test

`Services/SelfTest.swift` and the manifest validator check resources, schema, unique IDs, ready/planned availability, ownership boundaries, bundled commands and Services, runtime jobs, and migration inventories. The updater is verified by its focused tests. The current suite has **96 tests in 16 suites**.
