import CoreAudio
import Foundation

/// Core Audio 属性读取的薄封装。只读，不写任何设备属性（零干扰原则）
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(status, what) }
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get \(selector)")
        return value
    }

    static func defaultInputDevice() throws -> AudioObjectID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    static func bufferFrameSize(_ device: AudioObjectID) throws -> UInt32 {
        try get(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
    }

    static func deviceUID(_ device: AudioObjectID) throws -> String {
        let uid: CFString = try get(device, kAudioDevicePropertyDeviceUID, initial: "" as CFString)
        return uid as String
    }

    static func device(forUID uid: String) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &device)
        }
        try check(status, "translate UID")
        guard device != kAudioObjectUnknown else { throw CaptureError.deviceUnavailable(uid) }
        return device
    }

    static func inputChannelCount(_ device: AudioObjectID) throws -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "stream config size")
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "stream config")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 所有属性监听都在这个专用队列上接收，再异步转发到调用方的队列。
    /// 这样调用方在自己的队列上注销监听时，不会与 HAL 投递回调互相等待
    private static let listenerQueue = DispatchQueue(label: "moting.coreaudio.listeners")

    /// 注册属性监听，block 在 queue 上异步执行；返回用于注销的闭包
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue,
                       _ block: @escaping () -> Void) -> () -> Void {
        var addr = address(selector)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in queue.async(execute: block) }
        AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, listener)
        return {
            var addr = address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &addr, listenerQueue, listener)
        }
    }
}
