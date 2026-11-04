import Foundation
import MotingASR
import MotingCore
import MotingStorage

/// 跨线程传递识别器（加载后只读）
final class RecognizerBox: @unchecked Sendable {
    let modelID: String
    let recognizer: SherpaRecognizer
    init(modelID: String, recognizer: SherpaRecognizer) {
        self.modelID = modelID
        self.recognizer = recognizer
    }
}

/// 录音会话的音频回调线程与主线程之间共享当前转写器
final class TranscriberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: LiveTranscriber?
    var value: LiveTranscriber? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// 实时字幕：模型状态、识别器复用、悬浮窗显示的最近几行
@MainActor
final class LiveTranscriptModel: ObservableObject {
    enum ModelState: Equatable {
        case missing
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var lines: [SubtitleLine] = []
    #if DEBUG
    func showDemoLines(_ demo: [SubtitleLine]) {
        lines = demo
        modelState = .ready
    }
    #endif
    @Published private(set) var modelState: ModelState = .missing
    @Published private(set) var downloads: [String: Double] = [:]   // 设置页：各模型下载进度
    @Published var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Self.selectedKey)
            recognizer = nil
            refreshState()
            preload()
        }
    }
    /// 正在录音、但还没接上转写器（模型尚未就绪）：界面据此显示"字幕稍后开始"而不是"等待说话"
    @Published private(set) var waitingToAttach = false

    /// 录音会话写入音频后，经由它喂给当前转写器
    let feeder = TranscriberBox()

    private let env: AppEnvironment?
    private var recognizer: RecognizerBox?
    private var buffer = SubtitleBuffer()
    /// 当前正在录音的会议；模型晚于录音就绪时据此补接转写器（startSample 是绝对位置，时间戳仍正确）
    private var activeMeetingID: UUID?
    private static let selectedKey = "asr.selectedModel"

    init(env: AppEnvironment?) {
        self.env = env
        selectedModelID = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ModelCatalog.default.id
        refreshState()
        preload()
    }

    var selectedModel: StreamingModel {
        ModelCatalog.model(id: selectedModelID) ?? ModelCatalog.default
    }

    func isInstalled(_ m: StreamingModel) -> Bool {
        env?.modelStore.isInstalled(m) ?? false
    }

    func diskUsage(_ m: StreamingModel) -> Int64 {
        env?.modelStore.diskUsage(m) ?? 0
    }

    // MARK: - 录音生命周期

    /// 开始录音后调用：模型就绪则为本场会议建草稿版本并开始转写；
    /// 否则先只录音，模型就绪（加载完或下载完）后再补接
    func begin(meetingID: UUID) {
        buffer = SubtitleBuffer()
        lines = []
        activeMeetingID = meetingID
        attachIfPossible()
        if feeder.value == nil {
            waitingToAttach = true
            if modelState != .ready { preload() }
        }
    }

    private func attachIfPossible() {
        guard let env, let meetingID = activeMeetingID, feeder.value == nil,
              let box = recognizer, box.modelID == selectedModelID else { return }
        do {
            let versionID = try env.transcripts.createVersion(
                meetingID: meetingID, kind: .draft, engine: "sherpa-onnx \(sherpaOnnxVersion())",
                model: box.modelID, createdAt: Date())
            let transcripts = env.transcripts
            feeder.value = LiveTranscriber(recognizer: box.recognizer, versionID: versionID) { [weak self] event in
                if case .final(_, let segment) = event { try? transcripts.append(segment) }
                Task { @MainActor in self?.apply(event) }
            }
            waitingToAttach = false
        } catch {
            modelState = .failed(L("创建转写记录失败：\(error.localizedDescription)"))
        }
    }

    /// 结束录音时调用：把未定稿的字幕定稿并落库
    func end() {
        feeder.value?.finish()
        feeder.value = nil
        activeMeetingID = nil
        waitingToAttach = false
    }

    /// app 退出时用：等最后一句落库后再返回
    func endAndWait() {
        feeder.value?.finishAndWait()
        feeder.value = nil
        activeMeetingID = nil
    }

    // MARK: - 模型

    func install(_ m: StreamingModel) {
        guard let env, downloads[m.id] == nil else { return }
        downloads[m.id] = 0
        if m.id == selectedModelID { modelState = .downloading(0) }
        let store = env.modelStore
        Task.detached {
            do {
                try await store.install(m) { p in
                    Task { @MainActor [weak self] in
                        self?.downloads[m.id] = p
                        if m.id == self?.selectedModelID { self?.modelState = .downloading(p) }
                    }
                }
                await MainActor.run { [weak self] in
                    self?.downloads[m.id] = nil
                    self?.refreshState()
                    self?.preload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.downloads[m.id] = nil
                    if m.id == self?.selectedModelID { self?.modelState = .failed(L("模型下载失败：\(error.localizedDescription)")) }
                }
            }
        }
    }

    func installSelected() {
        install(selectedModel)
    }

    func remove(_ m: StreamingModel) {
        guard let env else { return }
        if recognizer?.modelID == m.id { recognizer = nil }
        try? env.modelStore.remove(m)
        refreshState()
        objectWillChange.send()
    }

    // MARK: - 内部

    private func refreshState() {
        guard downloads[selectedModelID] == nil else { return }
        if !isInstalled(selectedModel) {
            modelState = .missing
        } else if recognizer?.modelID == selectedModelID {
            modelState = .ready
        } else if modelState != .loading {
            modelState = .loading
        }
    }

    /// 后台加载识别器（约 1 秒），之后的录音一直复用
    private func preload() {
        guard let env, isInstalled(selectedModel), recognizer?.modelID != selectedModelID else { return }
        let m = selectedModel
        let dir = env.modelStore.directory(for: m)
        modelState = .loading
        Task.detached {
            do {
                let box = RecognizerBox(modelID: m.id, recognizer: try SherpaRecognizer(model: m, directory: dir))
                await MainActor.run { [weak self] in
                    guard let self, m.id == self.selectedModelID else { return }
                    self.recognizer = box
                    self.modelState = .ready
                    self.attachIfPossible()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.modelState = .failed(L("加载识别模型失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    private func apply(_ event: TranscriptEvent) {
        buffer.apply(event)
        lines = buffer.lines
    }
}
