# Changelog

All notable changes to NTFS Bridge are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-20

The first public release.

### Added

- Read and write NTFS drives in Finder through an FSKit file system extension.
- The Linux `ntfs3` driver in a Virtualization.framework microVM, with
  `ntfs-3g` as a fallback for volumes `ntfs3` refuses.
- Read-only mounting, with an explanation, for drives that Windows hibernated
  (Fast Startup) or that need a disk check.
- A menu bar app that lists NTFS drives, mounts new ones automatically and can
  remount drives that another driver mounted first.
- Mounting NTFS disk images (`.img`, `.dmg`).
- Disk Utility First Aid support: verify runs `ntfsfix -n` and repair runs `ntfsfix`.
- The `ntfsb` command-line tool for testing against disk images.
- A Developer ID signed and notarized app, shipped as a notarized disk image.

[Unreleased]: https://github.com/xscade/ntfs-bridge/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/xscade/ntfs-bridge/releases/tag/v0.1.0
