# Moting P2：实时字幕 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 录音时在 B 款悬浮窗里实时滚动显示字幕（"我 / 对方"分色、未定稿灰色），识别完全在本机，模型首次使用时下载、可查看与删除；并在飞书会议、腾讯会议上实测共享屏幕时悬浮窗不被录进去。

**Architecture:** 新增 `MotingASR` 库 target，封装 sherpa-onnx v1.13.8 的 C 接口（静态库打成本地 xcframework，作为 SwiftPM binaryTarget）。`RecordingSession` 新增"已写入音频"回调，`LiveTranscriber` 用一个识别器、每路一个流，按写盘后的采样位置计算会议时间。定稿片段写入数据库的草稿版本转写（P3 的正式稿会与之并存）。

**Tech Stack:**
- sherpa-onnx 1.13.8（C API，静态库 osx-arm64-static-no-tts-lib）
- URLSession + CryptoKit（模型下载与 SHA-256 校验）
- GRDB 迁移 v2，SwiftUI

**Spec:** `docs/superpowers/specs/2026-10-30-moting-design.md`（5.2、5.3、5.9、6.3）

**这一阶段做完，用户能看到 / 还看不到：**
- **能看到**：
  - 录音时悬浮窗滚动显示实时字幕
  - 首次使用时引导下载模型，带进度
  - 设置窗口里能看到模型存在哪、各占多大，可以删除
  - 主窗口底部同时显示录音和模型的占用
- **还看不到**：会后精准重转写、多人说话人区分（P3），AI 纪要和会议详情页（P4）。实时字幕是草稿，有错字属于预期内。

## Global Constraints

- **零干扰**：P1 的所有约束继续有效（不写设备属性、不开 voice processing、不用 hog mode）。
- **实时识别性能目标**（spec 5.3，M2 Air，录音 + 识别同时运行）：
  - 平均 CPU 占用 ≤ 单核 30%
  - 常驻内存 ≤ 600MB
  - 字幕延迟 ≤ 1.5 秒
- **识别只在本机进行**，录音和文字都不出本机。
- **模型存放**：`~/Library/Application Support/Moting/models/<model-id>/`，必须在界面上可见、可删除。
  - 用户对磁盘占用敏感：测试不得遗留文件。
  - 下载用 `.part` 临时文件，失败时清理。
- **模型来源**【本计划决定，偏离 spec 5.9】：
  - 默认 `https://huggingface.co`，失败时回退 `https://hf-mirror.com`
  - ModelScope 上找不到这几个 sherpa-onnx 模型；实测 HuggingFace 在用户网络下可以直连
- **sherpa-onnx 版本锁定 1.13.8**：v2.0.x 发布不足一周，不用。
- **Vendor 目录不入库**：`Vendor/` 由脚本生成，加入 `.gitignore`。
- **提交规范**：提交信息用中文，末尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。只提交到本地，不推送。
- **语言模式**：`MotingASR` 用 Swift 5 语言模式（C 指针接口）。

## Review Focus

1. **没有模型就开始录音**（没下载、下载中、校验失败）：录音必须照常进行，字幕区显示"需要下载识别模型"和下载入口，不能崩溃，也不能阻止录音。→ Task 6 `transcriberWithoutModelIsInert`
2. **下载中途失败后重试**：已经下载并校验通过的文件不应重新下载；校验失败的文件要删掉，不能留下半个模型被当成"已安装"。→ Task 3 `skipsVerifiedFiles`、`checksumMismatchRemovesFile`
3. **2 小时会议**：悬浮窗只保留最近几行，内存不随会议时长增长；完整定稿写入数据库。→ Task 5 `bufferKeepsOnlyRecentLines`
4. **暂停期间**：不产生字幕、不写片段；继续后的时间戳按会议时间（不含暂停）计算。→ Task 2 `pausedAudioIsNotForwarded`、`forwardedStartMatchesTrackPosition`
5. **某一路长时间静音或一直是噪声**：端点检测后空文本不应产生空片段，"对方"没人说话时不应出现空行。→ Task 5 `emptyEndpointProducesNoSegment`

---

### Task 0：引入 sherpa-onnx

**Files:**
- Create: `Scripts/fetch-sherpa-onnx.sh`
- Modify: `.gitignore`（加 `Vendor/`）
- Modify: `Package.swift`
- Create: `Sources/MotingASR/SherpaVersion.swift`
- Test: `Tests/MotingASRTests/SherpaLinkTests.swift`

**Interfaces:**
- Produces:
  - binaryTarget `CSherpaOnnx`（模块名 `CSherpaOnnx`，暴露 `c-api.h`）
  - 库 target `MotingASR`，依赖 `MotingCore`、`CSherpaOnnx`；加入产品 `MotingKit`
  - `public func sherpaOnnxVersion() -> String`

- [ ] **Step 1：写脚本 `Scripts/fetch-sherpa-onnx.sh`**

  脚本要幂等：`Vendor/CSherpaOnnx.xcframework` 已存在就直接退出。步骤：
  1. 下载 `https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-static-no-tts-lib.tar.bz2`
  2. 下载 `https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h`
  3. 用 `libtool -static -o libsherpa-onnx-all.a lib/*.a` 合并所有静态库（不含 portaudio）
  4. 生成 `include/c-api.h` 和 `include/module.modulemap`，内容为 `module CSherpaOnnx { header "c-api.h" export * }`
  5. 运行 `xcodebuild -create-xcframework -library libsherpa-onnx-all.a -headers include -output Vendor/CSherpaOnnx.xcframework`
  6. 中间文件放在 `mktemp -d` 里，结束时删除

- [ ] **Step 2：运行脚本** `bash Scripts/fetch-sherpa-onnx.sh && ls Vendor/CSherpaOnnx.xcframework` → 目录存在

- [ ] **Step 3：写失败测试**

  ```swift
  @Test func linksSherpaOnnx() { #expect(sherpaOnnxVersion() == "1.13.8") }
  ```

- [ ] **Step 4：运行确认失败** `swift test --filter SherpaLinkTests` → 编译失败

- [ ] **Step 5：实现**

  `Package.swift`：
  - 加 `.binaryTarget(name: "CSherpaOnnx", path: "Vendor/CSherpaOnnx.xcframework")`
  - `MotingASR` 的 `linkerSettings` 加 `.linkedLibrary("c++")`；其余缺失符号按链接错误补上 framework（如 `Accelerate`、`CoreML`、`Foundation`），把实际补了哪些写进提交信息

- [ ] **Step 6：运行确认通过**；同时运行 `cd App && xcodegen generate && xcodebuild ... build` → `** BUILD SUCCEEDED **`

- [ ] **Step 7：提交** `build(asr): 引入 sherpa-onnx 1.13.8 静态库`

---

### Task 1：转写存储（迁移 v2）

**Files:**
- Modify: `Sources/MotingStorage/AppDatabase.swift`（追加迁移 `v2`）
- Create: `Sources/MotingCore/Transcript.swift`、`Sources/MotingStorage/TranscriptRepository.swift`
- Test: `Tests/MotingStorageTests/TranscriptRepositoryTests.swift`

**Interfaces:**
- Produces:

  ```swift
  // MotingCore
  public enum TranscriptKind: String, Codable, Sendable { case draft, final }
  public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
      public var id: UUID; public var versionID: UUID
      public var channel: AudioChannel; public var speakerLabel: String?   // P3 用
      public var start: TimeInterval; public var end: TimeInterval        // 会议时间（秒）
      public var text: String
  }
  // MotingStorage
  public final class TranscriptRepository: Sendable {
      public init(db: AppDatabase)
      /// 每次调用新建一个版本，返回版本 id
      public func createVersion(meetingID: UUID, kind: TranscriptKind, engine: String, model: String,
                                createdAt: Date) throws -> UUID
      public func append(_ s: TranscriptSegment) throws
      public func latestVersion(meetingID: UUID, kind: TranscriptKind) throws -> UUID?
      public func segments(versionID: UUID) throws -> [TranscriptSegment]   // 按 start 升序
  }
  ```

- 迁移 `v2` 建两张表，外键都设级联删除：
  - `transcriptVersion`：`id TEXT PK`、`meetingId`、`kind`、`engine`、`model`、`createdAt`
  - `segment`：`id TEXT PK`、`versionId`、`channel`、`speakerLabel`、`start`、`end`、`text`

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func segmentsRoundTripInStartOrder()   // 乱序 append 三段 → segments 按 start 升序且字段一致
  @Test func latestVersionPicksNewest()        // 先后两个 draft 版本 → latestVersion 返回后者
  @Test func deletingMeetingCascades()         // MeetingRepository.delete 后 segments 为空
  ```

- [ ] **Step 2：运行确认失败** `swift test --filter TranscriptRepositoryTests`
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**，并跑全量 `swift test`
- [ ] **Step 5：提交** `feat(storage): 转写版本与片段表（迁移 v2）`

---

### Task 2：会话转发"已写入的音频"

**Files:**
- Modify: `Sources/MotingRecording/RecordingSession.swift`
- Test: `Tests/MotingRecordingTests/RecordingSessionTests.swift`

**Interfaces:**
- Produces（在 `RecordingSession` 上）：

  ```swift
  /// 每次真实音频写入轨道后在会话队列上回调：采样（不含补的静音）与它在轨道中的起始位置。
  /// startSample / 16000 即会议时间，与录音文件严格对齐。
  public var onTrackAudio: (@Sendable (AudioChannel, [Float], _ startSample: Int) -> Void)?
  ```

- [ ] **Step 1：写失败测试**（沿用 P1 的 `Fixture`）

  ```swift
  @Test func forwardedStartMatchesTrackPosition()
  // 时钟前进 1s 后 system emit 1600 → 回调一次，startSample == 14400，samples.count == 1600
  @Test func pausedAudioIsNotForwarded()
  // pause 后 emit → 无回调；resume 后 emit → 有回调，startSample == 暂停前已写数
  @Test func droppedLeadIsNotForwarded()
  // 超前被丢弃的部分不转发：回调的 samples.count == 实际写入数
  ```

- [ ] **Step 2：运行确认失败**
- [ ] **Step 3：实现**：在 `handle` 写入成功后调用；`startSample` 取写入前的 `writer.sampleCount`（补静音之后）
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(recording): 转发已写入轨道的音频与其轨道位置`

---

### Task 3：模型目录与下载

**Files:**
- Create: `Sources/MotingASR/ModelCatalog.swift`、`Sources/MotingASR/ModelStore.swift`
- Modify: `Sources/MotingStorage/AppPaths.swift`（`modelsRoot`、`modelsDiskUsage()`）
- Test: `Tests/MotingASRTests/ModelStoreTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum StreamingModelKind: String, Sendable { case transducer, paraformer }
  public struct ModelFile: Sendable, Equatable {
      public var name: String        // 仓库内路径，也是本地文件名
      public var sha256: String
      public var size: Int64
  }
  public struct StreamingModel: Identifiable, Sendable, Equatable {
      public var id: String          // 本地目录名
      public var displayName: String
      public var repo: String        // HuggingFace 仓库，如 "csukuangfj/xxx"
      public var kind: StreamingModelKind
      public var files: [ModelFile]
      /// transducer：encoder/decoder/joiner/tokens；paraformer：encoder/decoder/tokens
      public var roles: [String: String]   // 角色 → 文件名
      public var totalSize: Int64 { get }
  }
  public enum ModelCatalog {
      public static let bilingualZipformer: StreamingModel   // id "zipformer-bilingual-zh-en-2023-02-20"
      public static let chineseZipformer2025: StreamingModel // id "zipformer-zh-int8-2025-06-30"
      public static let bilingualParaformer: StreamingModel  // id "paraformer-bilingual-zh-en"
      public static let all: [StreamingModel]
      public static var `default`: StreamingModel { bilingualZipformer }   // Task 7 基准后可能改
  }
  public enum ModelStoreError: Error, Equatable { case checksumMismatch(String), allMirrorsFailed(String) }
  public final class ModelStore: @unchecked Sendable {
      public init(root: URL, mirrors: [URL] = [URL(string: "https://huggingface.co")!,
                                              URL(string: "https://hf-mirror.com")!],
                  session: URLSession = .shared)
      public func directory(for m: StreamingModel) -> URL
      public func isInstalled(_ m: StreamingModel) -> Bool        // 所有文件存在且大小一致
      /// 逐个文件下载到 .part，SHA-256 校验通过后改名；已存在且大小一致的文件跳过；
      /// 每个文件依次尝试各镜像：<mirror>/<repo>/resolve/main/<name>
      public func install(_ m: StreamingModel, progress: @escaping @Sendable (Double) -> Void) async throws
      public func remove(_ m: StreamingModel) throws
      public func diskUsage(_ m: StreamingModel) -> Int64
  }
  ```

  三个模型只收录 int8 版本，外加 `tokens.txt`（`bpe.model` 不需要）。各文件的 `sha256` 和 `size` 用 HuggingFace API 获取：`https://huggingface.co/api/models/<repo>/tree/main` 返回值里的 `lfs.oid` 和 `size`；非 LFS 小文件先下载，再用 `shasum -a 256` 计算。执行时把实际值写进 `ModelCatalog.swift`。

  `AppPaths` 新增：
  - `modelsRoot` = `root/models`
  - `modelsDiskUsage()`

- [ ] **Step 1：写失败测试**

  测试用 `file://` 临时目录充当镜像，目录结构为 `<tmp>/mirror/<repo>/resolve/main/<file>`。每个测试结束时删除临时目录。

  ```swift
  @Test func installsAndVerifies()            // 两个小文件 → isInstalled == true，progress 最后为 1.0
  @Test func fallsBackToSecondMirror()        // 第一个镜像目录不存在 → 从第二个装好
  @Test func checksumMismatchRemovesFile()    // sha 不符 → 抛 checksumMismatch(name)，目标文件与 .part 都不存在，isInstalled == false
  @Test func skipsVerifiedFiles()             // 先装好，再把镜像删掉后 install → 不报错（不需要再下载）
  @Test func removeDeletesDirectory()         // remove 后目录不存在，diskUsage == 0
  ```

- [ ] **Step 2：运行确认失败** `swift test --filter ModelStoreTests`
- [ ] **Step 3：实现**：用 `URLSession.download(from:)`，CryptoKit 流式计算 SHA-256（按 1MB 读块）
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：真实网络验证（手工）**

  运行 `MOTING_NET_IT=1 swift test --filter installsDefaultModelFromNetwork`。这个测试受环境变量控制，会把默认模型装到临时目录，校验通过后删除。确认下载成功，记录耗时。

- [ ] **Step 6：提交** `feat(asr): 模型目录与可回退镜像的校验下载`

---

### Task 4：sherpa-onnx 流式识别封装

**Files:**
- Create: `Sources/MotingASR/StreamingRecognizer.swift`
- Test: `Tests/MotingASRTests/StreamingRecognizerTests.swift`（受 `MOTING_ASR_IT=1` 控制，需要已安装默认模型）

**Interfaces:**
- Consumes: Task 3 的 `StreamingModel`、`ModelStore.directory(for:)`
- Produces:

  ```swift
  /// 便于 LiveTranscriber 用假实现测试
  public protocol StreamingRecognizing: AnyObject {
      func makeStream() -> RecognitionStream
  }
  public protocol RecognitionStream: AnyObject {
      func accept(_ samples: [Float])      // 16kHz
      func decode()                        // 解码所有就绪帧
      var text: String { get }             // 当前句的部分结果
      var isEndpoint: Bool { get }
      func reset()                         // 端点后开始下一句
  }
  public enum RecognizerError: Error { case modelNotInstalled(String), createFailed }
  public final class SherpaRecognizer: StreamingRecognizing {
      public init(model: StreamingModel, directory: URL, numThreads: Int = 2) throws
  }
  ```

  配置取值：
  - `feat_config`：sample_rate 16000，feature_dim 80
  - `decoding_method` = `"greedy_search"`，`provider` = `"cpu"`
  - 端点检测：`enable_endpoint = 1`，rule1 = 2.4、rule2 = 1.2、rule3 = 20.0
  - 文件路径从 `roles` 拼接

  C 字符串在 `init` 期间要保持有效，用 `withCString` 嵌套，或者先 `strdup`、`init` 结束时再 `free`。

- [ ] **Step 1：写测试**

  ```swift
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
  func recognizesBundledWav() throws {
      // 读模型目录下 test_wavs/1.wav（Task 3 的 IT 会一起下载 test_wavs/1.wav 到临时目录；此处直接下载到临时目录）
      // 按 100ms 一块喂入并 decode，结束后 text 非空
  }
  @Test func missingModelThrows()   // directory 为空目录 → 抛 modelNotInstalled
  ```

- [ ] **Step 2：运行确认失败** `swift test --filter StreamingRecognizerTests`
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**：先跑 `missingModelThrows`；再按 Task 3 Step 5 的方式装好默认模型后运行 `MOTING_ASR_IT=1` 那条，记录识别出的文字
- [ ] **Step 5：提交** `feat(asr): sherpa-onnx 流式识别封装`

---

### Task 5：实时转写（分句、缓冲、落库）

**Files:**
- Create: `Sources/MotingASR/LiveTranscriber.swift`、`Sources/MotingASR/SubtitleBuffer.swift`
- Test: `Tests/MotingASRTests/LiveTranscriberTests.swift`、`Tests/MotingASRTests/SubtitleBufferTests.swift`、`Tests/MotingASRTests/FakeRecognizer.swift`

**Interfaces:**
- Consumes: Task 4 的 `StreamingRecognizing`；Task 1 的 `TranscriptSegment`
- Produces:

  ```swift
  public struct SubtitleLine: Identifiable, Sendable, Equatable {
      public var id: UUID; public var channel: AudioChannel
      public var text: String; public var isFinal: Bool
  }
  public enum TranscriptEvent: Sendable {
      case partial(SubtitleLine)
      case final(SubtitleLine, TranscriptSegment)
  }
  public final class LiveTranscriber: @unchecked Sendable {
      /// versionID：本场会议的草稿版本
      public init(recognizer: StreamingRecognizing, versionID: UUID,
                  onEvent: @escaping @Sendable (TranscriptEvent) -> Void)
      /// 接 RecordingSession.onTrackAudio；内部串行队列（QoS .utility）上识别
      public func feed(_ channel: AudioChannel, _ samples: [Float], startSample: Int)
      public func finish()     // 结束录音时调用：把两路未定稿的文字作为 final 发出
  }
  /// 悬浮窗用：最多保留 maxLines 行；同一 id 的 partial 原地更新，final 定稿
  public struct SubtitleBuffer: Sendable, Equatable {
      public init(maxLines: Int = 6)
      public mutating func apply(_ e: TranscriptEvent)
      public private(set) var lines: [SubtitleLine]
  }
  ```

  分句规则：
  - 每路维护"当前句"，记录 id 和起始采样
  - 当前句文字有变化（去掉首尾空白后）→ 发 `.partial`
  - `isEndpoint` 为真时：文字非空就发 `.final`，片段时间为 `[句起始, 当前采样] / 16000`；文字为空则不发。然后 `reset()`，开新句

- [ ] **Step 1：写 `FakeRecognizer`**

  它的流按预设脚本返回 `text` 和 `isEndpoint`，比如第 N 次 decode 后返回 X。

- [ ] **Step 2：写失败测试**

  ```swift
  @Test func partialThenFinalWithMeetingTimes()   // mic 喂 3 块（startSample 0/1600/3200），脚本：“你” → “你好” → 端点 → final.text == "你好"，segment.start == 0，segment.end == 0.3，channel == .mic
  @Test func emptyEndpointProducesNoSegment()     // 文字始终为空且出现端点 → 无任何事件
  @Test func channelsAreIndependent()              // mic 与 system 交替喂，各自 final 的 channel 与时间正确
  @Test func finishFlushesPartial()                // 只有 partial 时 finish → 收到 final
  @Test func bufferKeepsOnlyRecentLines()          // apply 10 个 final → lines.count == 6，保留最后 6 条
  @Test func bufferUpdatesPartialInPlace()         // 同 id 的 partial 两次 → 1 行，文字为后者；final 后 isFinal == true
  ```

- [ ] **Step 3：运行确认失败** `swift test --filter "LiveTranscriberTests|SubtitleBufferTests"`
- [ ] **Step 4：实现**
- [ ] **Step 5：运行确认通过**
- [ ] **Step 6：提交** `feat(asr): 实时转写分句与字幕缓冲`

---

### Task 6：接入 app（字幕、模型引导、设置）

**Files:**
- Create: `App/Moting/LiveTranscriptModel.swift`、`App/Moting/SettingsView.swift`
- Modify: `App/Moting/RecordingController.swift`、`FloatingPanelView.swift`、`MeetingListView.swift`、`MotingApp.swift`、`AppEnvironment.swift`
- Test: `Tests/MotingASRTests/LiveTranscriberTests.swift`（追加）

**Interfaces:**
- Consumes：
  - `ModelStore`、`ModelCatalog.default`
  - `SherpaRecognizer`、`LiveTranscriber`、`SubtitleBuffer`
  - `TranscriptRepository`、`RecordingSession.onTrackAudio`
- Produces：

  ```swift
  @MainActor final class LiveTranscriptModel: ObservableObject {
      @Published private(set) var lines: [SubtitleLine]
      @Published private(set) var modelState: ModelState   // .missing / .downloading(Double) / .ready / .failed(String)
      func installDefaultModel()
  }
  ```

  行为：
  - **开始录音时**：模型已就绪，就为本场会议建草稿版本（`engine: "sherpa-onnx 1.13.8"`，`model: <id>`），再创建 `LiveTranscriber`；final 片段写入 `TranscriptRepository`。模型未就绪，则只录音，字幕区显示"实时字幕需要先下载识别模型（约 <totalSize>）"和"下载"按钮，按钮旁显示进度。
  - **识别器复用**：`SherpaRecognizer` 在第一次录音时创建，之后的录音一直复用，避免每次开录都加载模型。
  - **字幕区显示**：用 `SubtitleBuffer` 的 `lines`。"我"用 `#64D2FF`，"对方"用 `#FFD60A`，未定稿的文字用灰色；新行出现时自动滚到底部。
  - **设置窗口**（`Settings` scene，⌘,）：
    - 只有"识别模型"一节：列出 `ModelCatalog.all`，每个显示名称、大小、是否已下载
    - 操作：下载、删除、"设为默认"（选择保存在 `UserDefaults`）
    - 显示模型存放路径，以及"在 Finder 中显示"按钮
  - **主窗口底部占用**：改为"录音 X · 模型 Y"。

- [ ] **Step 1：写失败测试**（追加到 `LiveTranscriberTests`）

  ```swift
  @Test func transcriberWithoutModelIsInert()
  // 用 ModelStore 指向空目录，确认 isInstalled(default) == false，并且 SherpaRecognizer(init) 抛 modelNotInstalled
  // —— 这是 app 判断"不建转写器、只录音"的依据
  ```

- [ ] **Step 2：运行确认失败，实现，运行确认通过**
- [ ] **Step 3：构建 app** → `** BUILD SUCCEEDED **`
- [ ] **Step 4：手工验证**
  1. 删除默认模型后开始录音：录音正常，悬浮窗显示下载入口；点下载能看到进度，下载完成后**下一次**开录才出字幕
  2. 模型就绪后，对着麦克风说中英混杂的话，同时用浏览器播放视频：两种颜色的字幕都出现，延迟体感在 1.5 秒以内
  3. 录音 5 分钟，用 `ps -o %cpu,rss -p $(pgrep Moting)` 每 30 秒采样一次。平均 %CPU ≤ 30，RSS ≤ 600MB；结果写进提交信息
- [ ] **Step 5：提交** `feat(app): 悬浮窗实时字幕、模型下载引导与设置窗口`

---

### Task 7：选定默认模型

**Files:**
- Create: `Tests/MotingASRTests/ModelComparisonTests.swift`（受 `MOTING_ASR_BENCH=1` 控制）
- Modify: `Sources/MotingASR/ModelCatalog.swift`（`default`）、`docs/superpowers/specs/2026-10-30-moting-design.md`（第 8 节第 2 条写入结论）

- [ ] **Step 1：写对比测试**

  测试做的事：
  1. 把三个候选模型装到 `AppPaths.default.modelsRoot`，用户之后可以在设置里删除
  2. 每个模型分别跑同一组音频：
     - 候选仓库自带的 `test_wavs/0.wav`、`1.wav`、`2.wav`、`3.wav`
     - 用户最近一场会议两路录音的前 60 秒（从 `meetings/` 目录取最新一条）
  3. 每个模型输出三项：每段音频的识别文字、实时率 RTF（识别耗时 ÷ 音频时长）、峰值 RSS
  4. 结果写到 `~/Library/Application Support/Moting/model-comparison.md`，并打印到终端

- [ ] **Step 2：运行** `MOTING_ASR_BENCH=1 swift test --filter ModelComparisonTests`
- [ ] **Step 3：把三个模型的识别文字并排交给用户，由用户选默认模型**
  - 用户最清楚自己会议里说了什么，这一步不靠计算字错率
  - 选定后修改 `ModelCatalog.default`，把结论和 RTF 写进 spec 第 8 节第 2 条
  - 未选中模型的删除权交给用户，在设置里删
- [ ] **Step 4：提交** `chore(asr): 选定默认实时识别模型`

---

### Task 8：共享屏幕隐藏实测（飞书会议、腾讯会议）

**Files:**
- 可能修改：`App/Moting/FloatingPanelController.swift`
- 修改：spec 第 8 节第 5 条写入结论

- [ ] **Step 1：手工测试**

  用户分别在飞书会议、腾讯会议发起测试会议，用第二台设备或手机入会。分别在以下两种情况下观察入会端画面里能否看到悬浮窗：
  - 共享"整个屏幕"
  - 共享"某个窗口"

- [ ] **Step 2：若全部看不到**

  在 spec 记录"`sharingType = .none` 在飞书 / 腾讯会议有效（macOS 15.5）"，任务结束。

- [ ] **Step 3：若有任一情况能看到**

  加一个全局快捷键 ⌥⌘H 来显示 / 隐藏悬浮窗：
  - 用 Carbon `RegisterEventHotKey` 实现，不需要辅助功能权限
  - 悬浮窗右键菜单里加"隐藏（⌥⌘H）"

  然后在 spec 中记录哪些情况会泄漏。

- [ ] **Step 4：提交** `docs: 共享屏幕隐藏实测结论`（如有代码改动，用 `feat(app): ...`）
