import Accelerate
import AudioToolbox
import AVFoundation

enum SeparationError: LocalizedError {
    case decode(OSStatus)
    case empty
    case fft
    case inference(String)
    case modelOutput

    var errorDescription: String? {
        switch self {
        case .decode(let code): return "iPhone 無法解碼這個檔案（\(code)）。請確認檔案可播放且沒有 DRM 保護。"
        case .empty: return "檔案裡沒有可用的音訊。"
        case .fft: return "無法初始化音訊處理。"
        case .inference(let detail): return "本機模型執行失敗。\(detail)"
        case .modelOutput: return "模型傳回無效的結果。"
        }
    }
}

final class SeparationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = stopped
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

struct SeparationEngine {
    static let sampleRate = 44_100
    static let chunkSize = 88_200
    static let overlap = 8_820
    static let step = chunkSize - overlap

    static func run(input: URL, output: URL, model: URL, control: SeparationControl,
                    decodeProgress: () -> Void, progress: (Double) -> Void) throws {
        let reader = try AudioReader(url: input)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: output.path)
        decodeProgress()
        let fft = try Spectrogram()
        let threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        var error = [CChar](repeating: 0, count: 1024)
        let errorCapacity = error.count
        guard let session = music_ort_open(model.path, threads, &error, errorCapacity) else {
            throw SeparationError.inference(String(cString: error))
        }
        defer { music_ort_close(session) }

        var window = [Array(repeating: Float.zero, count: chunkSize), Array(repeating: Float.zero, count: chunkSize)]
        var pending = [Array(repeating: Float.zero, count: overlap), Array(repeating: Float.zero, count: overlap)]
        var count = 0
        var written: Int64 = 0
        var first = true

        while true {
            try control.check()
            let added = try reader.read(into: &window, offset: count, maxFrames: chunkSize - count)
            count += added
            if added == 0 {
                if first { throw SeparationError.empty }
                try write(pending, count: count, to: writer)
                break
            }
            let last = count < chunkSize
            if last {
                for c in 0..<2 {
                    for index in count..<chunkSize {
                        window[c][index] = window[c][reflected(index, length: count)]
                    }
                }
            }

            try autoreleasepool {
                var mix = fft.analyze(window)
                try control.check()
                var mask = Array(repeating: Float.zero, count: mix.count)
                let ran = mix.withUnsafeMutableBufferPointer { input in
                    mask.withUnsafeMutableBufferPointer { output in
                        music_ort_run(session, input.baseAddress!, output.baseAddress!, &error, errorCapacity)
                    }
                }
                guard ran else { throw SeparationError.inference(String(cString: error)) }
                try control.check()
                var instrumental = try mask.withUnsafeBufferPointer { ptr in
                    try fft.accompaniment(window, mix: mix, mask: ptr.baseAddress!)
                }
                if !first {
                    for c in 0..<2 {
                        for i in 0..<min(count, overlap) {
                            let t = Float(i + 1) / Float(overlap + 1)
                            instrumental[c][i] = pending[c][i] * (1 - t) + instrumental[c][i] * t
                        }
                    }
                }
                let length = last ? count : step
                try write(instrumental, count: length, to: writer)
                written += Int64(length)
                if !last {
                    for c in 0..<2 {
                        pending[c] = Array(instrumental[c][step..<chunkSize])
                        window[c].replaceSubrange(0..<overlap, with: Array(window[c][step..<chunkSize]))
                    }
                }
            }

            progress(reader.estimatedFrames > 0 ? min(0.99, Double(written) / reader.estimatedFrames) : 0)
            if last { break }
            count = overlap
            first = false
        }
        progress(1)
    }

    private static func write(_ planes: [[Float]], count: Int, to file: AVAudioFile) throws {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { throw SeparationError.modelOutput }
        buffer.frameLength = AVAudioFrameCount(count)
        for c in 0..<2 {
            for i in 0..<count {
                data[c][i] = max(-1, min(1, planes[c][i]))
            }
        }
        try file.write(from: buffer)
    }
}

private func reflected(_ index: Int, length: Int) -> Int {
    if length <= 1 { return 0 }
    let period = 2 * (length - 1)
    let wrapped = (index % period + period) % period
    return min(wrapped, period - wrapped)
}

private final class AudioReader {
    private let file: ExtAudioFileRef
    private let buffer: AVAudioPCMBuffer
    let estimatedFrames: Double

    init(url: URL) throws {
        var reference: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &reference)
        guard openStatus == noErr, let reference else { throw SeparationError.decode(openStatus) }
        var keepOpen = false
        defer { if !keepOpen { ExtAudioFileDispose(reference) } }

        var source = AudioStreamBasicDescription()
        var sourceSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let sourceStatus = ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileDataFormat, &sourceSize, &source)
        guard sourceStatus == noErr, source.mSampleRate > 0, source.mChannelsPerFrame > 0 else {
            throw SeparationError.decode(sourceStatus)
        }
        let channels: AVAudioChannelCount = source.mChannelsPerFrame == 1 ? 1 : 2
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SeparationEngine.sampleRate),
                                         channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw SeparationError.empty
        }
        var client = format.streamDescription.pointee
        let status = ExtAudioFileSetProperty(reference, kExtAudioFileProperty_ClientDataFormat, sourceSize, &client)
        guard status == noErr else { throw SeparationError.decode(status) }

        var frames: Int64 = 0
        var propertySize = UInt32(MemoryLayout<Int64>.size)
        _ = ExtAudioFileGetProperty(reference, kExtAudioFileProperty_FileLengthFrames, &propertySize, &frames)
        estimatedFrames = Double(frames) * format.sampleRate / source.mSampleRate
        self.file = reference
        self.buffer = buffer
        keepOpen = true
    }

    deinit { ExtAudioFileDispose(file) }

    func read(into planes: inout [[Float]], offset: Int, maxFrames: Int) throws -> Int {
        guard let channels = buffer.floatChannelData else { throw SeparationError.empty }
        var total = 0
        while total < maxFrames {
            var frames = UInt32(min(Int(buffer.frameCapacity), maxFrames - total))
            buffer.frameLength = frames
            let status = ExtAudioFileRead(file, &frames, buffer.mutableAudioBufferList)
            guard status == noErr else { throw SeparationError.decode(status) }
            if frames == 0 { break }
            for c in 0..<2 {
                let input = channels[min(c, Int(buffer.format.channelCount) - 1)]
                planes[c].withUnsafeMutableBufferPointer { pointer in
                    pointer.baseAddress!.advanced(by: offset + total).update(from: input, count: Int(frames))
                }
            }
            total += Int(frames)
        }
        return total
    }
}

private final class Spectrogram {
    private let n = 2_048
    private let half = 1_024
    private let bins = 1_025
    private let frames = SeparationEngine.chunkSize / 441 + 1
    private let hop = 441
    private let setup: FFTSetup
    private let hann: [Float]

    init() throws {
        guard let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else { throw SeparationError.fft }
        self.setup = setup
        self.hann = (0..<2_048).map { i in 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / 2_048) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func analyze(_ audio: [[Float]]) -> [Float] {
        var spec = Array(repeating: Float.zero, count: 4 * bins * frames)
        var re = Array(repeating: Float.zero, count: n)
        var im = re
        for c in 0..<2 {
            let realBase = (2 * c) * bins * frames
            let imagBase = realBase + bins * frames
            for frame in 0..<frames {
                let start = frame * hop - half
                for i in 0..<n {
                    let index = start + i
                    re[i] = audio[c][reflected(index, length: SeparationEngine.chunkSize)] * hann[i]
                    im[i] = 0
                }
                transform(re: &re, im: &im, direction: FFTDirection(FFT_FORWARD))
                for b in 0..<bins {
                    let index = b * frames + frame
                    spec[realBase + index] = re[b]
                    spec[imagBase + index] = im[b]
                }
            }
        }
        return spec
    }

    func accompaniment(_ audio: [[Float]], mix: [Float], mask: UnsafePointer<Float>) throws -> [[Float]] {
        let count = SeparationEngine.chunkSize
        var audioOut = audio
        var norm = Array(repeating: Float.zero, count: count)
        for frame in 0..<frames {
            let start = frame * hop - half
            for i in max(0, -start)..<min(n, count - start) {
                norm[start + i] += hann[i] * hann[i]
            }
        }

        var re = Array(repeating: Float.zero, count: n)
        var im = re
        for c in 0..<2 {
            let realBase = (2 * c) * bins * frames
            let imagBase = realBase + bins * frames
            var vocal = Array(repeating: Float.zero, count: count)
            for frame in 0..<frames {
                re[0] = 0
                im[0] = 0
                for b in 1..<bins {
                    let index = b * frames + frame
                    let r = mix[realBase + index]
                    let j = mix[imagBase + index]
                    let mr = mask[realBase + index]
                    let mj = mask[imagBase + index]
                    let real = r * mr - j * mj
                    let imag = r * mj + j * mr
                    re[b] = real
                    im[b] = b == half ? 0 : imag
                    if b < half {
                        re[n - b] = real
                        im[n - b] = -imag
                    }
                }
                transform(re: &re, im: &im, direction: FFTDirection(FFT_INVERSE))
                let start = frame * hop - half
                for i in max(0, -start)..<min(n, count - start) {
                    vocal[start + i] += re[i] * hann[i] / Float(n)
                }
            }
            for i in 0..<count {
                let result = audio[c][i] - vocal[i] / max(norm[i], 0.000001)
                guard result.isFinite else { throw SeparationError.modelOutput }
                audioOut[c][i] = result
            }
        }
        return audioOut
    }

    private func transform(re: inout [Float], im: inout [Float], direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { real in
            im.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 11, direction)
            }
        }
    }
}
