import Foundation

/// 界面文案：以中文为键，到 app 的 String Catalog 里查当前语言的翻译；找不到时就是中文本身。
/// 翻译都放在 App/Moting/Localizable.xcstrings，各个库共用这一份
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// 数据库里的说话人标签固定是中文（"我""对方""说话人 1"），大模型提示词也按这个约定；
/// 只有显示和导出时才换成当前语言。用户改过的真实姓名原样显示
public enum SpeakerLabel {
    public static let me = "我"
    public static let other = "对方"
    static let numberedPrefix = "说话人 "

    public static func display(_ raw: String) -> String {
        if raw == me { return L("我") }
        if raw == other { return L("对方") }
        if let n = number(in: raw) { return L("说话人 \(n)") }
        return raw
    }

    static func number(in raw: String) -> Int? {
        guard raw.hasPrefix(numberedPrefix) else { return nil }
        return Int(raw.dropFirst(numberedPrefix.count))
    }
}
