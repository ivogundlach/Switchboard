# Switchboard decisions

These boundaries describe the current product, not a promise that every catalog entry is enabled.

## Product and module boundary

Switchboard is one menu-bar app for general-purpose Mac utilities with one background agent. There are 16 ready modules and no planned modules. Warm Corners remains a pilot migration whose current path is fail-closed and whose `INSTALL=1` path remains blocked. Kinetics is ready as a signed nested companion owned by one continuous Switchboard agent job. A separate inert migration-only LoginLauncher bundle preserves exact SMAppService identity for recovery, but is never registered or launched. Smart Wake core wake/network/display-lock behavior is ready; its privileged sleep guard remains outside generic migration because it consumes the same user-state lease, while iMessage remains unresolved and is not migrated. Copy Path is a bundled ready module.

## Bundled operations

Sanitized command payloads, macOS Services, and the Copy Path Finder Sync extension ship inside the Switchboard bundle. Generic `LegacySchedulerMigration` retires only legacy LaunchAgents and exact cron entries, with recovery and rollback. Kinetics separately retires its legacy login registration. No generic app-bundle retirement exists yet, so the existing Copy Path host app remains. Copy Path uses its exact bundled extension identity and reverses an immediate activation failure. Settings are preserved through same-identity/canonical-state reuse or a module-specific migration, not a universal importer.

## Separate products and integrations

Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway remain standalone products; their workers remain in their own app bundles and DMGs. ForceCopyPaste, NewTabLinks, and YouTube Defaults remain separate Safari apps. Third-party utilities and general Apple Shortcuts stay outside Switchboard.

## Updates and distribution

The implemented updater discovers real published GitHub releases, downloads the update manifest and DMG, verifies the SHA-256 hash, runs a nested updater, and supports rollback from a verified recovery copy.

The release script requires Apple Developer ID signing, hardened runtime, notarization, stapling, and verification before publishing an immutable GitHub release. The Developer ID Application certificate for Team `Q2X7X86GYR` is locally available, and a disposable full nested-app Developer ID signing, secure-timestamp, and strict verification passed. The GitHub updater and release script are implemented, but notarization and publishing were not run. The local build is not installed, and no public DMG or public release exists. Public publication still requires notarization, Gatekeeper and privacy checks, and explicit release authorization.

## Source and license

Source is public under the MIT License. Public source does not change the separate product, worker, Safari-app, permission, or migration boundaries above.
