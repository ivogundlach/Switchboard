# Release and update process

## Status

The current release target is `v0.2.5`, with **172 tests in 29 suites**. The Developer ID Application certificate for Team `Q2X7X86GYR` is available. Publication is complete only when the notarized, stapled DMG and its matching update manifest are visible together on GitHub Releases.

`v0.2.5` automatically inventories and migrates detected standalone utilities, commands, Services, and background jobs after their exact permissions are ready. It preserves imported settings and enabled state, records all 46 component outcomes, verifies every enabled module through an explicit operational probe, and retires an old owner only after that probe passes. Onboarding moves the exact permission or module failure into view. Bundled scheduled workers now execute their bundled first-party code instead of depending on old standalone installation paths. Live migration validation also covers macOS's alternate missing-file error, atomic command replacement, recoverable first-party symlink takeover, stubborn legacy-app termination, approved-but-unloaded agent repair, shell-script process identity, cold Smart Wake startup, repair of partially imported command ownership, and stable historical signing requirements before public release.

The bundled weekly system-improvement worker now accepts routine signed Codex 0.x updates from the verified OpenAI Developer ID app instead of pinning one temporary binary hash, and it follows Codex's fixed owner-only `auth.json` layout for unattended isolated runs. It still fails closed for an altered signature, unexpected publisher or executable identity, downgrade below 0.147, the future 1.0 compatibility boundary, missing security-critical command options, a binary that changes during verification, expiring authentication, or authentication that changes during a run.
Its read-only transcript status collector also allows a bounded 60-second startup window so concurrent due jobs on agent launch do not create a false weekly-audit failure.

## Local verification

Run from the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The build creates a local app and does not install it. The self-test checks the manifest, ownership boundaries, bundled commands and Services, runtime jobs, nested helpers, update metadata, and migration inventories. Migration tests cover recoverable scheduler and app retirement, Warm Corners handoff, Kinetics login continuity, permissions, and activation rollback.

The release app is made runtime-read-only after its final signature. This prevents bundled Python tools from creating import caches inside signed Resources and invalidating the installed Developer ID seal; all mutable module state remains outside the app in its established user-state locations.

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

A clean exact tag can be notarized for installation testing without publishing by supplying `--output-dir` and omitting `--publish`. The same tag is published only after that installed build passes migration and health verification on the current Mac.

## Update behavior

The update coordinator discovers a published GitHub release and reads its signed manifest. The updater checks the expected version, architecture, bundle identity, Developer ID Team, code signature, and SHA-256 of the DMG before installation. It stages the candidate, keeps a verified recovery copy of the current app, and hands off to the nested updater. A failed or interrupted transaction can roll back from that recovery copy.

## Release entry point and source map

- Release script: `scripts/publish-release.sh`
- GitHub discovery and manifest verification: `Sources/Switchboard/Services/GitHubUpdateService.swift`
- Install, recovery, and rollback: `Sources/Switchboard/Services/UpdateInstaller.swift`, `Sources/Switchboard/Services/UpdateCoordinator.swift`
- Release-related module payloads: `Payloads/Modules/systems.repository-release/`
- Tests: `Tests/SwitchboardTests/UpdateInstallerTests.swift`, `Tests/SwitchboardTests/GitHubUpdateServiceTests.swift`
