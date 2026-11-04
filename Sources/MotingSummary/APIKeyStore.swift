import Foundation
import MotingCore
import Security

/// API Key 存在钥匙串里（仅本机、解锁后可读，不随 iCloud 同步），不落盘到任何配置文件
public struct APIKeyStore: Sendable {
    /// 按 bundle id 区分：正式版是 com.lidedongsn.moting.summary，调试版和测试用自己的条目，碰不到正式版的密钥
    public static let `default` = APIKeyStore(service: "\(Bundle.main.bundleIdentifier ?? "com.lidedongsn.moting").summary")
    private let service: String

    public init(service: String) {
        self.service = service
    }

    /// 只查有没有，不取内容：不读出密钥，也不会触发系统的钥匙串授权弹窗
    public func contains(account: String) -> Bool {
        SecItemCopyMatching(base(account) as CFDictionary, nil) == errSecSuccess
    }

    public func read(account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// 删掉本 app 存的所有 Key（各家服务）
    public func deleteAll() throws {
        let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary
        // macOS 上一次只删匹配到的第一条，删到没有为止
        while true {
            let status = SecItemDelete(query)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        L("钥匙串操作失败：\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
    }
}
