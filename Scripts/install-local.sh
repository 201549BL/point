#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
derived_data="$repo_dir/.build/xcode"
app_path="$derived_data/Build/Products/Release/Point.app"
destination="/Applications/Point.app"
repair_permissions=false
case "${1:-}" in
    "") ;;
    --repair-permissions) repair_permissions=true ;;
    *) print -u2 -- "Usage: Scripts/install-local.sh [--repair-permissions]"; exit 2 ;;
esac
if (( $# > 1 )); then
    print -u2 -- "Usage: Scripts/install-local.sh [--repair-permissions]"
    exit 2
fi

xcodebuild \
    -project "$repo_dir/Point.xcodeproj" \
    -scheme Point \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=DNPD2D9266 \
    build

lock_dir="${TMPDIR:-/tmp/}point-install-${UID}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    print -u2 -- "Another Point install holds $lock_dir. Wait for it to finish."
    exit 1
fi
trap 'rmdir "$lock_dir"' EXIT

if $repair_permissions; then
    "$repo_dir/Scripts/check-install-signing.sh" "$app_path"
else
    "$repo_dir/Scripts/check-install-signing.sh" "$app_path" "$destination"
fi

# Old builds used this persistent marker to reopen after ANY termination.
# Clear it and allow their already-scheduled one-second helper to drain before replacing files.
defaults delete com.eirikbjorndal.point screenCapturePermissionRelaunchPending 2>/dev/null || true
for attempt in {1..20}; do
    running_pid="$(pgrep -f "^${destination}/Contents/MacOS/Point$" || true)"
    if [[ -n "$running_pid" ]]; then
        kill -TERM ${(f)running_pid}
    fi
    sleep 0.2
done
if pgrep -f "^${destination}/Contents/MacOS/Point$" >/dev/null; then
    print -u2 -- "Point is still running or reopening. Installation stopped before replacing it."
    exit 1
fi

ditto "$app_path" "$destination"
if ! cmp -s "$app_path/Contents/MacOS/Point" "$destination/Contents/MacOS/Point"; then
    print -u2 -- "Installed Point does not match the freshly built Release binary."
    exit 1
fi

"$repo_dir/Scripts/check-install-signing.sh" "$destination"

# In-place installs can otherwise leave Finder and Launch Services holding the
# previous bundle metadata, especially when the version or icon changed.
touch "$destination"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -R -trusted "$destination"
/usr/bin/mdimport "$destination" >/dev/null 2>&1 || true

if $repair_permissions; then
    # Never reset all privacy permissions or touch TCC databases directly.
    tccutil reset ScreenCapture com.eirikbjorndal.point
    print -- "Screen Recording permission reset for Point only. Allow it on the next capture."
fi

print -r -- "Installed $destination"
print -r -- "Verified $(shasum -a 256 "$destination/Contents/MacOS/Point" | cut -d ' ' -f 1)"
open "$destination"
for attempt in {1..30}; do
    if pgrep -f "^${destination}/Contents/MacOS/Point$" >/dev/null; then
        print -- "Point is running from $destination"
        exit 0
    fi
    sleep 0.1
done
print -u2 -- "Installed Point, but could not verify launch."
exit 1
