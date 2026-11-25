# 第三方代码与依赖

本文件列出源码与构建入口中使用的主要第三方组件。各组件自身的许可文件和源文件头部声明应保留。

仓库根目录的 [MIT License](LICENSE) 适用于本项目的原创代码，不替代下列第三方组件及识别模型各自的许可。

| 组件 | 使用方式 | 许可文件位置 |
| --- | --- | --- |
| SpeexDSP | 部分 C 源码随仓库分发，用于回声消除 | [Sources/CSpeexDSP/COPYING](Sources/CSpeexDSP/COPYING) 及源文件头部 |
| GRDB.swift | Swift Package Manager 依赖 | [MIT 许可文本](docs/licenses/GRDB.swift-LICENSE) |
| Swift Atomics | Swift Package Manager 依赖 | [Apache License 2.0 许可文本](docs/licenses/swift-atomics-LICENSE.txt) |
| sherpa-onnx 及静态包内依赖 | `Scripts/fetch-sherpa-onnx.sh` 下载并合并静态库，本仓库不包含二进制包 | [上游 v1.13.8 许可](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/LICENSE)；包内依赖另见各自声明 |

Swift 包版本记录在 `Package.resolved`；sherpa-onnx 版本记录在 `Scripts/fetch-sherpa-onnx.sh`。

`docs/licenses/` 中的文本复制自当前锁定版本的依赖。升级依赖时应同步核对和更新这些文件。

识别模型在运行时另行下载，不随本仓库分发，其许可应以对应模型发布页及随附文件为准。分发编译后的应用时，还需整理随应用链接的组件及所附模型的完整许可声明；本索引不能替代那些许可文件。
