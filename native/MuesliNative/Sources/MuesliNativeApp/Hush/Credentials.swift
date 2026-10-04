import Foundation
import Security
import CryptoKit

struct Credentials {
    static func load(endpoint: URL) throws -> String {
        var query = baseQuery(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let bytes = result as? Data, let key = String(data: bytes, encoding: .utf8) else { throw AppError("Could not read inference key from Keychain (\(status))") }
        return key
    }
    static func save(_ key: String, endpoint: URL) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery(endpoint) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AppError("Could not update inference key (\(update))") }
        var query = baseQuery(endpoint)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError("Could not save inference key (\(status))") }
    }
    private static func baseQuery(_ endpoint: URL) -> [String: Any] {
        let origin = "\(endpoint.scheme?.lowercased() ?? "")://\(endpoint.host?.lowercased() ?? ""):\(endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80))"
        let account = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        // Preserve the service identity so existing inference credentials remain accessible.
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PrivateGranola.Inference", kSecAttrAccount as String: account]
    }
}
