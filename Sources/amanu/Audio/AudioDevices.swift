import CoreAudio
import Foundation
import JottieModels

/// The devices macOS is routing through, by name and by identity.
///
/// Asked at the moments where the answer is worth keeping — when capture
/// starts, and when the route changes under it — and, now that the mic track
/// follows a microphone rather than merely inheriting one, asked again
/// whenever something might have moved.
///
/// Read on demand rather than cached: every answer here is a fact about right
/// now, and a stale one is worse than the query it saved.
enum AudioDevices {
    static func defaultInput() -> AudioObjectID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutput() -> AudioObjectID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputName() -> String? { name(of: defaultInput()) }

    static func defaultOutputName() -> String? { name(of: defaultOutput()) }

    static func name(of device: AudioObjectID?) -> String? {
        guard let device else { return nil }
        var address = propertyAddress(kAudioObjectPropertyName)
        // These properties follow Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let name = value.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }

    /// Whether the device can record at all. Worth asking, because a process
    /// doing duplex I/O — anything with voice processing on, jottie included —
    /// lists its *output* device among the devices it is running input on, and
    /// a speaker is not a microphone.
    static func hasInput(_ device: AudioObjectID) -> Bool {
        channels(of: device, scope: kAudioObjectPropertyScopeInput) > 0
    }

    static func hasOutput(_ device: AudioObjectID) -> Bool {
        channels(of: device, scope: kAudioObjectPropertyScopeOutput) > 0
    }
    static func context(of device: AudioObjectID?, input: Bool) -> AudioDeviceContext {
        guard let device else { return AudioDeviceContext() }
        let transport = uint32(device, selector: kAudioDevicePropertyTransportType)
        let connection: String
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: connection = "built_in"
        case kAudioDeviceTransportTypeUSB: connection = "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: connection = "bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: connection = "display"
        case kAudioDeviceTransportTypeAirPlay: connection = "airplay"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: connection = "virtual_or_aggregate"
        default: connection = "unknown"
        }
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        var streams: [AudioObjectID] = []
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
            streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) != noErr { streams = [] }
        }
        let terminals = Set(streams.compactMap { uint32($0, selector: kAudioStreamPropertyTerminalType) })
        let kind = classify(terminals: terminals)
        return AudioDeviceContext(name: name(of: device), transport: connection, kind: kind,
            source: kind == "unknown" ? "unknown" : "core_audio_terminal")
    }
    /// A transport describes the connection, never the physical output kind.
    static func classify(terminals: Set<UInt32>) -> String {
        if terminals == [kAudioStreamTerminalTypeHeadphones] { return "headphones" }
        if terminals == [kAudioStreamTerminalTypeSpeaker] { return "speakers" }
        if terminals == [kAudioStreamTerminalTypeMicrophone] || terminals == [kAudioStreamTerminalTypeHeadsetMicrophone] { return "microphone" }
        return "unknown"
    }
    private static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    // MARK: -

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = propertyAddress(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func channels(
        of device: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }
}
