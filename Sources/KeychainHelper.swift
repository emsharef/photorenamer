import Foundation

/// File-based credential storage in ~/Library/Application Support/PhotoRenamer/
/// Used instead of the system Keychain because the app runs as an unsigned executable.
enum KeychainHelper {
    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PhotoRenamer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeAll(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) {
            // Set file permissions to owner-only read/write (0600)
            try? data.write(to: storageURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storageURL.path
            )
        }
    }

    static func save(account: String, password: String) {
        var dict = readAll()
        dict[account] = password
        writeAll(dict)
    }

    static func load(account: String) -> String? {
        readAll()[account]
    }

    static func delete(account: String) {
        var dict = readAll()
        dict.removeValue(forKey: account)
        writeAll(dict)
    }
}
