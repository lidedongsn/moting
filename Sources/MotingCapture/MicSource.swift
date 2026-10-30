import AVFoundation
import CoreAudio
import MotingCore

/// 麦克风源。deviceUID 为 nil 时跟随系统默认输入，默认设备变化时自动切换
public final class MicSource: AudioSource {
    public let channel: AudioChannel = .mic
    private let deviceUID: String?
    private let pump = ChunkPump(label: "moting.capture.mic")
    private var reader: DeviceIOReader?
    private var unlisteners: [() -> Void] = []

    public init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
    }

    public func start(handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        try Self.ensurePermission()
        try pump.queue.sync {
            let r = try makeReader()
            try pump.start(inputSampleRate: r.inputSampleRate, handler: handler)
            try r.start()
            reader = r
            watch(r.deviceID)
            if deviceUID == nil {
                unlisteners.append(CA.listen(AudioObjectID(kAudioObjectSystemObject),
                                             kAudioHardwarePropertyDefaultInputDevice, queue: pump.queue) { [weak self] in
                    self?.switchDevice(reason: "默认输入设备已变化")
                })
            }
        }
    }

    public func stop() {
        pump.queue.sync {
            unlisteners.forEach { $0() }
            unlisteners.removeAll()
            reader?.stop()
            reader = nil
            pump.stop()
        }
    }

    private func makeReader() throws -> DeviceIOReader {
        let id = try deviceUID.map(CA.device(forUID:)) ?? CA.defaultInputDevice()
        guard id != kAudioObjectUnknown else { throw CaptureError.deviceUnavailable("没有可用的输入设备") }
        return try DeviceIOReader(deviceID: id, ring: pump.ring)
    }

    /// 监听当前设备的采样率变化
    private func watch(_ device: AudioObjectID) {
        unlisteners.append(CA.listen(device, kAudioDevicePropertyNominalSampleRate, queue: pump.queue) { [weak self] in
            guard let self, let r = self.reader, let rate = try? CA.nominalSampleRate(r.deviceID) else { return }
            try? self.pump.reconfigure(inputSampleRate: rate)
        })
    }

    /// 在 pump.queue 上执行：停掉旧设备，接上新设备
    private func switchDevice(reason: String) {
        reader?.stop()
        reader = nil
        pump.send(.interrupted(reason))
        guard let r = try? makeReader() else { return }   // 暂无设备，等下次变化通知
        do {
            try pump.reconfigure(inputSampleRate: r.inputSampleRate)
            try r.start()
            reader = r
            watch(r.deviceID)
            pump.send(.resumed)
        } catch {
            pump.send(.interrupted("新设备启动失败：\(error)"))
        }
    }

    static func ensurePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sem.signal()
            }
            sem.wait()
            if !granted { throw CaptureError.permissionDenied(.mic) }
        default:
            throw CaptureError.permissionDenied(.mic)
        }
    }
}
