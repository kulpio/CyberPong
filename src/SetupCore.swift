import Foundation

// The first-run setup's plumbing, without any window: settings.json (spec C2), the key files
// (C3), reading `pong doctor` (C4) and `pong keys status`, turning the graph runner on (C5) in
// plain words, the folders the AI CLIs live in, and keeping ~/bin/pong and the engine in
// ~/.pong/lib in step with this app (C9). Foundation only, so tests/swift/run-setup.sh can
// compile it on its own against a temp folder.

// MARK: - Files only their owner may read

enum SecureFile {
    /// Make `dir` (and any missing parents) and set it to `mode`. False when it can't be made.
    @discardableResult
    static func ensureDir(_ dir: String, mode: mode_t = 0o700) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir) {
            guard isDir.boolValue else { return false }
        } else {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: NSNumber(value: Int(mode))])
            } catch {
                return false
            }
        }
        return chmod(dir, mode) == 0
    }

    /// Write `data` to `path` so no reader ever sees a half-written file and nobody else can read
    /// it at any moment: a temp file is created at `mode` (O_EXCL, in the same folder), filled,
    /// flushed, then renamed over the old one. Never write-then-chmod.
    @discardableResult
    static func write(_ data: Data, to path: String, mode: mode_t = 0o600) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let tmp = dir + "/." + (path as NSString).lastPathComponent + ".tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { return false }
        var ok = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, base + off, buf.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        // the umask can only narrow `mode`; set it exactly before anyone can see the name
        if ok { ok = fchmod(fd, mode) == 0 }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        if ok { ok = rename(tmp, path) == 0 }
        if !ok { unlink(tmp) }
        return ok
    }

    @discardableResult
    static func writeJSON(_ path: String, _ dict: [String: Any], mode: mode_t = 0o600) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return write(data, to: path, mode: mode)
    }

    /// The permission bits of `path`, or nil when it isn't there.
    static func mode(_ path: String) -> mode_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }
}

// MARK: - settings.json (C2): the app is its only writer, the engine only reads it

enum AppSettings {
    static var path: String { Pong.stateDir + "/settings.json" }

    static func load() -> [String: Any] { Pong.loadJSON(path) }

    /// Read, change and write back under the app's settings lock, so two quick changes can't
    /// lose each other. Keys this build doesn't know are kept as they are; the file is 0600.
    static func update(_ change: (inout [String: Any]) -> Void) {
        PairWriteLock.withLock {
            var root = Pong.loadJSON(path)
            if root.isEmpty { setAsideIfUnreadable() }
            change(&root)
            root["updated"] = Date().timeIntervalSince1970
            SecureFile.writeJSON(path, root)
        }
    }

    /// A settings file that isn't JSON would be replaced by the next write and its keys lost:
    /// keep it beside the new one instead, so nothing the person set disappears without a trace.
    private static func setAsideIfUnreadable() {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
              (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil else { return }
        let aside = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.moveItem(atPath: path, toPath: aside)
        Pong.log("settings.json was not readable; kept it as \(aside)")
    }

    static func set(_ key: String, _ value: Any?) {
        update { root in
            if let value { root[key] = value } else { root.removeValue(forKey: key) }
        }
    }

    // MARK: Values, with the engine's defaults when a key is absent

    /// What the AIs call the person; "" when unset (the engine then says "the person").
    static var ownerName: String {
        ((load()["owner_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanName(_ raw: String) -> String {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(one.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    static func setOwnerName(_ raw: String) {
        let n = cleanName(raw)
        set("owner_name", n.isEmpty ? nil : n)
    }

    /// First-run setup finished or skipped.
    static var setupDone: Bool { load()["setup"] is [String: Any] }

    static func markSetupDone(at now: Date = Date()) {
        set("setup", ["version": 1, "completed_at": Int(now.timeIntervalSince1970)])
    }

    /// The AI and model the graph-planning chat runs on; nil = the catalog's lead policy.
    static var architect: (runtime: String, model: String)? {
        guard let a = load()["architect"] as? [String: Any],
              let rt = a["runtime"] as? String, !rt.isEmpty else { return nil }
        return (rt, (a["model"] as? String) ?? "")
    }

    /// nil runtime removes the key: the engine's own recommendation applies again.
    static func setArchitect(runtime: String?, model: String?) {
        guard let rt = runtime, !rt.isEmpty else { set("architect", nil); return }
        var a: [String: Any] = ["runtime": rt]
        if let m = model, !m.isEmpty { a["model"] = m }
        set("architect", a)
    }

    /// Absent = on.
    static func aiEnabled(_ runtime: String) -> Bool {
        let d = (load()["ai_enabled"] as? [String: Any]) ?? [:]
        return flag(d[runtime]) ?? true
    }

    static func setAIEnabled(_ runtime: String, _ on: Bool) {
        update { root in
            var d = (root["ai_enabled"] as? [String: Any]) ?? [:]
            d[runtime] = on
            root["ai_enabled"] = d
        }
    }

    /// "auto" or "ask"; nil when never chosen (the engine then asks, as before 2.0).
    static var seatPermissions: String? {
        let v = (load()["seat_permissions"] as? String) ?? ""
        return v == "auto" || v == "ask" ? v : nil
    }

    static func setSeatPermissions(auto: Bool) { set("seat_permissions", auto ? "auto" : "ask") }

    /// The setup's switch shows a value before anyone touches it: save that value the moment it is
    /// shown, so leaving by Skip, Back, Esc or quitting can't leave the engine on "ask" while the
    /// sheet said on. A choice already saved is never changed. True when it wrote.
    @discardableResult
    static func saveSeatPermissionsShown(auto: Bool) -> Bool {
        guard seatPermissions == nil else { return false }
        setSeatPermissions(auto: auto)
        return true
    }

    struct Limits: Equatable {
        var rideOut5h = true
        var weekStopPct = 97
        var helperAI = true
        var jev = true
        var perplexity = true
        var perplexityDailyUSD: Double = 15
    }

    static var limits: Limits { limits(from: load()) }

    static func limits(from root: [String: Any]) -> Limits {
        let d = (root["limits"] as? [String: Any]) ?? [:]
        var l = Limits()
        if let b = flag(d["ride_out_5h"]) { l.rideOut5h = b }
        if let n = number(d["week_stop_pct"]) { l.weekStopPct = max(0, min(100, Int(n.rounded()))) }
        if let b = flag(d["helper_ai"]) { l.helperAI = b }
        if let b = flag(d["jev"]) { l.jev = b }
        if let b = flag(d["perplexity"]) { l.perplexity = b }
        if let n = number(d["perplexity_daily_usd"]) { l.perplexityDailyUSD = max(0, n) }
        return l
    }

    /// One of the C2 `limits` keys.
    static func setLimit(_ key: String, _ value: Any) {
        update { root in
            var d = (root["limits"] as? [String: Any]) ?? [:]
            d[key] = value
            root["limits"] = d
        }
    }

    static var developer: Bool { flag(load()["developer"]) ?? false }

    static func flag(_ a: Any?) -> Bool? {
        if let b = a as? Bool { return b }
        if let n = a as? NSNumber { return n.boolValue }
        return nil
    }

    static func number(_ a: Any?) -> Double? {
        if a is Bool { return nil }
        if let n = a as? NSNumber { return n.doubleValue }
        if let s = a as? String { return Double(s) }
        return nil
    }
}

// MARK: - Keys (C3): one file each under <state>/secrets, written straight from the app

enum SetupKeys {
    enum Name: String, CaseIterable {
        case jev, perplexity

        var variable: String { self == .jev ? "TYPESAFE_API_KEY" : "PERPLEXITY_API_KEY" }
        var title: String { self == .jev ? "Jev key" : "Perplexity key" }
    }

    static var dir: String { Pong.stateDir + "/secrets" }
    static func path(_ n: Name) -> String { dir + "/\(n.rawValue).env" }

    /// The engine's own rule for a key (`settings.valid_key`): one token of 8 to 512 characters.
    static let minLength = 8

    /// A pasted key, cleaned: spaces, a surrounding pair of quotes and a pasted
    /// "TYPESAFE_API_KEY=" prefix come off. nil when what's left can't be a key, or when it is the
    /// other service's line ("PERPLEXITY_API_KEY=…" pasted into Jev's field).
    static func clean(_ raw: String, for n: Name) -> String? {
        guard otherService(raw, for: n) == nil else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("export ") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if let eq = s.firstIndex(of: "="), s[..<eq].trimmingCharacters(in: .whitespaces) == n.variable {
            s = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        guard s.count >= minLength, s.count <= 512 else { return nil }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\"'"))
        guard s.unicodeScalars.allSatisfy({ !bad.contains($0) && $0.isASCII }) else { return nil }
        return s
    }

    /// The service whose `NAME=` line was pasted into `n`'s field, when it isn't `n`'s own.
    static func otherService(_ raw: String, for n: Name) -> Name? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("export ") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let eq = s.firstIndex(of: "=") else { return nil }
        let name = s[..<eq].trimmingCharacters(in: .whitespaces)
        return Name.allCases.first { $0 != n && $0.variable == name }
    }

    /// Why a pasted key won't be saved, in plain words; nil when `clean` accepts it.
    static func problem(_ raw: String, for n: Name) -> String? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste the key first." }
        if let o = otherService(raw, for: n) {
            return "That's the \(o == .jev ? "Jev" : "Perplexity") key: paste it in its own field."
        }
        return clean(raw, for: n) == nil ? "That doesn't look like a key. Paste it again." : nil
    }

    static func fileText(_ n: Name, key: String) -> String { "\(n.variable)=\(key)\n" }

    /// Folder 0700, file 0600, written in one step. The key is never logged.
    static func save(_ n: Name, key: String) -> Bool {
        guard SecureFile.ensureDir(dir, mode: 0o700) else { return false }
        return SecureFile.write(Data(fileText(n, key: key).utf8), to: path(n), mode: 0o600)
    }

    /// Removes only the file Settings wrote; a key from anywhere else stays where it is.
    @discardableResult
    static func remove(_ n: Name) -> Bool {
        let p = path(n)
        guard FileManager.default.fileExists(atPath: p) else { return true }
        return unlink(p) == 0
    }

    static func hasSettingsFile(_ n: Name) -> Bool { FileManager.default.fileExists(atPath: path(n)) }
}

/// `pong keys status --json` (also inside `pong doctor --json`): set or not, and from where.
/// Never a prefix or a length.
struct KeysStatus: Equatable {
    struct Key: Equatable {
        var set = false
        var source = ""
        var enabled = true
    }

    var jev = Key()
    var perplexity = Key()
    /// False until the engine (or the app's own check of the files) has said anything.
    var known = false

    subscript(_ n: SetupKeys.Name) -> Key { n == .jev ? jev : perplexity }

    static func parse(_ obj: [String: Any]) -> KeysStatus {
        func key(_ a: Any?) -> Key {
            let d = (a as? [String: Any]) ?? [:]
            return Key(set: AppSettings.flag(d["set"]) ?? false,
                       source: (d["source"] as? String) ?? "",
                       enabled: AppSettings.flag(d["enabled"]) ?? true)
        }
        var k = KeysStatus()
        k.jev = key(obj["jev"])
        k.perplexity = key(obj["perplexity"])
        k.known = obj["jev"] != nil || obj["perplexity"] != nil
        return k
    }

    /// The app's own check when the engine can't answer: only the files Settings writes.
    static func fromFiles() -> KeysStatus {
        var k = KeysStatus()
        k.jev = Key(set: SetupKeys.hasSettingsFile(.jev), source: SetupKeys.hasSettingsFile(.jev) ? "settings" : "",
                    enabled: AppSettings.limits.jev)
        k.perplexity = Key(set: SetupKeys.hasSettingsFile(.perplexity),
                           source: SetupKeys.hasSettingsFile(.perplexity) ? "settings" : "",
                           enabled: AppSettings.limits.perplexity)
        k.known = true
        return k
    }

    /// Where a key in use came from: "from Settings", "from the environment", …; "" for a source
    /// this build doesn't know.
    static func fromWords(_ source: String) -> String {
        switch source {
        case "settings": return "from Settings"
        case "environment": return "from the environment"
        case "key_file": return "from a key file"
        case "legacy": return "from an older setup file"
        // the owner's own Mac only (`settings.perplexity_key`): the key given to Claude Code
        case "claude_connector": return "from Claude Code's Perplexity connector"
        default: return ""
        }
    }

    /// "Set · from Settings", "Not set".
    static func words(_ k: Key) -> String {
        guard k.set else { return "Not set" }
        let from = fromWords(k.source)
        return from.isEmpty ? "Set" : "Set · " + from
    }

    /// The note under a key's row after Remove, once the engine has looked again (`now`). Remove
    /// takes away only the file Settings saved: a key from anywhere else is still there, and the
    /// key's own switch is what stops CyberPong using it.
    static func afterRemove(_ n: SetupKeys.Name, removed: Bool, now k: Key) -> String {
        guard removed else { return "Couldn't remove the key." }
        guard k.set, k.source != "settings" else { return "Removed from Settings." }
        let service = n == .jev ? "Jev" : "Perplexity"
        let switchName = n == .jev ? "Jev second opinions" : "Perplexity web research"
        let from = fromWords(k.source).isEmpty ? "somewhere else" : fromWords(k.source)
        return k.enabled
            ? "Removed from Settings, but a \(service) key is still set \(from). Switching off “\(switchName)” stops CyberPong using it."
            : "Removed from Settings. A \(service) key is still set \(from), but “\(switchName)” is off, so CyberPong doesn't use it."
    }
}

// MARK: - `pong doctor --json` (C4)

struct DoctorReport: Equatable {
    struct Tool: Equatable {
        var ok = false
        var path = ""
        var version = ""
        var fix = ""
    }

    struct Runner: Equatable {
        var ok = false
        var installed = false
        /// nil = can't tell.
        var running: Bool?
        var lastBeat: Double?
    }

    struct AI: Equatable {
        var id = ""
        var label = ""
        var installed = false
        var path = ""
        /// nil = can't tell (Hermes, or a check that didn't answer).
        var signedIn: Bool?
        var plan = ""
        var enabled = true
        var login = ""
        var install = ""
    }

    var version = ""
    var python = Tool()
    var tmux = Tool()
    var brew = Tool()
    var launcher = Tool()
    var engine = Tool()
    var runner = Runner()
    var ais: [AI] = []
    var keys = KeysStatus()
    /// False when the app checked this Mac by itself because the engine couldn't run.
    var fromEngine = true
    /// Why the engine couldn't answer, in plain words ("" when it did).
    var problem = ""

    static let aiOrder = ["claude", "grok", "codex", "hermes"]

    static let knownLabels = ["claude": "Claude Code", "grok": "Grok Build", "codex": "Codex", "hermes": "Hermes"]

    /// Sign-in and install commands for when the engine can't say (C4's table).
    static let knownLogin = ["claude": "claude auth login", "grok": "grok login", "codex": "codex login", "hermes": "hermes login"]
    static let knownInstall = ["claude": "npm install -g @anthropic-ai/claude-code", "codex": "npm install -g @openai/codex"]

    func ai(_ id: String) -> AI? { ais.first { $0.id == id } }

    static func parse(_ obj: [String: Any]) -> DoctorReport {
        func str(_ a: Any?) -> String {
            if let s = a as? String { return s }
            if let n = a as? NSNumber, !(a is Bool) { return n.stringValue }
            return ""
        }
        func tool(_ a: Any?) -> Tool {
            let d = (a as? [String: Any]) ?? [:]
            return Tool(ok: AppSettings.flag(d["ok"]) ?? false, path: str(d["path"]), version: str(d["version"]), fix: str(d["fix"]))
        }
        var r = DoctorReport()
        r.version = str(obj["version"])
        r.python = tool(obj["python"])
        r.tmux = tool(obj["tmux"])
        r.brew = tool(obj["brew"])
        r.launcher = tool(obj["launcher"])
        r.engine = tool(obj["engine"])
        let rn = (obj["runner"] as? [String: Any]) ?? [:]
        r.runner = Runner(ok: AppSettings.flag(rn["ok"]) ?? false,
                          installed: AppSettings.flag(rn["installed"]) ?? false,
                          running: rn["running"] is NSNull ? nil : AppSettings.flag(rn["running"]),
                          lastBeat: AppSettings.number(rn["last_beat_s"]))
        let ais = (obj["ais"] as? [String: Any]) ?? [:]
        let ids = aiOrder.filter { ais[$0] != nil } + ais.keys.filter { !aiOrder.contains($0) }.sorted()
        r.ais = ids.map { id in
            let d = (ais[id] as? [String: Any]) ?? [:]
            let label = str(d["label"])
            return AI(id: id, label: label.isEmpty ? (knownLabels[id] ?? id) : label,
                      installed: AppSettings.flag(d["installed"]) ?? false,
                      path: str(d["path"]),
                      signedIn: d["signed_in"] is NSNull ? nil : AppSettings.flag(d["signed_in"]),
                      plan: str(d["plan"]),
                      enabled: AppSettings.flag(d["enabled"]) ?? true,
                      login: str(d["login"]).isEmpty ? (knownLogin[id] ?? "") : str(d["login"]),
                      install: str(d["install"]))
        }
        r.keys = KeysStatus.parse((obj["keys"] as? [String: Any]) ?? [:])
        return r
    }

    /// The same report as the pages show it: the runner's last beat changes on every check and is
    /// never shown, so it doesn't count as a change (a change redraws the page and its pop-ups).
    var forDisplay: DoctorReport {
        var c = self
        c.runner.lastBeat = nil
        return c
    }

    func sameForDisplay(_ other: DoctorReport?) -> Bool {
        guard let other else { return false }
        return other.forDisplay == forDisplay
    }

    /// An install hint is either a command to copy ("npm install -g …", "curl … | bash") or a
    /// sentence the engine wrote when there is no one-line installer ("See Grok Build's install
    /// page"). Commands start with a lower-case program name.
    static func installIsCommand(_ hint: String) -> Bool {
        guard let c = hint.trimmingCharacters(in: .whitespaces).unicodeScalars.first else { return false }
        return c.isASCII && CharacterSet.lowercaseLetters.contains(c)
    }

    /// "Max plan" from "max"; "" when the plan isn't known.
    static func planWords(_ plan: String) -> String {
        let p = plan.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return "" }
        let w = p.replacingOccurrences(of: "_", with: " ")
        return w.prefix(1).uppercased() + w.dropFirst() + " plan"
    }
}

// MARK: - This Mac's two permissions, and what is still to fix

/// Accessibility and Automation (Terminal), read by the app itself: the engine can't see either.
/// `read()` (SetupParts.swift) asks macOS; what its answers mean lives here.
struct MacChecks: Equatable {
    /// `unknown`: macOS can't say right now (it only answers while Terminal is running).
    enum Automation: Equatable { case allowed, denied, notAsked, unknown }
    var accessibility = false
    var automation: Automation = .unknown

    /// The last answer macOS actually gave about Automation.
    static let automationKey = "setup.automation.last"

    /// AEDeterminePermissionToAutomateTarget's status: 0 allowed, -1743 (errAEEventNotPermitted)
    /// denied, -1744 (errAEEventWouldRequireUserConsent) not asked yet. Anything else, mostly
    /// procNotFound (-600) while Terminal isn't running, means macOS can't say.
    static func automation(status: Int32) -> Automation {
        switch status {
        case 0: return .allowed
        case -1743: return .denied
        case -1744: return .notAsked
        default: return .unknown
        }
    }

    /// A real answer is remembered. When macOS can't say, the last real "allowed" or "denied"
    /// stands in, so a closed Terminal doesn't read as a missing permission (it is checked again
    /// the next time Terminal is running).
    static func settle(_ read: Automation, defaults: UserDefaults = .standard) -> Automation {
        let s = settle(read, last: defaults.string(forKey: automationKey))
        if let r = s.remember { defaults.set(r, forKey: automationKey) }
        return s.shown
    }

    /// The same, without the storage: what to show, and what to remember (nil: leave it).
    static func settle(_ read: Automation, last: String?) -> (shown: Automation, remember: String?) {
        switch read {
        case .unknown:
            switch last {
            case "allowed": return (.allowed, nil)
            case "denied": return (.denied, nil)
            default: return (.unknown, nil)
            }
        case .allowed: return (.allowed, "allowed")
        case .denied: return (.denied, "denied")
        case .notAsked: return (.notAsked, "notAsked")
        }
    }
}

/// "Is this Mac ready?" in words: what is still to fix, and what won't work if the person goes on.
enum MacReadiness {
    /// What still needs fixing, by name: "tmux", "the graph runner". Automation counts only when
    /// macOS said no or hasn't asked: "can't say" (Terminal closed) is not a gap.
    static func gaps(_ d: DoctorReport?, _ m: MacChecks) -> [String] {
        guard let d else { return [] }
        var out: [String] = []
        if !d.python.ok { out.append("Python") }
        if !d.tmux.ok { out.append("tmux") }
        if !(d.launcher.ok && d.engine.ok) { out.append("the pong command") }
        if !d.runner.ok { out.append("the graph runner") }
        if !m.accessibility { out.append("Accessibility") }
        if m.automation == .denied || m.automation == .notAsked { out.append("Automation") }
        return out
    }

    /// What doesn't work yet, for the line under the card: "no AI can start", …. `appHasEngine`:
    /// the app runs its own copy of the engine, so its pages load without the pong command; the
    /// AIs still need the command to report back.
    static func consequences(_ d: DoctorReport?, _ m: MacChecks, appHasEngine: Bool) -> [String] {
        guard let d else { return [] }
        var out: [String] = []
        if !d.python.ok { out.append("nothing can run until Python is there") }
        if !d.tmux.ok { out.append("no AI can start") }
        if d.python.ok && !(d.launcher.ok && d.engine.ok) {
            out.append(appHasEngine ? "your AIs can't report back or ask you anything"
                                    : "graphs and chats can't load, and your AIs can't report back")
        }
        if !d.runner.ok { out.append("graphs stop after their first step") }
        if !m.accessibility { out.append("terminal windows stay where they are") }
        if m.automation == .denied { out.append("team windows won't open in Terminal") }
        return out
    }

    /// The pong command row's line when it is missing.
    static func launcherLine(appHasEngine: Bool) -> String {
        appHasEngine
            ? "Missing: your AIs use it to report back and to ask you questions. Fix puts it in your home folder."
            : "Missing: graphs and chats can't load, and your AIs can't report back. Fix puts it in your home folder."
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    /// The note under step 1 when going on leaves something not working.
    static func continueNote(_ effects: [String]) -> String {
        guard !effects.isEmpty else { return "" }
        return "If you continue now, " + list(effects) + ". Help › Set up CyberPong… brings this check back any time."
    }

    /// The note under Settings › This Mac while something there doesn't work yet.
    static func untilFixedNote(_ effects: [String]) -> String {
        guard !effects.isEmpty else { return "" }
        return "Until they're fixed, " + list(effects) + "."
    }
}

// MARK: - The graph runner: turning it on, in plain words

enum RunnerInstall {
    static let label = "com.cyberpong.runtime"

    /// The runner's launchd file; `pong doctor` says "installed" when it is there.
    static func plistPath(home: String) -> String { home + "/Library/LaunchAgents/\(label).plist" }

    /// Where the words are read: beside this Mac's rows (setup step 1, Settings › This Mac), or
    /// anywhere else (New graph, the launch question), where they also say where those rows are.
    enum Place { case rows, elsewhere }

    static let on = "The graph runner is on."
    static let preview = "This is a preview: it never turns this Mac's graph runner on."

    static func noPython(_ place: Place) -> String {
        place == .rows
            ? "Install Apple's command line tools first: the graph runner needs Python."
            : "Install Apple's command line tools first (Settings › This Mac): the graph runner needs Python."
    }

    /// `pong runtime install-agent --json`'s answer, for the person. The engine's refusals have plain
    /// words of their own; anything else (launchctl's output, an exception) is for the log only.
    static func words(code: Int32, out: String, err: String, place: Place) -> (ok: Bool, words: String) {
        let reply = (out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        if AppSettings.flag(reply?["ok"]) == true { return (true, on) }
        switch (reply?["reason"] as? String) ?? "" {
        case "no_engine":
            return (false, place == .rows
                ? "CyberPong's engine isn't in place yet. Press Fix on “The pong command” first, then Turn on."
                : "CyberPong's engine isn't in place yet. Press Fix on “The pong command” in Settings › This Mac, then Turn on.")
        case "not_this_home":
            return (false, "This copy of CyberPong is looking at a test folder: it leaves this Mac's graph runner alone.")
        default:
            break
        }
        // the app's own refusal (no Python, no engine) or the launcher's one line is already a sentence
        let lines = err.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if code == 127, reply == nil, lines.count == 1, var line = lines.first, line.hasSuffix("."), line.count <= 200 {
            if line.hasPrefix("pong: ") { line = String(line.dropFirst(6)) }
            return (false, line)
        }
        return (false, "Couldn't turn the graph runner on. Try again in a moment.")
    }

    /// At launch, for someone past the first-run setup (whose step 1 has the runner's row): ask
    /// once whether to turn the runner on while it isn't installed. Once it is installed again
    /// the question is forgotten, so losing it later asks again. `remember`: nil leaves it.
    static func launchQuestion(installed: Bool, asked: Bool) -> (ask: Bool, remember: Bool?) {
        if installed { return (false, asked ? false : nil) }
        return asked ? (false, nil) : (true, true)
    }
}

// MARK: - Where the AI CLIs live (the engine's `models.cli_dirs()`)

/// An app opened from the Finder gets a bare PATH. The engine searches these folders for the AI
/// CLIs and the `node` an npm-installed one runs on (python/pong/models.py `cli_dirs`); the app
/// searches the same ones, so it finds the same AIs.
enum CLIDirs {
    /// The engine's MANAGER_DIRS: volta, bun, an npm prefix, pnpm, Claude Code's own local install,
    /// and the shims of mise and asdf, under the home folder.
    static let managers = [".volta/bin", ".bun/bin", ".npm-global/bin", "Library/pnpm", ".claude/local",
                           ".local/share/mise/shims", ".asdf/shims"]

    /// The five the app has always put first, in its own order; always listed, there or not.
    static func base(home: String) -> [String] {
        ["\(home)/.grok/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/bin"]
    }

    /// "v22.11.0" → [22, 11, 0]: the first three numbers.
    static func versionKey(_ name: String) -> [Int] {
        let nums = name.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
        return nums.isEmpty ? [0] : nums
    }

    private static func newer(_ a: String, _ b: String) -> Bool {
        let x = versionKey(a), y = versionKey(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : -1, q = i < y.count ? y[i] : -1
            if p != q { return p > q }
        }
        return false
    }

    /// nvm's node versions' bin folders, newest first, with the one nvm's `default` alias names
    /// ahead of them: the node a new Terminal window runs.
    static func nvm(home: String, nvmDir: String?) -> [String] {
        let root = (nvmDir?.isEmpty == false ? nvmDir! : home + "/.nvm")
        let base = root + "/versions/node"
        let fm = FileManager.default
        var names = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).filter { n in
            var dir: ObjCBool = false
            return fm.fileExists(atPath: "\(base)/\(n)/bin", isDirectory: &dir) && dir.boolValue
        }
        names.sort(by: newer)
        var alias = ((try? String(contentsOfFile: root + "/alias/default", encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if alias.hasPrefix("v") { alias.removeFirst() }
        let parts = alias.split(separator: ".", omittingEmptySubsequences: false)
        if (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           let i = names.firstIndex(where: { n in
               let v = n.hasPrefix("v") ? String(n.dropFirst()) : n
               return v == alias || v.hasPrefix(alias + ".")
           }) {
            names.insert(names.remove(at: i), at: 0)
        }
        return names.map { "\(base)/\($0)/bin" }
    }

    /// The folders the person's login shell adds for the AI CLIs, as the engine last cached them
    /// (`<state>/cli-path.json`: {"dirs": [...], "at": …}). Absolute paths only.
    static func loginShell(_ cliPathFile: String) -> [String] {
        let obj = (FileManager.default.contents(atPath: cliPathFile)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        return ((obj?["dirs"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { $0.hasPrefix("/") }
    }

    /// Characters that would end or run something inside the `export PATH="…"` line of the
    /// Terminal scripts the app writes (sign-ins, installs): a folder holding one is left out.
    static let unsafeInShell = CharacterSet(charactersIn: "\"$`\\\n\r")

    /// The whole list, in the engine's order after the first five: nvm, the managers, then the
    /// login shell's. Besides the first five, only folders that are there; no repeats, and none
    /// whose name the Terminal scripts' PATH line can't hold as it is.
    static func list(home: String, cliPathFile: String, nvmDir: String? = nil) -> [String] {
        var out = base(home: home)
        let fm = FileManager.default
        for d in nvm(home: home, nvmDir: nvmDir) + managers.map({ "\(home)/\($0)" }) + loginShell(cliPathFile) {
            var dir: ObjCBool = false
            guard !d.isEmpty, !d.contains(":"), d.rangeOfCharacter(from: unsafeInShell) == nil, !out.contains(d),
                  fm.fileExists(atPath: d, isDirectory: &dir), dir.boolValue else { continue }
            out.append(d)
        }
        return out
    }
}

// MARK: - Which AIs can run the graph-planning chat

enum PlanningAI {
    /// The engine starts the planning chat on these only (`architect.ARCHITECT_RUNTIMES`): Hermes
    /// takes no first message on its command line, so `architect new` refuses it in plain words.
    static let runtimes = ["claude", "grok", "codex"]

    /// New graph's first AI and Model items, which pass nothing to the engine: it runs the saved
    /// default (`isDefault`) or its recommendation. The AI item names only the AI, so it fits its
    /// pop-up; the Model item names the model. Both say the same thing: never "AI: recommended"
    /// beside "Model: your default". `first` nil: nothing known yet.
    static func newGraphTitles(_ first: (ai: String, model: String, isDefault: Bool)?) -> (ai: String, model: String) {
        guard let f = first, !f.ai.isEmpty else { return ("AI: recommended", "Model: recommended") }
        let which = f.isDefault ? "your default" : "recommended"
        return ("AI: \(f.ai) (\(which))", f.model.isEmpty ? "Model: \(which)" : "Model: \(f.model)")
    }

    /// Why `rt` can't run the planning chat on this Mac ("off", "not installed", "can't plan
    /// graphs"), or nil when it can. `installed` nil = the check hasn't answered yet.
    static func blocker(_ rt: String, available: [String], enabled: Bool, installed: Bool?) -> String? {
        if !runtimes.contains(rt) { return "can't plan graphs" }
        if !enabled { return "off" }
        if installed == false || !available.contains(rt) { return "not installed" }
        return nil
    }

    /// The AIs to offer for planning: in the catalog, switched on, installed (when the check says),
    /// able to plan; signed-in ones first, then the usual order.
    static func offer(available: [String], enabled: (String) -> Bool, installed: Set<String>?,
                      signedIn: Set<String>) -> [String] {
        let order = DoctorReport.aiOrder
        func rank(_ rt: String) -> (Int, Int) {
            (signedIn.contains(rt) ? 0 : 1, order.firstIndex(of: rt) ?? order.count)
        }
        return available.filter { rt in
            blocker(rt, available: available, enabled: enabled(rt),
                    installed: installed.map { $0.contains(rt) }) == nil
        }.sorted { rank($0) < rank($1) }
    }
}

/// The AI a new team's lead starts on (New team): one that is on and signed in, Claude first;
/// else one that is on and installed; else Claude, the one the setup says to install first.
enum TeamLead {
    static func pick(_ order: [String], enabled: (String) -> Bool, signedIn: (String) -> Bool,
                     installed: (String) -> Bool?) -> String {
        let on = order.filter(enabled)
        if let s = on.first(where: signedIn) { return s }
        if let i = on.first(where: { installed($0) == true }) { return i }
        return order.contains("claude") ? "claude" : (order.first ?? "claude")
    }
}

// MARK: - Checking again while someone is looking

/// Who asked for `pong doctor` to be re-run, and how often: the shortest interval wins. Asking
/// again with the same owner (every redraw does) neither restarts the clock nor runs a check:
/// only a new owner gets one at once.
struct PollSchedule {
    private(set) var owners: [ObjectIdentifier: TimeInterval] = [:]

    var interval: TimeInterval? { owners.values.min() }

    /// - Returns: whether the interval changed (restart the clock) and whether this owner is new
    ///   (check at once).
    mutating func add(_ owner: ObjectIdentifier, every seconds: TimeInterval) -> (changed: Bool, isNew: Bool) {
        let before = interval
        let isNew = owners[owner] == nil
        owners[owner] = seconds
        return (interval != before, isNew)
    }

    /// - Returns: whether the interval changed.
    @discardableResult
    mutating func remove(_ owner: ObjectIdentifier) -> Bool {
        let before = interval
        owners.removeValue(forKey: owner)
        return interval != before
    }
}

// MARK: - The engine in ~/.pong/lib and the ~/bin/pong command (C9)

enum EngineVersion {
    /// `__version__` from a pong package folder's __init__.py.
    static func read(packageDir: String) -> String? {
        guard let text = try? String(contentsOfFile: packageDir + "/__init__.py", encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("__version__") else { continue }
            let parts = t.components(separatedBy: CharacterSet(charactersIn: "\"'"))
            if parts.count >= 2, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    /// -1, 0 or 1. "2.0.0-alpha" < "2.0.0" < "2.0.1" < "2.1".
    static func compare(_ a: String, _ b: String) -> Int {
        func split(_ v: String) -> ([Int], String) {
            let t = v.trimmingCharacters(in: .whitespaces).lowercased()
            let core = t.split(separator: "-", maxSplits: 1).first.map(String.init) ?? t
            let pre = t.count > core.count ? String(t.dropFirst(core.count + 1)) : ""
            return (core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }, pre)
        }
        let (ca, pa) = split(a), (cb, pb) = split(b)
        for i in 0..<max(ca.count, cb.count) {
            let x = i < ca.count ? ca[i] : 0, y = i < cb.count ? cb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if pa == pb { return 0 }
        if pa.isEmpty { return 1 }      // a release is newer than its own pre-release
        if pb.isEmpty { return -1 }
        return pa < pb ? -1 : 1
    }

    /// key=value lines (INSTALL_STAMP, BUILD_STAMP).
    static func stamp(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

enum EngineInstall {
    /// What install-control-plane.sh writes to ~/bin/pong, to the byte (tests/swift/run-setup.sh
    /// compares the two). On a Mac without Apple's command line tools /usr/bin/python3 is only a
    /// stub that pops an install dialog: the launcher says so in one line instead of running it,
    /// by the app's own rule (LocalChecks.pythonPath: Apple's python3 counts once the tools are in).
    static let launcherText = """
    #!/usr/bin/env bash
    export PYTHONPATH="${HOME}/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
    # Apple's /usr/bin/python3 is only a stub until the command line tools are installed: say so instead.
    if [ "$(command -v python3)" = /usr/bin/python3 ] && [ ! -d "$(/usr/bin/xcode-select -p 2>/dev/null)" ]; then
      echo "pong: Python isn't installed yet. Install Apple's command line tools (xcode-select --install), then try again." >&2
      exit 127
    fi
    exec python3 -m pong.cli.main "$@"

    """

    /// Launchers the app and install-control-plane.sh wrote before, to the byte: replaced by the
    /// one above when found (they run Apple's stub). Anything else at ~/bin/pong is never touched.
    static let olderLauncherTexts = [
        """
        #!/usr/bin/env bash
        export PYTHONPATH="${HOME}/.pong/lib${PYTHONPATH:+:$PYTHONPATH}"
        exec python3 -m pong.cli.main "$@"

        """,
    ]

    /// The INSTALL_STAMP `source` of a copy this app put there.
    static let appSource = "CyberPong.app"

    static func launcherPath(home: String) -> String { home + "/bin/pong" }

    enum LauncherState: Equatable {
        case missing, ready
        /// A link whose file isn't there (a checkout on a drive that isn't mounted yet).
        case danglingLink
        /// Something that isn't a program the shell can run.
        case notRunnable
    }

    /// What is at ~/bin/pong, looked at without following a link (lstat): a link whose file is
    /// missing is still the person's own link, not an empty place.
    static func launcherState(home: String) -> LauncherState {
        let p = launcherPath(home: home)
        var st = stat()
        guard lstat(p, &st) == 0 else { return .missing }
        if FileManager.default.isExecutableFile(atPath: p) { return .ready }
        if (st.st_mode & S_IFMT) == S_IFLNK, stat(p, &st) != 0 { return .danglingLink }
        return .notRunnable
    }

    /// A plain file holding one of `olderLauncherTexts` exactly (a link is the person's own).
    static func isOlderLauncher(home: String) -> Bool {
        let p = launcherPath(home: home)
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              let data = FileManager.default.contents(atPath: p), data.count < 4096,
              let text = String(data: data, encoding: .utf8) else { return false }
        return olderLauncherTexts.contains(text)
    }

    /// Write ~/bin/pong when nothing is there at all (mode 0755). True when there is a working one
    /// afterwards. Anything already there, a dangling link included, is never touched: it may be
    /// the owner's own. The one exception is an older launcher of ours, to the byte: it is brought
    /// up to `launcherText`, which is safe with or without Python. `create` false (no usable Python
    /// on this Mac yet) writes no new one: a `pong` command that can't run helps nobody.
    @discardableResult
    static func ensureLauncher(home: String, create: Bool = true) -> Bool {
        let state = launcherState(home: home)
        let p = launcherPath(home: home)
        if state == .ready, isOlderLauncher(home: home) {
            let ok = SecureFile.write(Data(launcherText.utf8), to: p, mode: 0o755)
            Pong.log(ok ? "setup: updated \(p) to the launcher that checks for Python" : "setup: could not update \(p)")
            return true     // runnable before, and still runnable if the write failed
        }
        guard state == .missing else { return state == .ready }
        guard create else { return false }
        try? FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        let ok = SecureFile.write(Data(launcherText.utf8), to: p, mode: 0o755)
        Pong.log(ok ? "setup: wrote \(p)" : "setup: could not write \(p)")
        return ok
    }

    /// Copy each of the app's graph-kit files over its installed copy (0755, one file at a time,
    /// as install-control-plane.sh does). Files the app doesn't carry, like the owner's own tools,
    /// stay where they are. True when every file was copied.
    @discardableResult
    static func copyKit(from src: String, to dest: String) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: src) else { return false }
        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        var ok = true
        for name in names.sorted() where !name.hasPrefix(".") {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: src + "/" + name, isDirectory: &dir), !dir.boolValue,
                  let data = fm.contents(atPath: src + "/" + name) else { continue }
            if !SecureFile.write(data, to: dest + "/" + name, mode: 0o755) { ok = false }
        }
        return ok
    }

    /// Whether one of the app's graph-kit files is missing from the installed kit.
    static func kitIncomplete(src: String, dest: String) -> Bool {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: src)) ?? []).filter { !$0.hasPrefix(".") }
        return names.contains { !fm.fileExists(atPath: dest + "/" + $0) }
    }

    enum Decision: Equatable {
        case seed(String)
        case keep(String)

        var seeds: Bool { if case .seed = self { return true }; return false }
    }

    /// Whether to copy the app's engine over the installed one. Never a downgrade: a newer
    /// engine stays. At the same version only a copy this app made from another build is
    /// replaced; one installed from a checkout (the owner's own) is left alone.
    static func decide(installedVersion: String?, installedStamp: [String: String],
                       bundleVersion: String?, bundleBuild: String) -> Decision {
        guard let bv = bundleVersion, !bv.isEmpty else { return .keep("the app carries no engine") }
        guard let iv = installedVersion, !iv.isEmpty else { return .seed("no engine installed") }
        let c = EngineVersion.compare(iv, bv)
        if c > 0 { return .keep("the installed engine \(iv) is newer than the app's \(bv)") }
        if c < 0 { return .seed("the installed engine \(iv) is older than the app's \(bv)") }
        if installedStamp["source"] == appSource, (installedStamp["build"] ?? "") != bundleBuild {
            return .seed("same version \(bv), another build of the app")
        }
        return .keep("the installed engine is the app's \(bv)")
    }

    /// The bundle's build id: BUILD_STAMP's built_at (written by build-app.sh), else the
    /// package's own modification time.
    static func bundleBuild(bundlePackage: String) -> String {
        let s = EngineVersion.stamp(bundlePackage + "/BUILD_STAMP")
        if let b = s["built_at"], !b.isEmpty { return b }
        let attrs = try? FileManager.default.attributesOfItem(atPath: bundlePackage + "/__init__.py")
        let t = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "mtime-\(Int(t))"
    }

    /// Copy `src` to `dest` with no moment where `dest` is half there: copy beside it, then
    /// swap the names. Bytecode is left behind (it embeds absolute paths and goes stale).
    @discardableResult
    static func swapIn(_ src: String, _ dest: String, extra: [String: String] = [:]) -> Bool {
        let fm = FileManager.default
        let parent = (dest as NSString).deletingLastPathComponent
        let name = (dest as NSString).lastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let staging = parent + "/.\(name)-new-\(getpid())"
        let old = parent + "/.\(name)-old-\(getpid())"
        try? fm.removeItem(atPath: staging)
        try? fm.removeItem(atPath: old)
        do { try fm.copyItem(atPath: src, toPath: staging) } catch {
            Pong.log("setup: copy \(src) failed: \(error.localizedDescription)")
            return false
        }
        if let e = fm.enumerator(atPath: staging) {
            var junk: [String] = []
            for case let rel as String in e {
                let base = (rel as NSString).lastPathComponent
                if base == "__pycache__" || base.hasSuffix(".pyc") { junk.append(rel) }
            }
            for rel in junk { try? fm.removeItem(atPath: staging + "/" + rel) }
        }
        for (file, text) in extra {
            try? text.write(toFile: staging + "/" + file, atomically: true, encoding: .utf8)
        }
        let had = fm.fileExists(atPath: dest)
        if had, rename(dest, old) != 0 {
            try? fm.removeItem(atPath: staging)
            return false
        }
        if rename(staging, dest) != 0 {
            if had { _ = rename(old, dest) }
            try? fm.removeItem(atPath: staging)
            return false
        }
        if had { try? fm.removeItem(atPath: old) }
        return true
    }

    struct Outcome: Equatable {
        var launcher = false
        var decision: Decision = .keep("")
        var seeded = false
        var kitSeeded = false
    }

    /// The whole launch-time check: the ~/bin/pong command, the engine in <state>/lib/pong (the
    /// app's own folder, replaced whole) and the app's files in <state>/lib/graph-kit (copied one
    /// by one: other files there stay). `kickstart` runs only after a re-seed. `writeLauncher`
    /// false (no usable Python yet) leaves a missing ~/bin/pong missing.
    static func refresh(home: String, stateDir: String, bundleResources: String?, writeLauncher: Bool = true,
                        now: Date = Date(), kickstart: (() -> Void)? = nil) -> Outcome {
        var out = Outcome()
        out.launcher = ensureLauncher(home: home, create: writeLauncher)
        guard let res = bundleResources else {
            out.decision = .keep("no app bundle")
            return out
        }
        let lib = stateDir + "/lib"
        let bundlePkg = res + "/python/pong"
        let installedPkg = lib + "/pong"
        let bv = EngineVersion.read(packageDir: bundlePkg)
        let build = bundleBuild(bundlePackage: bundlePkg)
        out.decision = decide(installedVersion: EngineVersion.read(packageDir: installedPkg),
                              installedStamp: EngineVersion.stamp(installedPkg + "/INSTALL_STAMP"),
                              bundleVersion: bv, bundleBuild: build)
        if out.decision.seeds, let bv {
            let iso = ISO8601DateFormatter().string(from: now)
            let stamp = "version=\(bv)\nsource=\(appSource)\nbuild=\(build)\ninstalled_at=\(iso)\n"
            out.seeded = swapIn(bundlePkg, installedPkg, extra: ["INSTALL_STAMP": stamp])
            Pong.log("setup: engine \(out.seeded ? "refreshed" : "NOT refreshed") — \(out.decision)")
        }
        let kitSrc = res + "/graph-kit"
        let kitDest = lib + "/graph-kit"
        if FileManager.default.fileExists(atPath: kitSrc),
           out.seeded || kitIncomplete(src: kitSrc, dest: kitDest) {
            out.kitSeeded = copyKit(from: kitSrc, to: kitDest)
        }
        if out.seeded { kickstart?() }
        return out
    }
}

// MARK: - `pong architect new --json`, read for the New graph sheet

enum ArchitectStart {
    enum Outcome: Equatable {
        /// The chat's key ("session/id"), and plain words when its AI didn't really start.
        case opened(key: String, warning: String?)
        case failed(String)
    }

    /// "the project folder … does not exist" → "The project folder … does not exist"; a program's
    /// own name keeps its case ("tmux isn't installed").
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = t.prefix { $0.isLetter || $0.isNumber }.lowercased()
        let programs: Set<String> = ["tmux", "pong", "python3", "brew", "npm", "launchctl"]
        return programs.contains(first) ? t : t.prefix(1).uppercased() + t.dropFirst()
    }

    static func read(out: String, err: String) -> Outcome {
        let obj = (out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        if let obj {
            let error = ((obj["error"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if AppSettings.flag(obj["ok"]) == false {
                return .failed(error.isEmpty ? "The chat couldn't start." : sentence(error))
            }
            let id = (obj["id"] as? String) ?? ""
            let session = (obj["session"] as? String) ?? ""
            if !id.isEmpty, !session.isEmpty {
                let note = ((obj["spawn_note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let alive = AppSettings.flag(obj["alive"])
                let started = alive ?? !noteSaysNotStarted(note)
                return .opened(key: session + "/" + id, warning: started ? nil : plainNote(note))
            }
        }
        let line = err.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        if line.lowercased().hasPrefix("error:") {
            let msg = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if !msg.isEmpty { return .failed(sentence(msg)) }
        }
        return .failed("Couldn't open the chat. Check that the AI is signed in, then try again.")
    }

    static func noteSaysNotStarted(_ note: String) -> Bool {
        let n = note.lowercased()
        return ["unavailable", "skipped", "no tmux", "failed", "not installed", "not found", "error", "refused"]
            .contains { n.contains($0) }
    }

    /// The engine's spawn note ("tmux unavailable — …", "tmux session x created, lead on window 0")
    /// is for the log: the person reads one of three plain sentences. They say what is wrong and
    /// where to fix it, and promise nothing: no AI starts again on its own (New graph adds how to
    /// start it again, `startAgainHint`; a chat started on a team has its own way back).
    static func plainNote(_ note: String) -> String {
        let n = note.lowercased()
        if n.contains("tmux") && !n.contains("created") && !n.contains("already there") {
            return "The chat was saved, but its AI couldn't start: tmux isn't working on this Mac. Help › Set up CyberPong… shows how to fix it."
        }
        if n.contains("not installed") || n.contains("not found") {
            return "The chat was saved, but its AI isn't installed on this Mac. Settings › AI accounts shows what to install."
        }
        return "The chat was saved, but its AI didn't start. Check that it's signed in (Settings › AI accounts)."
    }

    /// New graph only, where the chat's AI is its new team's lead: starting the team again
    /// (`pong team start`) brings the AI back on this chat.
    static let startAgainHint = "Then press Try again: its AI starts on this chat."

    /// `pong team start --json`'s error for New graph's Try again, in plain words.
    static func retryProblem(_ error: String) -> String {
        let e = error.lowercased()
        if e.contains("already running") {
            return "Its terminal is still open, but its AI isn't answering. Open the chat to see it."
        }
        if e.contains("tmux") {
            return "tmux still isn't working on this Mac. Help › Set up CyberPong… shows how to fix it."
        }
        if e.contains("not the live one") {
            return "This copy of CyberPong can't start AIs: it is looking at a test folder."
        }
        return "Its AI still didn't start. Check that it's signed in (Settings › AI accounts), then try again."
    }
}
