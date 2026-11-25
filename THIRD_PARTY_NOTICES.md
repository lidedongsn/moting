# 第三方代码与依赖

本文件列出源码与构建入口中使用的主要第三方组件。各组件自身的许可文件和源文件头部声明应保留。

仓库根目录的 [MIT License](LICENSE) 适用于本项目的原创代码，不替代下列第三方组件及识别模型各自的许可。

| 组件 | 使用方式 | 许可文件位置 |
| --- | --- | --- |
| SpeexDSP | 部分 C 源码随仓库分发，用于回声消除 | [版权与许可](docs/licenses/SpeexDSP-COPYING) 及源文件头部 |
| GRDB.swift | Swift Package Manager 依赖 | [MIT 许可文本](docs/licenses/GRDB.swift-LICENSE) |
| Swift Atomics | Swift Package Manager 依赖 | [Apache License 2.0 许可文本](docs/licenses/swift-atomics-LICENSE.txt) |
| sherpa-onnx | 固定版本 1.13.8 静态库，用于语音识别 | [许可文本](docs/licenses/sherpa-onnx-LICENSE) |
| ONNX Runtime | sherpa-onnx 包内的 1.28.2 静态库 | [许可](docs/licenses/onnxruntime-LICENSE)、[第三方声明](docs/licenses/onnxruntime-ThirdPartyNotices.txt) |
| Kaldi native fbank | 1.22.3，语音特征提取 | [许可文本](docs/licenses/kaldi-native-fbank-LICENSE) |
| Kaldi decoder | 0.3.0，解码 | [许可文本](docs/licenses/kaldi-decoder-LICENSE) |
| Kaldifst | 1.8.0，有限状态转换 | [许可文本](docs/licenses/kaldifst-LICENSE) |
| OpenFst | 1.8.5-2026-04-10，Kaldifst 依赖 | [许可声明](docs/licenses/openfst-COPYING) |
| KissFFT | 语音特征提取所用 FFT | [版权声明](docs/licenses/kissfft-COPYING)、[BSD 许可](docs/licenses/kissfft-BSD-3-Clause) |
| Simple SentencePiece | 0.7，分词 | [许可文本](docs/licenses/simple-sentencepiece-LICENSE) |

Swift 包版本记录在 `Package.resolved`；sherpa-onnx 版本记录在 `Scripts/fetch-sherpa-onnx.sh`。

许可文件的下载版本和来源记录在 [许可来源说明](docs/licenses/README.md)。升级依赖时应同步核对和更新这些文件。

识别模型在运行时另行下载，不随本仓库或当前安装包分发，其许可应以对应模型发布页及随附文件为准。下载包及应用资源中包含本索引和许可文本；本索引不能替代那些许可文件。
