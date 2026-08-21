# Release and update process

## Status

The current release target is `v0.2.1`, with **139 tests in 22 suites**. The Developer ID Application certificate for Team `Q2X7X86GYR` is available. Publication is complete only when the notarized, stapled DMG and its matching update manifest are visible together on GitHub Releases.

`v0.2.1` removes the conventional Applications shortcut from the image. That link conflicted with the updater's deliberate rule that a mounted update contain exactly one app and no symbolic links.

## Local verification

Run from the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The build creates a local app and does not install it. The self-test checks the manifest, ownership boundaries, bundled commands and Services, runtime jobs, nested helpers, update metadata, and migration inventories. Migration tests cover recoverable scheduler and app retirement, Warm Corners handoff, Kinetics login continuity, permissions, and activation rollback.

## Public release gate

Before publishing an immutable GitHub release, all of these must have current evidence:

1. Developer ID Application signing with Team `Q2X7X86GYR`.
2. Hardened runtime and secure timestamp on the app and nested code.
3. Notarization, stapling, and Gatekeeper acceptance for the DMG.
4. macOS 26 on Apple silicon validation.
5. The complete test suite, self-test, and migration checks.
6. Privacy, secret-scanning, and artifact-content checks.
7. Explicit authorization to publish.

Until then, describe the build as local and the release machinery as implemented; do not present a download or update feed as available.

## Update behavior

The update coordinator discovers a published GitHub release and reads its signed manifest. The updater checks the expected version, architecture, bundle identity, Developer ID Team, code signature, and SHA-256 of the DMG before installation. It stages the candidate, keeps a verified recovery copy of the current app, and hands off to the nested updater. A failed or interrupted transaction can roll back from that recovery copy.

## Release entry point and source map

- Release script: `scripts/publish-release.sh`
- GitHub discovery and manifest verification: `Sources/Switchboard/Services/GitHubUpdateService.swift`
- Install, recovery, and rollback: `Sources/Switchboard/Services/UpdateInstaller.swift`, `Sources/Switchboard/Services/UpdateCoordinator.swift`
- Release-related module payloads: `Payloads/Modules/systems.repository-release/`
- Tests: `Tests/SwitchboardTests/UpdateInstallerTests.swift`, `Tests/SwitchboardTests/GitHubUpdateServiceTests.swift`
