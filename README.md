# PodFlick

Drag & drop videos onto your classic iPod (5G/5.5G) — no iTunes.

PodFlick converts any video to the iPod Video spec (H.264 baseline
≤640×480 ≤1.5 Mbps + AAC) via ffmpeg and writes it directly into the
device's `iTunesDB`, using surgical in-place edits proven against real
hardware. Works with both Mac-formatted (HFS+) and Windows-formatted
(FAT32, incl. Rockbox dual-boot) iPods.

## Install

**[⬇ Download PodFlick.dmg](https://github.com/rockerlabs/podflick/releases/latest/download/PodFlick.dmg)**
(always the latest) — open it and drag **PodFlick** into **Applications**.
That's the whole install: the app is signed and **notarized** (it opens with no
"unidentified developer" warning) and **ffmpeg is bundled**, so no `brew
install` is needed.

Requirements: **Apple Silicon (arm64), macOS 14+**, and an iPod Video 5G/5.5G
mounted as a disk. (Moving the app into `/Applications` also registers the
Finder **Transfer to iPod** service — see below.)

A specific version or a plain `.zip` is on the [releases page](https://github.com/rockerlabs/podflick/releases).

## Status

**PodFlick 1.0 is released** — see the [changelog](CHANGELOG.md). The iTunesDB
engine is proven end-to-end on real hardware; the Python reference
implementation + golden fixtures are in [`reference/`](reference/) and the
format spec is in [docs/itunesdb-format.md](docs/itunesdb-format.md).

## Build from source

For contributors, or a dev build. A source build shells out to an `ffmpeg` on
your `PATH` (rather than the bundled one); producing a self-contained,
notarized release is documented in
[docs/bundling-ffmpeg.md](docs/bundling-ffmpeg.md).

```
brew install xcodegen ffmpeg
cp Signing.xcconfig.template Signing.local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate
xcodebuild -project PodFlick.xcodeproj -scheme PodFlick build
```

Build requirements: macOS 14+, Xcode 15+, `ffmpeg` on `PATH`.

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

## License

PodFlick's own code is released under the [MIT License](LICENSE).

**ffmpeg.** PodFlick shells out to `ffmpeg`/`ffprobe` as separate child
processes — it never links them in, so its own source stays MIT either way:

- **Source checkouts / Homebrew dev builds** do not bundle ffmpeg; they use an
  ffmpeg you install yourself (`brew install ffmpeg`), whose license stays with
  your copy.
- **Notarized release builds** bundle an **LGPL v2.1** ffmpeg/ffprobe (built
  with no GPL or non-free components). The compliance package — license text,
  the exact source revision, the build/configure line, and a written offer for
  the corresponding source — is in [`licenses/ffmpeg/`](licenses/ffmpeg/).

The iTunesDB read/write layer is an independent, byte-level reverse engineering
of the on-device format (see [docs/itunesdb-format.md](docs/itunesdb-format.md));
no third-party database library is used or derived from.

### Trademarks

"iPod" and "iTunes" are trademarks of Apple Inc. PodFlick refers to them only
to describe the hardware it works with (nominative use) and ships none of
Apple's artwork or icons. PodFlick is an independent, open-source project — not
affiliated with, endorsed by, or sponsored by Apple Inc. The same notice
appears in the app's About panel.
