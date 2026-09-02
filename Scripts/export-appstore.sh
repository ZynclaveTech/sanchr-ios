#!/bin/zsh
# Archive the Release configuration and export an App Store Connect package.
#
#   Scripts/export-appstore.sh            -> build/export/Sanchr.ipa
#
# Needs a distribution certificate in the login keychain (automatic signing
# fetches the profiles). ExportOptions.plist pins the iCloud container to
# Production and uploads symbols.
set -u
cd "$(dirname "$0")/.."
ARCHIVE=build/Sanchr.xcarchive
xcodegen generate || exit 1
xcodebuild archive \
  -project Sanchr.xcodeproj -scheme Sanchr -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates || exit 1
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates || exit 1
echo "Exported: $(ls build/export/*.ipa)"
