#!/usr/bin/env bash

set -Eeuo pipefail

# Build a Developer ID-signed, notarized, stapled DMG for Stacks.
#
# Local prerequisites:
#   - Xcode 27 selected via xcode-select or DEVELOPER_DIR
#   - Developer ID Application certificate with its private key in Keychain
#   - notarytool credentials stored with `xcrun notarytool store-credentials`
#
# CI prerequisites:
#   - a macOS runner with Xcode 27
#   - a Developer ID Application certificate imported into the runner keychain
#   - APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, and APPLE_API_PRIVATE_KEY secrets
#
# Useful examples:
#   ./Scripts/release.sh --dry-run
#   ./Scripts/release.sh --skip-notarization
#   NOTARYTOOL_PROFILE=StacksNotary ./Scripts/release.sh

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Stacks.xcodeproj}"
SCHEME="${SCHEME:-Stacks}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-N7J3BYZ94H}"
APP_NAME="${APP_NAME:-Stacks}"
VOLUME_NAME="${VOLUME_NAME:-Stacks}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
BUILD_DIR="${BUILD_DIR:-$DIST_DIR/.release}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_API_KEY_ID="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER_ID="${APPLE_API_ISSUER_ID:-}"
APPLE_API_KEY_PATH="${APPLE_API_KEY_PATH:-}"
APPLE_API_PRIVATE_KEY="${APPLE_API_PRIVATE_KEY:-}"
VERSION="${VERSION:-}"
DRY_RUN=0
SKIP_NOTARIZATION=0

ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg-root"
EXPORT_OPTIONS_PATH="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH=""

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh [options]

Builds, signs, notarizes, staples, and validates a Stacks DMG.

Options:
  --dry-run             Print the release plan without running build commands.
  --skip-notarization   Build and sign the DMG but do not submit or staple it.
  -h, --help            Show this help.

Environment overrides:
  DEVELOPER_DIR         Xcode developer directory.
  DEVELOPER_IDENTITY    Exact Developer ID Application identity to use.
  TEAM_ID               Apple Developer Team ID (defaults to this project team).
  VERSION               DMG version suffix; otherwise read from the exported app.
  NOTARYTOOL_PROFILE    Keychain profile created with `xcrun notarytool store-credentials`.
  APPLE_API_KEY_ID      App Store Connect Team API key ID for CI notarization.
  APPLE_API_ISSUER_ID   App Store Connect issuer ID for CI notarization.
  APPLE_API_KEY_PATH    Path to the App Store Connect .p8 private key.
  APPLE_API_PRIVATE_KEY Contents of the .p8 private key, commonly supplied as a CI secret.
  DIST_DIR              Output directory (defaults to ./dist).
  BUILD_DIR             Temporary release directory (defaults to ./dist/.release).

The default notarization method is a keychain profile. For CI, use the API-key
environment variables so no Apple password is stored in the repository.
EOF
}

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

assert_safe_build_dir() {
  [[ -n "$BUILD_DIR" ]] || die "BUILD_DIR must not be empty"
  [[ "$BUILD_DIR" != "/" ]] || die "BUILD_DIR must not be /"
  [[ "$BUILD_DIR" != "$ROOT_DIR" ]] || die "BUILD_DIR must not be the repository root"
  case "$BUILD_DIR" in
    "$ROOT_DIR"/*) ;;
    *) die "BUILD_DIR must be inside the repository: $BUILD_DIR" ;;
  esac
}

resolve_developer_identity() {
  if [[ -n "$DEVELOPER_IDENTITY" ]]; then
    return
  fi

  DEVELOPER_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' \
    | head -n 1)"

  [[ -n "$DEVELOPER_IDENTITY" ]] || die \
    "no Developer ID Application identity found; install the certificate and private key, or set DEVELOPER_IDENTITY"
}

write_export_options() {
  mkdir -p "$BUILD_DIR"
  cat >"$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF
}

notarize() {
  if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    run xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARYTOOL_PROFILE" \
      --wait
    return
  fi

  [[ -n "$APPLE_API_KEY_ID" ]] || die \
    "set NOTARYTOOL_PROFILE or APPLE_API_KEY_ID/APPLE_API_ISSUER_ID/APPLE_API_KEY_PATH for notarization"
  [[ -n "$APPLE_API_ISSUER_ID" ]] || die "APPLE_API_ISSUER_ID is required for API-key notarization"

  local key_path="$APPLE_API_KEY_PATH"
  if [[ -z "$key_path" && -n "$APPLE_API_PRIVATE_KEY" ]]; then
    key_path="$BUILD_DIR/AuthKey_${APPLE_API_KEY_ID}.p8"
    umask 077
    printf '%s\n' "$APPLE_API_PRIVATE_KEY" >"$key_path"
  fi
  [[ -n "$key_path" ]] || die "set APPLE_API_KEY_PATH or APPLE_API_PRIVATE_KEY for API-key notarization"
  [[ -f "$key_path" ]] || die "Apple API private key not found: $key_path"

  run xcrun notarytool submit "$DMG_PATH" \
    --key "$key_path" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait
}

while (($# > 0)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-notarization)
      SKIP_NOTARIZATION=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

if (( DRY_RUN )); then
  echo "Stacks release dry run"
  echo "  project:       $PROJECT_PATH"
  echo "  scheme:        $SCHEME"
  echo "  configuration: $CONFIGURATION"
  echo "  team:          $TEAM_ID"
  echo "  build dir:     $BUILD_DIR"
  echo "  notarization:  $([[ $SKIP_NOTARIZATION -eq 1 ]] && echo skipped || echo enabled)"
  echo
  echo "The actual app version and DMG filename are resolved after export."
  exit 0
fi

for command_name in xcodebuild xcrun codesign hdiutil spctl ditto security; do
  require_command "$command_name"
done
assert_safe_build_dir
resolve_developer_identity

XCODE_MAJOR="$(xcodebuild -version | awk 'NR == 1 { split($2, version, "."); print version[1]; exit }')"
[[ "$XCODE_MAJOR" == "27" ]] || die "Xcode 27 is required; selected Xcode reports major version $XCODE_MAJOR"

mkdir -p "$DIST_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$STAGING_DIR"
write_export_options

echo "Archiving $SCHEME with Xcode $XCODE_MAJOR..."
run xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  archive

echo "Exporting Developer ID application..."
run xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

[[ -d "$APP_PATH" ]] || die "exported app not found: $APP_PATH"

if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
fi
[[ -n "$VERSION" ]] || die "could not determine app version"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "Verifying exported app signature..."
run codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating DMG..."
run ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
run ln -s /Applications "$STAGING_DIR/Applications"
run hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

echo "Signing DMG with $DEVELOPER_IDENTITY..."
run codesign --force --timestamp --sign "$DEVELOPER_IDENTITY" "$DMG_PATH"
run codesign --verify --verbose=2 "$DMG_PATH"
run hdiutil verify "$DMG_PATH"

if (( SKIP_NOTARIZATION )); then
  echo "Skipping notarization and stapling by request."
else
  echo "Submitting DMG for notarization..."
  notarize
  echo "Stapling notarization ticket..."
  run xcrun stapler staple "$DMG_PATH"
  run xcrun stapler validate "$DMG_PATH"
  run spctl -a -vv --type open "$DMG_PATH"
  run spctl -a -vv --type execute "$APP_PATH"
fi

echo "Release artifact: $DMG_PATH"
