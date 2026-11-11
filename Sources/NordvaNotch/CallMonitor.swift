import CoreAudio
import CoreMediaIO
import Foundation

/// Tells whether a camera or a microphone is in use by any app. Both APIs report "running
/// somewhere" without opening the device, so no camera or microphone permission is needed.
enum CallMonitor {
    struct State: Equatable {
        var camera: Bool
        var microphone: Bool
        var inCall: Bool { camera || microphone }
    }

    static func current() -> State {
        State(camera: cameraRunning(), microphone: microphoneRunning())
    }

    // MARK: Camera

    static func cameraRunning() -> Bool {
        var devicesAddress = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &devicesAddress, 0, nil, size, &used, &devices) == noErr else { return false }
        var runningAddress = cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        return devices.contains { device in
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            let status = CMIOObjectGetPropertyData(
                device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running
            )
            return status == noErr && running != 0
        }
    }

    private static func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    // MARK: Microphone

    static func microphoneRunning() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for device in objects(of: system, kAudioHardwarePropertyDevices) where streamCount(device, kAudioObjectPropertyScopeInput) > 0 {
            guard uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 else { continue }
            // A headset that is one device for both directions also "runs" while it only plays
            // sound. The per-process flag tells real recording apart where macOS has it.
            if streamCount(device, kAudioObjectPropertyScopeOutput) == 0 { return true }
            if #available(macOS 14.2, *) {
                if anyProcessRecording() { return true }
            } else {
                return true
            }
        }
        return false
    }

    @available(macOS 14.2, *)
    private static func anyProcessRecording() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return objects(of: system, kAudioHardwarePropertyProcessObjectList).contains {
            uint32($0, kAudioProcessPropertyIsRunningInput) == 1
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func objects(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
