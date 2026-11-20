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
uvr_source="https://huggingface.co/Politrees/UVR_resources/resolve/8cc4418/models/MDXNet"
fetch_checked "$uvr_source/UVR-MDX-NET-Inst_HQ_4.onnx" Build/InstHQ4.onnx \
  3c4b5b9b05090fdf238f38ba5046813982d50e2a652e9cb3324ea79720c3c9c8
fetch_checked "$uvr_source/UVR-MDX-NET-Inst_Main.onnx" Build/InstMain.onnx \
  8ab401dfe4a548b87deb64f975294bd56ff946aa32903f53b4b24bb13b2cce1e

conversion_python="Build/HQ4Python/bin/python"
convert_mdx() {
  local name="$1" bins="$2"
  local source="Build/$name.onnx" package="Build/$name.mlpackage"
  if [[ -f "$package/Manifest.json" && ! "$source" -nt "$package/Manifest.json" &&
        ! prepare-mdx.py -nt "$package/Manifest.json" ]]; then
    return
  fi
  if [[ ! -f Build/HQ4Python/.dependencies-installed ]]; then
    local interpreter="${HQ4_PYTHON:-python3.12}"
    if ! command -v "$interpreter" >/dev/null && [[ -n "${RUNNER_TOOL_CACHE:-}" ]]; then
      for cached_python in "$RUNNER_TOOL_CACHE"/Python/3.12.*/arm64/bin/python3.12; do
        if [[ -x "$cached_python" ]]; then
          interpreter="$cached_python"
          break
        fi
      done
    fi
    "$interpreter" -m venv Build/HQ4Python
    "$conversion_python" -m pip install 'torch==2.9.1' 'torchvision==0.24.1' \
      'coremltools==9.0' 'onnx2torch==1.5.15' 'onnx==1.23.2' 'onnxruntime==1.24.2' 'numpy<2.3'
    touch Build/HQ4Python/.dependencies-installed
  fi
  rm -rf "$package.tmp.mlpackage"
  "$conversion_python" prepare-mdx.py "$source" "$package.tmp.mlpackage" --bins "$bins"
  rm -rf "$package"
  mv "$package.tmp.mlpackage" "$package"
}
convert_mdx InstHQ4 2560
convert_mdx InstMain 2048

models=(InstHQ4 InstHQ3 InstMain)
for model in "${models[@]}"; do
  rm -rf "Build/CoreML/$model.mlmodelc"
  xcrun --sdk iphoneos coremlcompiler compile "Build/$model.mlpackage" Build/CoreML
  test -d "Build/CoreML/$model.mlmodelc"
done
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
rm -rf Build/Package/Payload/Music.app
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
for model in "${models[@]}"; do
  ditto "Build/CoreML/$model.mlmodelc" "Build/Package/Payload/Music.app/$model.mlmodelc"
done
cp Build/MDX-LICENSE.txt Build/Package/Payload/Music.app/
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
ipa_entries="$(unzip -Z1 dist/Music-unsigned.ipa)"
for model in "${models[@]}"; do
  grep -F "Payload/Music.app/$model.mlmodelc/" <<<"$ipa_entries" >/dev/null
done
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
