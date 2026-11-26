import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String, status: OSStatus? = nil) {
        errorDescription = status.map { "\(message)（Core Audio: \($0)）" } ?? message
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioFailure(operation, status: status) }
    }

    static func property<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "音声デバイスの情報を取得できません")
        return value
    }

    static func text(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let result = try property(object, selector, initial: nil as Unmanaged<CFString>?)
        guard let result else { return "" }
        return result.takeRetainedValue() as String
    }

    static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
                  "音声デバイスの一覧を取得できません")
        guard size > 0 else { return [] }
        let width = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / width)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "音声デバイスの一覧を取得できません")
        return Array(ids.prefix(Int(size) / width))
    }

    static func streamChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: 0)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size),
                  "音声バッファの構成を取得できません")
        guard size > 0 else { return [] }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, data),
                  "音声バッファの構成を取得できません")
        return UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            .map(\.mNumberChannels)
    }

    static func setTapOnlyInput(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID,
                                tapIndex: Int, streamCount: Int) throws {
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = offset + streamCount * MemoryLayout<UInt32>.stride
        let data = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { data.deallocate() }
        data.storeBytes(of: unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        data.storeBytes(of: UInt32(streamCount), toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>
            .offset(of: \.mNumberStreams)!, as: UInt32.self)
        let flags = (data + offset).bindMemory(to: UInt32.self, capacity: streamCount)
        flags.initialize(repeating: 0, count: streamCount)
        flags[tapIndex] = 1
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: 0)
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), data),
                  "機器のマイク入力を無効にできないため、音声処理を停止しました")
    }

    static func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0
        )
        var result: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &result
        )
        return status == noErr && result != 0 ? result : nil
    }
}

struct OutputDevice: Hashable, Sendable {
    let id: AudioObjectID
    let name: String
    let sampleRate: Double
    let streams: [AudioObjectID]

    init(id: AudioObjectID) throws {
        self.id = id
        name = try HAL.text(id, kAudioObjectPropertyName)
        sampleRate = try HAL.property(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        streams = try HAL.objects(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    }

    static func current() throws -> OutputDevice? {
        let id = try HAL.property(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        return id == 0 ? nil : try OutputDevice(id: id)
    }
}

struct PlayingApp: Identifiable, Sendable {
    let id: String
    let name: String
    let processes: [AudioObjectID]
    let isPlaying: Bool
}

@MainActor
func findAudioApps() throws -> [PlayingApp] {
    let processIDs = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
    let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    var groups: [String: PlayingApp] = [:]
    for process in processIDs {
        guard let pid = try? HAL.property(process, kAudioProcessPropertyPID, initial: pid_t(0)),
              pid > 0, pid != getpid() else { continue }
        let bundleID = (try? HAL.text(process, kAudioProcessPropertyBundleID)) ?? ""
        let running = NSRunningApplication(processIdentifier: pid)
        let isPlaying = (try? HAL.property(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
        // Chromium and other browsers often play from an audio helper inside the main bundle.
        let app = runningApps.first { $0.processIdentifier == pid }
            ?? runningApps.first { app in
                guard let appID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
                return bundleID == appID || bundleID.hasPrefix(appID + ".helper")
            }
            ?? runningApps.first { app in
                guard let root = app.bundleURL?.standardizedFileURL.path,
                      let executable = running?.executableURL?.standardizedFileURL.path else { return false }
                return executable.hasPrefix(root + "/")
            }
        guard let key = app?.bundleIdentifier, let name = app?.localizedName else { continue }
        let previous = groups[key]
        groups[key] = PlayingApp(id: key, name: name, processes: (previous?.processes ?? []) + [process],
                                 isPlaying: isPlaying || previous?.isPlaying == true)
    }
    return groups.values.map { app in
        PlayingApp(id: app.id, name: app.name, processes: app.processes.sorted(), isPlaying: app.isPlaying)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
