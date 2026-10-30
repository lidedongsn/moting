# Moting P3：会后精准转写 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 录音结束后，在本机用离线大模型对两路完整录音重新转写，并依次完成以下处理，生成"正式稿"替换实时字幕草稿：
- 热词
- 标点
- "对方"多说话人分离
- "我"一路的声纹过滤（去掉旁边无关的人声）

**Architecture:**
- `MotingASR` 新增几个组件：
  - 离线识别 `OfflineRecognizer`
  - 人声分段 `VoiceSegmenter`（Silero VAD）
  - 标点 `Punctuator`
  - 说话人分离 `Diarizer`
  - 声纹 `VoiceprintMatcher`
- 新增 `MotingPipeline` target：持久化任务队列 + 会后处理各步骤
- 模型下载新增"GitHub 压缩包"来源
- 正式稿写入 `TranscriptKind.final` 版本；说话人显示名单独存表，供改名使用

**Tech Stack:**
- sherpa-onnx 1.13.8 C API：offline recognizer / VAD / speaker diarization / speaker embedding / offline punctuation
- GRDB 迁移 v3
- IOKit（电源状态）
- UserNotifications

**Spec:** `docs/superpowers/specs/2026-10-30-moting-design.md`（5.4、5.6 说话人改名、5.8 热词、5.9；第 8 节第 1 条）

**这一阶段做完，用户能看到 / 还看不到：**
- **能看到**：
  - 点"结束录音"后，悬浮窗显示"正在精准转写… N%"，可以关掉，转写在后台继续，完成后弹系统通知
  - 详情页的转写稿自动换成正式稿，可以和实时草稿切换对比；有"重新转写"按钮
  - "对方"一路分成"说话人 1/2/3"，可以改成真名
  - 设置里新增三项：热词表、"登记我的声纹"、离线模型管理
  - 用电池时会提示"插电后自动处理 / 现在处理"
- **还看不到**：AI 纪要（P4）、回声消除（P5）。

## Global Constraints

- **离线与内存**：识别、分离、声纹全部在本机完成。同一时间只加载一个大模型，用完立即释放（spec 5.4）。
- **准确率优先**（spec 5.4）：只要满足以下两条，就用基准测试里最准的引擎作为默认：
  - 1 小时会议处理不超过 60 分钟（M2 Air 插电）
  - 内存峰值不超过 8GB
- **原始录音永不修改**。正式稿是新版本，草稿保留；每次"重新转写"都生成新的 final 版本。
- **声纹过滤**（spec 5.4 补充需求）：麦克风一路只保留与用户声纹匹配的片段，其余直接丢弃，不标注、不进纪要。用户没有登记声纹时不过滤，并在详情页提示可以登记。
- **电源策略**（spec 5.4）：插电时会后立即开始；用电池时默认等插电，用户可以点"现在处理"。
- **数据可见、可清理**（用户偏好）：
  - 新增文件放在 `~/Library/Application Support/Moting/`：模型放 `models/`；声纹放 `voiceprint/me.f32`；热词放 `hotwords.txt`
  - 以上三项都要在设置里显示位置，并能删除
  - 测试不得遗留文件
- **线程隔离**（P2 踩过的坑）：交给 AVFoundation / Core Audio / UserNotifications / NotificationCenter 等框架、会在后台线程回调的闭包，必须显式标为 `@Sendable`，在闭包内部再切回主线程。
- **提交规范**：提交信息用中文，末尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。只提交到本地，不推送。

## Review Focus

1. **app 在处理中途退出或崩溃**：重启后从最近完成的步骤继续，不从头开始；不留下"处理中"却没人处理的会议。→ Task 2 `resumesFromLastCompletedStep`、`staleRunningJobIsRequeued`
2. **处理中开始新的录音**：录音优先。会后任务暂停让出 CPU 和内存，录音结束后继续，正在录的会议不能被处理。→ Task 2 `pausesWhileRecording`
3. **某一路完全没声音**（对方没人说话 / 麦克风静音）：该路不产生空片段，分离步骤不报错，整体仍能完成。→ Task 4 `silentTrackYieldsNoSegments`、Task 6 `diarizationOnSilenceIsEmpty`
4. **没登记声纹，或声纹和本人匹配度低**（感冒、换了麦克风）：不能把用户自己的话全部丢掉。阈值保守，过滤后麦克风一路剩余时长低于原来的 30% 时，放弃过滤并在详情页提示。→ Task 7 `fallsBackWhenFilterRemovesMost`
5. **处理很长的会议（2 小时）**：内存不能随时长线性增长。按 VAD 片段逐段识别、逐段落库，不把整段音频的 Float 数组同时保留在多个步骤里。→ Task 4 `processesInBoundedChunks`

---

### Task 0：模型目录扩展（离线模型与辅助模型，含 GitHub 压缩包来源）

**Files:**
- Modify: `Sources/MotingASR/ModelCatalog.swift`、`Sources/MotingASR/ModelStore.swift`
- Test: `Tests/MotingASRTests/ModelStoreTests.swift`

**Interfaces:**
- Produces：

  ```swift
  public enum ModelSource: Sendable, Equatable {
      case huggingFace(repo: String)                                       // 逐文件下载（已有）
      case githubArchive(url: URL, sha256: String, size: Int64, stripPrefix: String)  // 下载 tar.bz2，校验整包，只解出 files
  }
  /// 下载与安装只依赖这个协议；StreamingModel 改为遵守它（repo → source）
  public protocol DownloadableModel: Sendable {
      var id: String { get }
      var displayName: String { get }
      var source: ModelSource { get }
      var files: [ModelFile] { get }      // githubArchive 时只校验大小（整包已校验 sha）
      var totalSize: Int64 { get }
  }
  public enum OfflineModelKind: String, Sendable { case senseVoice, paraformer, transducer, qwen3ASR, fireRedASR }
  public struct OfflineModel: DownloadableModel, Identifiable, Equatable {
      public var kind: OfflineModelKind
      public var roles: [String: String]
      public var hasPunctuation: Bool      // 自带标点则跳过标点模型
      public var supportsHotwords: Bool
      // id / displayName / source / files 同上
  }
  public struct AuxModel: DownloadableModel, Identifiable, Equatable {}   // VAD、分离分段、声纹、标点
  public enum OfflineCatalog {
      public static let senseVoice: OfflineModel     // HF csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09
      public static let paraformerZh: OfflineModel   // HF csukuangfj/sherpa-onnx-paraformer-zh-int8-2025-10-07
      public static let xasrTransducer: OfflineModel // GitHub asr-models/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03
      public static let qwen3ASR: OfflineModel       // GitHub asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25
      public static let fireRedASR2: OfflineModel   // GitHub asr-models/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26
      public static let all: [OfflineModel]
      public static var `default`: OfflineModel { get }   // Task 9 后由用户选定，先设为 senseVoice
      public static let vad: AuxModel             // silero_vad.onnx（asr-models 发布页）
      public static let segmentation: AuxModel    // HF csukuangfj/sherpa-onnx-pyannote-segmentation-3-0（model.int8.onnx）
      public static let embedding: AuxModel       // speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx
      public static let punctuation: AuxModel     // punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8
  }
  // ModelStore.install / isInstalled / remove / diskUsage 改为接受 any DownloadableModel
  ```

  **执行时补全目录数据**：各文件的 sha256 / size、GitHub 资源的整包 sha256，用 `gh release view <tag> -R k2-fsa/sherpa-onnx --json assets` 获取，取 `digest` 字段；没有该字段就下载后用 `shasum -a 256` 计算。还需要确认各压缩包内的文件名，填进 `roles`。

  **解压方式**：用 `/usr/bin/tar -xjf <包> -C <临时目录> <stripPrefix>/<file>...`，只解出需要的文件，再移到模型目录；临时目录和压缩包解压完就删除。

- [ ] **Step 1：写失败测试**（`file://` 本地压缩包，测试前用 `tar -cjf` 现做一个）

  ```swift
  @Test func installsFromArchiveExtractingOnlyListedFiles()   // 包里 3 个文件、只列 2 个 → 目录里只有这 2 个，isInstalled
  @Test func archiveChecksumMismatchLeavesNothing()           // sha 错 → 抛 checksumMismatch，模型目录不存在或为空
  @Test func streamingModelsStillInstall()                    // 原有 HF 用例改用 DownloadableModel 后仍通过（不改原测试断言）
  @Test func offlineCatalogIsComplete()                       // 每个 OfflineModel 的 roles 都在 files 中；default 在 all 中
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**，并跑全量 `swift test`
- [ ] **Step 3：提交** `feat(asr): 离线与辅助模型目录，支持 GitHub 压缩包来源`

---

### Task 1：存储迁移 v3（任务队列、说话人名）

**Files:**
- Modify: `Sources/MotingStorage/AppDatabase.swift`
- Create: `Sources/MotingStorage/JobRepository.swift`、`Sources/MotingStorage/SpeakerRepository.swift`、`Sources/MotingCore/Job.swift`
- Test: `Tests/MotingStorageTests/JobRepositoryTests.swift`、`Tests/MotingStorageTests/SpeakerRepositoryTests.swift`

**Interfaces:**
- Produces：

  ```swift
  // MotingCore
  public enum JobStep: String, Codable, Sendable, CaseIterable {   // 顺序即执行顺序
      case transcribe, diarize, filterVoice, merge
  }
  public enum JobStatus: String, Codable, Sendable { case queued, waitingForPower, running, done, failed }
  public struct Job: Identifiable, Sendable, Equatable {
      public var id: UUID; public var meetingID: UUID
      public var status: JobStatus
      public var completedSteps: [JobStep]
      public var progress: Double               // 0–1，整体
      public var error: String?
      public var modelID: String                // 本次使用的离线模型
      public var createdAt: Date
  }
  // MotingStorage
  public final class JobRepository: Sendable {
      public func enqueue(meetingID: UUID, modelID: String, at: Date) throws -> Job   // 同一会议已有未完成任务时返回那个
      public func next() throws -> Job?                         // 最早的 queued（不含 waitingForPower）
      public func update(_ job: Job) throws
      public func job(for meetingID: UUID) throws -> Job?       // 最新一个
      public func requeueStaleRunning() throws -> Int           // 启动时把 running 改回 queued
      public func observe(meetingID: UUID) -> AsyncValueObservation<Job?>
  }
  public final class SpeakerRepository: Sendable {
      public func setName(meetingID: UUID, label: String, name: String) throws   // 空名 = 恢复默认
      public func names(meetingID: UUID) throws -> [String: String]              // label → 显示名
  }
  ```

  迁移 `v3`：
  - `job` 表：`id`、`meetingId`（级联删除）、`status`、`completedSteps`（JSON 文本）、`progress`、`error`、`modelId`、`createdAt`
  - `speaker` 表：`meetingId`（级联删除）、`label`、`displayName`，主键为 (`meetingId`, `label`)

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func enqueueIsIdempotentPerMeeting()
  @Test func nextSkipsWaitingForPowerAndDone()
  @Test func staleRunningJobIsRequeued()          // running → requeueStaleRunning → queued，completedSteps 保留
  @Test func completedStepsRoundTrip()
  @Test func speakerNamesRoundTripAndBlankResets()
  @Test func deletingMeetingCascadesJobsAndSpeakers()
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(storage): 会后任务队列与说话人显示名（迁移 v3）`

---

### Task 2：任务调度器

**Files:**
- Create: `Sources/MotingPipeline/PipelineRunner.swift`、`Sources/MotingPipeline/PowerMonitor.swift`
- Modify: `Package.swift`（新增 target `MotingPipeline`，依赖 Core / Storage / ASR / Capture；加入产品）
- Test: `Tests/MotingPipelineTests/PipelineRunnerTests.swift`

**Interfaces:**
- Produces：

  ```swift
  /// 一个步骤的执行者，便于用假实现测试调度
  public protocol PipelineStepRunner: Sendable {
      func run(_ step: JobStep, job: Job, progress: @escaping @Sendable (Double) -> Void) async throws
  }
  public protocol PowerSource: Sendable { var isOnAC: Bool { get } }
  public struct SystemPowerSource: PowerSource {}             // IOPSCopyPowerSourcesInfo
  public final class PipelineRunner: @unchecked Sendable {
      public init(jobs: JobRepository, meetings: MeetingRepository, steps: PipelineStepRunner,
                  power: PowerSource, isRecording: @escaping @Sendable () -> Bool)
      public func enqueue(meetingID: UUID, modelID: String) throws    // 用电池时置为 waitingForPower
      public func processNow(meetingID: UUID) throws                  // 用户点"现在处理"：waitingForPower → queued
      public func start()        // 启动时调用：requeueStaleRunning，然后开始消费
      public func wake()         // 录音结束、插电、入队时调用
      public var onJobFinished: (@Sendable (Job) -> Void)?            // 用于系统通知
  }
  ```

  调度规则：
  - **串行**：一次只跑一个任务；任务内的步骤按 `JobStep.allCases` 的顺序执行，跳过 `completedSteps` 里已完成的。
  - **每步结束后**：把这一步追加进 `completedSteps` 并落库；整体进度 = (已完成步数 + 当前步进度) / 步数。
  - **会议状态**：开始时设为 `.processing`；成功设为 `.done`，失败设为 `.failed` 并记录 `error`。
  - **录音优先**：`isRecording()` 为真时，在步骤之间等待（每 2 秒检查一次），不开始新步骤。
  - **电源**：用电池时，新入队的任务进入 `waitingForPower`；监听到插电（`IOPSNotificationCreateRunLoopSource`）后转为 `queued`，并调用 `wake()`。

- [ ] **Step 1：写失败测试**（假的 `StepRunner` 会记录调用顺序，并且可以设定在某一步抛错；假电源、假录音状态都可以切换）

  ```swift
  @Test func runsStepsInOrderAndMarksDone()
  @Test func resumesFromLastCompletedStep()        // completedSteps = [transcribe] → 只跑后三步
  @Test func failureMarksMeetingFailedWithError()
  @Test func waitsForPowerOnBattery()              // 电池 → waitingForPower，不执行；processNow → 执行
  @Test func pausesWhileRecording()                // isRecording 为真时第二步不开始；置假后继续
  @Test func progressIsMonotonic()
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(pipeline): 持久化会后任务调度（串行、断点续跑、录音优先、电源策略）`

---

### Task 3：VAD 分段 + 离线识别 + 标点（封装）

**Files:**
- Create: `Sources/MotingASR/VoiceSegmenter.swift`、`Sources/MotingASR/OfflineRecognizer.swift`、`Sources/MotingASR/Punctuator.swift`
- Test: `Tests/MotingASRTests/OfflineRecognizerTests.swift`（集成部分受 `MOTING_ASR_IT=1` 控制）

**Interfaces:**
- Produces：

  ```swift
  public struct SpeechSpan: Sendable, Equatable { public var start: Int; public var samples: [Float] }   // start 为采样位置
  public final class VoiceSegmenter {
      public init(vadModel: URL, minSilence: TimeInterval = 0.5, maxSpan: TimeInterval = 20) throws
      /// 流式喂入整条轨道（分块读文件），每切出一段就回调；内存只占当前段
      public func segment(reader: (Int, Int) throws -> [Float], total: Int,
                          onSpan: (SpeechSpan) throws -> Void) throws
  }
  public protocol OfflineRecognizing: AnyObject {
      func recognize(_ samples: [Float]) throws -> String
  }
  public final class SherpaOfflineRecognizer: OfflineRecognizing {
      public init(model: OfflineModel, directory: URL, hotwords: [String], numThreads: Int = 4) throws
  }
  public final class Punctuator {
      public init(model: AuxModel, directory: URL) throws
      public func punctuate(_ text: String) -> String
  }
  ```

  热词的传法按模型区分：
  - `qwen3ASR`：用 `qwen3_asr.hotwords`（逗号分隔）
  - `transducer`：用 `hotwords_buf`，同时把 `decoding_method` 设为 `modified_beam_search`、`max_active_paths` 设为 4
  - 其余不支持热词的模型：忽略热词

- [ ] **Step 1：写测试**

  ```swift
  @Test func segmenterRequiresModel()                 // 模型文件不存在 → 抛错
  @Test(.enabled(if: ...MOTING_ASR_IT...)) func segmentsAndRecognizesTTS()
  // 用 say 合成两句中文，中间留 2 秒静音 → 切出 2 段；默认离线模型识别两段都非空；Punctuator 给无标点文本加上标点
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**（集成部分在装好模型后运行，模型由 Task 9 下载，可以先只装默认模型）
- [ ] **Step 3：提交** `feat(asr): 人声分段、离线识别与标点封装`

---

### Task 4：转写步骤

**Files:**
- Create: `Sources/MotingPipeline/TranscribeStep.swift`
- Test: `Tests/MotingPipelineTests/TranscribeStepTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `VoiceSegmenter`、`OfflineRecognizing`、`Punctuator`；P1 的 `PCMMixReader` / `PCMTrackReader`；Task 1；P2 的 `TranscriptRepository`
- Produces：

  ```swift
  public struct TranscribeStep {
      public init(paths: AppPaths, transcripts: TranscriptRepository,
                  makeRecognizer: () throws -> OfflineRecognizing, makeSegmenter: () throws -> VoiceSegmenter,
                  punctuator: (() throws -> Punctuator)?)
      /// 为会议新建一个 final 版本（engine "sherpa-onnx 1.13.8 offline"，model = job.modelID），
      /// 两路逐段识别、逐段 append；返回版本 id 写入 job（completedSteps 外另存：job.error 不用，新增列见下）
      public func run(meetingID: UUID, modelID: String, progress: (Double) -> Void) throws -> UUID
  }
  ```

  **执行时的取舍**：如果任务中途中断，重跑转写步骤时会把之前那个未完成的 final 版本删掉，重新建。为此 `TranscriptRepository` 要加上 `deleteVersion(_:)` 和 `pendingVersion` 两个能力。这一点要记进台账。

- [ ] **Step 1：写失败测试**（假识别器返回"第 N 段"；`VoiceSegmenter` 换成按固定间隔切分的测试实现，需要把 `VoiceSegmenter` 抽象成协议 `SpeechSegmenting`）

  ```swift
  @Test func writesFinalVersionWithMeetingTimes()   // 每段的 start / end = span 位置 / 16000，channel 正确
  @Test func silentTrackYieldsNoSegments()           // 全零的轨道 → 该路没有片段
  @Test func processesInBoundedChunks()              // 每次 reader 读的长度都 ≤ 30 秒采样（防止整段载入）
  @Test func rerunReplacesUnfinishedVersion()
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(pipeline): 会后离线转写步骤`

---

### Task 5：声纹登记与比对

**Files:**
- Create: `Sources/MotingASR/VoiceprintMatcher.swift`
- Test: `Tests/MotingASRTests/VoiceprintMatcherTests.swift`

**Interfaces:**
- Produces：

  ```swift
  public final class VoiceprintMatcher {
      public init(embeddingModel: AuxModel, directory: URL) throws
      public func embedding(_ samples: [Float]) throws -> [Float]        // 16k
      public static func cosine(_ a: [Float], _ b: [Float]) -> Float
      public static func save(_ e: [Float], to url: URL) throws          // 小端 Float32 裸文件
      public static func load(_ url: URL) throws -> [Float]
  }
  public enum VoiceprintPolicy {
      public static let threshold: Float = 0.5        // 执行时用真实录音校准，结论写入 spec
      public static let minKeptRatio: Double = 0.3
  }
  ```

  声纹存放在 `AppPaths.voiceprintURL` = `root/voiceprint/me.f32`，需要在 `AppPaths` 里新增这个属性。

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func cosineOfIdenticalIsOne()
  @Test func saveLoadRoundTrip()
  @Test(.enabled(if: ...MOTING_ASR_IT...)) func sameSpeakerScoresHigherThanDifferent()
  // 用 say 两个不同的中文声音（Tingting / Meijia）：同一声音两句的相似度 > 不同声音
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(asr): 声纹提取与比对`

---

### Task 6：说话人分离步骤（"对方"一路）

**Files:**
- Create: `Sources/MotingASR/Diarizer.swift`、`Sources/MotingPipeline/DiarizeStep.swift`
- Test: `Tests/MotingPipelineTests/DiarizeStepTests.swift`

**Interfaces:**
- Produces：

  ```swift
  public struct SpeakerTurn: Sendable, Equatable { public var start: TimeInterval; public var end: TimeInterval; public var speaker: Int }
  public protocol Diarizing { func diarize(_ samples: [Float]) throws -> [SpeakerTurn] }
  public final class SherpaDiarizer: Diarizing {
      /// clusterThreshold 默认 0.5；numClusters 为 -1 表示自动
      public init(segmentation: AuxModel, embedding: AuxModel, directory: (AuxModel) -> URL) throws
  }
  public struct DiarizeStep {
      /// 给 final 版本里 channel == .system 的片段打 speakerLabel = "说话人 N"（N 从 1 起，按首次出现顺序），
      /// 一段的标签取与它时间重叠最长的 turn
      public func run(versionID: UUID, systemTrack: URL, progress: (Double) -> Void) throws
  }
  ```

  长会议的处理：sherpa 的分离接口吃的是整段音频，2 小时的 16k Float 约 460MB，可以接受。如果执行时实测内存超过 2GB，就按 30 分钟一窗分别分离，相邻窗口之间用声纹比对把说话人对上；这样做的话要记进台账。

- [ ] **Step 1：写失败测试**（假 `Diarizing`）

  ```swift
  @Test func labelsByLongestOverlapInFirstAppearanceOrder()
  @Test func micSegmentsAreUntouched()
  @Test func diarizationOnSilenceIsEmpty()        // turns 为空 → 不改任何片段，不报错
  @Test(.enabled(if: ...MOTING_ASR_IT...)) func realDiarizationOnFourSpeakerSample()
  // speaker-segmentation-models/0-four-speakers-zh.wav → 识别出 3–5 个说话人
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(pipeline): 对方一路说话人分离`

---

### Task 7：声纹过滤步骤 + 合并收尾

**Files:**
- Create: `Sources/MotingPipeline/FilterVoiceStep.swift`、`Sources/MotingPipeline/MergeStep.swift`、`Sources/MotingPipeline/DefaultStepRunner.swift`
- Modify: `Sources/MotingStorage/TranscriptRepository.swift`（`deleteSegments(ids:)`、`setSpeakerLabel(_:label:)`）
- Test: `Tests/MotingPipelineTests/FilterVoiceStepTests.swift`

**Interfaces:**
- Produces：

  ```swift
  public struct FilterVoiceStep {
      /// 没有声纹文件 → 不处理，返回 .skippedNoVoiceprint
      /// 逐段（mic）算相似度，低于阈值的片段删除；删除后剩余时长 < minKeptRatio → 全部保留，返回 .fellBack
      public func run(versionID: UUID, micTrack: URL, voiceprint: URL?, matcher: () throws -> VoiceprintMatcher) throws -> FilterOutcome
  }
  public enum FilterOutcome: String, Codable, Sendable { case filtered, skippedNoVoiceprint, fellBack }
  /// merge：把 final 版本标记为完成（transcriptVersion 新增 completedAt 列，迁移 v3 里一起加），记录 FilterOutcome
  public struct DefaultStepRunner: PipelineStepRunner { ... }  // 把 Task 4、6、7 串起来，并负责模型的加载 / 释放
  ```

- [ ] **Step 1：写失败测试**（假 matcher：按片段文字返回预设的相似度）

  ```swift
  @Test func dropsLowSimilarityMicSegments()
  @Test func skipsWithoutVoiceprint()
  @Test func fallsBackWhenFilterRemovesMost()
  @Test func systemSegmentsAreNeverFiltered()
  ```

- [ ] **Step 2：运行确认失败；实现；运行确认通过**
- [ ] **Step 3：提交** `feat(pipeline): 声纹过滤与合并收尾`

---

### Task 8：接入 app

**Files:**
- Modify:
  - `App/Moting/AppEnvironment.swift`（创建 `PipelineRunner`）
  - `RecordingController.swift`（录音结束后入队，并调用 `wake`；把录音状态提供给调度器）
  - `FloatingPanelView.swift`（结束后显示处理进度和"现在处理"按钮）
  - `MeetingDetailView.swift`（正式稿 / 草稿切换、处理进度、"重新转写"、说话人改名、声纹回退提示）
  - `SettingsView.swift`（新增"离线转写"一节：模型列表与默认、热词编辑、声纹登记 / 删除、各自的存放位置）
  - `MotingApp.swift`
- Create: `App/Moting/VoiceprintEnrollView.swift`、`App/Moting/Notifier.swift`

具体行为：
- **声纹登记**：
  - 屏幕上给一段约 40 字的朗读文本
  - 用 `MicSource` 录 10 秒，录音期间显示电平
  - 提取声纹后保存；可以重录、删除
- **热词**：
  - 用多行文本框编辑，保存为 `hotwords.txt`，每行一个词
  - 如果当前默认离线模型不支持热词，就在旁边注明
- **说话人改名**：
  - 在详情页转写稿里点说话人名字，弹出改名框
  - 名字写进 `SpeakerRepository`，显示和导出都用改后的名字（`MarkdownExporter` 接收一个 label → name 的映射）
- **通知**：用 `UNUserNotificationCenter` 发"会议纪要已生成"（P4 之前文案用"精准转写已完成"），点击打开主窗口并选中该会议。代理回调要显式标 `@Sendable` 或用 `nonisolated` 方法。

- [ ] **Step 1：实现**，然后构建 → `** BUILD SUCCEEDED **`
- [ ] **Step 2：用 16:56 那场会议手工验证**
  1. 点"重新转写"，悬浮窗和详情页能看到进度
  2. 完成后收到通知，详情页切到正式稿
  3. 给说话人改名，导出的 Markdown 里显示新名字
- [ ] **Step 3：提交** `feat(app): 会后精准转写接入（进度、正式稿、说话人改名、热词、声纹登记、通知）`

---

### Task 9：离线模型对比与选定（用户参与）

**Files:**
- Create: `Tests/MotingASRTests/OfflineModelComparisonTests.swift`（受 `MOTING_ASR_BENCH=1` 控制）
- Modify: `OfflineCatalog.default`；spec 第 8 节第 1 条

- [ ] **Step 1：告诉用户需要下载的总量，确认后再开始**
  - 候选 5 个离线模型合计约 2.2GB
  - 辅助模型（VAD、分段、声纹、标点）合计约 100MB
- [ ] **Step 2：运行对比**，对每个模型输出以下三项：
  - 用户最长那场会议两路的前 3 分钟识别文字
  - 识别耗时，按比例推算 1 小时会议需要多少分钟
  - 加载后内存
- [ ] **Step 3：把结果并排交给用户，由用户选定默认模型**
  - 修改 `OfflineCatalog.default`，结论写入 spec
  - 没选中的模型可以在设置里删除；删不删由用户决定，不擅自删
- [ ] **Step 4：用一段真实录音校准声纹阈值**
  - 用户登记声纹后，在一场有旁人说话的录音上比较过滤前后的效果，调整 `VoiceprintPolicy.threshold`
  - 结论写入 spec
- [ ] **Step 5：提交** `chore(asr): 选定默认离线模型并校准声纹阈值`
