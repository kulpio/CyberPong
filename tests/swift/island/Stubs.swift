import AppKit

// The few app symbols the island's model files and the sliced types reach for. PongUI's time words
// are faithful copies of src/PongComponents.swift (run.sh checks their signatures are still there).
// AppSettings keeps settings.json in memory: nothing here reads or writes ~/.pong.

enum PongColor {
    static let you = NSColor.orange
    static let live = NSColor.cyan
    static let fail = NSColor.red
    static let textSecondary = NSColor.gray
    static let textTertiary = NSColor.darkGray
}

enum PongUI {
    static func ago(_ t: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard t > 0 else { return "" }
        let s = max(0, Int(now - t))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86_400 {
            let h = s / 3600, m = (s % 3600) / 60
            return m == 0 || h >= 6 ? "\(h) h ago" : "\(h) h \(m) min ago"
        }
        return dayStamp(t)
    }

    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    static func dayStamp(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

/// Which teams are up: the tests set it.
enum SchedulesPageView {
    static var runningTeams: Set<String> = []
}

enum TeamNames {
    static var names: [String: String] = [:]
    static func name(_ session: String) -> String { names[session] ?? session }
}

/// settings.json, in memory.
enum AppSettings {
    static var root: [String: Any] = [:]
    static var writes = 0
    /// No file: IslandSettings' look at the file's date finds nothing to read again.
    static var path: String { NSTemporaryDirectory() + "island-harness-no-settings.json" }

    static func load() -> [String: Any] { root }

    static func update(_ change: (inout [String: Any]) -> Void) {
        change(&root)
        root["updated"] = 1
        writes += 1
    }

    static func set(_ key: String, _ value: Any?) {
        update { r in
            if let value { r[key] = value } else { r.removeValue(forKey: key) }
        }
    }
}
