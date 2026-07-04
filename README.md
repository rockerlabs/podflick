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

## Background transfer (Finder service + URL scheme)

Besides the main window, PodFlick can take a video without you opening the
app first:

- **Finder** — right-click a video → **Services → Transfer to iPod**.
- **Shortcuts / Automator** — open a `podflick://transfer?path=/abs/clip.mp4`
  URL (repeat `&path=` for several files).

Either way the app converts and writes in the background: no window, just a
menu-bar item showing progress and an **Eject** action, plus a completion
notification.

> **The Finder "Transfer to iPod" item only appears when `PodFlick.app` lives
> in `/Applications`.** Running a copy straight from the build folder works when
> invoked directly (e.g. via `NSPerformService`), but Finder won't surface the
> Services menu item for it. After the first copy into `/Applications`, launch
> the app once (and, if needed, `/System/Library/CoreServices/pbs -flush`) so
> macOS registers the service.

Full hardware smoke steps: [docs/smoke-service-transfer.md](docs/smoke-service-transfer.md).
