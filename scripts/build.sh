#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-$project_dir/dist}"
scratch_dir="${QUOTABAR_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$destination" "$scratch_dir"
export CLANG_MODULE_CACHE_PATH="$scratch_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_dir/swift-cache"
swift build --package-path "$project_dir" --scratch-path "$scratch_dir" --disable-sandbox -c release
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$scratch_dir" --disable-sandbox -c release --show-bin-path)"
app_dir="$destination/QuotaBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/QuotaBar" "$app_dir/Contents/MacOS/QuotaBar"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
if [ -f "$project_dir/Resources/AppIcon.icns" ]; then
    cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "Built: $app_dir"
