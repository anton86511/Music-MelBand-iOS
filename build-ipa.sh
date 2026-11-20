#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
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
hq4_source="https://huggingface.co/Politrees/UVR_resources/resolve/8cc4418"
fetch_checked "$hq4_source/models/MDXNet/UVR-MDX-NET-Inst_HQ_4.onnx" Build/InstHQ4.onnx \
  3c4b5b9b05090fdf238f38ba5046813982d50e2a652e9cb3324ea79720c3c9c8
if [[ ! -f Build/InstHQ4.mlpackage/Manifest.json || prepare-hq4.py -nt Build/InstHQ4.mlpackage/Manifest.json ]]; then
  hq4_python="${HQ4_PYTHON:-python3.12}"
  if ! command -v "$hq4_python" >/dev/null && [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
    for cached_python in "$RUNNER_TOOL_CACHE"/Python/3.12.*/arm64/bin/python3.12; do
      if [[ -x "$cached_python" ]]; then
        hq4_python="$cached_python"
        break
      fi
    done
  fi
  "$hq4_python" -m venv Build/HQ4Python
  Build/HQ4Python/bin/python -m pip install 'torch==2.9.1' 'torchvision==0.24.1' \
    'coremltools==9.0' 'onnx2torch==1.5.15' 'onnx==1.23.2' 'onnxruntime==1.24.2' 'numpy<2.3'
  rm -rf Build/InstHQ4.mlpackage
  Build/HQ4Python/bin/python prepare-hq4.py Build/InstHQ4.onnx Build/InstHQ4.mlpackage
fi
xcrun --sdk iphoneos coremlcompiler compile Build/InstHQ4.mlpackage Build/CoreML
test -d Build/CoreML/InstHQ4.mlmodelc
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
rm -rf Build/Package/Payload/Music.app
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
ditto Build/CoreML/InstHQ3.mlmodelc Build/Package/Payload/Music.app/InstHQ3.mlmodelc
ditto Build/CoreML/InstHQ4.mlmodelc Build/Package/Payload/Music.app/InstHQ4.mlmodelc
cp Build/MDX-LICENSE.txt Build/Package/Payload/Music.app/
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
unzip -Z1 dist/Music-unsigned.ipa | grep -F 'Payload/Music.app/InstHQ3.mlmodelc/' >/dev/null
unzip -Z1 dist/Music-unsigned.ipa | grep -F 'Payload/Music.app/InstHQ4.mlmodelc/' >/dev/null
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
