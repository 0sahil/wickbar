# Releasing Wickbar (maintainers)

Releases are built by GitHub Actions (`.github/workflows/release.yml`): Developer ID signed,
hardened runtime, notarized by Apple, stapled, packaged as a drag-to-Applications `.dmg` (also signed,
notarized and stapled) and a `.zip`, and attached to a **draft** GitHub release together with the
Sparkle `appcast.xml` that installed copies use to find updates.

## One-time setup

### 1. Developer ID Application certificate
An *Apple Distribution* certificate is for the App Store and won't work here.

1. developer.apple.com › Certificates, Identifiers & Profiles › Certificates › **+**
2. Choose **Developer ID Application** (Account Holder role required), upload a CSR from
   Keychain Access › Certificate Assistant › *Request a Certificate From a Certificate Authority…*
3. Download and double-click the certificate so it lands in your login keychain next to its private key.
4. Check: `security find-identity -v -p codesigning` should list `Developer ID Application: … (TEAMID)`.
5. Export it: Keychain Access › My Certificates › right-click the certificate › *Export…* › `.p12`, with a strong password.

### 2. App Store Connect API key (for notarization)
appstoreconnect.apple.com › Users and Access › Integrations › **App Store Connect API** › Team Keys › **+**,
role *Developer*. Download the `.p8` (you can only download it once) and note the **Key ID** and **Issuer ID**.

### 3. GitHub secrets
Run these yourself (they prompt for values, or read files) — never commit these files:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R 0sahil/wickbar
gh secret set DEVELOPER_ID_P12_PASSWORD -R 0sahil/wickbar          # paste the .p12 password
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_BASE64 -R 0sahil/wickbar
gh secret set NOTARY_API_KEY_ID -R 0sahil/wickbar                  # e.g. XXXXXXXXXX
gh secret set NOTARY_API_ISSUER_ID -R 0sahil/wickbar               # UUID
```

Then delete the exported `.p12` (the certificate stays in your keychain) and store the `.p8` somewhere safe.

### 4. Sparkle update signing key (EdDSA)
Updates are verified against the public key baked into every build (`SUPublicEDKey` in `scripts/build-app.sh`).
The key pair already exists; its private half is in the maintainer's login keychain under the account `wickbar`.
Sparkle's tools are in `.build/artifacts/sparkle/Sparkle/bin/` after `swift package resolve`.

```sh
BIN=.build/artifacts/sparkle/Sparkle/bin
$BIN/generate_keys --account wickbar          # prints the public key (creates a pair only if none exists)
$BIN/generate_keys --account wickbar -x key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY -R 0sahil/wickbar < key.txt
rm key.txt
```

The printed public key must equal `SUPublicEDKey`. **Back the private key up** (e.g. in a password manager, from
`generate_keys -x`): if it is lost, existing installs can never be updated again, because they only accept
updates signed with it. If it leaks, anyone who can serve the appcast can push an update.

## Cutting a release
1. Update `VERSION` (e.g. `0.2.0`) and move the `## [Unreleased]` notes in `CHANGELOG.md` under
   `## [0.2.0] - YYYY-MM-DD` (plus the compare links at the bottom).
2. Commit, then tag and push:
   ```sh
   git commit -am "Release 0.2.0"
   git tag v0.2.0 && git push origin main v0.2.0
   ```
3. Watch the *Release* workflow. When it finishes, open the draft release on GitHub, review the notes,
   and click **Publish**.

To rebuild an existing tag: Actions › Release › *Run workflow* with the tag name.

## Updates (Sparkle)
- `scripts/build-app.sh` embeds `Sparkle.framework` (minus its XPC services, which only sandboxed apps need)
  and writes `SUFeedURL` = `https://github.com/0sahil/wickbar/releases/latest/download/appcast.xml`.
- After notarizing, the workflow runs `scripts/make-appcast.sh`: it signs `Wickbar-<version>.zip` with
  `sign_update` (key from the `SPARKLE_ED_PRIVATE_KEY` secret, via stdin), checks the signature against the
  app's `SUPublicEDKey`, and writes `build/appcast.xml` with one item. `sparkle:version` is the built app's
  `CFBundleVersion` (the git commit count, which is what Sparkle compares), `sparkle:shortVersionString` is
  `VERSION`, and the release notes are this version's CHANGELOG section (Markdown, rendered by Sparkle).
  Updates download the zip, never the DMG.
- **Publishing is the gate.** `releases/latest/download/appcast.xml` resolves to the latest *published*
  release, so installed copies only see the new version once you click **Publish** on the draft. Until
  then they keep reading the previous release's appcast.
- Users on 0.1.x have no updater and must install 0.2.0 by hand once.

### Testing an update locally
`WickbarUpdateFeedURL` (a user default) overrides the feed URL. Signatures are still checked, so the zip must be
signed with the real key.

```sh
# 1. Build and zip a "newer" app (more commits than the installed copy, or bump VERSION locally),
#    then write its appcast with the real key from your keychain:
scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent build/Wickbar.app build/Wickbar-$(cat VERSION).zip
scripts/make-appcast.sh --keychain --notes-section Unreleased
# 2. Serve build/ and point the installed (older) Wickbar at it:
sed -i '' "s#https://github.com/0sahil/wickbar/releases/download/v[^/]*/#http://127.0.0.1:8765/#" build/appcast.xml
(cd build && python3 -m http.server 8765) &
defaults write com.0sahil.wickbar WickbarUpdateFeedURL http://127.0.0.1:8765/appcast.xml
# 3. In Wickbar: Check for Updates… ; afterwards:
defaults delete com.0sahil.wickbar WickbarUpdateFeedURL
```

`SKIP_SIGN=1 scripts/make-appcast.sh` writes a placeholder signature for checking the XML only; such an
appcast won't install.

## Local signed build (optional)
```sh
brew install create-dmg                      # once
xcrun notarytool store-credentials wickbar   # once; interactive
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=wickbar scripts/package-release.sh
# or SKIP_NOTARIZE=1 to only sign
```

## If the membership lapses
Already-published releases keep working (signatures carry a secure timestamp). New releases can't be
signed/notarized until the membership is renewed. Only certificate *revocation* breaks existing installs.
