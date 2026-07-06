# Bundling ffmpeg (self-contained release) — B.15 runbook

Goal: ship a release that Just Works with no `brew install ffmpeg`, while
staying **LGPL-only** (see the B.15 decision in `CLAUDE.md`: path A — LGPL
ffmpeg + Apple VideoToolbox encoder, ffmpeg exec'd as a separate binary so it is
never linked into PodFlick).

> **Shortcut:** `scripts/release.sh` automates steps (3)-(4) below (clean build →
> embed → sign → notarize → staple → verify). Set `FFMPEG_BIN_DIR` to the dir
> holding the LGPL ffmpeg/ffprobe and run it from the repo root; `SKIP_NOTARIZE=1`
> stops after signing. The steps below remain the source of truth it wraps.

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

## (3) Build the Release .app + embed the binaries

App-code lookup already prefers the bundled path (shipped). Build a Release
`.app`, then post-build-copy the two binaries into it (keeps the blob out of
git and lets a plain `swift build`/CI stay ffmpeg-free).

**Build unsigned, from a clean tree.** Two gotchas learned the hard way:

- Embedding happens *after* the build and invalidates any signature xcodebuild
  applied, so build-time signing is wasted — build with
  `CODE_SIGNING_ALLOWED=NO` and do all signing manually in step (4).
- Wipe `build/` first. An incremental rebuild leaves a previously-embedded
  `Contents/Resources/bin/` in place, so a stale ffmpeg can survive into a
  "fresh" bundle.

```
cd <repo>
rm -rf build                       # avoid a stale embedded bin/ surviving
xcodegen generate                  # after any project.yml change
xcodebuild -project PodFlick.xcodeproj -scheme PodFlick -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Confirm the bundle is clean (no `bin/` yet), then embed from the LGPL build:

```
APP="build/Build/Products/Release/PodFlick.app"
test -e "$APP/Contents/Resources/bin" && echo "STALE — rm -rf build, rebuild" || echo "clean"
mkdir -p "$APP/Contents/Resources/bin"
cp <ffmpeg-src>/dist/bin/ffmpeg <ffmpeg-src>/dist/bin/ffprobe "$APP/Contents/Resources/bin/"
ls -l "$APP/Contents/Resources/bin"   # ffmpeg, ffprobe — both executable, ~20 MB
```

(On Apple Silicon the linker ad-hoc-signs every Mach-O, so a
`CODE_SIGNING_ALLOWED=NO` build still shows `Identifier=…` under `codesign -dv`
— expected; step (4) replaces it with Developer ID.)

## (4) Sign (hardened runtime) + notarize — proven end-to-end 2026-07-06

**Precondition — a Developer ID Application cert.** Notarized *direct*
distribution (outside the App Store) needs a **Developer ID Application**
certificate. `Apple Development` and `Apple Distribution` do NOT work
(Distribution is App-Store-only). Confirm one exists for the release team:

```
security find-identity -p codesigning -v | grep "Developer ID Application"
```

If absent, create it in Xcode → Settings → Accounts → (the team) → Manage
Certificates → + → Developer ID Application (or developer.apple.com →
Certificates). It must be under the same team as `DEVELOPMENT_TEAM`
(`<TEAM_ID>`) in the gitignored `Signing.local.xcconfig` (copied from
`Signing.xcconfig.template`).

`ENABLE_HARDENED_RUNTIME` is set for the Release config in `project.yml`, but
since we build unsigned and re-sign manually with `--options runtime` below, the
flag is belt-and-suspenders — the manual sign is what applies it.

**Sign inner binaries first, then the app.** Each embedded Mach-O must carry
hardened runtime + a secure timestamp *before* the outer `.app` seals them, or
notarization rejects the bundle. No `--deep` (Apple discourages it — sign nested
code explicitly) and no entitlements (ffmpeg is exec'd as a child process, never
loaded into PodFlick, so hardened runtime needs no exception).

```
APP="build/Build/Products/Release/PodFlick.app"
IDENTITY="Developer ID Application: <NAME> (<TEAM_ID>)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  "$APP/Contents/Resources/bin/ffmpeg" "$APP/Contents/Resources/bin/ffprobe"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
```

Verify hardened runtime landed (`flags=0x10000(runtime)`) and the bundle is
sound *before* spending a notary round-trip:

```
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|flags='
codesign --verify --deep --strict --verbose=2 "$APP"    # -> valid on disk
```

**Notarize.** notarytool authenticates with an **app-specific password**, NOT
the Apple ID login password (login password → `HTTP 401`). Create one at
account.apple.com → Sign-In and Security → App-Specific Passwords (it's shown
once — copy it immediately; you can't view it later, only revoke/recreate).

⚠️ Two-Apple-ID trap: if the Mac is signed into more than one Apple ID on
different teams, create the app-specific password under — and pass `--apple-id`
for — the account that owns the *release* Team ID (`<TEAM_ID>`). A password from
the wrong account also returns `HTTP 401`. (Felt 2026-07-06: a password from the
other Apple ID on this Mac 401'd until regenerated under the release account.)

```
# one-time: store creds in the keychain (prompts for the app-specific password)
xcrun notarytool store-credentials <profile> --apple-id <APPLE_ID_EMAIL> --team-id <TEAM_ID>

# per release: zip, submit (blocks until Apple returns ~1-5 min), staple on success
ditto -c -k --keepParent "$APP" PodFlick.zip
xcrun notarytool submit PodFlick.zip --keychain-profile <profile> --wait   # -> status: Accepted
xcrun stapler staple "$APP"                                                # only if Accepted
```

If `status: Invalid`, do NOT staple — pull the reason and fix:
`xcrun notarytool log <submission-id> --keychain-profile <profile>`.

Final gate (offline Gatekeeper check):

```
spctl -a -vvv --type exec "$APP"    # -> accepted, source=Notarized Developer ID
```

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

- ✅ (3) code side — `FFmpegTools.locate` bundled-first lookup + tests.
- ✅ (1) hardened runtime wired into `project.yml` Release config (PR #38).
- ✅ (2) LGPL ffmpeg built (git snapshot N-117162, `--disable-gpl`
  `--disable-libx264`), **arm64-only** — no universal binary yet (x86_64
  deferred, so Intel Macs are unsupported until a `lipo`'d build ships).
- ✅ (3) build + embed + (4) sign + notarize proven end-to-end 2026-07-06.
- ⏳ (5) LGPL compliance artifacts + README posture, (6) size note,
  on-device smoke, and release tagging — remaining.
