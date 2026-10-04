import CryptoKit
import Foundation

/// Cryptographic identities shared by the vault and standalone encrypted-store clients.
public enum HushDatabaseEncryption {
    public static let keychainService = "PrivateGranola.Vault.v1"

    public static func keychainAccount(directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        var account = Data()
        account.reserveCapacity(64)
        for byte in digest {
            let high = byte >> 4
            let low = byte & 15
            account.append(high + (high < 10 ? 48 : 87))
            account.append(low + (low < 10 ? 48 : 87))
        }
        return String(decoding: account, as: UTF8.self)
    }

    /// Exposes only the domain-separated SQLCipher key, never the vault key itself.
    public static func deriveKey(vaultKey: SymmetricKey) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: vaultKey,
            salt: Data(keychainService.utf8),
            info: Data("Hush.Muesli.SQLCipher.v1".utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
