import CSpeexDSP

/// 麦克风一路的回声消除：外放时扬声器里的对方声音会被麦克风再录进去，
/// 用同一时刻的系统音频作参考，从麦克风数据里减掉（SpeexDSP MDF 自适应滤波），
/// 再做一层残余回声抑制：笔记本扬声器有失真，线性滤波实测只能压低约 17dB，剩下的仍会被识别成字。
/// 每 10ms 看"被滤波器认作回声的部分"和"剩下的部分"：对方在放、且剩下的远小于回声（只剩残余），就把这一帧静音；
/// 自己也在说话时，自己的声音无法被解释成回声，剩下的不会小，照常放行。
/// 不用 Speex 自带的残余回声抑制：实测双讲时会把自己的声音一起压掉。
/// 只处理送给实时识别的那份数据，录音文件不动；不调用系统 voice processing，不影响其他 app。
///
/// 两路按轨道采样位置对齐，但对齐有误差，回声也可能比参考早几十毫秒出现在麦克风里。
/// 所以把参考提前 lookahead 配对：麦克风位置 p 的帧配参考 p + lookahead 的帧，
/// 能消掉"比参考早 lookahead 到晚 (tail − lookahead)"之间到达的回声。
/// 代价是麦克风字幕晚 lookahead 出来。不是线程安全的，调用方串行使用。
public final class MicEchoFilter {
    public static let sampleRate = 16_000
    /// 每帧 10ms
    public static let frame = 160

    private let lookahead: Int
    private let maxWait: Int
    private let echo: OpaquePointer

    private var micPending: [Float] = []
    private var micStart = 0              // micPending[0] 的轨道位置
    private var started = false
    private var ref: [Float] = []
    private var refStart = 0              // ref[0] 的轨道位置
    private var refSeen = false           // 系统音频一路来过数据

    // 残余回声抑制
    /// 认作回声的能量比剩下的大这么多倍（3dB）时，剩下的判为残余回声
    private static let echoDominance: Float = 2
    /// 参考低于这个能量（约 -60dBFS）视为对方没在放
    private static let refActive: Float = 1e-6
    /// 残余回声帧的增益（约 -40dB）
    private static let floorGain: Float = 0.01
    /// 判为残余后多保持几帧，盖住回声拖尾
    private static let holdFrames = 8
    private var cancelledAvg: Float = 0
    private var residualAvg: Float = 0
    private var hold = 0
    private var gain: Float = 1

    /// lookahead：参考提前量；tail：回声最长持续；maxWait：参考迟迟不来时最多等多久就当静音处理
    public init(lookahead: Int = 1_600, tail: Int = 6_400, maxWait: Int = 8_000) {
        self.lookahead = lookahead
        self.maxWait = maxWait
        echo = speex_echo_state_init(Int32(Self.frame), Int32(tail))
        var rate = Int32(Self.sampleRate)
        speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit {
        speex_echo_state_destroy(echo)
    }

    /// 系统音频一路（参考）
    public func reference(_ samples: [Float], start: Int) {
        refSeen = true
        if ref.isEmpty {
            refStart = start
        } else {
            let end = refStart + ref.count
            if start > end {
                ref += [Float](repeating: 0, count: start - end)   // 中间缺的当静音
            } else if start < end {
                let overlap = end - start
                guard overlap < samples.count else { return }
                ref += samples[overlap...]
                return
            }
        }
        ref += samples
    }

    /// 麦克风一路；返回已处理好的一段（位置连续），参考还没到时可能返回 nil
    public func mic(_ samples: [Float], start: Int) -> (samples: [Float], start: Int)? {
        // 系统音频一路还没数据：没有可消的回声，原样立即输出，不等
        if !refSeen {
            started = true
            micStart = start + samples.count
            return samples.isEmpty ? nil : (samples, start)
        }
        if !started {
            started = true
            micStart = start
        } else {
            let end = micStart + micPending.count
            if start > end { micPending += [Float](repeating: 0, count: start - end) }
        }
        micPending += samples
        return drain(force: false)
    }

    /// 结束时取出剩下的（参考不够的部分当静音）
    public func flush() -> (samples: [Float], start: Int)? {
        let r = drain(force: true)
        micPending = []
        return r
    }

    private func drain(force: Bool) -> (samples: [Float], start: Int)? {
        let outStart = micStart
        var out: [Float] = []
        var micFrame = [Int16](repeating: 0, count: Self.frame)
        var refFrame = [Int16](repeating: 0, count: Self.frame)
        var clean = [Int16](repeating: 0, count: Self.frame)
        while micPending.count >= Self.frame || (force && !micPending.isEmpty) {
            let need = micStart + lookahead + Self.frame
            let refEnd = refStart + ref.count
            let micEnd = micStart + micPending.count
            // 参考还没到：除非已经等太久或在收尾，否则先等着
            if refEnd < need && !force && micEnd - refEnd < maxWait { break }
            let n = min(Self.frame, micPending.count)
            for i in 0..<Self.frame {
                micFrame[i] = i < n ? Self.toInt16(micPending[i]) : 0
                let r = micStart + lookahead + i - refStart
                refFrame[i] = r >= 0 && r < ref.count ? Self.toInt16(ref[r]) : 0
            }
            speex_echo_cancellation(echo, micFrame, refFrame, &clean)
            suppressResidual(mic: micFrame, ref: refFrame, clean: clean, count: n, into: &out)
            micPending.removeFirst(n)
            micStart += n
        }
        // 丢掉用不到的旧参考
        let keepFrom = micStart + lookahead - refStart
        if keepFrom > 0 {
            let k = min(keepFrom, ref.count)
            ref.removeFirst(k)
            refStart += k
        }
        return out.isEmpty ? nil : (out, outStart)
    }

    /// 残余回声抑制：按帧算增益，帧内线性过渡避免咔哒声
    private func suppressResidual(mic: [Int16], ref: [Int16], clean: [Int16], count n: Int, into out: inout [Float]) {
        var refE: Float = 0, cancelledE: Float = 0, residualE: Float = 0
        for i in 0..<Self.frame {
            let m = Float(mic[i]) / 32_768, c = Float(clean[i]) / 32_768, r = Float(ref[i]) / 32_768
            refE += r * r
            cancelledE += (m - c) * (m - c)
            residualE += c * c
        }
        let k = Float(Self.frame)
        // 平滑一点，避免逐帧抖动
        cancelledAvg = 0.6 * cancelledAvg + 0.4 * cancelledE / k
        residualAvg = 0.6 * residualAvg + 0.4 * residualE / k
        if refE / k > Self.refActive && cancelledAvg > Self.echoDominance * residualAvg {
            hold = Self.holdFrames
        } else if hold > 0 {
            hold -= 1
        }
        let target: Float = hold > 0 ? Self.floorGain : 1
        // 压得快（一帧到位）、放得也快（两帧回到 1），不吞自己说话的开头
        let next = target < gain ? target : min(1, gain + 0.5)
        for i in 0..<n {
            let g = gain + (next - gain) * Float(i + 1) / Float(n)
            out.append(Float(clean[i]) / 32_768 * g)
        }
        gain = next
    }

    private static func toInt16(_ x: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (x * 32_768).rounded())))
    }
}
