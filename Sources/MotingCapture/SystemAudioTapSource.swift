import CoreAudio
import Foundation
import MotingCore

/// 系统音频源：全局立体声 Process Tap（排除本进程）+ 私有聚合设备。
/// muteBehavior = .unmuted，用户照常听到声音；默认输出设备变化时重建。
public final class SystemAudioTapSource: AudioSource {
    public let channel: AudioChannel = .system
    private let pump = ChunkPump(label: "moting.capture.system")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var reader: DeviceIOReader?
    private var unlisteners: [() -> Void] = []
    /// 聚合设备的采样率监听，随 Tap 重建而重新注册
    private var unlistenRate: (() -> Void)?

    public init() {}

    public func start(handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        try pump.queue.sync {
            do {
                let r = try buildTap()
                try pump.start(inputSampleRate: r.inputSampleRate, handler: handler)
                try r.start()
                reader = r
                watchRate()
            } catch {
                teardownTap()
                throw Self.mapPermission(error)
            }
            unlisteners.append(CA.listen(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDefaultOutputDevice, queue: pump.queue) { [weak self] in
                self?.rebuild()
            })
        }
    }

    public func stop() {
        pump.queue.sync {
            unlisteners.forEach { $0() }
            unlisteners.removeAll()
            teardownTap()
            pump.stop()
        }
    }

    private func buildTap() throws -> DeviceIOReader {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        desc.name = "Moting System Audio"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateProcessTap(desc, &tap), "create process tap")
        tapID = tap

        // 只挂 Tap，不把输出设备作为子设备加入：
        // 否则输出设备若自带麦克风（如 AirPods），聚合设备会打开它的输入，导致耳机切到通话模式
        let outputUID = try CA.deviceUID(CA.defaultOutputDevice())
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Moting Tap",
            kAudioAggregateDeviceUIDKey: "moting-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "create aggregate device")
        aggregateID = agg
        return try DeviceIOReader(deviceID: agg, ring: pump.ring)
    }

    /// 蓝牙耳机切到通话模式等情况会改变聚合设备采样率，需要换重采样器，否则录成变速音频
    private func watchRate() {
        let device = aggregateID
        unlistenRate = CA.listen(device, kAudioDevicePropertyNominalSampleRate, queue: pump.queue) { [weak self] in
            guard let self, self.aggregateID == device, let rate = try? CA.nominalSampleRate(device) else { return }
            try? self.pump.reconfigure(inputSampleRate: rate)
        }
    }

    private func teardownTap() {
        unlistenRate?()
        unlistenRate = nil
        reader?.stop()
        reader = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// 在 pump.queue 上执行：默认输出设备变化后重建 Tap 与聚合设备
    private func rebuild() {
        teardownTap()
        pump.send(.interrupted("默认输出设备已变化"))
        do {
            let r = try buildTap()
            try pump.reconfigure(inputSampleRate: r.inputSampleRate)
            try r.start()
            reader = r
            watchRate()
            pump.send(.resumed)
        } catch {
            teardownTap()
            pump.send(.interrupted("系统音频重建失败：\(error)"))
        }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Tap 创建被 TCC 拒绝时 Core Audio 返回权限类错误码
    private static func mapPermission(_ error: Error) -> Error {
        if case CaptureError.coreAudio(let status, _) = error,
           status == kAudioHardwareIllegalOperationError || status == OSStatus(bitPattern: 0x6E6F7065) /* 'nope' */ {
            return CaptureError.permissionDenied(.system)
        }
        return error
    }
}
