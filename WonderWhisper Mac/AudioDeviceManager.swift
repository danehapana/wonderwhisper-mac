import Foundation
import AVFoundation
import CoreAudio

enum AudioInputSelection: Equatable {
    case systemDefault
    case deviceUID(String)

    static func load() -> AudioInputSelection {
        if let uid = UserDefaults.standard.string(forKey: "audio.input.uid"), !uid.isEmpty {
            return .deviceUID(uid)
        }
        return .systemDefault
    }

    func persist() {
        switch self {
        case .systemDefault:
            UserDefaults.standard.removeObject(forKey: "audio.input.uid")
        case .deviceUID(let uid):
            UserDefaults.standard.set(uid, forKey: "audio.input.uid")
        }
    }
}

struct AudioDeviceInfo: Hashable {
    let uid: String
    let name: String
}

enum AudioDeviceManager {
    static func availableInputDevices() -> [AudioDeviceInfo] {
        let devices = AVCaptureDevice.devices(for: .audio)
        return devices.map { AudioDeviceInfo(uid: $0.uniqueID, name: $0.localizedName) }
    }

    static func currentDefaultInputUID() -> String? {
        var deviceID = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(from: deviceID)
    }

    // MARK: - Input Volume (Gain)
    static func inputVolume(uid: String) -> Float? {
        guard let dev = deviceID(forUID: uid) else { return nil }
        // Try master element first
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMaster)
        if AudioObjectHasProperty(dev, &addr) {
            var vol: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        // Fallback to channel 1
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: 1)
        if AudioObjectHasProperty(dev, &addr) {
            var vol: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        return nil
    }

    @discardableResult
    static func setInputVolume(uid: String, volume: Float) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var vol = max(0, min(1, volume))
        // Try master element first
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMaster)
        if AudioObjectHasProperty(dev, &addr) {
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol) == noErr { return true }
        }
        // Fallback to channel 1
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: 1)
        if AudioObjectHasProperty(dev, &addr) {
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol) == noErr { return true }
        }
        return false
    }

    @discardableResult
    static func raiseInputVolumeIfNeeded(for selection: AudioInputSelection) -> Bool {
        let effectiveUID: String?
        switch selection {
        case .systemDefault:
            effectiveUID = currentDefaultInputUID()
        case .deviceUID(let uid):
            effectiveUID = uid
        }
        guard let uid = effectiveUID else { return false }
        if let current = inputVolume(uid: uid) {
            if current < 0.99 {
                return setInputVolume(uid: uid, volume: 1.0)
            }
            return true
        } else {
            // Some devices don't expose software gain; nothing to do
            return false
        }
    }
    
    static func deviceUID(from deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var dev = deviceID
        var status = AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size)
        guard status == noErr else { return nil }
        var cfStr: CFString = "" as CFString
        status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cfStr)
        guard status == noErr else { return nil }
        return cfStr as String
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = Array(repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        guard status == noErr else { return nil }
        for id in devices {
            if let dUID = deviceUID(from: id), dUID == uid { return id }
        }
        return nil
    }

    @discardableResult
    static func setSystemDefaultInput(toUID uid: String) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var newDev = dev
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &newDev)
        return status == noErr
    }
}
