#!/bin/bash
# Fakesigns a built GalaxyBudsClient.iOS.app with ldid and packs it into a rootless .deb.
# Usage: package.sh <path/to/GalaxyBudsClient.iOS.app> <version> <output dir>
# Needs ldid (ProcursusTeam) and dpkg-deb. Works on macOS and Linux.
set -euo pipefail

APP="${1:?app bundle}"
VERSION="${2:?version}"
OUT="${3:?output dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LDID="${LDID:-ldid}"

STAGE="$(mktemp -d)"
chmod 0755 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/var/jb/Applications/GalaxyBudsManager.app"
mkdir -p "$(dirname "$DEST")"
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

mkdir -p "$STAGE/DEBIAN"
sed "s/@VERSION@/$VERSION/" "$HERE/DEBIAN/control" > "$STAGE/DEBIAN/control"
cp "$HERE/DEBIAN/postinst" "$HERE/DEBIAN/prerm" "$STAGE/DEBIAN/"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

mkdir -p "$OUT"
DEB="$OUT/com.galaxybudsclient.app_${VERSION}_iphoneos-arm64.deb"
dpkg-deb -Zgzip --root-owner-group -b "$STAGE" "$DEB"
echo "built $DEB"
