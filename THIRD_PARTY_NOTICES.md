# Third-party components and release boundary

This repository pins source dependencies in `DrivePlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` but does not vendor their repositories or XCFrameworks. Consult the exact pinned revisions and preserve all applicable upstream copyright and license notices.

- KSPlayer — `kingslay/KSPlayer`, locked revision `25c923b70d3d7881275e8f3d917e1e9752416e27`.
- kingslay/FFmpegKit — locked revision `c32be9bfb628042737ad3ef622e930c5c7b15954`, version `6.1.4`.
- The dependency build uses upstream prebuilt XCFrameworks, not locally source-built frameworks. The lockfile fixes package revisions; it is not a complete binary provenance or corresponding-source manifest.

Upstream repositories and binary contents were not independently inspected in this isolated snapshot pass. Consult their actual licenses and grants at the locked revisions; this document does not resolve GPL-only versus GPL-or-later or conflicting package metadata for them. Vivi's GPL-3.0-only grant covers its original app, tests, scripts and documentation and does not narrow or replace third-party rights.

Before distributing any App binary, inventory the actually linked framework slices and their source revisions, build scripts/configuration, copyright notices, license texts, and corresponding source availability. Separately review store/channel conditions. No unsigned source build or public repository alone certifies binary redistribution compliance.

The video and metadata audio fixtures are newly generated entirely from integer sample formulas and literal test metadata by `tools/generate-fixtures.swift`. No input media or downloads are used. The generated assets, including their one-pixel artwork, are expressly granted under GPL-3.0-only; see `tools/README.md` for recipe, hashes, tool version and verification limits. This grant does not apply to third-party media or frameworks.
