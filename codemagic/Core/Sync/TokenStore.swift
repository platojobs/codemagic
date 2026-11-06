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
        let payload = try JSONEncoder().encode(
            StoredSession(userID: session.userID, token: session.token)
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先原地更新，失败再新增：刷新替换 token 时不会出现「先删后加」的空窗，
        // 并发读取要么看到旧 token、要么看到新 token。
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: payload] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AppError.sync(L10n.f("sync.keychain.failed", String(describing: updateStatus)))
        }
        var attributes = query
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = payload
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.sync(L10n.f("sync.keychain.failed", String(describing: status)))
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
