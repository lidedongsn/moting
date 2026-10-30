# Moting P1：录音基座 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能从菜单栏开始 / 暂停 / 结束录音的 Mac app：同时录制麦克风和系统音频，两路按时间对齐、崩溃安全地落盘，会议记录存入 SQLite，并在一个最小的主窗口里列出来。

**Architecture:** 根目录是一个 Swift Package `MotingKit`，按职责拆成 4 个库 target：
- `MotingCore`：领域模型和时钟
- `MotingStorage`：GRDB 数据库和文件布局
- `MotingCapture`：Core Audio 采集、环形缓冲、重采样、PCM 读写
- `MotingRecording`：会话编排和崩溃恢复

app 外壳放在 `App/`，用 XcodeGen 生成工程，依赖本地 package。音频走 Core Audio IOProc（麦克风设备 / Process Tap 聚合设备）→ 无锁环形缓冲 → 消费队列重采样到 16kHz 单声道 → 写成 Int16 PCM 文件。

**Tech Stack:**
- Swift 6.1 / Xcode 16.4，SwiftUI + AppKit
- Core Audio（`AudioHardwareCreateProcessTap`、`AudioDeviceCreateIOProcIDWithBlock`）、AVFoundation（`AVAudioConverter`）
- GRDB.swift 7.x，swift-atomics 1.2+
- 测试用 Swift Testing，工程用 XcodeGen，验证用 ffmpeg / ffplay

**Spec:** `docs/superpowers/specs/2026-10-30-moting-design.md`

### 整体路线（本计划只覆盖 P1）

| 阶段 | 内容 | 产出 |
|---|---|---|
| **P1 录音基座**（本计划） | 工程骨架、双路采集、对齐落盘、存储、崩溃恢复、菜单栏 + 最小列表 | 能录、能存、不丢 |
| P2 实时字幕 | sherpa-onnx 流式识别、B 款悬浮窗、共享屏幕隐藏验证、模型下载 | 会中看到字幕 |
| P3 会后精准转写 | `moting-bench` 引擎选型、任务队列、离线 ASR + 热词、说话人分离、合并对齐 | 正式稿 |
| P4 AI 纪要与主窗口 | OpenAI 兼容 Provider、钥匙串、模板、主窗口详情、说话人改名、Markdown 导出、设置 | 完整 MVP |
| P5 回声处理 | 实时 AEC + 离线去重 | 外放可用 |

每个阶段单独写计划，前一阶段完成后再写下一份。

## Global Constraints

- 最低系统 macOS 14.2（`MACOSX_DEPLOYMENT_TARGET = 14.2`，Package `platforms: [.macOS("14.2")]`）。
- 纯原生，不引入 Web 技术栈。
- 仅自用：非沙盒，不开 hardened runtime，用本机证书 "Apple Development" 签名；`DEVELOPMENT_TEAM` 放在不提交的 `App/Local.xcconfig`。
- **零干扰（硬性）**：
  - 不调用 `setVoiceProcessingEnabled`
  - 不修改任何设备的采样率、缓冲区大小（不写 `kAudioDevicePropertyNominalSampleRate` / `kAudioDevicePropertyBufferFrameSize`）
  - 不使用 hog mode
  - 非录音状态不打开麦克风
- 系统音频 Tap 的 `muteBehavior` 必须是 `.unmuted`；全局 Tap，排除本进程。
- 音频回调（IOProc）线程内禁止分配内存、加锁、I/O、调用 Swift 运行时的引用计数敏感 API；只做降混 + 写入环形缓冲。
- 落盘格式【本计划决定】：16kHz、单声道、Int16 小端裸 PCM，文件名 `mic.pcm` / `system.pcm`，位于 `~/Library/Application Support/Moting/meetings/<meeting-id>/`。理由：后续所有识别、分离模型都吃 16kHz；裸 PCM 崩溃后只需截断到偶数字节即可恢复。
- 两路音频的第 N 个采样必须对应同一会议时刻（会议时间 = 去掉暂停后的录音时长）。
- 代码注释、git 提交信息用中文；提交信息末尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- `MotingCapture` target 使用 Swift 5 语言模式（`swiftSettings: [.swiftLanguageMode(.v5)]`），避免 C 回调与严格并发检查纠缠；其余 target 用 Swift 6 模式。

## Review Focus

1. **录音中某一路采集失败或中途断开**（比如拔掉 USB 麦克风、系统里没有输入设备了）：会话不应崩溃，另一路照常录；该路恢复后用静音补齐，时间线不错位。→ Task 8 `sourceFailureKeepsOtherTrack`、`lateChunksArePadded`
2. **权限被拒（麦克风或系统音频录制）导致启动失败**：不应留下一个永远处于"录音中"的会议记录。→ Task 8 `startFailureMarksMeetingFailed`
3. **重复点击结束、在暂停状态下结束**：应当幂等，最终状态是"待处理"，暂停区间被正确关闭。→ Task 8 `stopIsIdempotentAndClosesPause`
4. **设备采样率不是 48k**（AirPods 通话模式 24k、部分声卡 44.1k）：落盘时长必须正确。→ Task 4 `resamplesCommonRates`
5. **两路启动有先后**（Tap 往往比麦克风晚几百毫秒出数据）：晚的那一路开头补静音，保证对齐。→ Task 5 `padsWhenBehind`、Task 8 `lateChunksArePadded`

---

### Task 0：仓库与工程骨架

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/MotingCore/MotingCore.swift`、`Sources/MotingStorage/MotingStorage.swift`、`Sources/MotingCapture/MotingCapture.swift`、`Sources/MotingRecording/MotingRecording.swift`（各一行占位注释）
- Create: `Tests/MotingCoreTests/SmokeTests.swift`
- Create: `App/project.yml`、`App/Local.xcconfig.example`、`App/Moting/Info.plist`、`App/Moting/MotingApp.swift`

**Interfaces:**
- Produces: package 产品 `MotingKit`（library，包含 4 个 target）；app target 名 `Moting`，bundle id `com.lidedongsn.moting`。

- [ ] **Step 1：初始化 git，写 `.gitignore`**

  忽略以下内容：
  - `.build/`、`.swiftpm/`、`App/*.xcodeproj`、`App/Local.xcconfig`
  - `.superpowers/`、`DerivedData/`、`*.xcuserstate`

  然后执行 `git init`，把 spec 和本计划一起作为首个提交。

- [ ] **Step 2：写 `Package.swift`**

  - `swift-tools-version: 6.0`，`platforms: [.macOS("14.2")]`
  - 依赖：
    - `https://github.com/groue/GRDB.swift` from `"7.0.0"`
    - `https://github.com/apple/swift-atomics` from `"1.2.0"`
  - target 依赖关系：
    - `MotingStorage` → `MotingCore` + `GRDB`
    - `MotingCapture` → `MotingCore` + `Atomics`（Swift 5 模式）
    - `MotingRecording` → 上面三个
  - 每个库 target 配一个 `<Name>Tests` 测试 target。

- [ ] **Step 3：写冒烟测试并运行**

  ```swift
  import Testing
  @testable import MotingCore
  @Test func packageBuilds() { #expect(Bool(true)) }
  ```

  Run: `swift test`
  Expected: `Test run with 1 test passed`

- [ ] **Step 4：写 XcodeGen 工程**

  `App/project.yml`：
  - 一个 macOS application target `Moting`，sources 为 `Moting/`，依赖本地 package `..` 的产品 `MotingKit`
  - `configFiles` 的 Debug / Release 都指向 `Local.xcconfig`
  - settings：
    - `MACOSX_DEPLOYMENT_TARGET: 14.2`
    - `ENABLE_HARDENED_RUNTIME: NO`
    - `CODE_SIGN_STYLE: Automatic`
    - `CODE_SIGN_IDENTITY: "Apple Development"`
    - `INFOPLIST_FILE: Moting/Info.plist`

  `Info.plist` 包含：
  - `NSMicrophoneUsageDescription` = "Moting 需要麦克风来录制你在会议中的发言。"
  - `NSAudioCaptureUsageDescription` = "Moting 需要录制系统音频来记录会议中其他人的发言。"
  - `LSUIElement` = `NO`

  `Local.xcconfig.example` 只有一行 `DEVELOPMENT_TEAM = `。把它复制为 `Local.xcconfig`，填入本机团队 ID：从 `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` 输出的 `OU=` 字段取值。

  `MotingApp.swift` 先放一个空的 `@main struct MotingApp: App`，带一个显示 "Moting" 的 `WindowGroup`。

- [ ] **Step 5：生成并构建**

  Run: `cd App && xcodegen generate && xcodebuild -project Moting.xcodeproj -scheme Moting -configuration Debug build 2>&1 | tail -3`
  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6：提交** `git commit -m "chore: 初始化 MotingKit 包与 Moting app 工程骨架"`

---

### Task 1：领域模型与会议时钟

**Files:**
- Create: `Sources/MotingCore/Models.swift`、`Sources/MotingCore/MeetingClock.swift`
- Test: `Tests/MotingCoreTests/MeetingClockTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public enum AudioChannel: String, Codable, Sendable, CaseIterable { case mic, system }
  public enum MeetingStatus: String, Codable, Sendable {
      case recording, pendingProcessing, interrupted, processing, done, failed
  }
  public struct Meeting: Identifiable, Codable, Sendable, Equatable {
      public var id: UUID; public var title: String
      public var startedAt: Date; public var endedAt: Date?
      public var status: MeetingStatus
      public static func new(startedAt: Date) -> Meeting  // title = "会议 yyyy-MM-dd HH:mm"
  }
  public struct Mark: Identifiable, Codable, Sendable, Equatable {
      public var id: UUID; public var meetingID: UUID; public var at: TimeInterval  // 会议时间，秒
  }
  public struct MeetingClock: Sendable {   // 值类型，纯逻辑，时间由调用方传入
      public init()
      public mutating func start(at: Date)
      public mutating func pause(at: Date)
      public mutating func resume(at: Date)
      public func elapsed(at: Date) -> TimeInterval   // 去掉暂停的累计时长
      public var isPaused: Bool { get }
  }
  ```

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func elapsedExcludesPauses() {
      var c = MeetingClock(); let t0 = Date(timeIntervalSince1970: 0)
      c.start(at: t0)
      c.pause(at: t0 + 10); c.resume(at: t0 + 25)
      #expect(c.elapsed(at: t0 + 30) == 15)
      #expect(c.elapsed(at: t0 + 12) == 10)   // 不传 pause 时间也正确
  }
  @Test func pauseAndResumeAreIdempotent() {
      var c = MeetingClock(); let t0 = Date(timeIntervalSince1970: 0)
      c.start(at: t0); c.pause(at: t0 + 5); c.pause(at: t0 + 8)
      c.resume(at: t0 + 10); c.resume(at: t0 + 11)
      #expect(c.elapsed(at: t0 + 20) == 15)
  }
  @Test func defaultTitle() {
      let m = Meeting.new(startedAt: ISO8601DateFormatter().date(from: "2026-10-30T06:05:00Z")!)
      #expect(m.title.hasPrefix("会议 2026-10-30"))
      #expect(m.status == .recording)
  }
  ```

- [ ] **Step 2：运行确认失败** `swift test --filter MotingCoreTests` → 编译失败（类型未定义）
- [ ] **Step 3：实现上述类型**（标题用本地时区格式化）
- [ ] **Step 4：运行确认通过** `swift test --filter MotingCoreTests` → 全部 PASS
- [ ] **Step 5：提交** `feat(core): 会议领域模型与去暂停的会议时钟`

---

### Task 2：存储（文件布局 + 数据库 + 仓储）

**Files:**
- Create: `Sources/MotingStorage/AppPaths.swift`、`AppDatabase.swift`、`Records.swift`、`MeetingRepository.swift`
- Test: `Tests/MotingStorageTests/MeetingRepositoryTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Meeting`、`Mark`、`MeetingStatus`、`AudioChannel`
- Produces:

  ```swift
  public struct AppPaths: Sendable {
      public init(root: URL)
      public static var `default`: AppPaths   // ~/Library/Application Support/Moting
      public var databaseURL: URL             // root/moting.sqlite
      public func meetingDirectory(_ id: UUID) -> URL     // root/meetings/<id>/
      public func trackURL(_ id: UUID, _ channel: AudioChannel) -> URL  // .../<mic|system>.pcm
      public func ensureMeetingDirectory(_ id: UUID) throws -> URL
  }
  public final class AppDatabase: Sendable {
      public static func open(at url: URL) throws -> AppDatabase
      public static func inMemory() throws -> AppDatabase
      public let writer: any DatabaseWriter
  }
  public struct AudioTrackInfo: Codable, Sendable, Equatable {
      public var meetingID: UUID; public var channel: AudioChannel
      public var relativePath: String; public var sampleRate: Int   // 16000
  }
  public final class MeetingRepository: Sendable {
      public init(db: AppDatabase)
      public func insert(_ m: Meeting, tracks: [AudioTrackInfo]) throws
      public func setStatus(_ id: UUID, _ s: MeetingStatus, endedAt: Date?) throws
      public func addMark(_ mark: Mark) throws
      public func beginPause(meetingID: UUID, at: Date) throws
      public func endOpenPause(meetingID: UUID, at: Date) throws   // 无未结束暂停时不做任何事
      public func meeting(_ id: UUID) throws -> Meeting?
      public func marks(_ id: UUID) throws -> [Mark]
      public func tracks(_ id: UUID) throws -> [AudioTrackInfo]
      public func pauses(_ id: UUID) throws -> [(start: Date, end: Date?)]
      public func meetings(status: MeetingStatus) throws -> [Meeting]
      public func observeAll() -> AsyncValueObservation<[Meeting]>    // 按 startedAt 倒序
  }
  ```

- 数据库迁移 `v1` 建 4 张表：
  - `meeting`
  - `audioTrack`
  - `mark`
  - `pause`：`id INTEGER PK`、`meetingId`、`startedAt`、`endedAt NULL`

  子表的外键都设 `ON DELETE CASCADE`。后续阶段只追加新的迁移，不修改 `v1`。

- [ ] **Step 1：写失败测试**（全部基于 `AppDatabase.inMemory()`）

  ```swift
  @Test func insertAndListNewestFirst()          // 插入两个会议，observeAll 首值为 [新, 旧]
  @Test func statusUpdateSetsEndedAt()           // setStatus(.pendingProcessing, endedAt: t) 后读回一致
  @Test func pauseOpenAndClose()                 // beginPause → endOpenPause → pauses 有一条且 end != nil；再 endOpenPause 不报错
  @Test func marksAndTracksRoundTrip()
  @Test func meetingsByStatus()                  // 只返回 .recording 的
  @Test func pathsLayout() {
      let p = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
      let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
      #expect(p.trackURL(id, .mic).path == "/tmp/x/meetings/00000000-0000-0000-0000-000000000001/mic.pcm")
  }
  ```

  前五个测试的断言按注释里的行为写。`observeAll` 首值用 `for try await` 取第一个值。

- [ ] **Step 2：运行确认失败** `swift test --filter MotingStorageTests`
- [ ] **Step 3：实现**。GRDB 记录类型放在 `Records.swift`（内部类型），对外只暴露 Core 模型；UUID 存为文本。
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(storage): 数据目录布局、v1 迁移与会议仓储`

---

### Task 3：无锁环形缓冲 + PCM 读写

**Files:**
- Create: `Sources/MotingCapture/SPSCRingBuffer.swift`、`PCMTrackWriter.swift`、`PCMTrackReader.swift`
- Test: `Tests/MotingCaptureTests/RingBufferTests.swift`、`PCMTrackTests.swift`

**Interfaces:**
- Produces:

  ```swift
  /// 单生产者单消费者，生产者在实时线程，write 不得分配内存或加锁
  public final class SPSCRingBuffer: @unchecked Sendable {
      public init(capacity: Int)                                   // Float 个数
      @discardableResult public func write(_ src: UnsafePointer<Float>, count: Int) -> Int  // 满了丢弃多余部分，返回实际写入数
      public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int
      public var availableToRead: Int { get }
      public var droppedSamples: Int { get }   // 溢出累计，供日志
  }
  public final class PCMTrackWriter {
      public init(url: URL) throws                  // 文件存在则追加（用于恢复后继续）
      public func append(_ samples: [Float]) throws // 截断到 [-1,1] 后转 Int16 LE
      public func appendSilence(_ count: Int) throws
      public private(set) var sampleCount: Int
      public func sync() throws                     // fsync
      public func close() throws
  }
  public enum PCMTrackReader {
      public static func readAll(_ url: URL) throws -> [Float]
      public static func sampleCount(_ url: URL) throws -> Int
      public static func repair(_ url: URL) throws  // 文件长度为奇数时截掉最后 1 字节
  }
  ```

  环形缓冲用 `ManagedAtomic<Int>` 保存读写位置，容量向上取 2 的幂。

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func ringWrapsAround()        // 容量 8：写 6 读 6 再写 6，读出顺序与写入一致
  @Test func ringDropsWhenFull()      // 容量 8 写 10 → 返回 8，droppedSamples == 2
  @Test func ringConcurrentSPSC()     // 一个线程写 1_000_000 个递增值，另一线程读，读到的序列严格递增且无重复
  @Test func pcmRoundTrip()           // append [0, 0.5, -0.5, 1.2] → readAll ≈ [0, 0.5, -0.5, 1.0]（容差 1/32768）
  @Test func pcmSilenceAndCount()     // append 3 个 + silence 5 → sampleCount == 8，文件 16 字节
  @Test func pcmRepairOddLength()     // 手工追加 1 字节 → repair 后 sampleCount 不变、文件长度为偶数
  @Test func pcmWriterAppendsToExisting()  // 写 4 个 close，再开 writer 写 2 个 → sampleCount == 6
  ```

- [ ] **Step 2：运行确认失败** `swift test --filter MotingCaptureTests`
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(capture): SPSC 无锁环形缓冲与 16k Int16 PCM 读写`

---

### Task 4：重采样器

**Files:**
- Create: `Sources/MotingCapture/Resampler.swift`
- Test: `Tests/MotingCaptureTests/ResamplerTests.swift`

**Interfaces:**
- Produces:

  ```swift
  public final class Resampler {
      public static let targetRate: Double = 16_000
      public init(inputSampleRate: Double) throws   // 输入为单声道 Float32
      public func process(_ input: [Float]) throws -> [Float]   // 流式，内部保持状态
      public func flush() throws -> [Float]
  }
  ```

  内部用 `AVAudioConverter`，`sampleRateConverterQuality = .max`。输入为 16k 时直接透传。

- [ ] **Step 1：写失败测试**

  ```swift
  @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
  func resamplesCommonRates(rate: Double) throws {
      // 1 秒 440Hz 正弦，按 10ms 一块喂入，再 flush
      // 输出总数在 16000 ± 32 内；输出中段的过零次数 ≈ 880/秒（±2%）
  }
  ```

- [ ] **Step 2：运行确认失败**
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(capture): 基于 AVAudioConverter 的流式重采样到 16kHz`

---

### Task 5：轨道对齐器

**Files:**
- Create: `Sources/MotingCapture/TrackAligner.swift`
- Test: `Tests/MotingCaptureTests/TrackAlignerTests.swift`

**Interfaces:**
- Produces:

  ```swift
  /// 纯逻辑：根据"此刻应写到第几个采样"与"已写了多少"，决定补多少静音
  public struct TrackAligner: Sendable {
      public init(sampleRate: Int = 16_000, tolerance: TimeInterval = 0.2)
      /// expectedElapsed：会议时钟当前时长（秒）；incoming：本次将写入的采样数
      public func silenceToInsert(expectedElapsed: TimeInterval, written: Int, incoming: Int) -> Int
  }
  ```

  规则：`expected = Int(expectedElapsed * rate)`。若 `expected - (written + incoming) > tolerance * rate`，返回 `expected - (written + incoming)`；否则返回 0。不丢弃超前的数据。

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func noPaddingWithinTolerance()  // expected 1.1s，written 16000，incoming 1600 → 0
  @Test func padsWhenBehind()            // expected 2.0s，written 0，incoming 1600 → 30400
  @Test func neverNegative()             // written 远超 expected → 0
  ```

- [ ] **Step 2：运行确认失败**
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(capture): 轨道对齐器，落后超过 200ms 时补静音`

---

### Task 6：Core Audio 设备读取 + 麦克风源

**Files:**
- Create: `Sources/MotingCapture/AudioSource.swift`、`CoreAudioHelpers.swift`、`DeviceIOReader.swift`、`MicSource.swift`
- Test: `Tests/MotingCaptureTests/MicSourceIntegrationTests.swift`（仅在环境变量 `MOTING_AUDIO_IT=1` 时运行）

**Interfaces:**
- Consumes: Task 3 的 `SPSCRingBuffer`，Task 4 的 `Resampler`
- Produces:

  ```swift
  public struct AudioChunk: Sendable {
      public var samples: [Float]          // 16kHz 单声道
      public var level: Float              // 本块 RMS，供 UI 电平
  }
  public enum AudioSourceEvent: Sendable {
      case chunk(AudioChunk)
      case interrupted(String)             // 设备消失等，源会自行尝试恢复
      case resumed
  }
  public protocol AudioSource: AnyObject {
      var channel: AudioChannel { get }
      /// handler 在源内部的串行消费队列上调用，绝不在实时线程
      func start(handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws
      func stop()
  }
  public enum CaptureError: Error { case permissionDenied(AudioChannel), deviceUnavailable(String), coreAudio(OSStatus, String) }

  final class DeviceIOReader {       // 内部：对一个 AudioObjectID 开 IOProc
      init(deviceID: AudioObjectID, ring: SPSCRingBuffer) throws
      var inputSampleRate: Double { get }   // 只读取 kAudioDevicePropertyNominalSampleRate，不写
      func start() throws; func stop()
  }
  public final class MicSource: AudioSource {
      public init(deviceUID: String? = nil)  // nil = 跟随系统默认输入
  }
  ```

  实现要点：
  - **IOProc 回调**：只把各声道平均成单声道写入一个预分配的临时缓冲，再写入环形缓冲；临时缓冲按设备最大帧数预分配。
  - **消费端**：一个串行 `DispatchQueue` 上每 20ms 触发一次的 `DispatchSourceTimer`，从环形缓冲读出数据，重采样后通过 `.chunk` 回调。
  - **跟随默认设备**（`deviceUID == nil`）：监听 `kAudioHardwarePropertyDefaultInputDevice`，变化时先回调 `.interrupted`，再重建 reader 和 resampler，然后回调 `.resumed`。
  - **采样率变化**：监听当前设备的 `kAudioDevicePropertyNominalSampleRate`，变化时重建 resampler。
  - **权限检查**：`start()` 前调用 `AVCaptureDevice.authorizationStatus(for: .audio)`；状态为 `.notDetermined` 时同步请求授权，被拒绝则抛出 `CaptureError.permissionDenied(.mic)`。

- [ ] **Step 1：写集成测试**

  ```swift
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AUDIO_IT"] == "1"))
  func micDeliversChunks() async throws {
      // 启动 MicSource 2 秒，收到的 chunk 采样总数在 32000 ± 3200 内
  }
  ```

- [ ] **Step 2：运行确认失败** `MOTING_AUDIO_IT=1 swift test --filter micDeliversChunks`（首次运行会弹出麦克风授权，在终端 app 上允许）
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：零干扰手工验证**

  一边用 FaceTime 或 Photo Booth 录一段音频，一边跑上面的测试。确认：
  - 对方 app 录音正常
  - 系统设置 → 声音 → 输入里的采样率没有变化

  在提交信息里记录结论。

- [ ] **Step 6：提交** `feat(capture): Core Audio IOProc 读取与跟随默认设备的麦克风源`

---

### Task 7：系统音频源（Process Tap）

**Files:**
- Create: `Sources/MotingCapture/SystemAudioTapSource.swift`
- Test: `Tests/MotingCaptureTests/SystemTapIntegrationTests.swift`（同样受 `MOTING_AUDIO_IT` 控制）

**Interfaces:**
- Consumes: Task 6 的 `AudioSource`、`DeviceIOReader`、`AudioSourceEvent`
- Produces:

  ```swift
  public final class SystemAudioTapSource: AudioSource {
      public init()   // 全局立体声 Tap，排除本进程
  }
  ```

  实现要点：
  1. **创建 Tap**：通过 `kAudioHardwarePropertyTranslatePIDToProcessObject` 拿到本进程的 AudioObjectID；用 `CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObjectID])` 建 Tap，设置 `muteBehavior = .unmuted`、`isPrivate = true`，再调用 `AudioHardwareCreateProcessTap`。
  2. **建聚合设备**：用 `AudioHardwareCreateAggregateDevice` 创建私有聚合设备：
     - 主设备 = 当前默认输出设备的 UID
     - `kAudioAggregateDeviceTapListKey` = 上面的 Tap
     - `kAudioAggregateDeviceTapAutoStartKey = true`
     - `kAudioAggregateDeviceIsPrivateKey = true`
  3. **读取数据**：用 `DeviceIOReader` 读聚合设备的输入，流程与麦克风相同。
  4. **输出设备切换**：监听 `kAudioHardwarePropertyDefaultOutputDevice`，变化时回调 `.interrupted`，销毁并重建聚合设备，再回调 `.resumed`。
  5. **停止时清理**：依次调用 `AudioHardwareDestroyAggregateDevice`、`AudioHardwareDestroyProcessTap`。
  6. **权限被拒**：创建 Tap 或读到全零且返回权限相关错误时，抛出 `CaptureError.permissionDenied(.system)`。

- [ ] **Step 1：写集成测试**

  ```swift
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AUDIO_IT"] == "1"))
  func tapCapturesPlayback() async throws {
      // 用 Process 启动 `afplay /System/Library/Sounds/Submarine.aiff`，循环 3 次
      // 期间运行 Tap 3 秒，断言最大 chunk.level > 0.01
  }
  ```

- [ ] **Step 2：运行确认失败**
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**

  如果测试进程拿不到系统音频录制权限，到"系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统音频"里给终端授权后重跑。

- [ ] **Step 5：零干扰手工验证**

  播放音乐时运行测试。确认：
  - 耳机或扬声器里的音量、音质没有变化
  - 测试结束后系统输出设备列表中没有残留的聚合设备

  在提交信息里记录结论。

- [ ] **Step 6：提交** `feat(capture): 基于 Core Audio Process Tap 的系统音频源`

---

### Task 8：录音会话编排

**Files:**
- Create: `Sources/MotingRecording/RecordingSession.swift`
- Test: `Tests/MotingRecordingTests/RecordingSessionTests.swift`、`Tests/MotingRecordingTests/FakeAudioSource.swift`

**Interfaces:**
- Consumes:
  - Task 1：`Meeting`、`MeetingClock`、`Mark`
  - Task 2：`MeetingRepository`、`AppPaths`
  - Task 3：`PCMTrackWriter`
  - Task 5：`TrackAligner`
  - Task 6：`AudioSource`、`AudioSourceEvent`
- Produces:

  ```swift
  public enum RecordingState: Sendable, Equatable { case idle, recording, paused, stopped }
  public final class RecordingSession: @unchecked Sendable {
      public init(paths: AppPaths, repository: MeetingRepository,
                  sources: [AudioSource], now: @escaping @Sendable () -> Date = Date.init)
      public private(set) var meeting: Meeting?
      public var state: RecordingState { get }
      public func start() throws -> Meeting       // 建目录、插入会议（含两条 AudioTrackInfo）、启动所有源
      public func pause() throws                   // 写 pause 记录；暂停期间收到的 chunk 丢弃
      public func resume() throws
      public func addMark() throws -> Mark         // at = 会议时钟 elapsed
      public func stop() throws                    // 幂等：停源、关闭暂停、sync+close writer、状态 pendingProcessing
      public func elapsed() -> TimeInterval
      public var onEvent: (@Sendable (AudioChannel, AudioSourceEvent) -> Void)?   // 给 UI 电平和 P2 实时识别订阅
  }
  ```

  行为约定：
  - **写入**：每个 channel 一个 writer，所有写入都在会话内部的一个串行队列上执行。
  - **对齐**：每次写入前先用 `TrackAligner` 按当前时钟补静音，再写数据。
  - **定期落盘**：每 5 秒调用一次 `sync()`。
  - **启动失败**：任一源 `start()` 抛错时，停掉已启动的源，会议状态设为 `.failed`，然后重新抛出原错误。
  - **中途断开**：某个源回调 `.interrupted` 时，会话不停止，其他源照常写入；等它 `.resumed` 后，通过对齐器自然补齐静音。

- [ ] **Step 1：写 `FakeAudioSource`**

  - 可以手动 `emit(.chunk(...))` 发出事件
  - 可以设置 `startError`，让 `start()` 抛错
  - 记录 `stop()` 被调用的次数

- [ ] **Step 2：写失败测试**（`now` 用测试可控的时钟；`AppPaths` 指向临时目录）

  ```swift
  @Test func startCreatesMeetingAndFiles()       // 状态 recording，两条 track，emit 1600 样本后两个 .pcm 文件存在
  @Test func pausedChunksAreDropped()            // pause 后 emit → 文件样本数不变；resume 后 emit → 增加
  @Test func lateChunksArePadded()               // 时钟前进 1s 后 system 才首次 emit 1600 → system 样本数 ≈ 16000+1600
  @Test func markUsesMeetingTime()               // start，前进 10s，pause 5s，resume，前进 2s，addMark → at == 12
  @Test func stopIsIdempotentAndClosesPause()    // pause 后 stop 两次 → 状态 pendingProcessing，endedAt 非空，pauses 全部 end != nil，源 stop 各 1 次
  @Test func startFailureMarksMeetingFailed()    // system 源 startError = permissionDenied → start 抛错，会议状态 .failed，mic 源被 stop
  @Test func sourceFailureKeepsOtherTrack()      // mic emit .interrupted 后 system 继续写；mic .resumed 后再 emit，mic 样本数被补齐到与时钟一致（±200ms）
  ```

- [ ] **Step 3：运行确认失败** `swift test --filter MotingRecordingTests`
- [ ] **Step 4：实现**
- [ ] **Step 5：运行确认通过**
- [ ] **Step 6：提交** `feat(recording): 双路录音会话编排（暂停、标记、对齐、失败处理）`

---

### Task 9：崩溃恢复

**Files:**
- Create: `Sources/MotingRecording/RecordingRecovery.swift`
- Test: `Tests/MotingRecordingTests/RecordingRecoveryTests.swift`

**Interfaces:**
- Consumes: `MeetingRepository`、`AppPaths`、`PCMTrackReader`
- Produces:

  ```swift
  public enum RecordingRecovery {
      /// app 启动时调用：所有 status == .recording 的会议 → 修复 PCM、关闭未结束暂停、
      /// 状态改为 .interrupted，endedAt = startedAt + 最长一路时长 + 暂停总时长
      @discardableResult
      public static func run(repository: MeetingRepository, paths: AppPaths, now: Date) throws -> [UUID]
  }
  ```

- [ ] **Step 1：写失败测试**

  ```swift
  @Test func recoversInterruptedMeeting()
  // 构造：会议 .recording，mic.pcm 16001 字节（奇数），system.pcm 32000 字节，一条未结束的暂停
  // 断言：返回含该 id；状态 .interrupted；mic 文件 16000 字节；暂停已关闭；endedAt ≈ startedAt + 1s + 暂停时长
  @Test func leavesFinishedMeetingsAlone()   // .pendingProcessing 的会议不被改动
  @Test func missingTrackFileIsTolerated()   // 只有 mic.pcm，system.pcm 不存在 → 不抛错，正常恢复
  ```

- [ ] **Step 2：运行确认失败**
- [ ] **Step 3：实现**
- [ ] **Step 4：运行确认通过**
- [ ] **Step 5：提交** `feat(recording): 启动时恢复中断的录音`

---

### Task 10：App 外壳（菜单栏 + 最小会议列表）

**Files:**
- Modify: `App/Moting/MotingApp.swift`
- Create: `App/Moting/AppEnvironment.swift`、`App/Moting/RecordingController.swift`、`App/Moting/MenuBarContent.swift`、`App/Moting/MeetingListView.swift`

**Interfaces:**
- Consumes:
  - `RecordingSession`、`RecordingRecovery`
  - `MicSource`、`SystemAudioTapSource`
  - `MeetingRepository.observeAll()`、`AppPaths.default`
- Produces（P2 / P4 会扩展）：

  ```swift
  @MainActor final class AppEnvironment: ObservableObject {
      let paths: AppPaths; let repository: MeetingRepository
      static func bootstrap() throws -> AppEnvironment   // 打开数据库、跑 RecordingRecovery
  }
  @MainActor final class RecordingController: ObservableObject {
      @Published private(set) var state: RecordingState
      @Published private(set) var elapsed: TimeInterval        // 每 0.5s 刷新
      @Published private(set) var levels: [AudioChannel: Float]
      @Published var lastError: String?
      func start(); func pause(); func resume(); func mark(); func stop()
  }
  ```

  界面：
  - **菜单栏**：用 `MenuBarExtra`，图标为 `waveform`，录音中变为 `record.circle.fill`。菜单内容：
    - 空闲时：开始录音、打开 Moting、退出
    - 录音中：计时、两路电平文字、暂停 / 继续、★ 标记、结束录音
  - **主窗口** `MeetingListView`：列表，每行显示标题、开始时间、时长（`endedAt - startedAt`）、状态中文名。状态与中文名的对应：

    | 状态 | 中文名 |
    |---|---|
    | `recording` | 录音中 |
    | `pendingProcessing` | 待处理 |
    | `interrupted` | 录音中断 |
    | `processing` | 处理中 |
    | `done` | 完成 |
    | `failed` | 失败 |

  - **错误提示**：`lastError` 用 `.alert` 弹出。权限被拒时，提示文字里说明去"系统设置 → 隐私与安全性"的哪一项开启。

- [ ] **Step 1：实现上述文件**
- [ ] **Step 2：构建**

  Run: `cd App && xcodegen generate && xcodebuild -project Moting.xcodeproj -scheme Moting -configuration Debug build 2>&1 | tail -3`
  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3：端到端手工验证**

  启动 app，开始录音。依次：
  1. 用浏览器播放一段有人声的视频 20 秒，同时自己说话
  2. 暂停 5 秒
  3. 继续录 10 秒
  4. 点一次标记
  5. 结束录音

  然后检查：
  - 列表出现一条"待处理"的会议，时长约 35 秒
  - 两路时长一致（暂停的 5 秒不计入）：对两个文件分别运行 `ffprobe -f s16le -ar 16000 -ch_layout mono <file> 2>&1 | grep Duration`，两个 Duration 都约 30 秒，相差不超过 0.3 秒
  - 内容正确：`ffplay -f s16le -ar 16000 -ch_layout mono -autoexit <file>`，`mic.pcm` 能听到自己，`system.pcm` 能听到视频
  - 视频播放期间系统音量和音质没有变化

- [ ] **Step 4：崩溃恢复手工验证**

  录音中执行 `pkill -9 Moting`，再重新启动 app。该会议应显示为"录音中断"，文件可以正常播放。

- [ ] **Step 5：零干扰手工验证（会议软件）**

  用腾讯会议或钉钉开一个测试会议，同时运行 Moting 录音 2 分钟。确认：
  - 会议里对方听你的声音正常
  - 你听对方的声音音量正常
  - 两路文件都有内容

  把结论（包括"全局 Tap 是否录到了会议声音"）追加到 spec 第 8 节第 3、4 条下面。

- [ ] **Step 6：提交** `feat(app): 菜单栏录音控制与最小会议列表`
