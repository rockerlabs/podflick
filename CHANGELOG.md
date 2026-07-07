# Changelog

All notable changes to PodFlick are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and PodFlick follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Work toward v2 (on `main`, not yet released).

### Added
- In-app creation of manual (non-master) playlists in the iTunesDB (backend).
- Settings window (⌘,) with a **Launch at login** toggle, and a **Help** menu.

## [1.0] — 2026-07-07

First release. Drag-and-drop video onto a classic iPod (5G/5.5G) from a native
macOS menu-bar app — no iTunes.

### Added
- Convert any video to the iPod Video spec (H.264 baseline ≤640×480 via Apple
  VideoToolbox + AAC) and write it straight into the device's `iTunesDB` with
  surgical, device-proven in-place edits. Supports HFS+ (Mac) and FAT32
  (Windows / Rockbox dual-boot) iPods.
- Background transfer without opening the app — a Finder **Transfer to iPod**
  service and a `podflick://transfer?path=…` URL scheme, with a menu-bar
  progress item, an **Eject** action, and a completion notification.
- Menu-bar (status-item) UI, and an **About** panel that shows the app version.
- Self-contained, **notarized** build — bundles an LGPL v2.1 `ffmpeg`/`ffprobe`
  (no GPL or non-free components), so it runs with no `brew install`.

### Notes
- Apple Silicon (arm64) only; macOS 14+.

[Unreleased]: https://github.com/rockerlabs/podflick/compare/v1.0...HEAD
[1.0]: https://github.com/rockerlabs/podflick/releases/tag/v1.0
