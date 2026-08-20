# Switchboard

Switchboard is a single menu-bar app for small, general-purpose Mac utilities. It presents the utilities as selectable modules, keeps each module's settings and permission boundary explicit, and records migration work so a replacement can be rolled back safely.

## Current status

- The first release targets **macOS 26 on Apple silicon**.
- **Warm Corners** is the only current pilot. It opens a chosen app when the pointer rests in a screen corner and can start at login.
- The other modules are listed for planning, repair, or inventory review. They are not implemented as available Switchboard features merely because they appear in the manifest.
- Switchboard is **not installed**. The build produces a local app under `build/Switchboard.app` and deliberately does not install it.
- Public release is blocked pending Apple-issued **Developer ID Application** signing. The local `Ivo Market Dev` certificate is self-signed, has no Apple Team ID, preserves the established local identity, and produces apps that Gatekeeper rejects.

## Module selection

The app reads `Sources/Switchboard/Resources/ModuleManifest.json`. A module can be turned on only when its manifest availability is `pilot`; today that means Warm Corners only. Persisted module selection never starts Warm Corners directly: every enable or relaunch goes through the migration/status gate. If legacy settings exist, the new watcher starts only after verified evidence that the legacy watcher process is absent and its login registration is disabled. The current pilot has no production status/quiescence provider, so it remains stopped rather than risking duplicate watchers. Enabled-module choices are stored locally in UserDefaults. The Warm Corners settings are also local UserDefaults data; no cloud service is part of this pilot. Legacy Warm Corners settings do not auto-import: import waits for verified legacy-watcher quiescence, creates an exact recovery snapshot, records ledger transitions, verifies a settings round trip, and fails closed with rollback if any step fails.

The planned module list is: Kinetics, Audio Disconnect Guard, Quit on Close, Smart Wake, Mac Brightness, Mail Assistant, Copy Path, AutoInstall DMG, Claude Code URL Handler, Copy Safari URL, Local Read Connectors, Memory System, Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, and Advanced Commands.

## Products that stay separate

These standalone products are not Switchboard modules: **Market**, **School**, **Tool Dashboard**, **Vitals**, **UsageQueue**, **ReleaseRadar**, **NutrientTracker**, **Psephos**, **Tax Simulator**, and **Runway**. Each product-specific background worker stays with its owning product and belongs in that product's own DMG.

These Safari apps also stay separate: **ForceCopyPaste**, **NewTabLinks**, and **YouTube Defaults**.

Third-party utilities and maintained forks stay outside Switchboard. General Apple Shortcuts stay outside it too; only the Mac day/night brightness behavior is replaced by a native Switchboard module.

## Privacy and configuration boundary

Switchboard keeps module choices and pilot settings on this Mac. A future module must declare its configuration keys, components, and permission categories in the manifest before it is enabled. Local-read and account-connected modules must remain read-only for the sources they expose. Sensitive values, credentials, browser profiles, runtime data, and private memory are not documentation or release inputs.

## Build, test, and self-test

From `$HOME/Projects/Switchboard`:

```bash
swift test
./build.sh
```

The focused test suite currently has **35 tests**.

`./build.sh` performs a release build, checks the app metadata, signs the local app, and verifies the signature. The executable's self-test checks the manifest, pilot set, ownership separation, and Warm Corners migration contract:

```bash
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The local build requires the stable signing identity **Ivo Market Dev** and pins the existing certificate fingerprint rather than trusting its display name alone. The keychain currently has no Apple-issued `Developer ID Application` identity, so this local signature is not suitable for public distribution. A public DMG requires Apple Developer ID signing, hardened runtime, a secure timestamp, and notarization. `INSTALL=1 ./build.sh` is intentionally blocked until the Warm Corners production migration gate is approved.

## License

Switchboard source is public under the [MIT License](LICENSE). A public DMG does not exist yet; release remains blocked pending Developer ID signing and notarization.
