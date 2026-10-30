import AVFoundation

public enum ResamplerError: Error {
    case cannotCreateConverter(Double)
    case conversionFailed(String)
}

/// 单声道 Float32 → 16kHz 单声道 Float32 的流式重采样，内部保持滤波器状态
public final class Resampler {
    public static let targetRate: Double = 16_000

    private let inputRate: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    public init(inputSampleRate: Double) throws {
        inputRate = inputSampleRate
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false)!
        if inputSampleRate == Self.targetRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw ResamplerError.cannotCreateConverter(inputSampleRate)
            }
            c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = c
        }
    }

    public func process(_ input: [Float]) throws -> [Float] {
        guard let converter else { return input }
        guard !input.isEmpty else { return [] }
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count))!
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: input.count) }
        var fed = false
        return try drain(converter) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
    }

    /// 输入结束时调用，取出滤波器里剩余的采样
    public func flush() throws -> [Float] {
        guard let converter else { return [] }
        let out = try drain(converter) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        return out
    }

    private func drain(_ converter: AVAudioConverter, input: @escaping AVAudioConverterInputBlock) throws -> [Float] {
        var result: [Float] = []
        let cap: AVAudioFrameCount = 4096
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap)!
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error, withInputFrom: input)
            if status == .error { throw ResamplerError.conversionFailed(error?.localizedDescription ?? "unknown") }
            let n = Int(outBuf.frameLength)
            if n > 0 { result.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)) }
            if status != .haveData || n < Int(cap) { break }
        }
        return result
    }
}
