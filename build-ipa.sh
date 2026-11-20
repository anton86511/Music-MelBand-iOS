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
mdx_source="https://huggingface.co/gyoom/UVR-MDX-CoreML/resolve/aa27ab16896fdb298cdb73cceb76c950e7580c00"
mdx_package="Build/InstHQ3.mlpackage"
mdx_remote="UVR-MDX-NET-Inst_HQ_3.mlpackage"
mkdir -p "$mdx_package/Data/com.apple.CoreML/weights" Build/CoreML
fetch_checked() {
  local source="$1" target="$2" checksum="$3"
  if [[ ! -f "$target" ]]; then
    curl --fail --location --retry 3 "$source" -o "$target.part"
    mv "$target.part" "$target"
  fi
  printf '%s  %s\n' "$checksum" "$target" | shasum -a 256 -c
}
fetch_checked "$mdx_source/$mdx_remote/Manifest.json" "$mdx_package/Manifest.json" \
  6d4940ef8e0f2f1de2bc83ff675548206af160c66ee44f25fcdda19dcd000d38
fetch_checked "$mdx_source/$mdx_remote/Data/com.apple.CoreML/model.mlmodel" "$mdx_package/Data/com.apple.CoreML/model.mlmodel" \
  fe4055846ccddb4a04765feb20ec7fe6530624383323782a91d125f760f05ac4
fetch_checked "$mdx_source/$mdx_remote/Data/com.apple.CoreML/weights/weight.bin" "$mdx_package/Data/com.apple.CoreML/weights/weight.bin" \
  0a687c627a66e8dc3dc6947e31d35526164f234757208624506ff2aaf47bd1a5
fetch_checked "$mdx_source/LICENSE" Build/MDX-LICENSE.txt \
  cf21ae3c45c311a38171b1a1de097145824c6629f32c3429680de2607230b9fa
xcrun --sdk iphoneos coremlcompiler compile "$mdx_package" Build/CoreML
test -d Build/CoreML/InstHQ3.mlmodelc
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
ditto Build/CoreML/InstHQ3.mlmodelc Build/Package/Payload/Music.app/InstHQ3.mlmodelc
cp Build/MDX-LICENSE.txt Build/Package/Payload/Music.app/
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
unzip -Z1 dist/Music-unsigned.ipa | grep -F 'Payload/Music.app/InstHQ3.mlmodelc/' >/dev/null
unzip -p dist/Music-unsigned.ipa Payload/Music.app/melband-phone.onnx | shasum -a 256 | grep -Fq fb25aa57aa8c90383ca6d74474abd759d7fc32f4d12642722b0944b8c65690a9
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
