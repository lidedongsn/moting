import CoreAudio
import Foundation

/// 哪些 app 正在用麦克风（Core Audio 的进程对象列表，macOS 14 起）。
/// 只读属性，不打开任何设备，不需要额外权限
public enum MicUsage {
    /// 正在录音输入的进程的 bundle id；excluding 是要排除的进程（Moting 自己）
    public static func activeInputBundleIDs(excluding pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> Set<String> {
        var addr = CA.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        var ids: Set<String> = []
        for object in objects {
            guard (try? CA.get(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0 != 0,
                  (try? CA.get(object, kAudioProcessPropertyPID, initial: pid_t(-1))) != pid,
                  let bundle: CFString = try? CA.get(object, kAudioProcessPropertyBundleID, initial: "" as CFString)
            else { continue }
            let id = bundle as String
            if !id.isEmpty { ids.insert(id) }
        }
        return ids
    }
}
