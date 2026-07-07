#!/usr/bin/env bash
#
# make-dmg.sh — package a notarized PodFlick.app into a drag-to-install DMG,
# then sign + notarize + staple the DMG itself so it mounts with no Gatekeeper
# warning. Run AFTER scripts/release.sh has produced the notarized .app.
#
# Usage: ./scripts/make-dmg.sh [path/to/PodFlick.app]
#   (defaults to build/Build/Products/Release/PodFlick.app)
#
# Config via environment variables (same as release.sh):
#   SIGN_IDENTITY    codesign identity; auto-detected when exactly one
#                    "Developer ID Application" cert is present
#   NOTARY_PROFILE   notarytool keychain profile        (default: podflick-notary)
#   SKIP_NOTARIZE=1  build + sign the DMG but skip the Apple round-trip
#
set -euo pipefail

APP="${1:-build/Build/Products/Release/PodFlick.app}"
NOTARY_PROFILE="${NOTARY_PROFILE:-podflick-notary}"

die()  { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ -d "$APP" ] || die "app not found: $APP (run scripts/release.sh first)"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")
# Version-less name so a release always has a `PodFlick.dmg` asset — that lets
# README link to the stable https://…/releases/latest/download/PodFlick.dmg
# (always the newest). The version lives in the app / tag / CHANGELOG.
DMG="PodFlick.dmg"
echo "packaging PodFlick $version -> $DMG"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  ids=$(security find-identity -p codesigning -v | grep "Developer ID Application" || true)
  [ -n "$ids" ] || die "no 'Developer ID Application' cert in the keychain"
  [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = 1 ] \
    || die "multiple 'Developer ID Application' certs — set SIGN_IDENTITY explicitly"
  SIGN_IDENTITY=$(printf '%s\n' "$ids" | sed -E 's/.*"(.*)".*/\1/')
fi
echo "signing identity: $SIGN_IDENTITY"

# A drag-to-install layout: the app next to an /Applications alias.
step "Stage the app + an Applications symlink"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"

step "Build the DMG ($DMG)"
rm -f "$DMG"
hdiutil create -volname PodFlick -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"

# The DMG is a container, not an executable — sign it (no hardened runtime; the
# .app inside already carries its own hardened-runtime signature).
step "Sign the DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-}" = 1 ]; then
  step "SKIP_NOTARIZE=1 — signed (not notarized) DMG ready: $DMG"
  exit 0
fi

step "Notarize the DMG (blocks until Apple returns)"
out=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$out"
grep -q "status: Accepted" <<<"$out" \
  || die "notarization not Accepted — inspect: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"

step "Staple the DMG"
xcrun stapler staple "$DMG"

step "Gatekeeper check"
spctl -a -t open --context context:primary-signature -v "$DMG"

step "Done — notarized + stapled: $DMG"
