import CoreAudio
import Foundation

/// 可以当麦克风用的输入设备
public struct InputDevice: Identifiable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var id: String { uid }
}

public enum InputDevices {
    /// 自己创建的录系统声音的聚合设备、系统内部的默认聚合设备都不是麦克风
    static func isSelectable(uid: String) -> Bool {
        !uid.hasPrefix("moting-tap-") && !uid.hasPrefix("CADefaultDeviceAggregate")
    }

    public static func all() -> [InputDevice] {
        var addr = CA.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard (try? CA.inputChannelCount(id)) ?? 0 > 0, let uid = try? CA.deviceUID(id), isSelectable(uid: uid),
                  let name = name(of: id) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    /// 系统默认输入设备的名字
    public static func defaultName() -> String? {
        (try? CA.defaultInputDevice()).flatMap(name(of:))
    }

    /// 设备插拔或系统默认输入变化时回调；返回用于注销的闭包
    public static func observe(queue: DispatchQueue, _ block: @escaping () -> Void) -> () -> Void {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let removers = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
            .map { CA.listen(system, $0, queue: queue, block) }
        return { removers.forEach { $0() } }
    }

    private static func name(of device: AudioObjectID) -> String? {
        guard device != kAudioObjectUnknown,
              let name: CFString = try? CA.get(device, kAudioObjectPropertyName, initial: "" as CFString) else { return nil }
        return name as String
    }
}
