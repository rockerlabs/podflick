# PodFlick

Drag & drop videos onto your classic iPod (5G/5.5G) — no iTunes.

PodFlick converts any video to the iPod Video spec (H.264 baseline
≤640×480 ≤1.5 Mbps + AAC) via ffmpeg and writes it directly into the
device's `iTunesDB`, using surgical in-place edits proven against real
hardware. Works with both Mac-formatted (HFS+) and Windows-formatted
(FAT32, incl. Rockbox dual-boot) iPods.

## Status

Early scaffold. The DB algorithm is fully proven in the Python reference
implementation (`reference/`, verified end-to-end on two devices on
2026-07-02); the Swift port is in progress.

- Format documentation: [docs/itunesdb-format.md](docs/itunesdb-format.md)
- Reference implementation + golden fixtures: [reference/](reference/)

## Build

```
brew install xcodegen ffmpeg
cp Signing.xcconfig.template Signing.local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate
xcodebuild -project PodFlick.xcodeproj -scheme PodFlick build
```

## Requirements

- macOS 14+, Xcode 15+
- ffmpeg on PATH (conversion)
- An iPod Video 5G/5.5G mounted as a disk
