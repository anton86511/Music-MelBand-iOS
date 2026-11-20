# 音樂

iPhone 本機去人聲工具。用 Kimberley Jensen 的 Mel-Band RoFormer INT8 模型分離人聲，再以原音減去人聲製作伴奏。音樂只在 iPhone 上解碼和分離。

1. 到 Releases 下載 `Music-unsigned.ipa`，從 LiveContainer 匯入。LiveContainer 須完成 JIT-Less 簽署設定。
2. 開啟「音樂」，按「下載離線模型」。首次需要約 236 MB 的模型下載，之後可以離線使用。也可在 App 匯入[原始 ONNX 模型檔](https://huggingface.co/redbaty/ytm-vocal-separator/resolve/d9d3f27d58c4f9c0286a07ed541b18ceaa91f107/sep-all-int8.onnx)。
3. 選取音檔。完成後可試聽伴奏並分享或儲存 44.1 kHz 立體聲 WAV。

可選取任意副檔名。實際解碼由 iOS 的 AudioToolbox 處理，支援常見的 MP3、M4A/AAC、WAV、AIFF、FLAC 等格式，依裝置的 iOS 解碼器而異。受 DRM 保護、損毀或 iOS 無相應解碼器的檔案無法匯入。

iOS 26 以上會在系統允許註冊時申請持續背景處理。LiveContainer 匯入版的系統背景權限取決於宿主 App，鎖屏長時間持續執行需在實機確認。若只能使用短時背景執行，保持 App 在前景可避免暫停。模型使用 CPU 並分段處理，速度與實際記憶體用量依裝置及音檔長度而異。

## 打包

macOS 使用 Xcode 26 以上版本與 XcodeGen，執行 `bash build-ipa.sh`。GitHub Actions 將 unsigned IPA 與 SHA-256 發佈到 Releases。

模型權重由 Kimberley Jensen 提供。ONNX 轉換及 INT8 權重來自 [redbaty/ytm-vocal-separator](https://huggingface.co/redbaty/ytm-vocal-separator)，建構程式碼源自 ZFTurbo 與 Phil Wang 的 MIT 實作。授權見 [MODEL-LICENSE.txt](MODEL-LICENSE.txt)。
