#!/usr/bin/env bash
#
# Archive the app, its widget and its share extension, and upload the result to
# App Store Connect. Signed automatically with the team's distribution
# certificate through the Apple ID signed in to Xcode. The upload appears in
# TestFlight once processed, and can then be chosen for a submission.
#
#   ./Scripts/release-ios.sh            # archive, export and upload
#   DOMAIN_DIG_PUBLISH=0 ./Scripts/release-ios.sh
#                                       # archive and export the .ipa only
#
# Adapted from moonrise's scripts/release-ios.sh, with two differences that
# matter.
#
# The build number is CURRENT_PROJECT_VERSION as committed, not the commit
# count. This project sets it by hand at each cut, states it in the cut's
# commit message, and verifies it against the built product; deriving it here
# instead would make the committed value a lie, and the two would drift apart
# from the first upload. moonrise has no such convention, so a commit count
# costs it nothing.
#
# The preflight is stricter, because this project tags every release. A publish
# requires HEAD to be the commit that v<version> points at, so an upload cannot
# carry code the tag does not. It also checks the bundled release notes against
# the marketing version, which nothing else does — the unit suite asserts the
# notes parse, not that they describe this build.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="DomainDig.xcodeproj"
SCHEME="DomainDig"
TEAM="ZCNAX3VL9D"
PUBLISH="${DOMAIN_DIG_PUBLISH:-1}"
OUT=".build/ios-release"

fail() {
    echo "release-ios: $1" >&2
    exit 1
}

# One value across all ten configurations, or the archive would disagree with
# the tag depending on which target you read.
single_setting() {
    local key="$1" values
    values="$(grep -oE "$key = [^;]+;" "$PROJECT/project.pbxproj" | sed -E "s/$key = (.*);/\1/" | sort -u)"
    [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ] \
        || fail "$key differs across configurations: $(printf '%s' "$values" | tr '\n' ' ')"
    printf '%s' "$values"
}

version="$(single_setting MARKETING_VERSION)"
build="$(single_setting CURRENT_PROJECT_VERSION)"

notes_version="$(
    python3 -c 'import json,sys; print(json.load(open("DomainDig/ReleaseNotes.json"))["version"])'
)"
[ "$notes_version" = "$version" ] \
    || fail "ReleaseNotes.json is $notes_version but MARKETING_VERSION is $version"

if [ "$PUBLISH" != 0 ]; then
    [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "the working tree has changes"
    [ "$(git branch --show-current)" = main ] || fail "release from main"
    git rev-parse -q --verify "refs/tags/v$version" >/dev/null \
        || fail "no tag v$version — cut the release first"
    [ "$(git rev-parse "v$version^{commit}")" = "$(git rev-parse HEAD)" ] \
        || fail "v$version does not point at HEAD"
fi

echo "==> DomainDig $version ($build)"

rm -rf "${OUT:?}"
mkdir -p "$OUT"
archive="$OUT/DomainDig.xcarchive"

echo "==> Archiving"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    -quiet

# The same check the release cuts make by hand: the project file is not the
# product, and Xcode has migrated Info.plist keys out from under this project
# before.
plist="$archive/Products/Applications/DomainDig.app/Info.plist"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
built_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[ "$built_version" = "$version" ] || fail "archive is $built_version, expected $version"
[ "$built_build" = "$build" ] || fail "archive is build $built_build, expected $build"

if [ "$PUBLISH" = 0 ]; then destination=export; else destination=upload; fi
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> ${destination^}ing"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" \
    -allowProvisioningUpdates \
    -quiet

echo
if [ "$PUBLISH" = 0 ]; then
    echo "==> Exported $(ls "$OUT"/export/*.ipa 2>/dev/null | head -1)"
    echo "    DomainDig $version ($build). Not uploaded."
else
    echo "==> Uploaded DomainDig $version ($build) to App Store Connect."
    echo "    It appears in TestFlight once processing finishes."
fi
