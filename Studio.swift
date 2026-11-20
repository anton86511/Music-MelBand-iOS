import AVFoundation
import BackgroundTasks
import CryptoKit
import SwiftUI
import UIKit

@MainActor
final class Studio: ObservableObject {
    @Published private(set) var modelReady = FileManager.default.fileExists(atPath: Self.model.path)
    @Published private(set) var fileName: String?
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var busy = false
    @Published private(set) var separating = false
    @Published private(set) var playing = false
    @Published private(set) var result: URL?
    @Published var error: String?

    nonisolated private static let folder = URL.applicationSupportDirectory.appendingPathComponent("MusicStudio", isDirectory: true)
    nonisolated private static let model = folder.appendingPathComponent("sep-all-int8.onnx")
    nonisolated private static let modelURL = URL(string: "https://huggingface.co/redbaty/ytm-vocal-separator/resolve/d9d3f27d58c4f9c0286a07ed541b18ceaa91f107/sep-all-int8.onnx")!
    nonisolated private static let modelHash = "e9570dac2ae14382c99357a547a6739777a029ad7f2b5f6e6bc22e9b0e7b2580"
    private var control: SeparationControl?
    private var player: AVAudioPlayer?
    private var playbackMonitor: Task<Void, Never>?

    func downloadModel() {
        prepareModel { destination in
            let (temporary, response) = try await URLSession.shared.download(from: Self.modelURL)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw SeparationError.modelDownload
            }
            try Self.installModel(from: temporary, to: destination)
        }
    }

    func importModel(_ url: URL) {
        prepareModel { destination in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            var coordinatorError: NSError?
            var operationError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { source in
                do { try Self.installModel(from: source, to: destination) }
                catch { operationError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let operationError { throw operationError }
        }
    }

    private func prepareModel(_ operation: @escaping @Sendable (URL) async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        status = "正在取得並驗證離線模型，請保持 App 開啟。"
        let destination = Self.model
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await operation(destination)
                }.value
                modelReady = true
                status = "離線模型已就緒。可匯入音樂。"
            } catch {
                status = ""
                self.error = error.localizedDescription
            }
        }
    }

    nonisolated private static func installModel(from input: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pending = destination.deletingLastPathComponent().appendingPathComponent("model-installing")
        try? manager.removeItem(at: pending)
        defer { try? manager.removeItem(at: pending) }
        try manager.copyItem(at: input, to: pending)
        let file = try FileHandle(forReadingFrom: pending)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == modelHash else { throw SeparationError.modelDownload }
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: pending.path)
        try manager.moveItem(at: pending, to: destination)
    }

    func separate(_ input: URL) {
        guard modelReady, !busy else { return }
        resetPlayer()
        busy = true
        separating = true
        fileName = input.lastPathComponent
        status = "正在從「檔案」讀取音樂…"
        progress = nil
        error = nil
        if let result { try? FileManager.default.removeItem(at: result) }
        result = nil

        let job = SeparationControl()
        control = job
        let granted = input.startAccessingSecurityScopedResource()
        let identifier = UUID().uuidString
        let suffix = input.pathExtension
        let staged = Self.folder.appendingPathComponent(suffix.isEmpty ? "input-\(identifier)" : "input-\(identifier).\(suffix)")
        let name = String(input.deletingPathExtension().lastPathComponent.prefix(100))
        let output = Self.folder.appendingPathComponent("\(name)-伴奏.wav")
        let partial = Self.folder.appendingPathComponent("output-\(identifier).wav")
        let model = Self.model

        let start: (Bool, @escaping (Double) -> Void, @escaping (Bool) -> Void) -> Void = {
            [weak self] continued, report, completion in
            Task { @MainActor in
                var success = false
                defer {
                    completion(success)
                    try? FileManager.default.removeItem(at: staged)
                    try? FileManager.default.removeItem(at: partial)
                    if granted { input.stopAccessingSecurityScopedResource() }
                }
                guard let self else { return }
                defer {
                    self.busy = false
                    self.separating = false
                    self.progress = nil
                    self.control = nil
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Self.copyInput(input, to: staged)
                        try job.check()
                        try SeparationEngine.run(input: staged, output: partial, model: model, control: job) {
                            Task { @MainActor [weak self] in
                                guard let self, self.control === job else { return }
                                self.status = continued ? "正在分離，可嘗試鎖屏。" : "正在分離。建議保持 App 開啟。"
                            }
                        } progress: { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, self.control === job else { return }
                                self.progress = fraction
                                report(fraction)
                            }
                        }
                        try job.check()
                    }.value
                    if FileManager.default.fileExists(atPath: output.path) {
                        try FileManager.default.removeItem(at: output)
                    }
                    try FileManager.default.moveItem(at: partial, to: output)
                    self.result = output
                    self.status = "分離完成，可試聽或儲存。"
                    success = true
                } catch is CancellationError {
                    self.status = "分離已中止。可重新選取音檔。"
                } catch {
                    self.status = ""
                    self.error = error.localizedDescription
                }
            }
        }

        if #available(iOS 26.0, *),
           BackgroundSeparation.shared.submit({ task in
               task.progress.totalUnitCount = 1_000
               task.expirationHandler = { job.cancel() }
               start(true, { fraction in
                   task.progress.completedUnitCount = Int64(fraction * 1_000)
               }, { success in
                   if success { task.progress.completedUnitCount = 1_000 }
                   task.setTaskCompleted(success: success)
               })
           }) { return }

        // Provides the short grace period iOS allows when a full continued task is unavailable.
        var token = UIBackgroundTaskIdentifier.invalid
        token = UIApplication.shared.beginBackgroundTask(withName: "Mel-Band RoFormer") {
            if token != .invalid {
                UIApplication.shared.endBackgroundTask(token)
                token = .invalid
            }
        }
        start(false, { _ in }, { _ in
            if token != .invalid {
                UIApplication.shared.endBackgroundTask(token)
                token = .invalid
            }
        })
    }

    nonisolated private static func copyInput(_ input: URL, to output: URL) throws {
        let manager = FileManager.default
        var coordinatorError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: input, options: [], error: &coordinatorError) { source in
            do {
                let attributes = try source.resourceValues(forKeys: [.isRegularFileKey])
                guard attributes.isRegularFile == true else { throw SeparationError.empty }
                try manager.copyItem(at: source, to: output)
            } catch {
                operationError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let operationError { throw operationError }
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: output.path)
    }

    func cancel() {
        control?.cancel()
        status = "正在停止分離…"
    }

    func togglePlayback() {
        if playing {
            player?.pause()
            playing = false
            playbackMonitor?.cancel()
            return
        }
        guard let result else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            if player == nil { player = try AVAudioPlayer(contentsOf: result) }
            guard let player, player.play() else { throw URLError(.cannotDecodeContentData) }
            playing = true
            playbackMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let self else { return }
                    if self.player?.isPlaying != true {
                        self.playing = false
                        return
                    }
                }
            }
        } catch {
            self.error = "無法試聽伴奏。\(error.localizedDescription)"
        }
    }

    private func resetPlayer() {
        playbackMonitor?.cancel()
        player?.stop()
        player = nil
        playing = false
    }
}
