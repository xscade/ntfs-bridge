# Releasing

This is the maintainer's checklist for publishing a version. It needs the
Developer ID team's credentials.

## 1. Prepare

- Update `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in
  `app/NTFSBridge.xcodeproj` for both targets.
- Move the `[Unreleased]` notes in [CHANGELOG.md](../CHANGELOG.md) under the new
  version and date.
- If guest packages changed, rebuild with `tools/build-guest.sh` and update the
  versions in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- Run the image self-test and a real-drive test (see
  [CONTRIBUTING.md](../CONTRIBUTING.md#testing)).

## 2. Archive and notarize the app

In Xcode: **Product › Archive**, then in the Organizer choose **Distribute App ›
Direct Distribution**, which uploads the app to Apple's notary service. Then export
the copy Apple notarized, with its ticket stapled:

```bash
xcodebuild -exportNotarizedApp \
  -archivePath ~/Library/Developer/Xcode/Archives/<date>/<archive>.xcarchive \
  -exportPath build/release
xcrun stapler validate "build/release/NTFS Bridge.app"
spctl -a -vv "build/release/NTFS Bridge.app"   # source=Notarized Developer ID
```

> [!IMPORTANT]
> Use `-exportNotarizedApp`, not `-exportArchive`. A new export re-signs the app,
> which changes its code hash, so the ticket Apple issued no longer matches.

To check on a submission, use an App Store Connect API key:

```bash
xcrun notarytool history --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
xcrun notarytool log <submission-id> --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>
```

## 3. Build the disk image

```bash
NOTARY_KEY=path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=<issuer-id> \
  tools/make-dmg.sh "build/release/NTFS Bridge.app"
```

This builds `build/dist/NTFS-Bridge-<version>.dmg` with the app, an Applications
shortcut and the license texts, then notarizes and staples the image and writes
a `.sha256` file next to it. You can use `NOTARY_PROFILE=<name>` instead, for a
profile saved with `xcrun notarytool store-credentials`.

## 4. Collect the GPL source

Bundle the exact upstream sources and Alpine recipes for every GPL component in
the guest (see [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)) into
`ntfs-bridge-<version>-gpl-sources.tar`. The `origin` and `commit` fields in
each package's `.PKGINFO` (inside `build/cache/*.apk`) identify the aports
commit to take.

## 5. Publish

```bash
git tag -a v<version> -m "NTFS Bridge <version>"
git push origin v<version>
gh release create v<version> --title "NTFS Bridge <version>" --notes-file <notes> \
  build/dist/NTFS-Bridge-<version>.dmg build/dist/NTFS-Bridge-<version>.dmg.sha256 \
  ntfs-bridge-<version>-gpl-sources.tar
```

Then download the disk image from the release page and open it on a Mac to check
that Gatekeeper accepts it.
