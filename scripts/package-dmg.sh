#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${1:-$project_dir/dist/QuotaBar.app}"
destination="${2:-$project_dir/dist}"
scratch_root="${QUOTABAR_DMG_WORK_DIR:-${TMPDIR:-/tmp}}"
if [ ! -f "$app_dir/Contents/MacOS/QuotaBar" ]; then
    printf '%s\n' "Build QuotaBar.app first with scripts/build.sh." >&2
    exit 1
fi
codesign --verify --deep --strict "$app_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architectures="$(lipo -archs "$app_dir/Contents/MacOS/QuotaBar")"
case "$architectures" in
    arm64) architecture=arm64 ;;
    x86_64) architecture=x86_64 ;;
    *arm64*x86_64*|*x86_64*arm64*) architecture=universal ;;
    *) printf '%s\n' "Unsupported architecture: $architectures" >&2; exit 1 ;;
esac
mkdir -p "$destination" "$scratch_root"
stage_dir="$(mktemp -d "$scratch_root/quotabar-dmg.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
payload_dir="$stage_dir/payload"
mkdir "$payload_dir"
ditto --norsrc --noextattr "$app_dir" "$payload_dir/QuotaBar.app"
ln -s /Applications "$payload_dir/Applications"
cp "$project_dir/docs/index.html" "$payload_dir/使い方.html"
dmg_path="$destination/QuotaBar-$version-$architecture.dmg"
# Build the HFS+ filesystem without mounting a temporary disk device.
hdiutil makehybrid -hfs -hfs-volume-name "QuotaBar $version" -hfs-openfolder "$payload_dir" -o "$stage_dir/QuotaBar.hfs.dmg" "$payload_dir"
hdiutil convert "$stage_dir/QuotaBar.hfs.dmg" -format UDZO -o "$dmg_path" -ov
hdiutil verify "$dmg_path"
(cd "$destination" && shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256")
printf '%s\n' "Packaged: $dmg_path"
