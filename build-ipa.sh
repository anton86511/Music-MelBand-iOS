#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Build/ORT
if [[ ! -f Build/ORT/onnxruntime.xcframework/Info.plist ]]; then
  curl --fail --location --retry 3 \
    https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip \
    -o Build/ort.zip
  (cd Build && printf '%s  ort.zip\n' f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54 | shasum -a 256 -c)
  unzip -oq Build/ort.zip -d Build/ORT
fi
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
