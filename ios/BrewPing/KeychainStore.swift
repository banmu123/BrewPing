import Foundation
import Security

/// 极简 Keychain 封装，只做「按 key 存/取/删一个字符串」。
///
/// 配对 token 必须放这里而不是 `UserDefaults`：
///  1. `UserDefaults` 是明文 plist，越狱/备份提取成本极低；
///  2. 顺带少一条 `NSPrivacyAccessedAPICategoryUserDefaults` 的声明理由。
///
/// 可访问性选 `AfterFirstUnlock`：WCSession 会在后台唤醒 App 来执行手表命令，
/// 那时设备是锁屏状态，用 `WhenUnlocked` 会直接读不到 token。
enum KeychainStore {
    private static let service = "com.brewping.ios.pairing"

    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func set(_ value: String?, forKey key: String) -> Bool {
        guard let value else { return delete(key) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
