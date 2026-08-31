#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
project="$repo_dir/Point.xcodeproj"
scheme="Point"
team_id="${POINT_TEAM_ID:-DNPD2D9266}"
signing_identity="${POINT_DISTRIBUTION_IDENTITY:-Developer ID Application}"
notary_profile="${POINT_NOTARY_PROFILE:-point-notary}"
export_options="$repo_dir/Scripts/ExportOptions.plist"

version="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null | awk '/MARKETING_VERSION =/ { print $3; exit }')"
build_number="$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null | awk '/CURRENT_PROJECT_VERSION =/ { print $3; exit }')"

if [[ -z "$version" || -z "$build_number" ]]; then
    print -u2 -- "Could not read Point's version from the Xcode project."
    exit 1
fi

release_dir="$repo_dir/Releases/Point-$version"
archive_path="$release_dir/Point.xcarchive"
export_dir="$release_dir/export"
submission_zip="$release_dir/Point-$version-notarization.zip"
distribution_zip="$release_dir/Point-$version-macOS.zip"
checksum_file="$release_dir/SHA256SUMS"

if ! security find-identity -v -p codesigning | grep -Fq "$signing_identity"; then
    print -u2 -- "No '$signing_identity' signing identity is available in the keychain."
    print -u2 -- "Create a Developer ID Application certificate in Xcode before releasing."
    exit 1
fi

if [[ -e "$release_dir" ]]; then
    print -u2 -- "Release output already exists: $release_dir"
    print -u2 -- "Move it aside or remove that exact directory before rebuilding."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    print -u2 -- "Notarization profile '$notary_profile' is unavailable."
    print -u2 -- "Store credentials with: xcrun notarytool store-credentials '$notary_profile'"
    exit 1
fi

mkdir -p "$release_dir"

print -- "Running tests..."
swift test --package-path "$repo_dir"

print -- "Archiving Point $version ($build_number)..."
xcodebuild archive \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive_path" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$signing_identity" \
    DEVELOPMENT_TEAM="$team_id"

print -- "Exporting the Developer ID app..."
xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options"

app_path="$export_dir/Point.app"
if [[ ! -d "$app_path" ]]; then
    print -u2 -- "Xcode did not export Point.app at $app_path"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"

print -- "Submitting Point to Apple's notary service..."
xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" \
    --wait

print -- "Stapling and validating the notarization ticket..."
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$distribution_zip"
(
    cd "$release_dir"
    shasum -a 256 "${distribution_zip:t}" > "${checksum_file:t}"
)

print -- "Release ready:"
print -- "  $distribution_zip"
print -- "  $checksum_file"
print -- "Publish with: Scripts/publish-release.sh $version"
