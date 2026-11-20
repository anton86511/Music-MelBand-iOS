import AVFoundation
import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
final class Studio: ObservableObject {
    @Published private(set) var fileName: String?
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var busy = false
    @Published private(set) var separating = false
    @Published private(set) var canPlaySource = false
    @Published private(set) var playingSource = false
    @Published private(set) var playing = false
    @Published private(set) var result: URL?
    @Published var error: String?

    nonisolated private static let folder = URL.applicationSupportDirectory.appendingPathComponent("MusicStudio", isDirectory: true)
    private var control: SeparationControl?
    private var player: AVAudioPlayer?
    private var sourcePlayer: AVAudioPlayer?
    private var sourceURL: URL?
    private var playbackMonitor: Task<Void, Never>?

    func separate(_ input: URL) {
        guard !busy else { return }
        guard let model = Bundle.main.url(forResource: "melband-phone", withExtension: "onnx") else {
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

        let job = SeparationControl()
        control = job
        let granted = input.startAccessingSecurityScopedResource()
        let identifier = UUID().uuidString
        let suffix = input.pathExtension
        let staged = Self.folder.appendingPathComponent(suffix.isEmpty ? "input-\(identifier)" : "input-\(identifier).\(suffix)")
        let name = String(input.deletingPathExtension().lastPathComponent.prefix(100))
        let output = Self.folder.appendingPathComponent("\(name)-伴奏.wav")
        let partial = Self.folder.appendingPathComponent("output-\(identifier).wav")

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
                    self.stopSourcePlayback()
                    self.sourceURL = nil
                    self.canPlaySource = false
                    self.busy = false
                    self.separating = false
                    self.progress = nil
                    self.control = nil
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Self.copyInput(input, to: staged)
                        try job.check()
                        try SeparationEngine.run(input: staged, output: partial, model: model, control: job) {
                            Task { @MainActor [weak self] in
                                guard let self, self.control === job else { return }
                                self.sourceURL = staged
                                self.canPlaySource = !continued
                                self.status = continued ? "正在分離，可嘗試鎖屏。" : "正在分離。若要鎖屏，可先播放原曲。"
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

    func toggleSourcePlayback() {
        if playingSource {
            stopSourcePlayback()
            status = "正在分離。若要鎖屏，可先播放原曲。"
            return
        }
        guard separating, let sourceURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let audio = try AVAudioPlayer(contentsOf: sourceURL)
            audio.numberOfLoops = -1
            guard audio.play() else { throw SeparationError.empty }
            sourcePlayer = audio
            playingSource = true
            status = "原曲在播放，可嘗試鎖屏。完成後會自動停止。"
        } catch {
            self.error = "無法背景播放這個原曲。請保持 App 開啟。"
        }
    }

    private func stopSourcePlayback() {
        if sourcePlayer != nil {
            sourcePlayer?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        sourcePlayer = nil
        playingSource = false
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
