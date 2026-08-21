# Contributing to Switchboard

Switchboard is a public MIT project for macOS 26 on Apple silicon. The catalog has 17 ready modules and one background agent.

## Before opening a change

From the repository root, run:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The current verification record is **142 tests in 22 suites**. The build creates a local, non-installed app. Do not add an install step to the normal build.

## Ownership boundary

The manifest in `Sources/Switchboard/Resources/ModuleManifest.json` is the source of truth for the 17 modules. Standalone products and their workers remain in their own bundles and DMGs. Safari apps remain separate. Third-party tools, forks, and general Apple Shortcuts remain separate; the two Mac brightness shortcuts are replaced by native Switchboard behavior.

Preserve these migration rules when changing code:

- Normal launches show setup/review; login/background launches stay hidden.
- Existing legacy settings/state win once, followed by one user confirmation.
- The upgrade contract is per component: `migrate`, `retain`, or `alreadyRetired`.
- Permission onboarding is progressive and exact. Do not add blanket Full Disk Access. Attribute Accessibility to the actor that needs it; Mail Assistant FDA belongs to its exact nested helper; Local Read permissions belong to its permanent external command host; App Management appears only for old-app retirement.
- Administrator prompts happen only at the privileged action.
- Command and Service activation is reversible; scheduler migration is recoverable; unresolved jobs stay active and visible.
- Retire old apps only after exact path and identity checks, a verified archive, and replacement capability health; then move them to Trash.
- Kinetics keeps its existing preferences domain and keys and proves its event tap and agent heartbeat before retiring the old login registration.

## Pull requests and issues

Keep changes narrow and describe the user-visible effect. Include commands run and their results. Add or update focused tests when behavior or a safety gate changes. Do not include secrets, personal paths, account names, local usernames, private settings, or copied runtime data in issues, pull requests, logs, or screenshots.

## Release contributions

The release entry point is `scripts/publish-release.sh`. The updater verifies the GitHub manifest, Developer ID Team `Q2X7X86GYR`, and SHA-256 before installation and retains a recovery copy for rollback. Notarization, stapling, Gatekeeper, privacy checks, and explicit authorization are required before publication. A release is public only when its verified assets are visible together on GitHub Releases.

## Source map

- App shell and launch policy: `Sources/Switchboard/main.swift`, `Sources/Switchboard/AppDelegate.swift`, `Sources/Switchboard/Views/`
- Catalog and state: `Sources/Switchboard/Models/`, `Sources/Switchboard/Resources/ModuleManifest.json`
- Migration and permissions: `Sources/Switchboard/Services/LegacyUpgradeScanner.swift`, `Sources/Switchboard/Models/UpgradeMigrationContract.swift`, `Sources/Switchboard/Services/PermissionOnboardingService.swift`
- Recovery and retirement: `Sources/Switchboard/Services/LegacySchedulerMigration.swift`, `Sources/Switchboard/Services/LegacyAppRetirement.swift`, `Sources/Switchboard/Services/OperationCoordinator.swift`
- Verification: `Sources/Switchboard/Services/SelfTest.swift`, `Tests/SwitchboardTests/`
