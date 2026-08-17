import Foundation
import Security

/// Stores API keys in the macOS Keychain. Keys never touch the repository,
/// UserDefaults, or any plaintext config file.
public enum KeychainStore {
    private static let service = "com.airtraffic.apikeys"

    public static func apiKey(for provider: ProviderKind) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setAPIKey(_ key: String, for provider: ProviderKind) -> Bool {
        deleteAPIKey(for: provider)
        guard !key.isEmpty else { return true }
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func deleteAPIKey(for provider: ProviderKind) -> Bool {
        SecItemDelete(baseQuery(provider) as CFDictionary) == errSecSuccess
    }

    /// Keychain first, environment variable as fallback.
    public static func resolveAPIKey(for provider: ProviderKind) -> String? {
        if let key = apiKey(for: provider), !key.isEmpty { return key }
        if let env = ProcessInfo.processInfo.environment[provider.apiKeyEnvName],
            !env.isEmpty
        {
            return env
        }
        return nil
    }

    private static func baseQuery(_ provider: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
