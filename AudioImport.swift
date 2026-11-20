import AudioToolbox
import AVFoundation
import CoreMedia

enum AudioImportError: LocalizedError {
    case webPage
    case noAudioTrack
    case unsupported
    case unsupportedWebM
    case assetDecode(String)

    var errorDescription: String? {
        switch self {
        case .webPage:
            return "這個檔案是下載頁面或下載錯誤訊息。請回下載頁重新下載音檔或影片。"
        case .noAudioTrack:
            return "這個檔案裡找不到音軌。請重新下載有聲音的版本。"
        case .unsupported:
            return "無法讀取音訊。檔案可能下載不完整或使用 iOS 不支援的格式，請試用 MP3、M4A 或含 AAC 音軌的 MP4。"
        case .unsupportedWebM:
            return "iOS 無法解碼這個 WebM／Ogg 音訊。請選擇 MP3、M4A 或含 AAC 音軌的 MP4。"
        case .assetDecode(let detail):
            return "已找到音軌，但 iOS 無法解碼。\(detail)"
        }
    }
}

enum AudioImport {
    static func prepare(_ input: URL, control: SeparationControl) async throws -> URL {
        try control.check()
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_096) ?? Data()
        guard !data.isEmpty else { throw SeparationError.empty }
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") ||
            prefix.hasPrefix("<head") || prefix.hasPrefix("<body") ||
            prefix.hasPrefix("<?xml") || prefix.hasPrefix("{") {
            throw AudioImportError.webPage
        }

        let bytes = Array(data.prefix(16))
        let detected = fileExtension(bytes)
        let candidate: URL
        if let detected, input.pathExtension.lowercased() != detected {
            candidate = input.deletingPathExtension().appendingPathExtension(detected)
            try FileManager.default.moveItem(at: input, to: candidate)
        } else {
            candidate = input
        }

        if (try? AudioReader(url: candidate).hasAudio()) == true { return candidate }
        try control.check()

        let pcm = candidate.deletingLastPathComponent().appendingPathComponent("decoded.caf")
        do {
            try await extractAudio(candidate, to: pcm, control: control)
            return pcm
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioImportError {
            if detected == "webm" || detected == "ogg" { throw AudioImportError.unsupportedWebM }
            throw error
        }
    }

    private static func fileExtension(_ bytes: [UInt8]) -> String? {
        if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            switch String(decoding: bytes[8..<12], as: UTF8.self) {
            case "M4A ", "M4B ": return "m4a"
            case "qt  ": return "mov"
            default: return "mp4"
            }
        }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if bytes.starts(with: Array("OggS".utf8)) { return "ogg" }
        if bytes.starts(with: Array("fLaC".utf8)) { return "flac" }
        if bytes.count >= 12 && bytes.starts(with: Array("RIFF".utf8)) &&
           String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" { return "wav" }
        if bytes.starts(with: Array("ID3".utf8)) { return "mp3" }
        if bytes.count >= 4 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0 {
            if bytes[1] & 0xF6 == 0xF0 { return "aac" }
            if bytes[1] & 0x18 != 0x08 && bytes[1] & 0x06 != 0 &&
               bytes[2] & 0xF0 != 0xF0 && bytes[2] & 0x0C != 0x0C { return "mp3" }
        }
        return nil
    }

    private static func extractAudio(_ input: URL, to destination: URL, control: SeparationControl) async throws {
        let asset = AVURLAsset(url: input)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            try control.check()
            throw AudioImportError.unsupported
        }
        try control.check()
        guard let track = tracks.first else { throw AudioImportError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImportError.assetDecode(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioImportError.unsupported }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioImportError.assetDecode(reader.error?.localizedDescription ?? "")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var file: AVAudioFile?
        var written = false
        while let sample = output.copyNextSampleBuffer() {
            try control.check()
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 { continue }
            guard count <= Int(Int32.max),
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: stream),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            else { throw AudioImportError.unsupported }
            if file == nil {
                file = try AVAudioFile(forWriting: destination, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                      ofItemAtPath: destination.path)
                #endif
            }
            guard let file, file.processingFormat == format else { throw AudioImportError.unsupported }
            buffer.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                                     into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw SeparationError.decode(status) }
            try file.write(from: buffer)
            written = true
        }
        try control.check()
        guard reader.status == .completed else {
            throw AudioImportError.assetDecode(reader.error?.localizedDescription ?? "")
        }
        guard written else { throw AudioImportError.noAudioTrack }
    }
}
