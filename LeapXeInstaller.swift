import CoreML
import CryptoKit
import Foundation

enum LeapXeInstaller {
    private static let checkpointURL = URL(string: "https://huggingface.co/pcunwa/BS-Roformer-Leap/resolve/4e47d6662ae82eaa8b4ac4329fe66099a843b48e/Xe/bs_leap_xe_voc.ckpt")!
    private static let checkpointSHA = "b739c1d2d87a81cd3dd3844ed9ad0bd678708c7a0a761a03a1aaff9af79a096d"
    private static let checkpointLength: UInt64 = 267_796_851
    private static let folder = URL.applicationSupportDirectory
        .appendingPathComponent("MusicStudio/LeapXe-v1", isDirectory: true)
    private static let installed = folder.appendingPathComponent("LeapXe.mlmodelc", isDirectory: true)

    private struct Recipe: Decodable {
        let modelSHA: String
        let weightsSHA: String
        let weightsSize: UInt64
        let patches: [Patch]

        struct Patch: Decodable {
            let target: Int
            let offset: UInt64
            let source: UInt64
            let count: Int
            let kind: String
        }
    }

    private enum InstallError: LocalizedError {
        case download, integrity, resources

        var errorDescription: String? {
            switch self {
            case .download: return "無法下載 Leap Xe 權重。請確認網路連線後重試。"
            case .integrity: return "Leap Xe 模型完整性驗證失敗。請重新下載模型。"
            case .resources: return "找不到 Leap Xe 模型設定。請重新匯入 IPA。"
            }
        }
    }

    static var modelURL: URL? {
        FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    static func install() async throws {
        if modelURL != nil { return }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("LeapXeTemplate", isDirectory: true),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("plan.json").path)
        else { throw InstallError.resources }

        let (archive, response) = try await URLSession.shared.download(from: checkpointURL)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.download }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var cacheFolder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try cacheFolder.setResourceValues(values)
        let temp = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let package = temp.appendingPathComponent("LeapXe.mlpackage", isDirectory: true)
        try assemble(checkpoint: archive, template: root, into: package)
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        let staged = temp.appendingPathComponent("Compiled.mlmodelc", isDirectory: true)
        try fm.copyItem(at: compiled, to: staged)
        try fm.moveItem(at: staged, to: installed)
    }

    static func assemble(checkpoint: URL, template root: URL, into package: URL) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: checkpoint.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == checkpointLength,
              try sha256(checkpoint) == checkpointSHA else { throw InstallError.integrity }
        let data = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        try fm.createDirectory(at: data.appendingPathComponent("weights", isDirectory: true), withIntermediateDirectories: true)
        let specification = data.appendingPathComponent("model.mlmodel")
        let weights = data.appendingPathComponent("weights/weight.bin")

        try fm.copyItem(at: root.appendingPathComponent("Manifest.json"), to: package.appendingPathComponent("Manifest.json"))
        try fm.copyItem(at: root.appendingPathComponent("model.template"), to: specification)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: specification.path)
        guard fm.createFile(atPath: weights.path, contents: nil) else { throw InstallError.resources }
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: root.appendingPathComponent("plan.json")))
        try restore(recipe, checkpoint: checkpoint, literals: root.appendingPathComponent("literals.bin"),
                    model: specification, weights: weights)
        guard try sha256(specification) == recipe.modelSHA, try sha256(weights) == recipe.weightsSHA
        else { throw InstallError.integrity }
    }

    private static func restore(_ recipe: Recipe, checkpoint: URL, literals: URL, model: URL, weights: URL) throws {
        let source = try FileHandle(forReadingFrom: checkpoint)
        defer { try? source.close() }
        let constants = try FileHandle(forReadingFrom: literals)
        defer { try? constants.close() }
        let modelFile = try FileHandle(forWritingTo: model)
        defer { try? modelFile.close() }
        let weightsFile = try FileHandle(forWritingTo: weights)
        defer { try? weightsFile.close() }
        try weightsFile.truncate(atOffset: recipe.weightsSize)
        for patch in recipe.patches {
            try Task.checkCancellation()
            let input: FileHandle
            let count: Int
            switch patch.kind {
            case "literal":
                input = constants
                count = patch.count
            case "f32":
                input = source
                count = 4 * patch.count
            default:
                throw InstallError.resources
            }
            let output = patch.target == 0 ? modelFile : weightsFile
            try input.seek(toOffset: patch.source)
            let data = try read(input, count: count)
            try output.seek(toOffset: patch.offset)
            try output.write(contentsOf: data)
        }
        try modelFile.synchronize()
        try weightsFile.synchronize()
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let piece = try file.read(upToCount: count - data.count), !piece.isEmpty else {
                throw InstallError.integrity
            }
            data.append(piece)
        }
        return data
    }

    private static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
