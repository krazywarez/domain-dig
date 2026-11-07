#!/bin/sh
#
# Archive the app, its widget and its share extension, and upload the result to
# App Store Connect. The work is done by appstore-kit, checked out beside this
# repository or at $APPSTORE_KIT.
#
#   ./Scripts/release-ios.sh            # archive, export and upload
#   DOMAIN_DIG_PUBLISH=0 ./Scripts/release-ios.sh
#                                       # archive and export the .ipa only
#
# The build number is CURRENT_PROJECT_VERSION as committed, not the commit
# count. This project sets it by hand at each cut, states it in the cut's
# commit message, and verifies it against the built product; deriving it
# instead would make the committed value a lie.
#
# A publish requires HEAD to be the commit that v<version> points at, so an
# upload cannot carry code the tag does not. The bundled release notes are
# checked against the marketing version, which nothing else does — the unit
# suite asserts the notes parse, not that they describe this build.

PUBLISH="${DOMAIN_DIG_PUBLISH:-1}"
name=DomainDig
project=DomainDig.xcodeproj
scheme=DomainDig
build_number=committed
allow_untracked=1

preflight() {
    notes_version="$(
        python3 -c 'import json; print(json.load(open("DomainDig/ReleaseNotes.json"))["version"])'
    )"
    [ "$notes_version" = "$version" ] \
        || fail "ReleaseNotes.json is $notes_version but MARKETING_VERSION is $version"
    [ "$publish" != 0 ] || return 0
    git rev-parse -q --verify "refs/tags/v$version" >/dev/null \
        || fail "no tag v$version — cut the release first"
    [ "$(git rev-parse "v$version^{commit}")" = "$(git rev-parse HEAD)" ] \
        || fail "v$version does not point at HEAD"
}

. "${APPSTORE_KIT:-$(dirname "$0")/../../appstore-kit}/release-ios.sh"
