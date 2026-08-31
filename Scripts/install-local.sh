#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
derived_data="$repo_dir/.build/xcode"
app_path="$derived_data/Build/Products/Release/Point.app"
destination="/Applications/Point.app"

xcodebuild \
    -project "$repo_dir/Point.xcodeproj" \
    -scheme Point \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    build

if ! codesign --verify --deep --strict "$app_path"; then
    print -u2 -- "Point was not signed successfully. Select your Team in Xcode's Point target first."
    exit 1
fi

signature_details="$(codesign --display --verbose=2 "$app_path" 2>&1)"
if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
    print -u2 -- "Point has an ad-hoc signature."
    print -u2 -- "Open Point.xcodeproj and select an Apple Development Team under Signing & Capabilities, then retry."
    exit 1
fi

running_pid="$(pgrep -f "^${destination}/Contents/MacOS/Point$" || true)"
if [[ -n "$running_pid" ]]; then
    kill -TERM ${(f)running_pid}
    for _ in {1..30}; do
        if ! pgrep -f "^${destination}/Contents/MacOS/Point$" >/dev/null; then
            break
        fi
        sleep 0.1
    done
    if pgrep -f "^${destination}/Contents/MacOS/Point$" >/dev/null; then
        print -u2 -- "Could not quit the installed Point app. Quit it manually, then retry."
        exit 1
    fi
fi

ditto "$app_path" "$destination"
if ! cmp -s "$app_path/Contents/MacOS/Point" "$destination/Contents/MacOS/Point"; then
    print -u2 -- "Installed Point does not match the freshly built Release binary."
    exit 1
fi

# In-place installs can otherwise leave Finder and Launch Services holding the
# previous bundle metadata, especially when the version or icon changed.
touch "$destination"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -R -trusted "$destination"
/usr/bin/mdimport "$destination" >/dev/null 2>&1 || true

print -r -- "Installed $destination"
print -r -- "Verified $(shasum -a 256 "$destination/Contents/MacOS/Point" | cut -d ' ' -f 1)"
open -n "$destination"
