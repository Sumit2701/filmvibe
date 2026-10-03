#!/bin/zsh
# Builds an unsigned FilmVibe.ipa for sideloading. AltStore / SideStore / Sideloadly
# re-sign it with your own Apple ID when installing.
# Usage (from anywhere):  filmvibe/scripts/build-ipa.sh   →  filmvibe/build/FilmVibe.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/ipa
rm -rf $OUT build/FilmVibe.ipa
xcodebuild -project FilmVibe.xcodeproj -scheme FilmVibe -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath $OUT/dd -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p $OUT/Payload
cp -R $OUT/dd/Build/Products/Release-iphoneos/FilmVibe.app $OUT/Payload/
(cd $OUT && zip -qry ../FilmVibe.ipa Payload)
echo "built $(pwd)/build/FilmVibe.ipa"
