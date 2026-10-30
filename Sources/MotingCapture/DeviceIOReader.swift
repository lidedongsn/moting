import CoreAudio
import Foundation

/// 对一个设备开 IOProc，把输入降混成单声道写入环形缓冲。
/// 只读取设备属性，不修改采样率和缓冲大小。
final class DeviceIOReader {
    let deviceID: AudioObjectID
    let inputSampleRate: Double
    private let ring: SPSCRingBuffer
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int
    private var procID: AudioDeviceIOProcID?

    init(deviceID: AudioObjectID, ring: SPSCRingBuffer) throws {
        self.deviceID = deviceID
        self.ring = ring
        inputSampleRate = try CA.nominalSampleRate(deviceID)
        guard inputSampleRate > 0, try CA.inputChannelCount(deviceID) > 0 else {
            throw CaptureError.deviceUnavailable("设备 \(deviceID) 没有输入声道")
        }
        // 预分配降混缓冲，实时线程里不再分配
        scratchCapacity = max(Int((try? CA.bufferFrameSize(deviceID)) ?? 0) * 4, 16_384)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func start() throws {
        guard procID == nil else { return }
        // 实时线程内只用到这几个裸指针，避免引用计数操作
        let scratch = self.scratch
        let capacity = scratchCapacity
        let ring = Unmanaged.passUnretained(self.ring)
        var id: AudioDeviceIOProcID?
        try CA.check(AudioDeviceCreateIOProcIDWithBlock(&id, deviceID, nil) { _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var frames = 0
            var totalChannels = 0
            for buf in list where buf.mData != nil && buf.mNumberChannels > 0 {
                let ch = Int(buf.mNumberChannels)
                let n = min(Int(buf.mDataByteSize) / (4 * ch), capacity)
                let src = buf.mData!.assumingMemoryBound(to: Float.self)
                if totalChannels == 0 {
                    frames = n
                    for i in 0..<n { scratch[i] = 0 }
                }
                let m = min(n, frames)
                for i in 0..<m {
                    var sum: Float = 0
                    for c in 0..<ch { sum += src[i * ch + c] }
                    scratch[i] += sum
                }
                totalChannels += ch
            }
            guard frames > 0, totalChannels > 0 else { return }
            let scale = 1 / Float(totalChannels)
            for i in 0..<frames { scratch[i] *= scale }
            ring.takeUnretainedValue().write(scratch, count: frames)
        }, "create IOProc")
        procID = id
        let status = AudioDeviceStart(deviceID, id)
        if status != noErr {
            AudioDeviceDestroyIOProcID(deviceID, id!)
            procID = nil
            throw CaptureError.coreAudio(status, "AudioDeviceStart")
        }
    }

    func stop() {
        guard let id = procID else { return }
        AudioDeviceStop(deviceID, id)
        AudioDeviceDestroyIOProcID(deviceID, id)
        procID = nil
    }
}
