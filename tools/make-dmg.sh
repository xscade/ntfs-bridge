#!/bin/bash
# Packages a notarized NTFS Bridge.app into a drag-to-install disk image
# (built with dmgbuild, so Finder is not needed), notarizes the image and
# staples the ticket to it.
#
#   tools/make-dmg.sh path/to/NTFS\ Bridge.app [output-dir]
#
# Notarization credentials come from the environment, either a stored
# notarytool profile:
#   NOTARY_PROFILE=name
# or an App Store Connect API key:
#   NOTARY_KEY=path/to/AuthKey_XXXX.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=uuid
# Set SKIP_NOTARIZE=1 to build an unnotarized image for local testing.
set -euo pipefail

app="${1:?usage: make-dmg.sh path/to/NTFS Bridge.app [output-dir]}"
out="${2:-build/dist}"
[[ -d "$app" ]] || { echo "no such app: $app" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
name="NTFS Bridge"
dmg="$out/NTFS-Bridge-$version.dmg"
mkdir -p "$out"

# The app inside must already be notarized; the image's ticket covers only the image.
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  xcrun stapler validate "$app" >/dev/null || {
    echo "$app has no stapled notarization ticket; export it with xcodebuild -exportNotarizedApp" >&2
    exit 1
  }
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
dmgbuild="$root/build/.venv/bin/dmgbuild"
if [[ ! -x "$dmgbuild" ]]; then
  python3 -m venv "$root/build/.venv"
  "$root/build/.venv/bin/pip" install -q dmgbuild==2.0.0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Licenses travel with the binaries: GPL-3.0 for NTFS Bridge, plus the texts
# for the third-party components in the Linux guest.
lic="$work/Licenses"
mkdir -p "$lic"
cp "$root/LICENSE" "$lic/NTFS Bridge - GPL-3.0.txt"
cp "$root/THIRD_PARTY_NOTICES.md" "$lic/Third-Party Notices.md"
cp "$root"/LICENSES/*.txt "$lic/"

rm -f "$dmg"
"$dmgbuild" -s "$root/tools/dmg-settings.py" -D app="$app" -D licenses="$lic" "$name" "$dmg"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    creds=(--keychain-profile "$NOTARY_PROFILE")
  else
    creds=(--key "${NOTARY_KEY:?set NOTARY_PROFILE or NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER}"
           --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
  fi
  xcrun notarytool submit "$dmg" "${creds[@]}" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

(cd "$out" && shasum -a 256 "$(basename "$dmg")" >"$(basename "$dmg").sha256")
echo "$dmg"
