# Moting 界面重设计 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按已确认的设计稿重做主窗口、悬浮字幕窗、菜单栏面板和设置窗口，并补上"存储"管理。

**Architecture:**
- **可测试的逻辑**（说话人配色、迷你声纹条、波形包络、会议分组 / 搜索、存储清单）放进各个包模块，用单元测试覆盖。
- **SwiftUI 视图**拆成小文件，放在 `App/Moting/UI/` 下，共享一套 `Theme`。
- 视图只做构建验证，最后用安装脚本装进 /Applications，交给用户看。

**Tech Stack:** SwiftUI（macOS 14.2+）、`MenuBarExtra(.window)`、`NavigationSplitView`、`Canvas`（画声纹带）、材质模拟玻璃效果。

**Spec:** `docs/superpowers/specs/2026-10-30-moting-ui-redesign.md`；设计稿 `docs/superpowers/design/2026-10-30-moting-ui.html`

**做完能看到 / 还看不到：**
- 能看到：设计稿里的全部 6 个画面，以及能真正删除文件的"存储"页。
- 还看不到：纪要页的 AI 内容（P4）；"识别模型"页的实测数字只填评测过的模型。

## Global Constraints

- 配色、字体、材质和画面布局以 spec 与设计稿为准。
- 不新增落盘位置：波形缓存只放内存；下载时 `URLSession.configuration.urlCache = nil`。
- 交给框架、会在后台线程回调的闭包必须标 `@Sendable`（P2 踩过的坑）。
- 每个任务结束都要能编译通过。界面交付前用 `Scripts/install-app.sh` 安装。
- 提交信息用中文，末尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。只提交到本地，不推送。

## Review Focus

1. **说话人很多**（6 人以上）：颜色循环使用，不崩溃；同一个人在侧栏、声纹带、转写稿、字幕窗里颜色一致。→ Task 1 `paletteCyclesAndIsStable`
2. **很长的会议**（2 小时）：声纹带只读一次轨道，并按固定的分桶数降采样，内存不随时长增长；切换会议时不卡界面（在后台计算）。→ Task 2 `envelopeHasFixedBins`
3. **会议没有转写内容 / 没有录音文件**：迷你条和声纹带显示为空的灰条，不报错。→ Task 1 `emptySegmentsGiveEmptyBar`、Task 2 `missingTrackGivesZeros`
4. **跨午夜、跨年分组**：用本地日历判断"今天 / 昨天 / 本周 / 更早"。→ Task 3 `groupsByLocalCalendar`
5. **存储清理不会误删在用的模型**：实时和离线当前选用的模型、必需的辅助模型都不算"未使用"。→ Task 4 `inUseModelsAreNeverUnused`

---

### Task 1：说话人配色与迷你声纹条

**Files:**
- Create: `Sources/MotingCore/SpeakerPalette.swift`
- Test: `Tests/MotingCoreTests/SpeakerPaletteTests.swift`

**Interfaces:**

```swift
public enum SpeakerKey: Hashable, Sendable { case me, other(String) }   // other 的标签，如 "说话人 1"；未分离时为 "对方"
public extension TranscriptSegment { var speakerKey: SpeakerKey { get } }
public enum SpeakerPalette {
    /// 0 = 我；1… = 其他人，按在会议里首次出现的顺序编号
    public static func indices(for segments: [TranscriptSegment]) -> [SpeakerKey: Int]
}
/// 迷你声纹条：把会议时长切成 bins 段，每段取说话最多的人；nil 表示无人说话
public enum SpeakingTimeline {
    public static func bins(_ segments: [TranscriptSegment], duration: TimeInterval, count: Int) -> [SpeakerKey?]
}
```

- [ ] **写测试**：
  - `paletteCyclesAndIsStable`：8 个说话人得到 0…8 的编号，同样的输入两次结果相同
  - `meIsAlwaysZero`
  - `emptySegmentsGiveEmptyBar`
  - `binsPickDominantSpeaker`
- [ ] **确认失败 → 实现 → 确认通过 → 提交** `feat(core): 说话人配色编号与迷你声纹条`

### Task 2：声纹带波形包络

**Files:**
- Create: `Sources/MotingCapture/WaveformEnvelope.swift`
- Test: `Tests/MotingCaptureTests/WaveformEnvelopeTests.swift`

**Interfaces:**

```swift
public enum WaveformEnvelope {
    /// 分块顺序读取 16k Int16 轨道，返回 bins 个 0–1 的峰值包络（按全轨道最大值归一化）
    public static func compute(_ url: URL, bins: Int) throws -> [Float]
}
```

- [ ] **写测试**：
  - `envelopeHasFixedBins`：3 秒和 30 秒的轨道都返回 bins 个值
  - `loudSectionIsHigher`
  - `missingTrackGivesZeros`：文件不存在时返回全 0，不抛错
- [ ] **确认失败 → 实现**（每次读 1 秒）**→ 确认通过 → 提交**

### Task 3：会议分组与搜索

**Files:**
- Create: `Sources/MotingCore/MeetingGrouping.swift`
- Modify: `Sources/MotingStorage/TranscriptRepository.swift`（`meetingIDs(matching:)`）
- Test: `Tests/MotingCoreTests/MeetingGroupingTests.swift`、`Tests/MotingStorageTests/TranscriptRepositoryTests.swift`

**Interfaces:**

```swift
public enum MeetingGroup: String, CaseIterable, Sendable { case today = "今天", yesterday = "昨天", thisWeek = "本周", earlier = "更早" }
public enum MeetingGrouping {
    public static func group(_ meetings: [Meeting], now: Date, calendar: Calendar) -> [(MeetingGroup, [Meeting])]
}
// TranscriptRepository
public func meetingIDs(matching text: String) throws -> Set<UUID>   // 任意版本里片段文字包含 text
```

- [ ] **写测试**：
  - `groupsByLocalCalendar`：用固定的日历和时区，覆盖跨午夜、周一边界
  - `searchFindsTranscriptText`
- [ ] **确认失败 → 实现 → 确认通过 → 提交**

### Task 4：存储清单

**Files:**
- Create: `Sources/MotingPipeline/StorageInventory.swift`
- Test: `Tests/MotingPipelineTests/StorageInventoryTests.swift`

**Interfaces:**

```swift
public struct StorageItem: Identifiable, Sendable { public var id: String; public var name: String; public var kind: Kind; public var bytes: Int64; public var inUse: Bool
    public enum Kind: Sendable { case recordings, realtimeModel, offlineModel, auxModel, other } }
public struct StorageReport: Sendable {
    public var items: [StorageItem]; public var total: Int64
    public var reclaimable: Int64 { get }       // 未使用模型合计
}
public enum StorageInventory {
    /// 只统计已下载的模型；realtimeID / offlineID 为当前选用；辅助模型一律算在用
    public static func scan(paths: AppPaths, store: ModelStore, realtimeID: String, offlineID: String) -> StorageReport
    public static func removeUnusedModels(_ report: StorageReport, store: ModelStore) throws
}
```

- [ ] **写测试**（在临时目录里伪造模型目录）：
  - `inUseModelsAreNeverUnused`
  - `reclaimableSumsUnused`
  - `removeUnusedKeepsInUse`
- [ ] **确认失败 → 实现 → 确认通过 → 提交**

### Task 5：主题与主窗口

**Files:**
- Create: `App/Moting/UI/Theme.swift`、`UI/Sidebar.swift`、`UI/MeetingRow.swift`、`UI/VoiceRibbon.swift`、`UI/DetailView.swift`、`UI/TranscriptList.swift`、`UI/MarksList.swift`、`UI/StorageCard.swift`
- Modify / 删除：旧的 `MeetingListView.swift`、`MeetingDetailView.swift`、`RecorderBar.swift`（逻辑迁移到新视图）

具体做法：
- **Theme**：颜色常量（浅色和深色）、`speakerColor(index:scheme:)`、玻璃卡片修饰器 `glassCard(radius:)`。
- **侧栏**：`List` 的侧栏样式，外层包一个圆角玻璃面板。会议行显示状态标签，迷你条用 `SpeakingTimeline` 的 60 个分桶来画。
- **声纹带**：用 `Canvas` 画上下两条轨道，"我"和对方的包络各算 180 个分桶，在后台 `Task` 里计算，按会议 id 缓存在内存。颜色按片段时间映射到说话人。★ 和播放头叠加在上面；点击或拖动用 `seek`。
- **工具栏**：用 `.toolbar`，录音按钮是胶囊样式，录音中显示计时和结束。

- [ ] **实现 → 构建 → 提交**

### Task 6：悬浮字幕窗重绘

- **Files:** `App/Moting/FloatingPanelView.swift`、`FloatingPanelController.swift`
- 改为圆角 18 的玻璃卡片，内高光加细描边；字幕的说话人名着色；胶囊态按设计稿；处理进度态加进度条。
- 窗口默认尺寸改为 330×220。
- [ ] **实现 → 构建 → 提交**

### Task 7：菜单栏面板

- **Files:** `App/Moting/MenuBarContent.swift`、`MotingApp.swift`
- `MenuBarExtra` 改为 `.menuBarExtraStyle(.window)`；录音中菜单栏的图标标签改为红点加计时文字。
- 增加全局快捷键 ⌥⌘R 开始 / 结束录音，用 Carbon 的 `RegisterEventHotKey`，不需要辅助功能权限。
- [ ] **实现 → 构建 → 提交**

### Task 8：设置重做与存储页

- **Files:** `App/Moting/Settings/` 下：`SettingsRoot.swift`、`GeneralPane.swift`、`ModelsPane.swift`、`SummaryPane.swift`、`VoicePane.swift`、`StoragePane.swift`、`DownloadPane.swift`；删除旧的 `SettingsView.swift`、`RealtimeSettingsView.swift`
- 设置窗口用 `NavigationSplitView`，左边是图标加名称的分栏。
- **识别模型页**：读取 `ModelCatalog` / `OfflineCatalog` 的 `benchmark` 字段。在 `StreamingModel` / `OfflineModel` 里新增 `public var benchmark: Benchmark?`，含 `cer` 和 `minutesPerHour`，值为会议测试集实测结果。
- **存储页**：用 `StorageInventory`，"删除全部数据"需要二次确认，删除后退出 app。
- **通用页**：两个设置项 `UserDefaults("pipeline.autoTranscribe")` 和 `("pipeline.batteryPolicy")`，在 `ProcessingModel` 里生效。
- 下载用的 `URLSession` 设置 `urlCache = nil`。
- [ ] **实现 → 构建 → 提交**

### Task 9：交付

- [ ] 全量 `swift test` 通过
- [ ] 运行 `Scripts/install-app.sh`
- [ ] 盘点磁盘占用，确认没有新增落盘位置
- [ ] 请用户看效果
