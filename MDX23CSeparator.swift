import CoreML

final class MDX23CSeparator {
    private let model: MLModel
    private let input: MLMultiArray
    private let features: MLDictionaryFeatureProvider
    private let bins: Int
    private let frames: Int

    init(url: URL, bins: Int, frames: Int) throws {
        self.bins = bins
        self.frames = frames

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: configuration)
        input = try MLMultiArray(
            shape: [1, 4, bins, frames].map { NSNumber(value: $0) },
            dataType: .float32
        )
        features = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": MLFeatureValue(multiArray: input)])
    }

    func predict(_ mix: [Float]) throws -> [Float] {
        let planeSize = bins * frames
        guard mix.count == input.count,
              input.strides.map(\.intValue) == [4 * planeSize, planeSize, frames, 1] else {
            throw SeparationError.modelOutput
        }

        let destination = input.dataPointer.assumingMemoryBound(to: Float.self)
        mix.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: source.count)
        }

        let prediction = try model.prediction(from: features)
        guard let stems = prediction.featureValue(for: "stems")?.multiArrayValue,
              stems.dataType == .float32,
              stems.shape.map(\.intValue) == [1, 2, 4, bins, frames] else {
            throw SeparationError.modelOutput
        }

        let strides = stems.strides.map(\.intValue)
        // Stem 0 contains vocals, and stem 1 contains the instrumental.
        let instrumentalOffset = strides[1]
        return withExtendedLifetime(stems) {
            let source = stems.dataPointer.assumingMemoryBound(to: Float.self) + instrumentalOffset
            if strides[2] == planeSize && strides[3] == frames && strides[4] == 1 {
                return Array(UnsafeBufferPointer(start: source, count: 4 * planeSize))
            }

            var result = Array(repeating: Float.zero, count: 4 * planeSize)
            for channel in 0..<4 {
                for bin in 0..<bins {
                    let destinationOffset = channel * planeSize + bin * frames
                    let sourceOffset = channel * strides[2] + bin * strides[3]
                    for frame in 0..<frames {
                        result[destinationOffset + frame] = source[sourceOffset + frame * strides[4]]
                    }
                }
            }
            return result
        }
    }
}
