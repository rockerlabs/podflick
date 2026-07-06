# Bundling ffmpeg (self-contained release) — B.15 runbook

Goal: ship a release that Just Works with no `brew install ffmpeg`, while
staying **LGPL-only** (see the B.15 decision in `CLAUDE.md`: path A — LGPL
ffmpeg + Apple VideoToolbox encoder, ffmpeg exec'd as a separate binary so it is
never linked into PodFlick).

The **code** side is done and shipped: `FFmpegTools.locate` prefers
`PodFlick.app/Contents/Resources/bin/{ffmpeg,ffprobe}` and falls back to the
session PATH + package-manager prefixes when that directory is absent (a plain
`swift build`, an unbundled dev build, or an OSS build that skips bundling).
Nothing below changes app code — it is the operator-only pipeline that produces,
embeds, signs, and legally clears the binaries. **None of it is committed to the
repo** (a 30–70 MB binary blob does not belong in git); it runs at
release-packaging time.

The steps map 1:1 to the B.15 sub-steps `(2)`–`(6)`.

---

## (2) Build an LGPL ffmpeg (x264 off, VideoToolbox on)

ffmpeg is LGPL **by default**: it only becomes GPL when you pass `--enable-gpl`
or enable a GPL component (x264 is GPL — leave `--enable-libx264` off). Apple's
VideoToolbox H.264 encoder and the native `aac` encoder are LGPL-compatible, so
a minimal default configure already satisfies path A.

The build must contain everything the converter and probe actually invoke
(`Sources/PodFlick/Convert/IPodVideoConverter.swift`):

- encoders: `h264_videotoolbox`, `aac` (both on by default on macOS)
- muxer: `mov`/`mp4`/`m4v` with `+faststart`; filter: `scale`
- ffprobe: JSON output (`-show_format`/`-show_streams`)
- a broad decoder/demuxer set (arbitrary input video) — the default set covers it

Per-arch build (repeat for `arm64` and, for a universal binary, `x86_64`),
starting recipe — **verify against the current ffmpeg release before trusting**:

```
# from a fresh ffmpeg source tree, per architecture
./configure \
  --prefix="$PWD/dist/$(uname -m)" \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --disable-libx264 \
  --disable-gpl \
  --disable-nonfree \
  --disable-doc \
  --disable-debug \
  --enable-static --disable-shared
make -j"$(sysctl -n hw.ncpu)"
make install
```

For a universal binary, build both arches then `lipo` each tool:

```
lipo -create dist/arm64/bin/ffmpeg  dist/x86_64/bin/ffmpeg  -output dist/ffmpeg
lipo -create dist/arm64/bin/ffprobe dist/x86_64/bin/ffprobe -output dist/ffprobe
```

Sanity-check the result before embedding:

```
./dist/ffmpeg -hide_banner -encoders | grep -E 'h264_videotoolbox|(^| )aac'
./dist/ffmpeg -hide_banner -L | grep -i gpl   # must print nothing / "LGPL"
```

## (3) Embed under Contents/Resources/bin/  — code done; wiring at package time

App-code lookup already prefers the bundled path (shipped). Two ways to place
the binaries into the built `.app`:

- **Post-build copy** (recommended — keeps the built product out of git and lets
  a plain `swift build`/CI stay ffmpeg-free): after `xcodebuild`, copy the two
  binaries into `PodFlick.app/Contents/Resources/bin/` as a release-packaging
  step (a `Makefile`/`release.sh` target, not a source change).
- **project.yml Copy-Files phase**: add a `Resources/bin/` source folder + a
  copy phase so xcodegen embeds it. Only do this once the binaries actually
  exist on disk — wiring a copy phase against a missing path breaks the build,
  and it would drag the blob into the dev loop.

Verify placement:

```
ls -l PodFlick.app/Contents/Resources/bin
# ffmpeg, ffprobe — both executable
```

## (4) Sign (hardened runtime) + notarize

The embedded binaries are separate Mach-O executables — each must be signed with
the hardened runtime **before** the outer `.app` is signed/notarized, or
Gatekeeper rejects the bundle. Needs a real signing identity: set
`DEVELOPMENT_TEAM` in the gitignored `Signing.local.xcconfig` (copy it from
`Signing.xcconfig.template`); `<TEAM_ID>` below is that same 10-char Apple Team
ID. Current local builds are unsigned.

```
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  PodFlick.app/Contents/Resources/bin/ffmpeg \
  PodFlick.app/Contents/Resources/bin/ffprobe

# then sign the app outermost, staple after notarization
codesign --force --options runtime --timestamp --deep \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" PodFlick.app
xcrun notarytool submit PodFlick.zip --keychain-profile <profile> --wait
xcrun stapler staple PodFlick.app
```

Verify: `codesign --verify --deep --strict PodFlick.app` and
`spctl -a -vvv --type exec PodFlick.app` (accepted).

## (5) LGPL compliance for the shipped binary

Because ffmpeg is redistributed (not just referenced), the release must carry:

- ffmpeg's **LICENSE / COPYING.LGPLv2.1** text, and
- either the **corresponding source** for the exact build, or a **written offer**
  to provide it, plus the **configure line / build config** used in step (2).

Ship these in the release (e.g. a `licenses/ffmpeg/` folder in the DMG and/or a
GitHub release asset). Update `README.md` **License** section at that point — it
currently states PodFlick does *not* bundle ffmpeg; once a release bundles it,
the section must describe the LGPL posture + where the source/offer lives.
`FFmpegTools`'s doc comment already references this file.

## (6) Size

Expect **+30–70 MB** to the shipped app (two static universal binaries). If that
is too heavy, an arm64-only build roughly halves it; document the arch support
matrix in the release notes.

---

## Status

- ✅ (3) code side — `FFmpegTools.locate` bundled-first lookup + tests (this PR).
- ⏳ (2)(4)(5)(6) — operator-run at release-packaging time, per the steps above.
