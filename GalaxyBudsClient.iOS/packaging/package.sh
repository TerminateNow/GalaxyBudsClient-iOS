#!/bin/bash
# Fakesigns a built GalaxyBudsClient.iOS.app with ldid and packs it as an .ipa for TrollStore Lite
# (or AppSync Unified) on a jailbroken device.
# Usage: package.sh <path/to/GalaxyBudsClient.iOS.app> <version> <output dir>
# Needs ldid (ProcursusTeam) and zip. Works on macOS and Linux.
#
# It must be installed as a user app (TrollStore Lite / installd), not dropped into /var/jb/Applications:
# registered with uicache, the app gets neither a writable data container nor GPU access, and Avalonia can't start.
set -euo pipefail

APP="${1:?app bundle}"
VERSION="${2:?version}"
OUT="${3:?output dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LDID="${LDID:-ldid}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/Payload/GalaxyBudsManager.app"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$DEST"
rm -rf "$DEST/_CodeSignature" "$DEST/embedded.mobileprovision"

EXE="$(/usr/bin/python3 -c 'import plistlib,sys;print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleExecutable"])' "$DEST/Info.plist")"

is_macho() {
    local magic
    magic="$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;; *) return 1 ;; esac
}

# Sign nested code first (frameworks, dylibs), then the main executable with the entitlements
while IFS= read -r -d '' f; do
    [ "$f" = "$DEST/$EXE" ] && continue
    if is_macho "$f"; then
        echo "signing ${f#$DEST/}"
        "$LDID" -S "$f"
    fi
done < <(find "$DEST" -type f -print0)
echo "signing $EXE (with entitlements)"
"$LDID" -S"$HERE/entitlements.plist" "$DEST/$EXE"
chmod 0755 "$DEST/$EXE"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
IPA="$OUT/GalaxyBudsManager_${VERSION}_jailbreak.ipa"
rm -f "$IPA"
(cd "$STAGE" && zip -qry "$IPA" Payload)
echo "built $IPA"
