// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MotingKit",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "MotingKit", targets: ["MotingCore", "MotingStorage", "MotingCapture", "MotingRecording", "MotingASR", "MotingPlayback"]),
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
        .target(name: "MotingPlayback", dependencies: ["MotingCapture"]),
        // sherpa-onnx 静态库由 Scripts/fetch-sherpa-onnx.sh 生成，不入库
        .binaryTarget(name: "CSherpaOnnx", path: "Vendor/CSherpaOnnx.xcframework"),
        .target(
            name: "MotingASR",
            dependencies: ["MotingCore", "MotingStorage", "CSherpaOnnx"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(name: "MotingCoreTests", dependencies: ["MotingCore"]),
        .testTarget(name: "MotingStorageTests", dependencies: ["MotingStorage"]),
        .testTarget(name: "MotingCaptureTests", dependencies: ["MotingCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MotingRecordingTests", dependencies: ["MotingRecording"]),
        .testTarget(name: "MotingPlaybackTests", dependencies: ["MotingPlayback", "MotingCapture"]),
        .testTarget(name: "MotingASRTests", dependencies: ["MotingASR", "MotingCapture"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
