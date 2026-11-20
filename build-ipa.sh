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
mkdir -p Build/LeapXeResources
unzip -oq LeapXeTemplate.zip -d Build/LeapXeResources
test -f Build/LeapXeResources/LeapXeTemplate/plan.json
if [[ "${CI:-}" == true ]]; then
  leapxe_source="https://huggingface.co/pcunwa/BS-Roformer-Leap/resolve/4e47d6662ae82eaa8b4ac4329fe66099a843b48e/Xe/bs_leap_xe_voc.ckpt"
  fetch_checked "$leapxe_source" Build/LeapXe-author.ckpt \
    b739c1d2d87a81cd3dd3844ed9ad0bd678708c7a0a761a03a1aaff9af79a096d
  xcrun --sdk macosx swiftc -O -parse-as-library LeapXeInstaller.swift LeapXeInstallCheck.swift \
    -o Build/LeapXeInstallCheck
  Build/LeapXeInstallCheck Build/LeapXe-author.ckpt Build/LeapXeResources/LeapXeTemplate Build/LeapXeValidation.mlpackage
  # Temporary CI fixture from LibriSpeech (CC BY 4.0), Ashiel Mystery read by Garth Comira.
  fetch_checked https://librosa.org/data/audio/5703-47212-0000.ogg Build/LeapXeValidation.ogg \
    a284612b46af0535f7e1873758c4387bb8369f6dbbe192ffdec1f171108f98dd
  leapxe_ref=Build/LeapXeReference
  leapxe_code="https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/e491b540cac3a91ba0d438984adab3cdcaf527e6/models/bs_roformer"
  mkdir -p "$leapxe_ref/models/bs_roformer"
  fetch_checked "$leapxe_code/bs_roformer.py" "$leapxe_ref/models/bs_roformer/bs_roformer.py" \
    a6f670325cdb8a7a212914f62602119b23eb888df9bcfe4a85f9be74728b3ef4
  fetch_checked "$leapxe_code/attend.py" "$leapxe_ref/models/bs_roformer/attend.py" \
    c7abbc40a3fd20ff7f6001fa9f8ee9ad5df6452272712a5e719b8f8468bf2223
  fetch_checked "${leapxe_source%/*}/leap_xe_config_voc.yaml" "$leapxe_ref/config.yaml" \
    d3cb8c84be2e9bcbc64c1086e2256dc097ab5addebc5ce507818e90ff8cbdc25
  Build/HQ4Python/bin/python -m pip install 'einops==0.8.1' 'rotary-embedding-torch==0.8.9' \
    'beartype==0.21.0' 'soundfile==0.13.1' 'scipy==1.15.3'
  Build/HQ4Python/bin/python validate-leapxe.py Build/LeapXeValidation.mlpackage \
    Build/LeapXe-author.ckpt Build/LeapXeValidation.ogg "$leapxe_ref"
fi
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath Build/Derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Build/Package/Payload dist
ditto Build/Derived/Build/Products/Release-iphoneos/Music.app Build/Package/Payload/Music.app
ditto Build/CoreML/InstHQ3.mlmodelc Build/Package/Payload/Music.app/InstHQ3.mlmodelc
ditto Build/CoreML/InstHQ4.mlmodelc Build/Package/Payload/Music.app/InstHQ4.mlmodelc
ditto Build/LeapXeResources/LeapXeTemplate Build/Package/Payload/Music.app/LeapXeTemplate
cp Build/MDX-LICENSE.txt Build/Package/Payload/Music.app/
rm -f dist/Music-unsigned.ipa
(cd Build/Package && zip -qry ../../dist/Music-unsigned.ipa Payload)
unzip -tq dist/Music-unsigned.ipa
unzip -Z1 dist/Music-unsigned.ipa | grep -F 'Payload/Music.app/InstHQ3.mlmodelc/' >/dev/null
unzip -Z1 dist/Music-unsigned.ipa | grep -F 'Payload/Music.app/InstHQ4.mlmodelc/' >/dev/null
unzip -Z1 dist/Music-unsigned.ipa | grep -Fx 'Payload/Music.app/LeapXeTemplate/plan.json' >/dev/null
unzip -p dist/Music-unsigned.ipa Payload/Music.app/melband-phone.onnx | shasum -a 256 | grep -Fq fb25aa57aa8c90383ca6d74474abd759d7fc32f4d12642722b0944b8c65690a9
/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' Build/Package/Payload/Music.app/Info.plist | grep -Fx '音樂'
shasum -a 256 dist/Music-unsigned.ipa | sed 's|dist/||' > dist/Music-unsigned.ipa.sha256
