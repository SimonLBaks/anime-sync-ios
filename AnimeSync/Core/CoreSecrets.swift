import Foundation
import Security

protocol CoreSecrets {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data?, for key: String) throws
}

/// Device-only Keychain records never go into backups or the provider WebView.
final class KeychainSecrets: CoreSecrets {
    private let service: String
    init(service: String = "xyz.loibaks.animesync.companion") { self.service = service }
    private func query(_ key: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] }
    func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CoreError.message("Secure storage is unavailable") }
        return item as? Data
    }
    func write(_ data: Data?, for key: String) throws {
        let q = query(key)
        guard let data = data else { let status = SecItemDelete(q as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError.message("Could not clear secure storage") }; return }
        let update = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = q; update.forEach { create[$0.key] = $0.value }
            guard SecItemAdd(create as CFDictionary, nil) == errSecSuccess else { throw CoreError.message("Could not save credentials securely") }
        } else if status != errSecSuccess { throw CoreError.message("Could not save credentials securely") }
    }
}
