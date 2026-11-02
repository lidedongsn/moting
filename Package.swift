// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotingKit",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MotingKit", targets: ["MotingCore", "MotingStorage", "MotingCapture", "MotingRecording", "MotingASR", "MotingPlayback", "MotingPipeline", "MotingDSP", "MotingSummary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-atomics", from: "1.2.0"),
    ],
    targets: [
        .target(name: "MotingCore"),
        .target(name: "MotingStorage", dependencies: ["MotingCore", .product(name: "GRDB", package: "GRDB.swift")]),
        // C 回调与严格并发检查冲突较多，采集层使用 Swift 5 语言模式
        .target(
            name: "MotingCapture",
            dependencies: ["MotingCore", .product(name: "Atomics", package: "swift-atomics")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "MotingRecording", dependencies: ["MotingCore", "MotingStorage", "MotingCapture"]),
        .target(
            name: "MotingPipeline",
            dependencies: ["MotingCore", "MotingStorage", "MotingCapture", "MotingASR"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // 捕获 AVFoundation 抛出的 Objective-C 异常（Swift 无法捕获）
        .target(name: "MotingObjCSupport"),
        .target(name: "MotingPlayback", dependencies: ["MotingCapture", "MotingObjCSupport"]),
        // sherpa-onnx 静态库由 Scripts/fetch-sherpa-onnx.sh 生成，不入库
        .binaryTarget(name: "CSherpaOnnx", path: "Vendor/CSherpaOnnx.xcframework"),
        // SpeexDSP 回声消除（BSD，源码入库，只编译用到的几个文件）
        .target(
            name: "CSpeexDSP",
            cSettings: [.define("FLOATING_POINT"), .define("USE_SMALLFT"), .define("EXPORT", to: "")]
        ),
        .target(name: "MotingDSP", dependencies: ["CSpeexDSP"]),
        // AI 纪要：OpenAI 兼容接口（默认 DeepSeek），提示词模板放在资源文件里
        .target(name: "MotingSummary", dependencies: ["MotingCore"], resources: [.process("Resources")],
                linkerSettings: [.linkedFramework("Security")]),
        .target(
            name: "MotingASR",
            dependencies: ["MotingCore", "MotingStorage", "MotingDSP", "CSherpaOnnx"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(name: "MotingCoreTests", dependencies: ["MotingCore"]),
        .testTarget(name: "MotingStorageTests", dependencies: ["MotingStorage"]),
        .testTarget(name: "MotingCaptureTests", dependencies: ["MotingCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MotingRecordingTests", dependencies: ["MotingRecording"]),
        .testTarget(name: "MotingPipelineTests", dependencies: ["MotingPipeline"]),
        .testTarget(name: "MotingPlaybackTests", dependencies: ["MotingPlayback", "MotingCapture", "MotingObjCSupport"]),
        .testTarget(name: "MotingDSPTests", dependencies: ["MotingDSP"]),
        .testTarget(name: "MotingSummaryTests", dependencies: ["MotingSummary"]),
        .testTarget(name: "MotingASRTests", dependencies: ["MotingASR", "MotingCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
