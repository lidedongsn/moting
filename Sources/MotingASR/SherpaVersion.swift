import CSherpaOnnx

/// 链接进来的 sherpa-onnx 版本号
public func sherpaOnnxVersion() -> String {
    String(cString: SherpaOnnxGetVersionStr())
}
