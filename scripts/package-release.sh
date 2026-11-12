#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled Wickbar release zip.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-release.sh
#
# Notarization credentials (pick one):
#   - App Store Connect API key:  NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   - Stored keychain profile:     NOTARY_PROFILE  (created with `xcrun notarytool store-credentials`)
#   - SKIP_NOTARIZE=1              sign only (local testing; Gatekeeper will still warn)
#
# Output: build/Wickbar-<version>.zip and build/Wickbar-<version>.zip.sha256
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: …' identity}"
case "$SIGN_IDENTITY" in
  "Developer ID Application"*) ;;
  *) echo "SIGN_IDENTITY must be a 'Developer ID Application' certificate (got: $SIGN_IDENTITY)" >&2; exit 1 ;;
esac

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/Wickbar.app"
ZIP="$ROOT/build/Wickbar-$VERSION.zip"

SIGN_IDENTITY="$SIGN_IDENTITY" bash "$ROOT/scripts/build-app.sh"

notary_args=()
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> SKIP_NOTARIZE=1: not notarizing"
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_PATH}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_PATH}"
  notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "No notarization credentials: set NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID or NOTARY_PROFILE (or SKIP_NOTARIZE=1)" >&2
  exit 1
fi

rm -f "$ZIP" "$ZIP.sha256"
if [[ ${#notary_args[@]} -gt 0 ]]; then
  echo "==> Submitting for notarization (this usually takes a few minutes)"
  SUBMIT_ZIP="$ROOT/build/Wickbar-notarize.zip"
  rm -f "$SUBMIT_ZIP"
  ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
  xcrun notarytool submit "$SUBMIT_ZIP" "${notary_args[@]}" --wait --timeout 30m | tee "$ROOT/build/notarize.log"
  if ! grep -q "status: Accepted" "$ROOT/build/notarize.log"; then
    id="$(awk '/^  id:/{print $2; exit}' "$ROOT/build/notarize.log")"
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${notary_args[@]}" || true
    echo "Notarization failed" >&2
    exit 1
  fi
  rm -f "$SUBMIT_ZIP"
  echo "==> Stapling"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> Gatekeeper check"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
cat "$ZIP.sha256"
echo "==> Done: $ZIP"
