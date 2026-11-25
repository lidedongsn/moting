# 开发说明

欢迎通过 Issue 讨论问题和改进建议。提交较大修改前，请先说明使用场景、方案和影响范围，以便确认方向。

## 准备与构建

环境要求、依赖准备和应用运行步骤见 [README.md](README.md)。提交 `Package.resolved` 以保留 Swift 包解析版本；不要提交 `Vendor/`、`.build/` 或生成的 Xcode 工程。

修改 Xcode 工程配置时编辑 `App/project.yml`，然后在 `App/` 中运行 `xcodegen generate`。签名团队只填在被忽略的 `App/Local.xcconfig` 中。

## 验证

从仓库根目录运行：

```sh
swift test
```

同时验证应用目标可以编译：

```sh
(cd App && xcodegen generate)
xcodebuild -project App/Moting.xcodeproj -scheme Moting \
  -configuration Debug -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO build
```

[CI](.github/workflows/ci.yml) 在 Apple Silicon macOS runner 上执行默认测试，并编译 Debug 和 Release 应用目标。工作流只使用合成测试数据和空签名配置，不需要开发者证书、API Key 或真实会议数据。

真实设备、网络和数据集测试默认关闭。以下变量按需启用，运行前先阅读对应测试文件，确认所需模型、数据目录及权限：

| 环境变量 | 用途 |
| --- | --- |
| `MOTING_AUDIO_IT=1` | 麦克风、系统音频与真实录音集成测试 |
| `MOTING_ASR_IT=1` | 识别、说话人区分及流水线集成测试，部分测试会下载数据 |
| `MOTING_NET_IT=1` | 模型联网下载测试；可用 `MOTING_NET_MODELS` 指定模型 |
| `MOTING_HOTWORD_IT=1` | 热词编码集成测试 |
| `MOTING_ASR_BENCH=1` | 模型对比基准测试 |
| `MOTING_AEC_DIR` | 指向本机回声测试数据目录 |
| `MOTING_BENCH_DIR` | 指向本机会议基准数据目录 |

修改界面文案后，在已生成 Xcode 工程的前提下运行：

```sh
./Scripts/check-translations.sh
```

## 提交前检查

```sh
git config core.hooksPath Scripts/git-hooks
git diff --check
git status --short
```

Hook 会检查暂存文件名、文件大小，以及新增内容中的常见密钥和本机个人信息。它是辅助检查，不覆盖全部泄漏形式，也不会清除历史记录。

请勿提交会议音频、转写稿、数据库、个人声纹、模型、API Key 或签名材料。复现问题时优先使用合成数据；分享日志和截图前移除会议内容与个人信息。

提交说明应交代修改原因及验证结果。录音、权限、回放等依赖真实设备的修改，还应说明手动验证的 macOS 版本和音频设备。

## Pull Request

- 每个 PR 聚焦一个问题，说明触发条件、修改后的行为和验证结果。
- 变更公共行为时更新相关文档；修改界面时提供不含个人信息的截图。
- 为行为修复添加能够复现问题的回归测试；涉及真实设备的场景补充手动验证记录。
- 不要在 PR 中混入生成产物、无关格式修改或本机配置。

## 发布说明

本地安装脚本面向开发调试，不执行公证，也不生成面向用户分发的发布包。发布版本前应单独完成版本号确认、签名与公证、第三方许可核对，以及真实设备上的录音、权限和升级验证。
