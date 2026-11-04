import Combine
import Foundation
import MotingCapture

/// 用哪个麦克风：没选过就跟随系统默认
enum MicPreference {
    static let uidKey = "audio.micUID"
    static let nameKey = "audio.micName"

    static func source() -> MicSource {
        let uid = UserDefaults.standard.string(forKey: uidKey) ?? ""
        return MicSource(deviceUID: uid.isEmpty ? nil : uid)
    }
}

/// 设置页显示的设备列表，插拔设备时自动刷新
@MainActor
final class MicDevicesModel: ObservableObject {
    @Published private(set) var devices: [InputDevice] = InputDevices.all()
    @Published private(set) var defaultName: String? = InputDevices.defaultName()
    nonisolated(unsafe) private var stopObserving: (() -> Void)?

    init() {
        stopObserving = InputDevices.observe(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { stopObserving?() }

    private func refresh() {
        devices = InputDevices.all()
        defaultName = InputDevices.defaultName()
    }
}
