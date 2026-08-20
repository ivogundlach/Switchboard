import CoreAudio
import Darwin
import Foundation

/// Keeps a newly selected non-Bluetooth output silent after a Bluetooth output disconnects.
///
/// The controller owns the Core Audio listener while it is running. It never restores a
/// volume or mute state, so a user can choose when to make the output audible again.
final class AudioDisconnectGuardController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ivogundlach.switchboard.audio-disconnect-guard")
    private var listener: AudioObjectPropertyListenerBlock?
    private var previousDevice: AudioDeviceID?
    private var previousWasBluetooth = false
    private(set) var isRunning = false

    deinit { stop() }

    func start() {
        guard !isRunning else { return }

        previousDevice = Self.defaultOutputDevice()
        previousWasBluetooth = previousDevice.map(Self.isBluetooth) ?? false

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputChanged()
        }
        let result = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            callback
        )
        guard result == noErr else { return }

        listener = callback
        isRunning = true
    }

    func stop() {
        guard isRunning, let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        self.listener = nil
        isRunning = false
        previousDevice = nil
        previousWasBluetooth = false
    }

    private func outputChanged() {
        guard isRunning, let current = Self.defaultOutputDevice(), current != previousDevice else {
            return
        }

        let shouldSilence = previousWasBluetooth && !Self.isBluetooth(current)
        previousDevice = current
        previousWasBluetooth = Self.isBluetooth(current)

        if shouldSilence {
            _ = Self.silence(current)
        }
    }

    private static func propertyValue<T: BitwiseCopyable>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type = T.self
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let value = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        value.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let result = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        return result == noErr ? value.load(as: T.self) : nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        propertyValue(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            as: AudioDeviceID.self
        ).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        propertyValue(object: device, selector: kAudioDevicePropertyTransportType, as: UInt32.self)
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        guard let transport = transportType(device) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func setProperty<T: BitwiseCopyable>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        return AudioObjectSetPropertyData(
            object,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<T>.size),
            &value
        ) == noErr
    }

    private static func silence(_ device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 1
        if setProperty(
            object: device,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain,
            value: &muted
        ) {
            return true
        }

        var volume: Float32 = 0
        if setProperty(
            object: device,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain,
            value: &volume
        ) {
            return true
        }

        var changedChannel = false
        for channel in 1...32 {
            var channelVolume: Float32 = 0
            changedChannel = setProperty(
                object: device,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: AudioObjectPropertyElement(channel),
                value: &channelVolume
            ) || changedChannel
        }
        return changedChannel
    }
}
