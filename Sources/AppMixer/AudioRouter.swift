import CoreAudio
import MixerDSP
import Synchronization

struct RoutingPreferences: Sendable {
    var enabled = false
    var volumes: [String: Int] = [:]
    var equalizer = Equalizer()
}

actor AudioRouter {
    private var routes: [RouteKey: AudioRoute] = [:]

    func update(_ preferences: RoutingPreferences, apps: [PlayingApp]) throws {
        guard preferences.enabled else { return stop() }
        do {
            let output = try HAL.property(HAL.system, kAudioHardwarePropertyDefaultOutputDevice,
                                          initial: AudioObjectID(0))
            guard output != 0 else { throw AudioFailure("既定の音声出力が見つかりません") }
            let adjusted = apps.filter { preferences.volumes[$0.id, default: 100] != 100 }
            var desired: [RouteKey: Int] = [:]
            for app in adjusted {
                desired[RouteKey(kind: .app(app.id), output: output, processes: app.processes)] =
                    preferences.volumes[app.id, default: 100]
            }
            if !preferences.equalizer.isFlat {
                desired[RouteKey(kind: .remainder, output: output,
                                 processes: Set(adjusted.flatMap(\.processes)).sorted())] = 100
            }
            removeObsoleteRoutes(desired)
            for (key, volume) in desired where key.kind != .remainder {
                try updateRoute(key, volume: volume, equalizer: preferences.equalizer)
            }
            for (key, volume) in desired where key.kind == .remainder {
                try updateRoute(key, volume: volume, equalizer: preferences.equalizer)
            }
        } catch {
            // Restore native playback instead of leaving a partially connected graph.
            stop()
            throw error
        }
    }

    private func removeObsoleteRoutes(_ desired: [RouteKey: Int]) {
        let obsolete = routes.keys.filter { desired[$0] == nil }
        for key in obsolete { routes.removeValue(forKey: key)?.stop() }
    }

    private func updateRoute(_ key: RouteKey, volume: Int, equalizer: Equalizer) throws {
        if let route = routes[key] {
            route.adjust(volume: volume, equalizer: equalizer)
        } else {
            routes[key] = try AudioRoute(key: key, volume: volume, equalizer: equalizer)
        }
    }

    private func stop() {
        for route in routes.values { route.stop() }
        routes.removeAll()
    }
}

private struct RouteKey: Hashable {
    enum Kind: Hashable { case app(String), remainder }
    let kind: Kind
    let output: AudioObjectID
    let processes: [AudioObjectID]
}

private final class AudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var renderer: Renderer?

    init(key: RouteKey, volume: Int, equalizer: Equalizer, validateOnly: Bool = false) throws {
        do {
            try connect(key: key, volume: volume, equalizer: equalizer, validateOnly: validateOnly)
        } catch {
            stop()
            throw error
        }
    }

    private func connect(key: RouteKey, volume: Int, equalizer: Equalizer, validateOnly: Bool) throws {
        let outputUID = try HAL.text(key.output, kAudioDevicePropertyDeviceUID)
        let inputs = try HAL.objects(key.output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let transport = try HAL.property(key.output, kAudioDevicePropertyTransportType, initial: UInt32(0))
        guard !outputUID.isEmpty, inputs.isEmpty, transport == kAudioDeviceTransportTypeBuiltIn else {
            throw AudioFailure("この試作では、Macの内蔵スピーカーを出力先に選んでください")
        }
        _ = try Self.stereoFormat(key.output, scope: kAudioDevicePropertyScopeOutput)

        let description: CATapDescription
        if key.kind == .remainder {
            guard let ownProcess = HAL.ownProcess() else {
                throw AudioFailure("AppMixer自身の音声出力を除外できないため、EQを停止しました")
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: key.processes + [ownProcess])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: key.processes)
        }
        description.name = "AppMixer"
        description.deviceUID = outputUID
        description.isPrivate = true
        description.muteBehavior = validateOnly ? .unmuted : .mutedWhenTapped
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "音声タップを作成できません")

        let specification: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer Output",
            kAudioAggregateDeviceUIDKey: "local.appmixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate),
                      "内部の音声入出力を作成できません")
        let input = try Self.stereoFormat(aggregate, scope: kAudioDevicePropertyScopeInput)
        let output = try Self.stereoFormat(aggregate, scope: kAudioDevicePropertyScopeOutput)
        guard input.mSampleRate == output.mSampleRate, output.mSampleRate > 0 else {
            throw AudioFailure("入出力のサンプルレートが一致しません")
        }
        guard !validateOnly else { return }
        let renderer = Renderer(sampleRate: output.mSampleRate, volume: volume, equalizer: equalizer)
        self.renderer = renderer
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
            renderer.render(input, output)
        }, "音声処理を登録できません。システムオーディオの録音権限を確認してください")
        guard let ioProc else { throw AudioFailure("音声処理を登録できません") }
        try HAL.check(AudioDeviceStart(aggregate, ioProc),
                      "音声処理を開始できません。システムオーディオの録音権限を確認してください")
        started = true
    }

    fileprivate static func stereoFormat(_ device: AudioObjectID, scope: AudioObjectPropertyScope)
        throws -> AudioStreamBasicDescription {
        let streams = try HAL.objects(device, kAudioDevicePropertyStreams, scope: scope)
        guard streams.count == 1, let stream = streams.first else {
            throw AudioFailure("この試作では、単一のステレオ音声ストリームのみ対応しています")
        }
        let format = try HAL.property(stream, kAudioStreamPropertyVirtualFormat,
                                      initial: AudioStreamBasicDescription())
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let foreignEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, !foreignEndian,
              format.mBytesPerFrame == (planar ? 4 : 8) else {
            throw AudioFailure("この試作では、32ビット浮動小数点のステレオ出力のみ対応しています")
        }
        return format
    }

    func adjust(volume: Int, equalizer: Equalizer) {
        renderer?.adjust(volume: volume, equalizer: equalizer)
    }

    func stop() {
        if let ioProc {
            if started { AudioDeviceStop(aggregate, ioProc) }
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
            started = false
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
            tap = 0
        }
        renderer = nil
    }

    deinit { stop() }
}

func checkAudioOutput() throws -> String {
    let output = try HAL.property(HAL.system, kAudioHardwarePropertyDefaultOutputDevice,
                                  initial: AudioObjectID(0))
    let name = try HAL.text(output, kAudioObjectPropertyName)
    let inputs = try HAL.objects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    let format = try AudioRoute.stereoFormat(output, scope: kAudioObjectPropertyScopeOutput)
    return "\(name): \(format.mChannelsPerFrame)ch / \(Int(format.mSampleRate))Hz, input streams: \(inputs.count), self: \(String(describing: HAL.ownProcess()))"
}

func checkAudioRoutes(app: PlayingApp) throws {
    let output = try HAL.property(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    let appRoute = try AudioRoute(key: RouteKey(kind: .app(app.id), output: output, processes: app.processes),
                                  volume: 20, equalizer: Equalizer(), validateOnly: true)
    defer { appRoute.stop() }
    let eqRoute = try AudioRoute(key: RouteKey(kind: .remainder, output: output, processes: app.processes),
                                 volume: 100, equalizer: Equalizer(), validateOnly: true)
    defer { eqRoute.stop() }
    print("Prepared \(app.name) and global EQ routes without starting I/O.")
}

// Core Audio serializes calls for one IOProc. The UI-facing path only writes the atomic settings.
private final class Renderer: @unchecked Sendable {
    private let settings: Atomic<UInt32>
    private var applied: UInt32
    private var processor: StereoProcessor

    init(sampleRate: Double, volume: Int, equalizer: Equalizer) {
        let initial = Self.pack(volume, equalizer)
        settings = Atomic(initial)
        applied = initial
        processor = StereoProcessor(sampleRate: sampleRate)
        processor.configure(volume: volume, equalizer: equalizer, immediately: true)
    }

    private static func pack(_ volume: Int, _ equalizer: Equalizer) -> UInt32 {
        func band(_ decibels: Int) -> UInt32 { UInt32(min(12, max(-12, decibels)) + 12) }
        return UInt32(min(StereoProcessor.maximumVolume, max(0, volume))) | (band(equalizer.low) << 8)
            | (band(equalizer.mid) << 16) | (band(equalizer.high) << 24)
    }

    func adjust(volume: Int, equalizer: Equalizer) {
        settings.store(Self.pack(volume, equalizer), ordering: .relaxed)
    }

    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputBuffers where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        guard let source = StereoBuffer(inputBuffers), let destination = StereoBuffer(outputBuffers) else { return }
        let next = settings.load(ordering: .relaxed)
        if applied != next {
            processor.configure(volume: Int(next & 0xff), equalizer: Equalizer(
                low: Int((next >> 8) & 0xff) - 12, mid: Int((next >> 16) & 0xff) - 12,
                high: Int((next >> 24) & 0xff) - 12
            ))
            applied = next
        }
        for frame in 0..<min(source.frames, destination.frames) {
            let (left, right) = processor.process(left: source.left[frame * source.stride],
                                                  right: source.right[frame * source.stride])
            destination.left[frame * destination.stride] = left
            destination.right[frame * destination.stride] = right
        }
    }
}

private struct StereoBuffer {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let frames: Int
    let stride: Int

    init?(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard !buffers.isEmpty, let first = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
        if buffers.count == 1, buffers[0].mNumberChannels == 2 {
            left = first
            right = first + 1
            frames = Int(buffers[0].mDataByteSize) / 8
            stride = 2
        } else if buffers.count == 2, buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                  let second = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            left = first
            right = second
            frames = Int(min(buffers[0].mDataByteSize, buffers[1].mDataByteSize)) / 4
            stride = 1
        } else {
            return nil
        }
    }
}
