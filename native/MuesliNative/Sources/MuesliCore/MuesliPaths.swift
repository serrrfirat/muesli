import Foundation

public enum MuesliPaths {
    private static let runtimeRootLock = NSLock()
    nonisolated(unsafe) private static var runtimeRoot: URL?

    /// The native shell fixes its data root before constructing any service.
    /// Standalone core clients retain the ordinary default when unconfigured.
    public static func configureRuntimeSupportDirectory(_ directory: URL) throws {
        runtimeRootLock.lock()
        defer { runtimeRootLock.unlock() }
        let resolved = directory.standardizedFileURL
        if let runtimeRoot, runtimeRoot != resolved {
            throw NSError(domain: "MuesliPaths", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The native runtime data directory is already configured."
            ])
        }
        runtimeRoot = resolved
    }

    public static func defaultSupportDirectoryURL(appName: String = "Muesli") -> URL {
        runtimeRootLock.lock()
        let configuredRoot = runtimeRoot
        runtimeRootLock.unlock()
        if let configuredRoot { return configuredRoot }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public static func defaultDatabaseURL(appName: String = "Muesli") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("muesli.db")
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
    }
}
