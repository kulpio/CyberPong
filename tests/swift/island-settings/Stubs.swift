import Foundation

/// settings.json, in memory: nothing here reads or writes ~/.pong.
enum AppSettings {
    static var root: [String: Any] = [:]
    /// No file: IslandSettings' look at the file's date finds nothing to read again.
    static var path: String { NSTemporaryDirectory() + "island-settings-harness-no-settings.json" }

    static func load() -> [String: Any] { root }

    static func update(_ change: (inout [String: Any]) -> Void) {
        change(&root)
    }

    static func set(_ key: String, _ value: Any?) {
        update { r in
            if let value { r[key] = value } else { r.removeValue(forKey: key) }
        }
    }
}
