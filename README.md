# Switchboard

Switchboard is one menu-bar app for small Mac utilities. It presents each utility as a module, keeps its settings and permissions explicit, and records migrations so a replaced command or service can be restored safely.

## Current status

- The target is **macOS 26 on Apple silicon**.
- One Switchboard background agent runs the enabled schedules and module workers.
- Ready modules are **Warm Corners**, **Audio Disconnect Guard**, **Quit on Close**, **Mac Brightness**, **Smart Wake**, **Mail Assistant**, **AutoInstall DMG**, **Copy Safari URL**, **Copy Path**, **Local Read Connectors**, **Memory System**, **Codex & System Improvement**, **Repository & Release Automation**, **NotebookLM Sync**, **Backup Coverage Audit**, and **Advanced Commands**.
- Planned modules are **Kinetics**. Smart Wake core wake/network/display-lock behavior is ready; its privileged sleep guard remains in place and iMessage remains unresolved rather than being migrated.
- The app bundles sanitized command payloads, macOS Services, and the Copy Path Finder Sync extension. Activating a command, service, extension, or scheduler migrates it through a recoverable transaction with rollback support. The current workflow does not delete legacy items or the existing Copy Path host app.
- A local build is not installed. There is no current public DMG or public release.

## Module catalog and boundaries

The catalog in `Sources/Switchboard/Resources/ModuleManifest.json` is the source of truth. `ready` modules can be enabled; `planned` modules are reserved for later implementation. Warm Corners opens a chosen app when the pointer rests in a screen corner and can start at login. Module changes use their migration and status gates rather than silently replacing existing workers.

Switchboard owns one background agent, its bundled payloads, and its Services. Standalone products and their workers remain in their own app bundles and DMGs. Safari apps remain separate. Third-party utilities and general Apple Shortcuts are excluded; Switchboard does not absorb them.

| Category | Contents |
|---|---|
| Standalone products | Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, Runway |
| Separate Safari apps | ForceCopyPaste, NewTabLinks, YouTube Defaults |
| Planned Switchboard modules | Kinetics |

## Updates and release status

The implemented update path discovers a real published GitHub release, downloads the signed update manifest and DMG, verifies the SHA-256 hash, runs the nested updater, and supports rollback from a verified recovery copy. This is an implemented local update mechanism, not a claim that a public release exists.

The release script builds a Developer ID-signed, notarized, stapled DMG and publishes an immutable GitHub release only after verification. It is currently blocked because the required Apple Developer ID certificate is absent. No public DMG or release is available today.

## Privacy and configuration boundary

Settings and module choices stay on this Mac. Local-read and account-connected modules remain read-only for the sources they expose. Credentials, browser profiles, runtime data, and private memory are never documentation or release inputs.

## Build, test, and self-test

From the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The test suite currently has **98 tests in 16 suites**. `./build.sh` creates a local app but does not install it; it stops when the pinned local signing identity is unavailable. The self-test validates the manifest, ownership boundaries, bundled commands and Services, runtime jobs, and migration inventories. The updater has its own focused test suite.

## License

Switchboard source is public under the [MIT License](LICENSE). A public DMG and public release do not exist yet.
