# Switchboard decisions

These boundaries describe the current product, not a promise that every catalog entry is enabled.

## Product and module boundary

Switchboard is one menu-bar app for general-purpose Mac utilities with one background agent. Ready modules are Warm Corners, Audio Disconnect Guard, Quit on Close, Mac Brightness, Mail Assistant, AutoInstall DMG, Copy Safari URL, Local Read Connectors, Memory System, Codex & System Improvement, Repository & Release Automation, NotebookLM Sync, Backup Coverage Audit, and Advanced Commands. Kinetics, Smart Wake, and Copy Path are planned and remain unavailable.

## Bundled operations

Sanitized command payloads and macOS Services ship inside the Switchboard bundle. Command, service, and scheduler migration is recoverable: it records intent, verifies each replacement, and can roll back. The current migration path does not delete legacy items.

## Separate products and integrations

Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway remain standalone products; their workers remain in their own app bundles and DMGs. ForceCopyPaste, NewTabLinks, and YouTube Defaults remain separate Safari apps. Third-party utilities and general Apple Shortcuts stay outside Switchboard.

## Updates and distribution

The implemented updater discovers real published GitHub releases, downloads the update manifest and DMG, verifies the SHA-256 hash, runs a nested updater, and supports rollback from a verified recovery copy.

The release script requires Apple Developer ID signing, hardened runtime, notarization, stapling, and verification before publishing an immutable GitHub release. It is currently blocked because the required Developer ID certificate is absent. The local build is not installed, and no public DMG or public release exists.

## Source and license

Source is public under the MIT License. Public source does not change the separate product, worker, Safari-app, permission, or migration boundaries above.
