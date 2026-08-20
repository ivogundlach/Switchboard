# Release process

There is currently **no public DMG and no public release**. A local build is not installed.

## Local build and checks

From the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The current test suite has **98 tests in 16 suites**. `./build.sh` creates the local app and deliberately does not install it. It remains blocked when the required Apple Developer ID certificate is absent.

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

The gate is blocked today because the required Developer ID certificate is absent. Do not describe a public DMG, public release, or update feed as available.
