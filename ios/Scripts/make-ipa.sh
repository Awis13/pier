#!/bin/sh
# Builds Pier.ipa for sideloading (SideStore, AltStore, Sideloadly).
#
#     ios/Scripts/make-ipa.sh [extra xcodebuild arguments]
#
# The app is built signed (your team in project.yml), then the profiles go
# and it is signed ad hoc with Pier's entitlements, for the sideloading tool
# to sign again. A build made with signing switched off does not do: iOS
# will not start its JIT helper extension after it is re-signed.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/build/ipa
derived=$here/build/release
rm -rf "$out" && mkdir -p "$out/Payload"
xcodebuild -project "$here/Pier.xcodeproj" -scheme Pier -configuration Release \
    -destination generic/platform=iOS -derivedDataPath "$derived" \
    -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation "$@" build
app=$out/Payload/Pier.app
cp -R "$derived/Build/Products/Release-iphoneos/Pier.app" "$app"
find "$app" -name embedded.mobileprovision -delete
for f in "$app"/Frameworks/*.framework "$app"/PlugIns/*.appex; do
    codesign -f -s - "$f"
done
codesign -f -s - --entitlements "$here/Resources/Pier.entitlements" "$app"
(cd "$out" && zip -qry -9 Pier.ipa Payload)
echo "$out/Pier.ipa"
