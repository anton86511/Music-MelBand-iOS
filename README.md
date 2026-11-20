# 音樂

iPhone 本機去人聲工具。從分離模型選單選擇 UVR Inst HQ 3、UVR Inst HQ 4 或 Mel-Band RoFormer。兩款 UVR 模型透過 Core ML 啟用 GPU，Mel-Band RoFormer INT8 透過 ONNX Runtime 使用 CPU。音樂只在 iPhone 上解碼和分離。

1. 到 Releases 下載 `Music-unsigned.ipa`，從 LiveContainer 匯入。LiveContainer 須完成 JIT-Less 簽署設定。
2. 開啟「音樂」選取音檔。模型已隨 IPA 內建，可直接離線使用。
3. 完成後可試聽伴奏並分享或儲存 44.1 kHz 立體聲 WAV。

可選取音檔或含音軌的 MP4／MOV。匯入時會依檔案內容辨識常見容器，並在需要時從影片擷取 PCM 音軌。實際解碼由 iOS 的 AudioToolbox 處理，支援常見的 MP3、M4A/AAC、WAV、AIFF、FLAC 等格式，依裝置的 iOS 解碼器而異。受 DRM 保護、損毀或 iOS 無相應解碼器的檔案無法匯入。

GPU 加速模式建議保持 App 在前景。高品質模式在 iOS 26 以上會在系統允許註冊時申請持續背景處理。LiveContainer 匯入版的系統背景權限取決於宿主 App，鎖屏長時間持續執行需在實機確認。LiveContainer 可嘗試在分離中按「播放原曲並鎖屏」。App 會播放並循環原曲，分離完成後停止播放。若裝置中斷背景音訊，請返回 App 繼續。Mel-Band RoFormer 使用 CPU 和 2 秒視窗交疊處理，速度與實際記憶體用量依裝置及音檔長度而異。

## 打包

macOS 使用 Xcode 26 以上版本、XcodeGen 及 Python 3.12，執行 `bash build-ipa.sh`。GitHub Actions 將 unsigned IPA 與 SHA-256 發佈到 Releases。

模型權重由 Kimberley Jensen 提供。ONNX 轉換及 INT8 權重來自 [redbaty/ytm-vocal-separator](https://huggingface.co/redbaty/ytm-vocal-separator)，建構程式碼源自 ZFTurbo 與 Phil Wang 的 MIT 實作。打包時由 `prepare-model.py` 縮短模型時間視窗，原始 INT8 權重保留。授權見 [MODEL-LICENSE.txt](MODEL-LICENSE.txt)。

UVR Inst HQ 3 權重由 Kimberley Jensen 與 Ultimate Vocal Remover 專案提供，Core ML 轉換來自 [Gyoom](https://huggingface.co/gyoom/UVR-MDX-CoreML)，授權隨 IPA 內附。

UVR Inst HQ 4 的 ONNX 權重來自 [UVR_resources](https://huggingface.co/Politrees/UVR_resources)，打包時轉為 Core ML，推論採 FP32。
