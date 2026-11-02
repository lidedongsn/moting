import MotingASR
import MotingCapture
import SwiftUI

/// 登记声纹：朗读一段文字约 10 秒，提取声纹保存
struct VoiceprintEnrollView: View {
    let env: AppEnvironment
    let onDone: () -> Void

    private enum Phase: Equatable {
        case ready, recording(Double), processing, done, failed(String)
    }

    @State private var phase: Phase = .ready
    @State private var level: Float = 0
    @State private var mic: MicSource?
    /// 录音计时与提取：取消时一并取消，不能拿录了一半的声音覆盖已有声纹
    @State private var work: Task<Void, Never>?

    private static let script = "今天的会议主要讨论三件事：第一是新版本的上线时间，第二是测试环境的搭建，第三是接口文档的评审。请大家会后把各自的待办整理一下，周五之前同步给我。"
    private static let duration: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("登记我的声纹").font(.title2.weight(.semibold))
            Text("点「开始」后，用平时开会的音量和距离朗读下面这段话，约 10 秒。")
                .foregroundStyle(.secondary)
            Text(Self.script)
                .font(.title3)
                .lineSpacing(6)
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            switch phase {
            case .ready:
                EmptyView()
            case .recording(let p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p)
                    HStack {
                        Text("正在录音… \(Int(Self.duration * (1 - p))) 秒")
                        Spacer()
                        Text("音量").foregroundStyle(.secondary)
                        ProgressView(value: Double(min(1, (level * 50).squareRoot() / 3))).frame(width: 100)
                    }
                    .font(.callout)
                }
            case .processing:
                HStack { ProgressView().controlSize(.small); Text("正在提取声纹…（首次需要下载约 27MB 的声纹模型）") }
            case .done:
                Label("声纹已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(phase == .done ? "完成" : "取消") {
                    work?.cancel()
                    mic?.stop()
                    onDone()
                }
                if phase == .ready || isFailed {
                    Button("开始") { start() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func start() {
        let buffer = SampleBuffer()
        let source = MicSource()
        mic = source
        phase = .recording(0)
        do {
            try source.start { event in
                if case .chunk(let c) = event {
                    buffer.append(c.samples)
                    Task { @MainActor in level = c.level }
                }
            }
        } catch {
            phase = .failed("无法打开麦克风：\(error.localizedDescription)")
            return
        }
        work = Task { @MainActor in
            let t0 = Date()
            while Date().timeIntervalSince(t0) < Self.duration {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { source.stop(); mic = nil; return }
                phase = .recording(min(1, Date().timeIntervalSince(t0) / Self.duration))
            }
            source.stop()
            mic = nil
            phase = .processing
            await finish(buffer.samples)
        }
    }

    private func finish(_ samples: [Float]) async {
        let store = env.modelStore, url = env.paths.voiceprintURL
        let result: Result<[Float], Error> = await Task.detached {
            do {
                if !store.isInstalled(OfflineCatalog.embedding) {
                    try await store.install(OfflineCatalog.embedding) { _ in }
                }
                let m = try VoiceprintMatcher(embeddingModel: OfflineCatalog.embedding,
                                              directory: store.directory(for: OfflineCatalog.embedding))
                let e = try m.embedding(samples)
                guard !e.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return .success(e)
            } catch {
                return .failure(error)
            }
        }.value
        // 提取期间点了取消：不保存，保留原来的声纹
        guard !Task.isCancelled else { return }
        do {
            try VoiceprintMatcher.save(try result.get(), to: url)
            phase = .done
        } catch {
            phase = .failed("提取声纹失败：\(error.localizedDescription)")
        }
    }
}

/// 麦克风回调线程与主线程共享的采样缓存
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [Float] = []
    func append(_ s: [Float]) { lock.withLock { data += s } }
    var samples: [Float] { lock.withLock { data } }
}
