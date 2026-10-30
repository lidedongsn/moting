import Foundation

/// 为 C 配置结构体提供在作用域内有效的 C 字符串，作用域结束时统一释放
final class CStringPool {
    private var owned: [UnsafeMutablePointer<CChar>] = []

    func c(_ s: String) -> UnsafePointer<CChar> {
        let p = strdup(s)!
        owned.append(p)
        return UnsafePointer(p)
    }

    deinit {
        owned.forEach { free($0) }
    }
}
