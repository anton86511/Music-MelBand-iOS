import Accelerate
import AudioToolbox
import AVFoundation
import CoreML

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
    private let condition = NSCondition()
    private var stopped = false

    func cancel() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    func check() throws {
        condition.lock()
        let cancelled = stopped
        condition.unlock()
        if cancelled { throw CancellationError() }
    }

    func waitForCooling(report: (Bool) -> Void) throws {
        var paused = false
        while true {
            try check()
            switch ProcessInfo.processInfo.thermalState {
            case .nominal, .fair:
                if paused { report(false) }
                return
            case .serious, .critical:
                break
            @unknown default:
                if paused { report(false) }
                return
            }
            if !paused {
                paused = true
                report(true)
            }
            condition.lock()
            if !stopped { _ = condition.wait(until: Date().addingTimeInterval(1)) }
            condition.unlock()
        }
    }
}

enum SeparationMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case hq4
    case quality
    case leapXeFast
    case leapXe

    var id: Self { self }

    var title: String {
        switch self {
        case .fast: return "UVR Inst HQ 3"
        case .hq4: return "UVR Inst HQ 4"
        case .quality: return "Mel-Band RoFormer"
        case .leapXeFast: return "BS-RoFormer Leap Xe（省熱）"
        case .leapXe: return "BS-RoFormer Leap Xe"
        }
    }

    var usesCoreML: Bool { self != .quality }
    var leapXeVariant: LeapXeInstaller.Variant? {
        switch self {
        case .leapXe: return .original
        case .leapXeFast: return .fast
        default: return nil
        }
    }

    var predictsVocals: Bool { self == .quality || leapXeVariant != nil }

    static var available: [Self] {
        if #available(iOS 18.0, *) { return allCases }
        return allCases.filter { $0 != .leapXeFast }
    }

    var backend: String {
        usesCoreML ? "Core ML · GPU 加速" : "ONNX Runtime · CPU"
    }

    func modelURL(in bundle: Bundle = .main) -> URL? {
        switch self {
        case .fast: return bundle.url(forResource: "InstHQ3", withExtension: "mlmodelc")
        case .hq4: return bundle.url(forResource: "InstHQ4", withExtension: "mlmodelc")
        case .quality: return bundle.url(forResource: "melband-phone", withExtension: "onnx")
        case .leapXe, .leapXeFast: return leapXeVariant.flatMap(LeapXeInstaller.modelURL(for:))
        }
    }
}

struct SeparationEngine {
    static let sampleRate = 44_100

    static func run(input: URL, output: URL, model: URL, mode: SeparationMode, control: SeparationControl,
                    decodeProgress: () -> Void, cooling: (Bool) -> Void, progress: (Double) -> Void) throws {
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
        let fft: Spectrogram
        let predict: (inout [Float]) throws -> [Float]
        let overlap: Int
        switch mode {
        case .fast, .hq4:
            let fftSize = mode == .hq4 ? 5_120 : 6_144
            fft = try Spectrogram(size: fftSize, hop: 1_024, frames: 256, includeNyquist: false)
            let separator = try SpectrogramCoreML(url: model, bins: fft.bins, frames: fft.frames,
                                                  inputName: "input", outputName: "output", dataType: .float16)
            predict = { try separator.predict($0) }
            overlap = 24_576
        case .leapXe, .leapXeFast:
            try control.waitForCooling(report: cooling)
            fft = try Spectrogram(size: 2_048, hop: 512, frames: 193, includeNyquist: true)
            let separator = try SpectrogramCoreML(url: model, bins: fft.bins, frames: fft.frames,
                                                  inputName: "mix", outputName: "mask", dataType: .float32)
            predict = { mix in
                var mask = try separator.predict(mix)
                applyVocalMask(&mask, to: mix, planeSize: fft.bins * fft.frames, dcFrames: fft.frames)
                return mask
            }
            overlap = 24_576
        case .quality:
            fft = try Spectrogram(size: 2_048, hop: 441, frames: 201, includeNyquist: true)
            let separator = try RoFormerSeparator(url: model)
            predict = { try separator.vocals(&$0, planeSize: fft.bins * fft.frames) }
            overlap = 8_820
        }
        let chunkSize = fft.sampleCount
        let step = chunkSize - overlap

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

            if mode.leapXeVariant != nil { try control.waitForCooling(report: cooling) }
            try autoreleasepool {
                var mix = fft.analyze(window)
                try control.check()
                let stem = try predict(&mix)
                try control.check()
                var instrumental = try fft.reconstruct(window, stem: stem, subtract: mode.predictsVocals)
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

final class AudioReader {
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

    func hasAudio() throws -> Bool {
        var samples = [[Float.zero], [Float.zero]]
        return try read(into: &samples, offset: 0, maxFrames: 1) == 1
    }

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

private final class RoFormerSeparator {
    private let session: OpaquePointer

    init(url: URL) throws {
        let threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        var error = [CChar](repeating: 0, count: 1_024)
        let capacity = error.count
        guard let session = music_ort_open(url.path, threads, &error, capacity) else {
            throw SeparationError.inference(String(cString: error))
        }
        self.session = session
    }

    deinit { music_ort_close(session) }

    func vocals(_ mix: inout [Float], planeSize: Int) throws -> [Float] {
        var mask = Array(repeating: Float.zero, count: mix.count)
        var error = [CChar](repeating: 0, count: 1_024)
        let capacity = error.count
        let ran = mix.withUnsafeMutableBufferPointer { input in
            mask.withUnsafeMutableBufferPointer { output in
                music_ort_run(session, input.baseAddress!, output.baseAddress!, &error, capacity)
            }
        }
        guard ran else { throw SeparationError.inference(String(cString: error)) }

        applyVocalMask(&mask, to: mix, planeSize: planeSize, dcFrames: 201)
        return mask
    }
}

private func applyVocalMask(_ mask: inout [Float], to mix: [Float], planeSize: Int, dcFrames: Int) {
    for channel in 0..<2 {
        let real = 2 * channel * planeSize
        let imag = real + planeSize
        for i in 0..<planeSize {
            let mr = mask[real + i]
            let mi = mask[imag + i]
            mask[real + i] = i < dcFrames ? 0 : mix[real + i] * mr - mix[imag + i] * mi
            mask[imag + i] = i < dcFrames ? 0 : mix[real + i] * mi + mix[imag + i] * mr
        }
    }
}

private final class SpectrogramCoreML {
    private let model: MLModel
    private let input: MLMultiArray
    private let features: MLDictionaryFeatureProvider
    private let shape: [Int]
    private let outputName: String
    private let dataType: MLMultiArrayDataType
    private let contiguous: [Int]
    private let bins: Int
    private let frames: Int

    init(url: URL, bins: Int, frames: Int, inputName: String, outputName: String,
         dataType: MLMultiArrayDataType) throws {
        self.outputName = outputName
        self.dataType = dataType
        let shape = [1, 4, bins, frames]
        self.shape = shape
        self.bins = bins
        self.frames = frames
        self.contiguous = [4 * bins * frames, bins * frames, frames, 1]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: configuration)
        input = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
        features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
    }

    func predict(_ mix: [Float]) throws -> [Float] {
        guard mix.count == input.count, input.strides.map(\.intValue) == contiguous
        else { throw SeparationError.modelOutput }
        if dataType == .float32 {
            let destination = input.dataPointer.assumingMemoryBound(to: Float.self)
            mix.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
        } else {
            let destination = input.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in mix.indices { destination[i] = Float16(mix[i]) }
        }
        let prediction = try model.prediction(from: features)
        guard let output = prediction.featureValue(for: outputName)?.multiArrayValue,
              output.dataType == dataType,
              output.shape.map(\.intValue) == shape
        else { throw SeparationError.modelOutput }
        let strides = output.strides.map(\.intValue)
        return withExtendedLifetime(output) {
            if dataType == .float32 {
                let source = output.dataPointer.assumingMemoryBound(to: Float.self)
                if strides == contiguous {
                    return Array(UnsafeBufferPointer(start: source, count: output.count))
                }
                return contiguousOutput(strides: strides, read: { source[$0] })
            }
            let source = output.dataPointer.assumingMemoryBound(to: Float16.self)
            if strides == contiguous {
                return (0..<output.count).map { Float(source[$0]) }
            }
            return contiguousOutput(strides: strides, read: { Float(source[$0]) })
        }
    }

    private func contiguousOutput(strides: [Int], read: (Int) -> Float) -> [Float] {
        var values = Array(repeating: Float.zero, count: 4 * bins * frames)
        for plane in 0..<4 {
            for bin in 0..<bins {
                let start = (plane * bins + bin) * frames
                let offset = plane * strides[1] + bin * strides[2]
                for frame in 0..<frames {
                    values[start + frame] = read(offset + frame * strides[3])
                }
            }
        }
        return values
    }
}

private final class Spectrogram {
    let bins: Int
    let frames: Int
    let sampleCount: Int
    private let n: Int
    private let half: Int
    private let hop: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private let hann: [Float]
    private let synthesisScale: [Float]

    init(size: Int, hop: Int, frames: Int, includeNyquist: Bool) throws {
        let length = vDSP_Length(size)
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, length, .FORWARD) else { throw SeparationError.fft }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, length, .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw SeparationError.fft
        }
        let hann = (0..<size).map { i in 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(size)) }
        let count = (frames - 1) * hop
        let half = size / 2
        var norm = Array(repeating: Float.zero, count: count)
        for frame in 0..<frames {
            let start = frame * hop - half
            for i in max(0, -start)..<min(size, count - start) {
                norm[start + i] += hann[i] * hann[i]
            }
        }
        self.forward = forward
        self.inverse = inverse
        self.hann = hann
        self.synthesisScale = norm.map { 1 / (Float(size) * max($0, 0.000001)) }
        self.n = size
        self.half = half
        self.bins = half + (includeNyquist ? 1 : 0)
        self.frames = frames
        self.hop = hop
        self.sampleCount = count
    }

    deinit {
        vDSP_DFT_DestroySetup(inverse)
        vDSP_DFT_DestroySetup(forward)
    }

    func analyze(_ audio: [[Float]]) -> [Float] {
        var spec = Array(repeating: Float.zero, count: 4 * bins * frames)
        var re = Array(repeating: Float.zero, count: n)
        var im = re
        var realSpectrum = re
        var imagSpectrum = re
        for channel in 0..<2 {
            let realBase = (2 * channel) * bins * frames
            let imagBase = realBase + bins * frames
            let samples = audio[channel]
            for frame in 0..<frames {
                let start = frame * hop - half
                if start >= 0 && start + n <= sampleCount {
                    samples.withUnsafeBufferPointer { samples in
                        hann.withUnsafeBufferPointer { window in
                            vDSP_vmul(samples.baseAddress! + start, 1, window.baseAddress!, 1, &re, 1, vDSP_Length(n))
                        }
                    }
                } else {
                    for i in 0..<n {
                        re[i] = samples[reflected(start + i, length: sampleCount)] * hann[i]
                    }
                }
                vDSP_vclr(&im, 1, vDSP_Length(n))
                vDSP_DFT_Execute(forward, re, im, &realSpectrum, &imagSpectrum)
                for bin in 0..<bins {
                    let index = bin * frames + frame
                    spec[realBase + index] = realSpectrum[bin]
                    spec[imagBase + index] = imagSpectrum[bin]
                }
            }
        }
        return spec
    }

    func reconstruct(_ audio: [[Float]], stem: [Float], subtract: Bool) throws -> [[Float]] {
        var audioOut = audio
        var re = Array(repeating: Float.zero, count: n)
        var im = re
        var signal = re
        var imaginarySignal = re
        for channel in 0..<2 {
            let realBase = (2 * channel) * bins * frames
            let imagBase = realBase + bins * frames
            var reconstructed = Array(repeating: Float.zero, count: sampleCount)
            for frame in 0..<frames {
                re[0] = stem[realBase + frame]
                im[0] = 0
                re[half] = 0
                im[half] = 0
                for bin in 1..<bins {
                    let index = bin * frames + frame
                    let real = stem[realBase + index]
                    let imag = stem[imagBase + index]
                    re[bin] = real
                    if bin < half {
                        im[bin] = imag
                        re[n - bin] = real
                        im[n - bin] = -imag
                    }
                }
                vDSP_DFT_Execute(inverse, re, im, &signal, &imaginarySignal)
                let start = frame * hop - half
                for i in max(0, -start)..<min(n, sampleCount - start) {
                    reconstructed[start + i] += signal[i] * hann[i]
                }
            }
            for i in 0..<sampleCount {
                let sample = reconstructed[i] * synthesisScale[i]
                let result = subtract ? audio[channel][i] - sample : sample
                guard result.isFinite else { throw SeparationError.modelOutput }
                audioOut[channel][i] = result
            }
        }
        return audioOut
    }

}
