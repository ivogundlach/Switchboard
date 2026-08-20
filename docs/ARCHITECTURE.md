# Switchboard architecture

Switchboard is a menu-bar app with a manifest-driven module catalog. The first release targets **macOS 26 on Apple silicon**. Only **Warm Corners** is a pilot; other entries are planned, repair-required, or classification-required.

## App shell

`Sources/Switchboard/main.swift` handles the self-test command or starts the AppKit application. `AppDelegate.swift` owns application setup. `Views/` owns the menu-bar interface, module groups, detail views, and shared visual style.

## Manifest and selection

`Models/ModuleDefinition.swift` defines the decoded manifest types, module ownership, availability states, standalone products, and separate Safari apps. `Models/ModuleStore.swift` loads `ModuleManifest.json`, keeps only pilot modules enabled, persists enabled IDs in local UserDefaults, and routes every enable or relaunch through the migration/status gate rather than starting Warm Corners directly.

The manifest states are:

- `pilot`: can be enabled; currently only Warm Corners.
- `planned`: listed for later implementation.
- `repair-required`: listed but blocked pending repair.
- `classification-required`: listed pending ownership or inventory review.

Standalone products and Safari apps are validated as disjoint from Switchboard modules. Their workers and extension packaging remain outside this app.

## Warm Corners pilot

`Modules/WarmCorners/` owns the pilot runtime, corner settings, dwell countdown, pointer hit and release behavior, pause state, and start-at-login setting. Partial global/local monitor registration fails closed. A target app must be a valid executable, non-symlink `.app` bundle before it can launch.

`WarmCornersMigrationService.swift` does not auto-import legacy settings. It requires verified legacy-watcher quiescence, snapshots the exact legacy bytes, records ordered ledger transitions, verifies a settings round trip, and fails closed with rollback when a migration step fails. The migration contract defines the health checks, stabilization triggers, and recoverable retirement path.

When legacy settings exist, the new watcher starts only after verified evidence that the legacy watcher process is absent and its login registration is disabled. The current pilot has no production status/quiescence provider, so the runtime remains stopped rather than risking duplicate watchers.

## Coordination and recovery

`Services/OperationCoordinator.swift` allows one managed update, migration, restore, module transition, or privileged-helper change at a time. `MigrationLedger.swift` records ordered migration states and events, persists safe recovery records, detects interrupted states, and supports rollback after replacement starts. Its allowed path is planned → preflighted → quiesced → replacement installed → replacement registered → health verified → stabilizing → retired, with rollback paths from interrupted replacement stages.

## Self-test

`Services/SelfTest.swift` and the manifest validator check resources, schema, unique module IDs, the Warm Corners-only pilot set, standalone and Safari ownership boundaries, shortcut boundaries, owner references, and required standalone worker ownership. `InventoryBaseline.json` is locked, and self-test requires exact equality between the baseline and the manifest's module, schedule, command, service, standalone, Safari, and disposition inventories. `Tests/SwitchboardTests/` currently contains 35 focused tests covering ledger transitions and recovery, module selection, settings compatibility, dwell behavior, and related safety cases.
