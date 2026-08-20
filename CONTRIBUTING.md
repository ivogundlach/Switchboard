# Contributing to Switchboard

Switchboard is a public MIT project for **macOS 26 on Apple silicon**. The source is public, but the first release is still an unreleased Warm Corners pilot. Other manifest entries are not implemented as available modules.

## Before you start

Use a clean local checkout and keep unrelated work untouched. From `$HOME/Projects/Switchboard`:

```bash
swift test
./build.sh
build/Switchboard.app/Contents/MacOS/Switchboard --self-test
```

The local build uses the established `Ivo Market Dev` identity for continuity. It is not a public-release signature. Do not install the app as part of development.

## Ownership boundary

Warm Corners is the only current pilot. The manifest is the source of truth for module ownership and availability. Market, School, Tool Dashboard, Vitals, UsageQueue, ReleaseRadar, NutrientTracker, Psephos, Tax Simulator, and Runway remain separate products, with their workers in their own DMGs. ForceCopyPaste, NewTabLinks, and YouTube Defaults remain separate Safari apps. Third-party utilities and general Apple Shortcuts remain outside Switchboard.

Changes touching migration, helpers, signing, updates, local-read access, or Mail access need an explicit explanation of the permission and rollback effect. Do not broaden a permission experiment after an unexpected prompt, denial, identity change, or behavior change.

## Issues and pull requests

Open an issue for a reproducible problem. Include the macOS version, Apple-silicon status, the module and availability state involved, exact reproduction steps, and relevant self-test output. Do not include secrets, personal paths, private account data, or copied runtime data.

Pull requests should be narrow, explain the user-visible effect, preserve the ownership boundary, and include the commands run and their results. Do not claim a planned module is implemented. Do not add an install step, ad-hoc signing, or a public release artifact to a code change.
