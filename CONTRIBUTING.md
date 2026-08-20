# Contributing to Switchboard

Switchboard is a public MIT project for **macOS 26 on Apple silicon**. The catalog contains ready modules and no planned entries.

## Before you start

From the repository root, run:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The suite currently reports **105 tests in 17 suites**. The build makes a local, non-installed app, including the signed nested Kinetics companion and inert migration helper. The release script remains blocked until an Apple Developer ID certificate and the required notarization setup are available; do not add ad-hoc signing or an install step.

## Ownership boundary

Ready modules are Warm Corners, Kinetics, Audio Disconnect Guard, Quit on Close, Mac Brightness, Smart Wake core wake/network/display-lock behavior, Mail Assistant, AutoInstall DMG, Copy Safari URL, Copy Path, Local Read Connectors, Memory System, Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, and Advanced Commands. Smart Wake's privileged sleep guard remains in place, and its unresolved iMessage path is not migrated.

Switchboard has one background agent. It owns sanitized bundled command payloads and macOS Services. Command, service, and scheduler migration is recoverable and supports rollback; current migration does not delete legacy items.

Standalone products and their workers stay in their own app bundles and DMGs. Safari apps stay separate. Third-party utilities and general Apple Shortcuts remain outside Switchboard.

## Updates and releases

The update implementation discovers a published GitHub release, downloads and verifies its manifest and DMG hash, invokes the nested updater, and can roll back from a verified recovery copy. The release workflow requires Developer ID signing and notarization. There is currently no public DMG or public release.

## Issues and pull requests

Open an issue for a reproducible problem. Include the macOS version, Apple-silicon status, module and availability state, exact reproduction steps, and relevant self-test output. Do not include secrets, personal paths, private account data, or copied runtime data.

Pull requests should be narrow, explain the user-visible effect, preserve ownership boundaries, and include commands run and their results. Do not claim a public release exists.
