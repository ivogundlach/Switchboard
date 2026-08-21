# Contributing to Switchboard

Switchboard is a public MIT project for **macOS 26 on Apple silicon**. The catalog contains ready modules and no planned entries.

## Before you start

From the repository root, run:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The suite currently reports **111 tests in 19 suites**. The build makes a local, non-installed app, including the signed nested Kinetics companion and inert migration helper. A signed local installation and Warm Corners migration verification have also passed. `scripts/publish-release.sh` is implemented, and the Developer ID certificate is available, but notarization and public release publishing have not been run; do not add ad-hoc signing or an install step to the normal build.

## Ownership boundary

The 17 ready modules are Warm Corners, Kinetics, Audio Disconnect Guard, Quit on Close, Mac Brightness, Smart Wake core wake/network/display-lock behavior, Mail Assistant, AutoInstall DMG, Copy Safari URL, Copy Path, Local Read Connectors, Memory System, Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, and Advanced Commands. Warm Corners has passed its verified migration. Smart Wake's privileged sleep guard remains in place, and its unresolved iMessage path is not migrated.

Switchboard has one background agent. It owns sanitized bundled command payloads and macOS Services. Generic command, service, and scheduler migration is recoverable and supports rollback; it does not delete legacy apps. Warm Corners specifically archives and moves its bridge app to Trash only after verified health.

Standalone products and their workers stay in their own app bundles and DMGs. Safari apps stay separate. Third-party utilities and general Apple Shortcuts remain outside Switchboard.

## Updates and releases

The update implementation discovers a published GitHub release, downloads and verifies its manifest and DMG hash, invokes the nested updater, and can roll back from a verified recovery copy. `scripts/publish-release.sh` is implemented and requires Developer ID signing and notarization. Notarization and public release publishing have not been run; there is currently no public DMG or public release.

## Issues and pull requests

Open an issue for a reproducible problem. Include the macOS version, Apple-silicon status, module and availability state, exact reproduction steps, and relevant self-test output. Do not include secrets, personal paths, private account data, or copied runtime data.

Pull requests should be narrow, explain the user-visible effect, preserve ownership boundaries, and include commands run and their results. Do not claim a public release exists.
