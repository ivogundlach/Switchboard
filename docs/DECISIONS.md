# Switchboard decisions

These boundaries are deliberate product decisions, not a promise that every listed item is already implemented.

## Product boundary

Switchboard is the mega app for small general-purpose utilities. The first release supports macOS 26 on Apple silicon, and Warm Corners is the only current pilot. Every other manifest entry remains planned, repair-required, or classification-required until its own implementation and verification pass.

## Separate products and workers

Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway stay independent apps and DMGs. A product-specific background worker belongs in that product's DMG, not in Switchboard. This keeps ownership, updates, permissions, and rollback paths understandable.

## Separate Safari apps

ForceCopyPaste, NewTabLinks, and YouTube Defaults stay separate Safari apps. Safari extension packaging and permissions are their own product boundary and are not folded into the mega app.

## Third-party and fork boundary

Third-party utilities stay outside Switchboard. Maintained forks stay in separate repositories and keep their upstream history and ownership boundaries. Switchboard may expose an approved local operation only when the manifest explicitly assigns it to Switchboard; it does not absorb third-party applications.

## Shortcuts boundary

General Apple Shortcuts stay outside Switchboard. The Mac day/night brightness shortcuts are the one replacement: the planned Mac Brightness module provides native brightness control instead. Other unrelated shortcuts are excluded rather than silently reproduced.

## Permissions, identity, and migration

Replacement work preserves existing permission identities where possible and verifies each replacement in production before retiring a superseded component. Warm Corners is governed by its migration contract: stop both pointer watchers before import or rollback, preserve the exact legacy settings value in the transaction recovery record, and require the health checks and stabilization cycle. Retirement is a future production-only action with no removal operation in the current pilot; once enabled, it may move the legacy app to Trash only after stabilization. The signed restore source is retained independently.

## Distribution and signing

The local build requires the stable `Ivo Market Dev` signing identity. That certificate is self-signed, has no Apple Team ID, preserves the established local identity, and produces apps Gatekeeper rejects. The keychain currently has no Apple-issued `Developer ID Application` identity. A public DMG requires Apple Developer ID signing, hardened runtime, a secure timestamp, and notarization; public release is blocked until those requirements are met. Switchboard is currently not installed, and no public DMG exists. No ad-hoc signing or unreviewed installation is part of this project.

## Source and license

Ivo selected public source and the MIT License. Source publication does not change the separate product, worker, Safari-app, permission, or migration boundaries above, and it does not imply that a distributable signed DMG is available.
