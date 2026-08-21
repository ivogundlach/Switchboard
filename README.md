# Switchboard

Switchboard is one menu-bar app for small Mac utilities. It presents each utility as a module, keeps its settings and permissions explicit, and records migrations so a replaced command or service can be restored safely.

## Current status

- The target is **macOS 26 on Apple silicon**.
- One Switchboard background agent runs the enabled schedules and module workers.
- There are **17 ready modules** and no planned or pilot modules. Warm Corners uses a same-identity handoff, exact settings verification, hidden replacement-health check, recovery archives, and Trash-based retirement. Smart Wake core wake/network/display-lock behavior is ready; its privileged sleep guard remains in place and iMessage remains unresolved rather than being migrated.
- The app bundles sanitized command payloads, macOS Services, and the Copy Path Finder Sync extension. Generic `LegacySchedulerMigration` retires only legacy LaunchAgents and exact cron entries, with recovery data and rollback. Kinetics separately retires its legacy login registration. There is no generic app-bundle retirement yet, so the existing Copy Path host app remains. Copy Path activates only its exact bundled extension identity and rolls back an immediate enable failure.
- The repository does not auto-install local builds. There is no current public DMG or public release.

## Module catalog and boundaries

The catalog in `Sources/Switchboard/Resources/ModuleManifest.json` is the source of truth. It currently contains 17 ready modules and no planned or pilot modules. Warm Corners is connected through a production migration transaction: the signed compatibility bridge quiesces the old watcher, Switchboard imports and verifies the authoritative settings, the hidden replacement proves its watcher is running, and only then is the old app archived and moved to Trash. Settings are otherwise preserved by reusing the same identity and canonical state when possible, or by a module-specific migration; there is no universal settings importer.

Switchboard owns one background agent, its bundled payloads, and its Services. Standalone products and their workers remain in their own app bundles and DMGs. Safari apps remain separate. Third-party utilities and general Apple Shortcuts are excluded; Switchboard does not absorb them.

| Category | Contents |
|---|---|
| Standalone products | Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, Runway |
| Separate Safari apps | ForceCopyPaste, NewTabLinks, YouTube Defaults |
| Planned Switchboard modules | None |

## Updates and release status

The implemented update path discovers a real published GitHub release, downloads the signed update manifest and DMG, verifies the SHA-256 hash, runs the nested updater, and supports rollback from a verified recovery copy. This is an implemented local update mechanism, not a claim that a public release exists.

The release script builds a Developer ID-signed, notarized, stapled DMG and publishes an immutable GitHub release only after verification. The Developer ID Application certificate for Team `Q2X7X86GYR` is locally available, and a disposable full nested-app Developer ID signing, secure-timestamp, and strict verification passed. The GitHub updater and release script are implemented, but notarization and publishing have not been run; no public DMG or release is available today. Public publication still requires notarization, Gatekeeper and privacy checks, and explicit release authorization.

The update manifest identifies the release and DMG, including the expected team and SHA-256 hash. The updater verifies those values before installing and keeps a verified recovery copy so it can roll back to the previous version if the update fails.

## Privacy and configuration boundary

Settings and module choices stay on this Mac. Local-read and account-connected modules remain read-only for the sources they expose. Credentials, browser profiles, runtime data, and private memory are never documentation or release inputs.

## Build, test, and self-test

From the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The test suite currently has **107 tests in 18 suites**. `./build.sh` creates a local app, including the signed nested Kinetics companion and an inert migration-only LoginLauncher bundle that is never registered, but does not install it. Installation uses the verified Developer ID path or updater transaction. The self-test validates the manifest, ownership boundaries, bundled commands and Services, runtime jobs, nested companion/helper identity, and migration inventories. The updater has its own focused test suite.

## License

Switchboard source is public under the [MIT License](LICENSE). A public DMG and public release do not exist yet.
