#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
version="${1:-}"

if [[ -z "$version" ]]; then
    print -u2 -- "Usage: Scripts/publish-release.sh <version>"
    exit 1
fi

tag="v$version"
release_dir="$repo_dir/Releases/Point-$version"
archive="$release_dir/Point-$version-macOS.zip"
checksums="$release_dir/SHA256SUMS"

if [[ ! -f "$archive" || ! -f "$checksums" ]]; then
    print -u2 -- "Build and notarize Point $version with Scripts/release.sh first."
    exit 1
fi

(
    cd "$release_dir"
    shasum -a 256 -c "${checksums:t}"
)

codesign --verify --deep --strict --verbose=2 "$release_dir/export/Point.app"
xcrun stapler validate "$release_dir/export/Point.app"
spctl --assess --type execute --verbose=2 "$release_dir/export/Point.app"

cd "$repo_dir"
if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 -- "The Git working tree must be clean before publishing a release."
    exit 1
fi

gh release create "$tag" \
    "$archive" \
    "$checksums" \
    --target main \
    --title "Point $version" \
    --generate-notes
