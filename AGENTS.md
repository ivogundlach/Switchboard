# Switchboard agent rules

## Source map and ownership

- `Sources/Switchboard/main.swift`, `AppDelegate.swift`, and `Views/` own the app shell and presentation.
- `Sources/Switchboard/Models/ModuleDefinition.swift` and `ModuleStore.swift` own manifest decoding, module selection, and local enabled-state storage.
- `Sources/Switchboard/Modules/WarmCorners/` owns the only current pilot runtime and settings.
- `Sources/Switchboard/Services/MigrationLedger.swift` owns recoverable migration state; `Modules/WarmCorners/WarmCornersMigrationService.swift` owns the guarded legacy import; `OperationCoordinator.swift` serializes operations; `CanonicalInstallGate.swift` identifies the canonical installed path; `SelfTest.swift` owns structural checks.
- `Sources/Switchboard/Resources/ModuleManifest.json` is the ownership and availability manifest. `WarmCornersMigrationContract.json` is the pilot's migration contract.
- `Tests/SwitchboardTests/` owns focused migration-ledger tests. `build.sh` owns the reproducible local app build and signing path.

Standalone products remain separate: Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway. Their workers belong in their own DMGs. ForceCopyPaste, NewTabLinks, and YouTube Defaults remain separate Safari apps. Third-party utilities, maintained forks, and general Apple Shortcuts are not Switchboard modules.

## Required commands

Run from `$HOME/Projects/Switchboard`:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The focused test suite currently has **35 tests**.

The local build must use the stable signing identity `Ivo Market Dev` and pin the existing certificate fingerprint, not only the display name. It is self-signed, has no Apple Team ID, preserves the established local identity, and its apps are rejected by Gatekeeper. Do not substitute an ad-hoc signature, a personal temporary identity, or an unsigned app. The keychain currently has no Apple-issued `Developer ID Application` identity. A public DMG may be released only after Apple Developer ID signing, hardened runtime, a secure timestamp, and notarization are all present. Do not add an install shortcut: `INSTALL=1` remains blocked until the Warm Corners production migration gate is approved.

## Safety gates

- A permission experiment stops at the first unexpected prompt, denial, identity change, or behavior change. Record the result and stop; do not work around it by broadening permissions.
- Do not mutate installed apps, LaunchAgents, user settings, or other system state without current explicit authority for that action.
- Do not mutate GitHub, remotes, releases, or other external services without current explicit authority.
- Preserve a dirty repository. Inspect existing changes, do not overwrite or revert them, and keep unrelated work out of the change.
- Keep migration work recoverable: verify the replacement and its health before retiring anything, and retain the signed restore source outside Trash.
- Legacy Warm Corners settings do not auto-import. Import requires verified legacy-watcher quiescence, an exact recovery snapshot, ordered ledger transitions, round-trip verification, and fail-closed rollback on failure.
- Partial global/local monitor registration fails closed. Target apps must be valid executable, non-symlink `.app` bundles before a corner action can launch them.
- `Sources/Switchboard/Resources/InventoryBaseline.json` is locked; self-test requires exact equality between it and the manifest's discovered inventory.
- Persisted module selection never starts Warm Corners directly. Every enable or relaunch must pass the migration/status gate.
- If legacy settings exist, start the new watcher only with verified evidence that the legacy watcher process is absent and its login registration is disabled. The current pilot has no production status/quiescence provider, so it remains stopped rather than risking duplicate watchers.
- Keep the source public under the MIT License, but do not imply that a public DMG exists while the Developer ID release gate is blocked.
