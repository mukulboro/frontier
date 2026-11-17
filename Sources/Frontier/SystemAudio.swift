import AudioToolbox
import CoreAudio
import Foundation

/// Volume and mute for the default output device, straight through CoreAudio.
///
/// This needs no permission at all, unlike the media keys, and runs in-process with no subprocess.
/// Transport (play, skip) has no such route and still goes through `MediaKeys`.
enum SystemAudio {
    private static var defaultOutput: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0…1, or nil when the device has no software volume (some external DACs).
    static var volume: Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let device = defaultOutput
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setVolume(_ newValue: Float) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let device = defaultOutput
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value = max(0, min(1, newValue))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    /// One notch, matching roughly what a volume key does.
    @discardableResult
    static func nudgeVolume(by delta: Float) -> Bool {
        guard let current = volume else { return false }
        return setVolume(current + delta)
    }

    static var isMuted: Bool? {
        var addr = address(kAudioDevicePropertyMute)
        let device = defaultOutput
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    @discardableResult
    static func toggleMute() -> Bool {
        var addr = address(kAudioDevicePropertyMute)
        let device = defaultOutput
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue,
              let muted = isMuted else {
            // Some devices expose no mute switch; drop the volume to zero instead.
            if let v = volume, v > 0 { return setVolume(0) }
            return false
        }
        var value: UInt32 = muted ? 0 : 1
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
