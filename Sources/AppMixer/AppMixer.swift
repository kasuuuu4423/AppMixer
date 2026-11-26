import MixerDSP
import SwiftUI

@main
enum AppMixer {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first
        if command == "--check-audio" || command == "--check-routes" {
            do {
                print(try checkAudioOutput())
                let apps = try findAudioApps()
                for app in apps {
                    print("\(app.name) [\(app.id)]: \(app.processes), playing: \(app.isPlaying)")
                }
                if command == "--check-routes" {
                    guard let app = apps.first(where: \.isPlaying) ?? apps.first else {
                        throw AudioFailure("音声処理の候補アプリが見つかりません")
                    }
                    try checkAudioRoutes(app: app)
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        AppMixerScene.main()
    }
}

private struct AppMixerScene: App {
    @State private var mixer = MixerModel()
    var body: some Scene {
        MenuBarExtra("AppMixer", systemImage: "slider.horizontal.3") {
            MixerPanel(mixer: mixer)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class MixerModel {
    private(set) var preferences = RoutingPreferences()
    private(set) var apps: [PlayingApp] = []
    private(set) var message: String?
    private(set) var busy = false
    @ObservationIgnored private let router = AudioRouter()
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var preMuteVolumes: [String: Int] = [:]

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
                if self == nil { return }
            }
        }
    }

    private func refresh() {
        do {
            let previous = apps.map(\.processes)
            apps = try findAudioApps()
            if !busy && (preferences.enabled || previous != apps.map(\.processes)) { apply() }
        } catch {
            if preferences.enabled {
                preferences.enabled = false
                apply()
            }
            message = error.localizedDescription
        }
    }

    func enable(_ enabled: Bool) {
        message = nil
        preferences.enabled = enabled
        apply()
    }

    func volume(_ value: Int, for app: PlayingApp) {
        if value == 100 { preferences.volumes.removeValue(forKey: app.id) }
        else { preferences.volumes[app.id] = value }
        apply()
    }

    func reset() {
        preferences.volumes = [:]
        preferences.equalizer = Equalizer()
        preMuteVolumes = [:]
        apply()
    }

    func toggleMute(_ app: PlayingApp) {
        let value = preferences.volumes[app.id, default: 100]
        if value == 0 {
            volume(preMuteVolumes.removeValue(forKey: app.id) ?? 100, for: app)
        } else {
            preMuteVolumes[app.id] = value
            volume(0, for: app)
        }
    }

    func equalizer(_ value: Int, at keyPath: WritableKeyPath<Equalizer, Int>) {
        preferences.equalizer[keyPath: keyPath] = value
        apply()
    }

    private func apply() {
        pending = true
        guard !busy else { return }
        busy = true
        Task {
            while pending {
                pending = false
                do {
                    try await router.update(preferences, apps: apps)
                } catch {
                    preferences.enabled = false
                    message = error.localizedDescription
                }
            }
            busy = false
        }
    }
}

private struct MixerPanel: View {
    let mixer: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AppMixer").font(.headline)
                Spacer()
                Toggle("音声処理", isOn: Binding(get: { mixer.preferences.enabled }, set: { mixer.enable($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if let message = mixer.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if !mixer.preferences.enabled {
                Text("音声処理をオンにすると、下の設定が反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("アプリ別の音量").font(.subheadline.bold())
            if mixer.apps.isEmpty {
                Text("調整したいアプリで音を鳴らしてください。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(mixer.apps) { app in volumeRow(app) }
                    }
                }
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("出力全体のEQ").font(.subheadline.bold())
            band("低音", at: \.low)
            band("中音", at: \.mid)
            band("高音", at: \.high)
            HStack {
                Button("リセット") { mixer.reset() }
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { mixer.startMonitoring() }
    }

    private func volumeRow(_ app: PlayingApp) -> some View {
        let value = mixer.preferences.volumes[app.id, default: 100]
        return HStack {
            Button {
                mixer.toggleMute(app)
            } label: {
                Image(systemName: value == 0 ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(value == 0 ? "\(app.name)のミュートを解除" : "\(app.name)をミュート")
            .accessibilityLabel(value == 0 ? "\(app.name)のミュートを解除" : "\(app.name)をミュート")
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1).foregroundStyle(app.isPlaying ? .primary : .secondary)
                Slider(value: Binding(get: { Double(mixer.preferences.volumes[app.id, default: 100]) },
                                      set: { mixer.volume(Int($0), for: app) }),
                       in: 0...Double(StereoProcessor.maximumVolume), step: 1) { Text("\(app.name)の音量") }
                    .labelsHidden()
            }
            Text("\(value)%").monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    private func band(_ label: String, at keyPath: WritableKeyPath<Equalizer, Int>) -> some View {
        let value = mixer.preferences.equalizer[keyPath: keyPath]
        return HStack {
            Text(label).frame(width: 35, alignment: .leading)
            Slider(value: Binding(get: { Double(mixer.preferences.equalizer[keyPath: keyPath]) },
                                  set: { mixer.equalizer(Int($0), at: keyPath) }),
                   in: -12...12, step: 1) { Text(label) }
                .labelsHidden()
            Text("\(value > 0 ? "+" : "")\(value) dB").monospacedDigit().frame(width: 55, alignment: .trailing)
        }
    }
}
