import SwiftUI
import UniformTypeIdentifiers

@main
struct MusicApp: App {
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
    @State private var mode: SeparationMode = .hq3

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
                        Text("iPhone 本機分離").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        LinearGradient(colors: [Color(red: 0.08, green: 0.25, blue: 0.23),
                                                Color(red: 0.09, green: 0.15, blue: 0.20)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("分離模型", selection: $mode) {
                            ForEach(SeparationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(studio.busy)
                        Text("Core ML · GPU 加速").font(.caption).foregroundStyle(.secondary)
                        Text("分離期間請保持 App 在前景。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    if studio.separating {
                        Button("取消分離", role: .destructive, action: studio.cancel)
                    }
                }
                .padding(20)
            }
            .navigationTitle("音樂")
            .fileImporter(isPresented: $pickingAudio, allowedContentTypes: [.item]) { selection in
                switch selection {
                case .success(let url): studio.separate(url, mode: mode)
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
