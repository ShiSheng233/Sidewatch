#!/bin/zsh
# Builds a Developer ID-signed, notarized, stapled Sidewatch DMG.
#
#   Scripts/release.sh [-h]
#
# Environment:
#   TEAM_ID         Apple Developer team ID (default: DEVELOPMENT_TEAM from Config/Local.xcconfig)
#   NOTARY_PROFILE  notarytool keychain profile (default: sidewatch-notary)
#   OUTPUT_DIR      build output directory (default: build/release)
#   SKIP_NOTARIZE=1 sign and package only; skip notarization and stapling
#   ALLOW_DIRTY=1   build even if the working tree has uncommitted changes
#
# The version and build number come from Config/Version.xcconfig.
#
# One-time setup of the keychain profile (app-specific password from
# account.apple.com, or use --key/--key-id/--issuer for an API key):
#   xcrun notarytool store-credentials sidewatch-notary \
#     --apple-id <apple-id> --team-id <team-id>

set -euo pipefail
setopt extendedglob

if [[ ${1:-} == (-h|--help) ]]; then
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 0
fi

APP_NAME=Sidewatch
APP_ID=dev.shisheng.Sidewatch
EXT_ID=dev.shisheng.Sidewatch.Monitor

ROOT=${0:A:h:h}
NOTARY_PROFILE=${NOTARY_PROFILE:-sidewatch-notary}
OUTPUT_DIR=${OUTPUT_DIR:-$ROOT/build/release}
ARCHIVE=$OUTPUT_DIR/$APP_NAME.xcarchive
EXPORT_DIR=$OUTPUT_DIR/export
EXPORT_OPTIONS=$OUTPUT_DIR/ExportOptions.plist
APP=$EXPORT_DIR/$APP_NAME.app
EXT=$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension

step() { print -P "\n%F{cyan}==>%f %B$*%b" }
fail() { print -P "%F{red}error:%f $*" >&2; exit 1 }

notarize() {
  local file=$1 result id state
  step "Notarizing ${file:t}"
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json) || true
  id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null) || id=
  state=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null) || state=
  if [[ $state != Accepted ]]; then
    print -r -- "$result" >&2
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    fail "notarization of ${file:t} finished with status '${state:-unknown}'"
  fi
  print "Accepted ($id)"
}

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 ||
    fail "notarytool profile '$NOTARY_PROFILE' not found; see the setup note at the top of this script"
fi

# The team ID is not committed: read it from the environment or Config/Local.xcconfig.
xcconfig_value() {
  awk -F= -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" { gsub(/[[:space:]]/, "", $2); value = $2 } END { print value }' "$2"
}
if [[ -z ${TEAM_ID:-} && -f $ROOT/Config/Local.xcconfig ]]; then
  TEAM_ID=$(xcconfig_value DEVELOPMENT_TEAM "$ROOT/Config/Local.xcconfig")
fi
[[ ${TEAM_ID:-} == [A-Z0-9](#c10) ]] ||
  fail "set TEAM_ID or DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Local.xcconfig.example)"

if [[ -z ${ALLOW_DIRTY:-} && -n $(git -C "$ROOT" status --porcelain 2>/dev/null) ]]; then
  fail "the working tree has uncommitted changes; commit them or set ALLOW_DIRTY=1"
fi

VERSION=$(xcconfig_value MARKETING_VERSION "$ROOT/Config/Version.xcconfig")
BUILD=$(xcconfig_value CURRENT_PROJECT_VERSION "$ROOT/Config/Version.xcconfig")
[[ -n $VERSION && -n $BUILD ]] || fail "Config/Version.xcconfig must set MARKETING_VERSION and CURRENT_PROJECT_VERSION"
print "$APP_NAME $VERSION ($BUILD), team $TEAM_ID"

SIGN_ID=$(security find-identity -v -p codesigning |
  awk -v t="($TEAM_ID)" '/"Developer ID Application:/ && index($0, t) { print $2; exit }')
[[ -n $SIGN_ID ]] || fail "no Developer ID Application identity for team $TEAM_ID in the keychain"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

step "Archiving"
xcodebuild archive \
  -project "$ROOT/$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUTPUT_DIR/DerivedData" \
  -clonedSourcePackagesDirPath "$OUTPUT_DIR/SourcePackages" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -quiet

step "Exporting with Developer ID"
cp "$ROOT/Scripts/ExportOptions.plist" "$EXPORT_OPTIONS"
plutil -replace teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -quiet
[[ -d $APP && -d $EXT ]] || fail "exported app or embedded system extension is missing"

step "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
for bundle in "$APP" "$EXT"; do
  info=$(codesign -dvv "$bundle" 2>&1)
  grep -q "Authority=Developer ID Application:.*($TEAM_ID)" <<<"$info" ||
    fail "${bundle:t} is not signed with Developer ID"
  grep -q "flags=.*runtime" <<<"$info" || fail "${bundle:t} lacks the hardened runtime"
  grep -q "Timestamp=" <<<"$info" || fail "${bundle:t} lacks a secure timestamp"
  ents=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null)
  [[ $ents != *get-task-allow* ]] || fail "${bundle:t} has get-task-allow"
  [[ -f $bundle/Contents/embedded.provisionprofile ]] ||
    fail "${bundle:t} has no embedded provisioning profile"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null |
  grep -q com.apple.developer.system-extension.install || fail "app lacks system-extension.install"
codesign -d --entitlements - --xml "$EXT" 2>/dev/null |
  grep -q com.apple.developer.endpoint-security.client || fail "extension lacks endpoint-security.client"
# sysextd rejects Endpoint Security extensions without this key ("validation").
plutil -extract NSSystemExtensionUsageDescription raw "$EXT/Contents/Info.plist" >/dev/null 2>&1 ||
  fail "extension Info.plist lacks NSSystemExtensionUsageDescription"

for bundle in "$APP" "$EXT"; do
  [[ $(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist") == "$VERSION" &&
     $(plutil -extract CFBundleVersion raw "$bundle/Contents/Info.plist") == "$BUILD" ]] ||
    fail "${bundle:t} version does not match Config/Version.xcconfig"
done
DMG=$OUTPUT_DIR/$APP_NAME-$VERSION.dmg

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  # Notarize and staple the app itself so the copy in /Applications passes
  # Gatekeeper offline, then wrap it in a separately notarized DMG.
  ZIP=$OUTPUT_DIR/$APP_NAME.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm "$ZIP"
  step "Stapling app"
  xcrun stapler staple "$APP"
fi

step "Building DMG"
STAGE=$OUTPUT_DIR/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
  -ov "$DMG" -quiet
rm -rf "$STAGE"
codesign --sign "$SIGN_ID" --timestamp "$DMG"

if [[ -z ${SKIP_NOTARIZE:-} ]]; then
  notarize "$DMG"
  step "Stapling DMG"
  xcrun stapler staple "$DMG"

  step "Gatekeeper assessment"
  xcrun stapler validate "$APP"
  xcrun stapler validate "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

step "Done"
print "$DMG"
print "SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
