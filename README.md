# 音樂

iPhone 本機去人聲工具。分離模型可選 UVR Inst HQ 4、UVR Inst HQ 3（預設）或 UVR-MDX-NET-Inst_Main。三款皆內建於 IPA，使用 Core ML 的 CPU 與 GPU 在 iPhone 上離線產生伴奏。

1. 到 Releases 下載 `Music-unsigned.ipa`，從 LiveContainer 匯入。LiveContainer 須完成 JIT-Less 簽署設定。
2. 開啟「音樂」，選擇分離模型並匯入音檔。
3. 完成後可試聽伴奏並分享或儲存 44.1 kHz 立體聲 WAV。

可選取音檔或含音軌的 MP4／MOV。匯入時會依檔案內容辨識常見容器，並在需要時從影片擷取 PCM 音軌。實際解碼由 iOS 的 AudioToolbox 處理，支援常見的 MP3、M4A/AAC、WAV、AIFF、FLAC 等格式，依裝置的 iOS 解碼器而異。受 DRM 保護、損毀或 iOS 無相應解碼器的檔案無法匯入。

分離期間請保持 App 在前景。當系統回報溫度過高時，App 會在音訊分段之間暫停，降溫後自動繼續。

## 打包

macOS 使用 Xcode 26 以上版本、XcodeGen 及 Python 3.12，執行 `bash build-ipa.sh`。GitHub Actions 將 unsigned IPA 與 SHA-256 發佈到 Releases。

UVR Inst HQ 3 權重由 Kimberley Jensen 與 Ultimate Vocal Remover 專案提供，Core ML 轉換來自 [Gyoom](https://huggingface.co/gyoom/UVR-MDX-CoreML)，授權隨 IPA 內附。

UVR Inst HQ 4 與 UVR-MDX-NET-Inst_Main 的 ONNX 權重來自 [UVR_resources](https://huggingface.co/Politrees/UVR_resources)，打包時轉為 Core ML，推論採 FP32。
