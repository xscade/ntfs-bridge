#!/bin/bash
# Installs a built NTFS Bridge.app into /Applications, avoiding what is known to
# reset the FSKit "File System Extensions" switch.
#
# Known to reset it: a second registered copy with the same bundle ID (Xcode's
# build products, an .xcarchive), `pluginkit -a`, or unregistering the installed
# copy. Even with those avoided, macOS 27.0.1 sometimes turns the switch off after
# an update (observed 1 in 4 installs); the script reports the state, and the app
# shows a banner when the module is off. This script
#   1. cleanly unmounts every volume served by NTFS Bridge,
#   2. unregisters and deletes the build-products copy before anything else sees it,
#   3. replaces the bundle's contents in place (same path, same record),
#   4. re-registers only /Applications and reports the switch state.
set -euo pipefail
src="${1:?usage: install-app.sh path/to/NTFS Bridge.app}"
dst="/Applications/NTFS Bridge.app"
lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
probe="$(cd "$(dirname "$0")/.." && pwd)/build/probe-dd/Build/Products/Release/FSKitProbe.app/Contents/MacOS/FSKitProbe"

state() {
  [[ -x "$probe" ]] || { echo "(probe not built)"; return; }
  "$probe" list | grep com.ravi.NTFSBridge.FS || echo "com.ravi.NTFSBridge.FS not registered yet"
}
echo "before: $(state)"

osascript -e 'quit app "NTFS Bridge"' 2>/dev/null || true
# NTFS Bridge reports its volumes as type "ntfs" through fskit.
for vol in $(mount | awk '/\(ntfs, .*fskit/ {print $1}'); do
  echo "unmounting $vol"
  diskutil unmount "$vol"
done

staged="$(mktemp -d)/NTFS Bridge.app"
ditto "$src" "$staged"
"$lsr" -u "$src" 2>/dev/null || true
rm -rf "$src"

mkdir -p "$dst"
rsync -a --delete "$staged/" "$dst/"
rm -rf "$(dirname "$staged")"
"$lsr" -f "$dst"
sleep 6
echo "after:  $(state)"
if ! state | grep -q "enabled=true"; then
  echo "NTFS Bridge is switched off: System Settings › General › Login Items & Extensions › By Category › File System Extensions."
fi
open "$dst"
