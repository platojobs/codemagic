import Foundation
import Security

/// token 存储抽象。业务代码只依赖协议，测试可注入内存实现。
protocol TokenStoring {
    func load() -> AnonymousSession?
    func save(_ session: AnonymousSession) throws
    func clear()
}

/// Keychain 实现：服务端 token 属于凭据，不能放 UserDefaults。
/// 使用 `kSecClassGenericPassword`，`kSecAttrAccessibleAfterFirstUnlock` 便于后台同步读取。
final class KeychainTokenStore: TokenStoring {
    private let service = "com.platojobs.codemagic.sync"
    private let account = "anonymous-session"

    func load() -> AnonymousSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let payload = try? JSONDecoder().decode(StoredSession.self, from: data),
              !payload.token.isEmpty
        else { return nil }
        return AnonymousSession(userID: payload.userID, token: payload.token)
    }

    func save(_ session: AnonymousSession) throws {
        clear()
        let payload = try JSONEncoder().encode(
            StoredSession(userID: session.userID, token: session.token)
        )
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: payload,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.sync("Keychain 写入失败（OSStatus \(status)）")
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct StoredSession: Codable {
        let userID: String
        let token: String
    }
}
