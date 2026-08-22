# Switchboard

Switchboard is a menu-bar control center for 17 small Mac utilities. It keeps module ownership, existing settings, permissions, migrations, and recovery state explicit instead of silently taking over unrelated software.

## Current status

- Target: macOS 26 on Apple silicon.
- Runtime: one Switchboard background agent runs enabled scheduled jobs and workers.
- Catalog: 17 ready Switchboard modules; no planned or pilot entries.
- Verification: the current suite is **158 tests in 26 suites**.
- Distribution: the Developer ID Application certificate for Team `Q2X7X86GYR` is available. The implemented updater verifies a GitHub manifest, expected team, and SHA-256 before installation. A release is public only when its notarized DMG and manifest are visible together on GitHub Releases.

## Product boundaries

The ownership source of truth is [`Sources/Switchboard/Resources/ModuleManifest.json`](Sources/Switchboard/Resources/ModuleManifest.json). The 17 modules are:

| Group | Modules |
|---|---|
| Desktop Controls | Warm Corners, Kinetics, Audio Disconnect Guard, Quit on Close, Smart Wake, Mac Brightness |
| Mail | Mail Assistant |
| Files & Links | Copy Path, AutoInstall DMG, Copy Safari URL |
| Local Data | Local Read Connectors, Memory System |
| Agent Systems | Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, Advanced Commands |

These products stay outside Switchboard:

- Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway remain standalone products. Their workers remain in their own app bundles and DMGs.
- ForceCopyPaste, NewTabLinks, and YouTube Defaults remain separate Safari apps and extensions.
- Third-party utilities, maintained forks, and general Apple Shortcuts remain separate. The two Mac brightness shortcuts are the deliberate exception: Switchboard replaces them with native Mac Brightness behavior.

## First run and launch behavior

1. A normal user launch opens the control center and presents setup/review when first-run work or legacy evidence exists.
2. A login-item or background launch stays hidden; it starts the agent and enabled modules without opening a window.
3. Switchboard scans every exact legacy component, imports its existing enabled state and settings, and records all 46 component dispositions in a private migration ledger.
4. Migration starts automatically when required permissions are ready. A module retires its standalone owner only after the replacement passes that module's real operational health check; a failure remains retryable on the next launch.
5. When macOS requires user approval, onboarding moves the exact blocked permission or module into view. Only the process that performs the protected action is shown, and an administrator prompt appears only when the requested operation actually needs privilege.

## Migration and recovery model

Migration is serialized and journaled. Every module commits independently, so one failed replacement cannot retire another module's old app. Command and Service activation is reversible. Legacy scheduler migration snapshots exact LaunchAgents or cron entries, quiesces them, verifies the replacement, and can restore the snapshot after an interrupted or failed transaction. Unresolved jobs remain active and visible as retained items; they are not hidden or silently removed.

An old app is retired only when all of these checks pass: exact canonical path, expected identity and executable, trusted signature, verified recovery archive, and replacement capability health. Only then is the app moved to the operating system Trash. The verified archive remains the recovery source.

Warm Corners uses a same-identity handoff and verifies settings, watcher health, login state, and rollback records before retirement. Kinetics preserves its existing preferences domain and keys, verifies its event tap and continuous-agent heartbeat, and retires its old login registration only after those checks pass. Mac Brightness preserves editable day and night levels in Switchboard; the old Shortcuts remain untouched because macOS does not expose their action values to the background migration.

## Permissions

Switchboard does not request blanket Full Disk Access. The onboarding list names the exact component:

- Accessibility is attributed to Switchboard, the nested Kinetics companion, or the Quit-on-Close helper as appropriate.
- Mail Assistant Full Disk Access belongs to its exact nested helper, not the outer app.
- Local Read permissions belong to the permanent external command host that runs those commands.
- App Management is requested only when a legacy app must be retired.
- Finder extension and Safari Automation permissions are requested on demand.

## Build and verify locally

From the repository root:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The build produces a local app and does not install it. Installation and updates use the canonical app location and their verified transactions.

## Updates and release workflow

The update path discovers a published GitHub release, downloads its manifest and DMG, verifies the expected version, Developer ID team, and SHA-256, then hands off to the nested updater. A verified recovery copy enables rollback if installation fails.

[`scripts/publish-release.sh`](scripts/publish-release.sh) is the release entry point. A public release requires Developer ID signing, hardened runtime, notarization and stapling, Gatekeeper checks, privacy and secret-scanning checks, the full test/self-test/migration checks, and explicit release authorization. The source tree alone is never evidence that an artifact was published.

## Source map

- App shell and launch policy: [`Sources/Switchboard/main.swift`](Sources/Switchboard/main.swift), [`Sources/Switchboard/AppDelegate.swift`](Sources/Switchboard/AppDelegate.swift), [`Sources/Switchboard/Views/`](Sources/Switchboard/Views/)
- Module ownership and enabled state: [`Sources/Switchboard/Models/ModuleDefinition.swift`](Sources/Switchboard/Models/ModuleDefinition.swift), [`Sources/Switchboard/Models/ModuleStore.swift`](Sources/Switchboard/Models/ModuleStore.swift), [`Sources/Switchboard/Resources/ModuleManifest.json`](Sources/Switchboard/Resources/ModuleManifest.json)
- Upgrade contract and scanner: [`Sources/Switchboard/Models/UpgradeMigrationContract.swift`](Sources/Switchboard/Models/UpgradeMigrationContract.swift), [`Sources/Switchboard/Resources/UpgradeMigrationContract.json`](Sources/Switchboard/Resources/UpgradeMigrationContract.json), [`Sources/Switchboard/Services/LegacyUpgradeScanner.swift`](Sources/Switchboard/Services/LegacyUpgradeScanner.swift)
- Recovery and retirement: [`Sources/Switchboard/Services/LegacyAppRetirement.swift`](Sources/Switchboard/Services/LegacyAppRetirement.swift), [`Sources/Switchboard/Services/LegacySchedulerMigration.swift`](Sources/Switchboard/Services/LegacySchedulerMigration.swift), [`Sources/Switchboard/Services/OperationCoordinator.swift`](Sources/Switchboard/Services/OperationCoordinator.swift)
- Permissions and updates: [`Sources/Switchboard/Services/PermissionOnboardingService.swift`](Sources/Switchboard/Services/PermissionOnboardingService.swift), [`Sources/Switchboard/Services/UpdateInstaller.swift`](Sources/Switchboard/Services/UpdateInstaller.swift), [`Sources/Switchboard/Services/GitHubUpdateService.swift`](Sources/Switchboard/Services/GitHubUpdateService.swift)
- Tests: [`Tests/SwitchboardTests/`](Tests/SwitchboardTests/)

## License

Switchboard source is public under the [MIT License](LICENSE).
