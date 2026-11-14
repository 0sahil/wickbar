#!/usr/bin/env bash
# Writes a Sparkle appcast (build/appcast.xml) with one item for this release, signed with EdDSA.
#   scripts/make-appcast.sh [--app PATH] [--zip PATH] [--out PATH] [--notes-section NAME] [--ed-key-file PATH|-]
# Defaults: build/Wickbar.app, build/Wickbar-<VERSION>.zip, build/appcast.xml, CHANGELOG section <VERSION>.
# Signing key, first match wins: --ed-key-file PATH ('-' = stdin), $SPARKLE_ED_PRIVATE_KEY (base64, from
# `generate_keys -x`), --keychain (the `wickbar` keychain account). SKIP_SIGN=1 writes a placeholder signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/Wickbar.app"
ZIP=""
OUT="$ROOT/build/appcast.xml"
NOTES_SECTION="$VERSION"
KEY_FILE=""
USE_KEYCHAIN=0
REPO_URL="https://github.com/0sahil/wickbar"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --notes-section) NOTES_SECTION="$2"; shift 2 ;;
    --ed-key-file) KEY_FILE="$2"; shift 2 ;;
    --keychain) USE_KEYCHAIN=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
ZIP="${ZIP:-$ROOT/build/Wickbar-$VERSION.zip}"

[[ -d "$APP" ]] || { echo "No app at $APP (run scripts/build-app.sh first)" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "No update archive at $ZIP" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
# Sparkle compares CFBundleVersion, so take it from the app that was actually built rather than recomputing it.
BUNDLE_VERSION="$(plist CFBundleVersion)"
SHORT_VERSION="$(plist CFBundleShortVersionString)"
PUBLIC_KEY="$(plist SUPublicEDKey)"
[[ "$SHORT_VERSION" == "$VERSION" ]] || { echo "App version $SHORT_VERSION doesn't match VERSION ($VERSION)" >&2; exit 1; }

LENGTH="$(stat -f %z "$ZIP")"
ENCLOSURE_URL="$REPO_URL/releases/download/v$VERSION/$(basename "$ZIP")"

# --- EdDSA signature -------------------------------------------------------------------------------
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
if [[ "${SKIP_SIGN:-0}" == "1" ]]; then
  echo "==> SKIP_SIGN=1: writing a PLACEHOLDER signature; this appcast will not install anywhere" >&2
  SIGNATURE="SKIP_SIGN_PLACEHOLDER"
else
  # sign_update ships in the Sparkle SwiftPM artifact, so its version always matches Package.resolved.
  [[ -x "$SIGN_UPDATE" ]] || swift package resolve >/dev/null
  [[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found at $SIGN_UPDATE" >&2; exit 1; }
  if [[ -n "$KEY_FILE" ]]; then
    SIGNATURE="$("$SIGN_UPDATE" -p --ed-key-file "$KEY_FILE" "$ZIP")"
  elif [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" -p --ed-key-file - "$ZIP")"
  elif [[ "$USE_KEYCHAIN" == "1" ]]; then
    SIGNATURE="$("$SIGN_UPDATE" -p --account wickbar "$ZIP")"
  else
    echo "No signing key: pass --ed-key-file, set SPARKLE_ED_PRIVATE_KEY, use --keychain, or SKIP_SIGN=1" >&2
    exit 1
  fi
  SIGNATURE="$(printf '%s' "$SIGNATURE" | tr -d '[:space:]')"
  [[ -n "$SIGNATURE" ]] || { echo "sign_update produced no signature" >&2; exit 1; }

  # A key that doesn't match the SUPublicEDKey baked into the app would make every install reject the
  # update, so check the signature against that public key (needs OpenSSL 3; LibreSSL lacks Ed25519).
  OPENSSL=""
  for c in "$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl" /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
    if [[ -x "$(command -v "$c" 2>/dev/null)" ]] && "$c" version 2>/dev/null | grep -q '^OpenSSL 3'; then OPENSSL="$c"; break; fi
  done
  if [[ -n "$OPENSSL" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    # DER SubjectPublicKeyInfo prefix for Ed25519, followed by the 32-byte raw key.
    { printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$PUBLIC_KEY" | base64 -D; } > "$TMP/pub.der"
    printf '%s' "$SIGNATURE" | base64 -D > "$TMP/sig.bin"
    if ! "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.der" -keyform DER -rawin \
         -in "$ZIP" -sigfile "$TMP/sig.bin" >/dev/null 2>&1; then
      echo "Signature does not verify against the app's SUPublicEDKey: wrong private key?" >&2
      exit 1
    fi
    echo "==> Signature verified against SUPublicEDKey"
  else
    echo "warning: OpenSSL 3 not found; skipping the SUPublicEDKey check" >&2
  fi
fi

# --- Release notes (markdown, rendered by Sparkle >= 2.9) ------------------------------------------
NOTES="$(awk -v h="## [$NOTES_SECTION]" '
  index($0, h) == 1 { f = 1; next }
  f && /^## \[/ { exit }
  f && /^\[[^]]+\]: / { next }
  f { print }
' CHANGELOG.md | sed -e '/./,$!d')"
[[ -n "$NOTES" ]] || NOTES="Wickbar $VERSION"
# "]]>" would end the CDATA section early.
NOTES="${NOTES//]]>/]]]]><![CDATA[>}"

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wickbar</title>
    <link>$REPO_URL</link>
    <description>Wickbar updates</description>
    <language>en</language>
    <item>
      <title>Wickbar $SHORT_VERSION</title>
      <link>$REPO_URL/releases/tag/v$VERSION</link>
      <sparkle:version>$BUNDLE_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <pubDate>$PUB_DATE</pubDate>
      <description sparkle:format="markdown"><![CDATA[
$NOTES
]]></description>
      <enclosure url="$ENCLOSURE_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML

xmllint --noout "$OUT"
echo "==> Wrote $OUT (version $BUNDLE_VERSION / $SHORT_VERSION, $LENGTH bytes)"
