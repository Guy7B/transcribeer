import CoreAudio
import Foundation

/// Unified Core Audio device enumeration and UID resolution.
///
/// Extracted from `MicCapture` + `SystemAudioCapture` so the GUI can
/// present pickers without duplicating Core Audio boilerplate.
public enum AudioDevices {
    // MARK: - Input devices

    /// All currently connected audio input devices with at least one input
    /// channel.
    public static func availableInputDevices() -> [(id: AudioDeviceID, name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String, uid: String)] = []
        for deviceID in deviceIDs {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID, &inputAddress, 0, nil, &bufferListSize
            ) == noErr, bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(
                deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPtr
            ) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            guard let name = deviceName(for: deviceID),
                  let uid = deviceUID(for: deviceID) else { continue }
            result.append((id: deviceID, name: name, uid: uid))
        }
        return result
    }

    /// Resolve a stable UID string to the current `AudioDeviceID`.
    public static func inputDeviceID(forUID uid: String) -> AudioDeviceID? {
        availableInputDevices().first { $0.uid == uid }?.id
    }

    /// The system default input device.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    // MARK: - Output devices

    /// All currently connected audio output devices with at least one output
    /// channel.
    public static func availableOutputDevices() -> [(id: AudioDeviceID, name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        var result: [(id: AudioDeviceID, name: String, uid: String)] = []
        for deviceID in deviceIDs {
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                deviceID, &outputAddress, 0, nil, &outputSize
            ) == noErr, outputSize > 0 else { continue }

            guard let name = deviceName(for: deviceID),
                  let uid = deviceUID(for: deviceID) else { continue }
            result.append((id: deviceID, name: name, uid: uid))
        }
        return result
    }

    /// Resolve a stable UID string to the current `AudioDeviceID`.
    public static func outputDeviceID(forUID uid: String) -> AudioDeviceID? {
        availableOutputDevices().first { $0.uid == uid }?.id
    }

    /// The system default output device.
    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - Device classification

    /// Core Audio transport type for a device (e.g. `kAudioDeviceTransportTypeBuiltIn`,
    /// `kAudioDeviceTransportTypeBluetooth`). Returns `nil` if the property
    /// isn't queryable on this device.
    ///
    /// Used by callers that need to make routing decisions based on the
    /// physical class of the device (built-in speaker vs. headphones jack vs.
    /// AirPods, etc.) — for example, deciding whether to enable
    /// echo cancellation on the mic capture path.
    public static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    /// FourCC of the active output data source (e.g. `'spkr'` = internal
    /// speakers, `'hdpn'` = headphone jack). Only meaningful on devices that
    /// expose a data-source selector — typically the built-in audio device on
    /// Macs with a 3.5 mm jack. `nil` otherwise.
    public static func outputDataSource(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source) == noErr
        else { return nil }
        return source
    }

    // MARK: - Shared helpers

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeUnretainedValue() as String
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}
