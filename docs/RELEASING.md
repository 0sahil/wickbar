# Releasing Wickbar (maintainers)

Releases are built by GitHub Actions (`.github/workflows/release.yml`): Developer ID signed,
hardened runtime, notarized by Apple, stapled, zipped, and attached to a **draft** GitHub release.

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

## Local signed build (optional)
```sh
xcrun notarytool store-credentials wickbar   # once; interactive
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=wickbar scripts/package-release.sh
# or SKIP_NOTARIZE=1 to only sign
```

## If the membership lapses
Already-published releases keep working (signatures carry a secure timestamp). New releases can't be
signed/notarized until the membership is renewed. Only certificate *revocation* breaks existing installs.
