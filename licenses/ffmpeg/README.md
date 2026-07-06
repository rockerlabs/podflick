# FFmpeg — LGPL v2.1 compliance

PodFlick's **notarized release build** bundles two executables from the
[FFmpeg project](https://ffmpeg.org) — `ffmpeg` and `ffprobe` — under
`PodFlick.app/Contents/Resources/bin/`. (Source checkouts and Homebrew-based
dev builds do **not** bundle them; they fall back to an ffmpeg on `PATH`.)

This directory is the LGPL v2.1 compliance package for that bundled copy. It
must ship alongside every release that contains the binaries (in the DMG/zip
and as a GitHub release asset).

## License

The bundled FFmpeg binaries are licensed under the **GNU Lesser General Public
License, version 2.1** — full text in [`COPYING.LGPLv2.1`](COPYING.LGPLv2.1).

The build enables **no** GPL or non-free components (see the configure line
below: no `--enable-gpl`, no `--enable-nonfree`, and `--disable-libx264` — the
x264 encoder is GPL). The H.264 and AAC encoders used are Apple's system
VideoToolbox / AudioToolbox, invoked through FFmpeg. The result is LGPL-only.

## How PodFlick uses it (why the app stays MIT)

PodFlick invokes `ffmpeg`/`ffprobe` as **separate child processes**
(`fork`/`exec`) — it never links, `dlopen`s, or statically embeds FFmpeg code
into its own binary. Under the LGPL this is mere aggregation/use of a separate
program, so PodFlick's own source remains under the [MIT License](../../LICENSE);
only the FFmpeg binaries carry the LGPL, satisfied by this package.

## Corresponding source (LGPL v2.1 §4 — written offer)

The exact source for the bundled binaries is:

- **FFmpeg**, git revision **`N-117162-g38e224c2ba`** (upstream
  <https://github.com/FFmpeg/FFmpeg>, commit `38e224c2ba`).
- Configured and built with:

  ```
  ./configure --prefix="$PWD/dist" \
    --enable-videotoolbox --enable-audiotoolbox \
    --disable-libx264 --disable-gpl --disable-nonfree \
    --disable-doc --disable-debug \
    --enable-static --disable-shared
  make -j"$(sysctl -n hw.ncpu)"
  make install
  ```

  Target: macOS `arm64` (Apple Silicon). See
  [`docs/bundling-ffmpeg.md`](../../docs/bundling-ffmpeg.md) for the full recipe.

**Written offer.** For at least three (3) years from the date of the release
that includes these binaries, the complete corresponding source for that exact
build is made available:

- as a source archive attached to the same GitHub release, and/or
- on request — open an issue at the PodFlick GitHub repository and it will be
  provided (the upstream revision above plus the configure line reproduce it
  byte-for-byte).

Because the binaries are LGPL and PodFlick links to them only via process
execution, a user may also replace them: drop a compatible `ffmpeg`/`ffprobe`
(same LGPL-compatible feature set) into `Contents/Resources/bin/`, or remove
them so PodFlick uses one from `PATH`.
