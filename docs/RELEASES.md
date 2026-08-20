# Release process

Switchboard currently has **no public DMG** and no public update feed. The local bundle remains not installed.

## Local continuity builds

`./build.sh` creates a local `build/Switchboard.app` and signs it with the established self-signed `Ivo Market Dev` identity. This preserves local continuity for development and verification. It is not a public distribution build: it has no Apple Team ID and Gatekeeper rejects apps signed this way.

## Public release gate

A public DMG may be produced only after every item below passes:

1. An Apple-issued `Developer ID Application` identity is available.
2. The app is signed for the hardened runtime with a secure timestamp.
3. The DMG and app are notarized, stapled, and accepted by Gatekeeper.
4. The artifact targets macOS 26 on Apple silicon (`arm64`).
5. `swift test`, the bundled self-test, and the required migration checks pass.
6. Privacy review and a Gitleaks scan pass with no exposed secrets or personal paths.
7. The immutable GitHub release artifact is created only after the preceding checks pass.

The public gate is blocked today because the keychain has no Apple-issued `Developer ID Application` identity. Do not imply that a public DMG, notarized build, or public update feed exists.

## Future update channel

An appcast or other update-feed mechanism may be documented later when an implemented, reviewed update system exists. No update feed or Sparkle integration is implemented now.
