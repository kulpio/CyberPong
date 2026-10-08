import Foundation

// The few app symbols SetupCore.swift reaches for. loadJSON is a faithful copy of the real one
// (src/MenuBarApp.swift); log records; PairWriteLock is the real in-process lock.
//
// Pong.stateDir points at a TEMP DIR set by the harness. Never ~/.pong.

enum Pong {
    static var stateDirOverride = NSTemporaryDirectory() + "setup-harness-unset"
    static var stateDir: String { stateDirOverride }

    static var logLines: [String] = []

    static func log(_ msg: String) {
        logLines.append(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func loadJSON(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }
}

enum PairWriteLock {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
