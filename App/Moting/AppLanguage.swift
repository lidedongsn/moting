import AppKit
import MotingCore

/// 界面语言。macOS 的做法是给 app 单独设置 AppleLanguages，启动时读取，所以切换后要重启
enum AppLanguage: String, CaseIterable {
    case system, zhHans, en

    static let key = "interfaceLanguage"
    /// 这次启动时生效的语言，和它不同时提示重启
    static let atLaunch = AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system

    /// 语言名用它自己的文字写，选错了也认得出来
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    func save() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .zhHans: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// 退出后由一个独立进程重新打开自己
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
