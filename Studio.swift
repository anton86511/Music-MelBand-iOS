import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class Studio: ObservableObject {
    @Published private(set) var fileName: String?
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var busy = false
    @Published private(set) var separating = false
    @Published private(set) var playing = false
    @Published private(set) var result: URL?
    @Published var error: String?

    nonisolated private static let folder = URL.applicationSupportDirectory.appendingPathComponent("MusicStudio", isDirectory: true)
    private var control: SeparationControl?
    private var player: AVAudioPlayer?
    private var playbackMonitor: Task<Void, Never>?

    func separate(_ input: URL, mode: SeparationMode) {
        guard !busy else { return }
        guard let model = mode.modelURL() else {
            error = "安裝包缺少離線模型。請重新下載 IPA。"
            return
        }
        resetPlayer()
        busy = true
        separating = true
        fileName = input.lastPathComponent
        status = "正在從「檔案」讀取音樂…"
        progress = nil
        error = nil
        if let result { try? FileManager.default.removeItem(at: result) }
        result = nil

        let started = ContinuousClock.now
        let job = SeparationControl()
        control = job
        let granted = input.startAccessingSecurityScopedResource()
        let identifier = UUID().uuidString
        let suffix = input.pathExtension
        let jobFolder = Self.folder.appendingPathComponent("Import-\(identifier)", isDirectory: true)
        let staged = jobFolder.appendingPathComponent(suffix.isEmpty ? "input" : "input.\(suffix)")
        let name = String(input.deletingPathExtension().lastPathComponent.prefix(100))
        let output = Self.folder.appendingPathComponent("\(name)-伴奏.wav")
        let partial = Self.folder.appendingPathComponent("output-\(identifier).wav")

        // Keep the short background grace period for interruptions such as switching apps.
        var token = UIBackgroundTaskIdentifier.invalid
        func endBackgroundTask() {
            if token != .invalid {
                UIApplication.shared.endBackgroundTask(token)
                token = .invalid
            }
        }
        token = UIApplication.shared.beginBackgroundTask(withName: mode.title) {
            endBackgroundTask()
        }

        Task { @MainActor in
            defer {
                endBackgroundTask()
                try? FileManager.default.removeItem(at: jobFolder)
                try? FileManager.default.removeItem(at: partial)
                if granted { input.stopAccessingSecurityScopedResource() }
                self.busy = false
                self.separating = false
                self.progress = nil
                self.control = nil
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.copyInput(input, to: staged)
                    let prepared = try await AudioImport.prepare(staged, control: job)
                    try SeparationEngine.run(input: prepared, output: partial, model: model, mode: mode, control: job) {
                        Task { @MainActor [weak self] in
                            guard let self, self.control === job, (try? job.check()) != nil else { return }
                            self.status = "正在分離，請保持 App 在前景。"
                        }
                    } cooling: { paused in
                        Task { @MainActor [weak self] in
                            guard let self, self.control === job, (try? job.check()) != nil else { return }
                            self.status = paused
                                ? "iPhone 溫度偏高，已暫停分離。降溫後會自動繼續。"
                                : "正在分離，請保持 App 在前景。"
                        }
                    } progress: { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.control === job else { return }
                            self.progress = fraction
                        }
                    }
                    try job.check()
                }.value
                if FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                try FileManager.default.moveItem(at: partial, to: output)
                self.result = output
                let elapsed = started.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                self.status = "分離完成 · 耗時 \(seconds.formatted(.number.precision(.fractionLength(1)))) 秒"
            } catch is CancellationError {
                self.status = "分離已中止。可重新選取音檔。"
            } catch {
                self.status = ""
                self.error = error.localizedDescription
            }
        }
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
