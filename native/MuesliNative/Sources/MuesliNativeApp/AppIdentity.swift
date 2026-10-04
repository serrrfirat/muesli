import Foundation
import MuesliCore

public enum AppIdentity {
    private static let defaultName = "Hush"

    static var bundleName: String {
        stringValue(for: "CFBundleName") ?? defaultName
    }

    static var displayName: String {
        stringValue(for: "CFBundleDisplayName") ?? bundleName
    }

    static var marketingVersion: String {
        stringValue(for: "CFBundleShortVersionString") ?? "0.0.0"
    }

    static var supportDirectoryName: String {
        stringValue(for: "MuesliSupportDirectoryName") ?? "PrivateGranola"
    }

    /// One immutable launch root preserves vault/Keychain identities and keeps
    /// explicit verification and mock runs out of the user's production data.
    public static let supportDirectoryURL: URL = {
        let options = LaunchOptions()
        return (options.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(options.mock ? "PrivateGranola-Mock" : "PrivateGranola", isDirectory: true)).standardizedFileURL
    }()

    private static func stringValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
