# Release process

There is currently **no public DMG and no public release**. A local build is not installed.

## Local build and checks

From the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The current test suite has **105 tests in 17 suites**. `./build.sh` creates the local app, including the signed nested Kinetics companion and inert migration helper, and deliberately does not install it. The Developer ID Application certificate for Team `Q2X7X86GYR` is locally available. A disposable full nested-app Developer ID signing, secure-timestamp, and strict verification passed; this does not mean a public release has been notarized or published.

## Implemented update path

Switchboard can discover a real published GitHub release, download its update manifest and DMG, verify the SHA-256 hash, invoke the nested updater, and roll back to a verified recovery copy. This implementation does not imply that a public release is available now.

## Public release gate

A public DMG may be produced only after all of these pass:

1. Apple Developer ID Application signing is available.
2. The app uses hardened runtime and a secure timestamp.
3. The DMG and app are notarized, stapled, and accepted by Gatekeeper.
4. The artifact targets macOS 26 on Apple silicon.
5. `swift test`, the self-test, and migration checks pass.
6. Privacy and secret-scanning checks pass.
7. The immutable GitHub release is created only after the preceding checks.

The certificate gate is no longer blocked. Notarization and publishing have not been run, so do not describe a public DMG, public release, or update feed as available. Public publication additionally requires Gatekeeper and privacy checks plus explicit release authorization.
