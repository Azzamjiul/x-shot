#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
PROJECT="$PROJECT_ROOT/X-Shot.xcodeproj"
SCHEME="X-Shot"
DIST_DIR="$PROJECT_ROOT/dist"
RELEASE_TMP_ROOT=${TMPDIR:-/tmp}
WORK_DIR=$(/usr/bin/mktemp -d "${RELEASE_TMP_ROOT%/}/x-shot-release.XXXXXX")
DERIVED_DATA="$WORK_DIR/DerivedData"

cleanup() {
    case "$WORK_DIR" in
        "${RELEASE_TMP_ROOT%/}"/x-shot-release.*) /bin/rm -rf "$WORK_DIR" ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $(/usr/bin/uname -m) != "arm64" ]]; then
    print -u2 "X-Shot releases must be built and tested on Apple Silicon."
    exit 1
fi

print "Running tests..."
/usr/bin/xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA" \
    test

print "Building arm64 Release..."
/usr/bin/xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    clean build

APP="$DERIVED_DATA/Build/Products/Release/X-Shot.app"
BINARY="$APP/Contents/MacOS/X-Shot"

if [[ ! -d "$APP" ]]; then
    print -u2 "Release app was not produced at $APP"
    exit 1
fi

ARCHITECTURES=$(/usr/bin/lipo -archs "$BINARY")
if [[ "$ARCHITECTURES" != "arm64" ]]; then
    print -u2 "Expected an arm64-only binary, got: $ARCHITECTURES"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO=$(/usr/bin/codesign -dvv "$APP" 2>&1)
if ! print -r -- "$SIGNATURE_INFO" | /usr/bin/grep -q "Signature=adhoc"; then
    print -u2 "Expected an ad-hoc signature."
    exit 1
fi
if ! print -r -- "$SIGNATURE_INFO" | /usr/bin/grep -Eq "^CodeDirectory .*flags=.*runtime"; then
    print -u2 "Hardened Runtime is not enabled."
    exit 1
fi

ENTITLEMENTS=$(/usr/bin/codesign -d --entitlements - "$APP" 2>/dev/null)
if print -r -- "$ENTITLEMENTS" | /usr/bin/grep -q "com.apple.security.get-task-allow"; then
    print -u2 "Release app contains the debug get-task-allow entitlement."
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if ! print -r -- "$VERSION" | /usr/bin/grep -Eq "^[A-Za-z0-9][A-Za-z0-9._-]*$"; then
    print -u2 "Release version contains unsafe filename characters: $VERSION"
    exit 1
fi

DMG_NAME="X-Shot-${VERSION}-arm64.dmg"
DMG="$DIST_DIR/$DMG_NAME"
TEMP_DMG="$WORK_DIR/$DMG_NAME"
TEMP_CHECKSUM="$WORK_DIR/$DMG_NAME.sha256"
STAGE="$WORK_DIR/dmg-root"

/bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/X-Shot.app"
/bin/ln -s /Applications "$STAGE/Applications"

print "Creating $DMG_NAME..."
/usr/bin/hdiutil create \
    -volname "X-Shot" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$TEMP_DMG"
/usr/bin/hdiutil verify "$TEMP_DMG"

(
    cd "$WORK_DIR"
    /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

/bin/mkdir -p "$DIST_DIR"
/bin/mv -f "$TEMP_DMG" "$DMG"
/bin/mv -f "$TEMP_CHECKSUM" "$DMG.sha256"
(
    cd "$DIST_DIR"
    /usr/bin/shasum -a 256 -c "$DMG_NAME.sha256"
)

print ""
print "Release created:"
print "  $DMG"
print "  $DMG.sha256"
print ""
print "This build is ad-hoc signed and not notarized. Users must approve it in"
print "System Settings > Privacy & Security > Open Anyway on first launch."
