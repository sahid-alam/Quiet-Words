import AVFoundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.sahidalam.quietwords", category: "devices")

/// A microphone, for reporting only — the app records from the system default.
///
/// Opening the mic on a Bluetooth headset switches it from A2DP to the hands-free
/// profile, and its *output* collapses to narrowband mono for everything on the machine
/// — music, video, calls — for as long as the mic is held. That is worth warning about.
///
/// Recording from a different device instead was tried and abandoned; see the
/// input-device trap in CLAUDE.md. `preferredWired` names what to switch the *system*
/// default to, which is what the button in Settings offers.
struct AudioInput: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let deviceID: AudioDeviceID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

enum AudioDevices {
    /// Every device with at least one input channel.
    static func inputs() -> [AudioInput] {
        deviceIDs().compactMap(describe).filter { $0.uid != "" }
    }

    /// What the app is actually recording from — the system default input.
    static func systemDefault() -> AudioInput? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id: AudioDeviceID = 0
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return describe(id)
    }

    /// A microphone that will not put a headset into hands-free mode: built-in first,
    /// then anything else that is not Bluetooth. nil when every input is Bluetooth.
    static func preferredWired() -> AudioInput? {
        let inputs = inputs()
        return inputs.first(where: \.isBuiltIn) ?? inputs.first { !$0.isBluetooth }
    }

    /// Changes the system default input. Deliberately an explicit, user-pressed action:
    /// silently repointing the default around each dictation would hijack the mic out of
    /// whatever call the user is on.
    @discardableResult
    static func makeSystemDefault(_ device: AudioInput) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = device.deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status == noErr {
            logger.log("system input set to \(device.name, privacy: .public)")
        } else {
            logger.error("could not set system input: OSStatus \(status, privacy: .public)")
        }
        return status == noErr
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func describe(_ id: AudioDeviceID) -> AudioInput? {
        guard inputChannels(of: id) > 0 else { return nil }
        return AudioInput(
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
            deviceID: id,
            name: string(id, kAudioObjectPropertyName) ?? "Unknown",
            transport: integer(id, kAudioDevicePropertyTransportType) ?? 0)
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
    }

    private static func integer(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
