import BackgroundTasks
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(MusicDelegate.self) private var delegate
    @StateObject private var studio = Studio()

    var body: some Scene {
        WindowGroup {
            StudioView(studio: studio)
                .preferredColorScheme(.dark)
        }
    }
}

private struct StudioView: View {
    @ObservedObject var studio: Studio
    @State private var pickingAudio = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.mint)
                            .accessibilityHidden(true)
                        Text("去人聲").font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("Mel-Band RoFormer · iPhone 本機分離").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        LinearGradient(colors: [Color(red: 0.08, green: 0.25, blue: 0.23),
                                                Color(red: 0.09, green: 0.15, blue: 0.20)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24)
                    )

                    if let name = studio.fileName {
                        Label(name, systemImage: "music.note").font(.headline)
                    }
                    if !studio.status.isEmpty {
                        Text(studio.status).foregroundStyle(.secondary)
                    }
                    if studio.busy {
                        if let progress = studio.progress {
                            ProgressView(value: progress).tint(.mint)
                                .accessibilityLabel("去人聲進度")
                        } else {
                            ProgressView().tint(.mint)
                        }
                    }
                    if let result = studio.result {
                        Button(action: studio.togglePlayback) {
                            Label(studio.playing ? "暫停伴奏" : "試聽伴奏",
                                  systemImage: studio.playing ? "pause.fill" : "play.fill")
                        }
                        ShareLink(item: result) {
                            Label("分享或儲存 WAV", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let error = studio.error {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    }

                    if !studio.busy {
                        prominent("選擇音樂檔案", systemImage: "plus") { pickingAudio = true }
                    }
                    if studio.canPlaySource {
                        Button(action: studio.toggleSourcePlayback) {
                            Label(studio.playingSource ? "停止播放原曲" : "播放原曲並鎖屏",
                                  systemImage: studio.playingSource ? "pause.circle" : "lock")
                        }
                    }
                    if studio.separating {
                        Button("取消分離", role: .destructive, action: studio.cancel)
                    }
                }
                .padding(20)
            }
            .navigationTitle("音樂")
            .fileImporter(isPresented: $pickingAudio, allowedContentTypes: [.item]) { selection in
                switch selection {
                case .success(let url): studio.separate(url)
                case .failure(let error): studio.error = error.localizedDescription
                }
            }
        }
        .tint(.mint)
    }

    private func prominent(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(7)
        }
        .buttonStyle(.borderedProminent)
        .tint(.mint)
        .foregroundStyle(.black)
    }
}

final class MusicDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if #available(iOS 26.0, *) {
            BackgroundSeparation.shared.register()
        }
        return true
    }
}

@available(iOS 26.0, *)
@MainActor
final class BackgroundSeparation {
    static let shared = BackgroundSeparation()
    private static let prefix = "tw.anton86511.melband.music.separation"

    private var registered = false
    private var pending: ((BGContinuedProcessingTask) -> Void)?

    func register() {
        guard Bundle.main.bundleIdentifier == "tw.anton86511.melband.music" else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.prefix + ".*", using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                guard let self, let launch = self.pending else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.pending = nil
                launch(task)
            }
        }
    }

    func submit(_ start: @escaping (BGContinuedProcessingTask) -> Void) -> Bool {
        guard registered, pending == nil else { return false }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.prefix + "." + UUID().uuidString,
            title: "音樂 · 去人聲", subtitle: "正在 iPhone 上分離伴奏")
        request.strategy = .fail
        pending = start
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            pending = nil
            return false
        }
    }
}
