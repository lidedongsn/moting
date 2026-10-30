import Foundation
import IOKit.ps

public protocol PowerSource: Sendable {
    var isOnAC: Bool { get }
}

/// 读系统电源状态
public struct SystemPowerSource: PowerSource {
    public init() {}

    public var isOnAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

/// 监听插拔电源，在主 runloop 上回调
public final class PowerMonitor {
    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
            source = s
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
