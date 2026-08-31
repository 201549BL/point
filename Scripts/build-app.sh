#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${1:-debug}"
build_dir="$repo_dir/.build/$configuration"
app_dir="$repo_dir/.build/Point.app"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_dir/.build/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="$repo_dir/.build/clang-module-cache"

swift build --disable-sandbox --package-path "$repo_dir" -c "$configuration"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Point "$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.eirikbjorndal.point "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string Point "$app_dir/Contents/Info.plist"
plutil -replace CFBundleName -string Point "$app_dir/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.1.0 "$app_dir/Contents/Info.plist"
plutil -replace CFBundleVersion -string 1 "$app_dir/Contents/Info.plist"
cp "$build_dir/Point" "$app_dir/Contents/MacOS/Point"
signing_identity="${POINT_SIGNING_IDENTITY:-}"
if [[ -n "$signing_identity" ]]; then
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"
else
    print -u2 -- "warning: using an ad-hoc signature; Screen Recording permission may reset after rebuilding"
    print -u2 -- "set POINT_SIGNING_IDENTITY to an Apple Development identity for a stable local build"
    codesign --force --sign - "$app_dir"
fi

print -r -- "$app_dir"
