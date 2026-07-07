#!/usr/bin/env bash
#
# release.sh — build a notarized, self-contained PodFlick.app.
#
# A thin wrapper over docs/bundling-ffmpeg.md steps (3)-(4): clean build →
# embed the LGPL ffmpeg/ffprobe → sign (hardened runtime) → notarize → staple →
# verify. The runbook is the source of truth; this just runs it without typos.
# Run from the repo root.
#
# One-time prerequisites (see docs/bundling-ffmpeg.md):
#   - a "Developer ID Application" certificate in the keychain
#   - a notarytool keychain profile:
#       xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <TEAM>
#   - Signing.local.xcconfig with DEVELOPMENT_TEAM set (copy Signing.xcconfig.template)
#
# Config via environment variables:
#   FFMPEG_BIN_DIR   dir holding the LGPL ffmpeg + ffprobe to embed   (required)
#   SIGN_IDENTITY    codesign identity; auto-detected when exactly one
#                    "Developer ID Application" cert is present
#   NOTARY_PROFILE   notarytool keychain profile        (default: podflick-notary)
#   SKIP_NOTARIZE=1  stop after signing (local signed build, no Apple round-trip)
#
set -euo pipefail

SCHEME=PodFlick
CONFIG=Release
APP="build/Build/Products/$CONFIG/$SCHEME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-podflick-notary}"

die()  { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ -f project.yml ] || die "run from the repo root (project.yml not found)"

# ---- config + prerequisites -------------------------------------------------
FFMPEG_BIN_DIR="${FFMPEG_BIN_DIR:-}"
[ -n "$FFMPEG_BIN_DIR" ] || die "set FFMPEG_BIN_DIR to the dir holding ffmpeg + ffprobe"
for tool in ffmpeg ffprobe; do
  [ -x "$FFMPEG_BIN_DIR/$tool" ] || die "not executable: $FFMPEG_BIN_DIR/$tool"
done
[ -f Signing.local.xcconfig ] \
  || die "Signing.local.xcconfig missing (copy Signing.xcconfig.template, set DEVELOPMENT_TEAM)"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  ids=$(security find-identity -p codesigning -v | grep "Developer ID Application" || true)
  [ -n "$ids" ] || die "no 'Developer ID Application' cert in the keychain (docs/bundling-ffmpeg.md)"
  [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] \
    || die "multiple 'Developer ID Application' certs — set SIGN_IDENTITY explicitly"
  SIGN_IDENTITY=$(printf '%s\n' "$ids" | sed -E 's/.*"(.*)".*/\1/')
fi
echo "signing identity: $SIGN_IDENTITY"

# ---- (3) clean build + embed ------------------------------------------------
step "Clean build (unsigned — embedding invalidates any build-time signature)"
rm -rf build
xcodegen generate
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

step "Embed ffmpeg + ffprobe under Contents/Resources/bin"
bin="$APP/Contents/Resources/bin"
mkdir -p "$bin"
cp "$FFMPEG_BIN_DIR/ffmpeg" "$FFMPEG_BIN_DIR/ffprobe" "$bin/"

# ---- (4) sign ---------------------------------------------------------------
step "Sign inner binaries first, then the app (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  "$bin/ffmpeg" "$bin/ffprobe"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"

step "Verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Capture then match via a here-string, NOT `codesign … | grep -q`: grep -q
# closes the pipe on the first match, codesign gets SIGPIPE, and under
# `set -o pipefail` that fails the pipeline even though the flag WAS found.
sig=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q 'flags=0x10000(runtime)' <<<"$sig" \
  || die "hardened runtime flag missing on the signed app"

if [ "${SKIP_NOTARIZE:-}" = 1 ]; then
  step "SKIP_NOTARIZE=1 — signed (not notarized) build ready: $APP"
  exit 0
fi

# ---- notarize + staple ------------------------------------------------------
step "Notarize (blocks until Apple returns)"
zip="build/$SCHEME.zip"
ditto -c -k --keepParent "$APP" "$zip"
out=$(xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$out"
grep -q "status: Accepted" <<<"$out" \
  || die "notarization not Accepted — inspect: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"

step "Staple"
xcrun stapler staple "$APP"

step "Gatekeeper check"
spctl -a -vvv --type exec "$APP"

step "Done — notarized + stapled: $APP"
