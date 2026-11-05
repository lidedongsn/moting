import Foundation

/// 系统音频录制权限。macOS 没有公开接口，这里用 TCC 框架的私有函数（只能用于 App Store 之外发布）；
/// 找不到函数时按"未决定"处理，真正录音时系统仍会询问
public enum SystemAudioPermission {
    public enum Status: Sendable { case granted, denied, undetermined }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private nonisolated(unsafe) static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// 弹出系统授权框；completion 在任意线程回调
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { completion($0) }
    }
}
