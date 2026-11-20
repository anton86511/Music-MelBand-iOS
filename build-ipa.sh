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
if [[ ! -f Build/melband-phone.onnx ]]; then
  curl --fail --location --retry 3 \
    https://huggingface.co/redbaty/ytm-vocal-separator/resolve/d9d3f27d58c4f9c0286a07ed541b18ceaa91f107/sep-all-int8.onnx \
    -o Build/model-original.onnx
  python3 -m venv Build/ModelPython
  Build/ModelPython/bin/python -m pip install 'onnx==1.23.2'
  Build/ModelPython/bin/python prepare-model.py Build/model-original.onnx Build/melband-phone.onnx
fi
(cd Build && printf '%s  melband-phone.onnx\n' fb25aa57aa8c90383ca6d74474abd759d7fc32f4d12642722b0944b8c65690a9 | shasum -a 256 -c)
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
unzip -p dist/Music-unsigned.ipa Payload/Music.app/melband-phone.onnx | shasum -a 256 | grep -Fq fb25aa57aa8c90383ca6d74474abd759d7fc32f4d12642722b0944b8c65690a9
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
