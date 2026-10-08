import Foundation

// Standalone harness for src/SetupCore.swift: settings.json (C2), the key files (C3), reading
// `pong doctor` and `pong keys status` (C4), `architect new --json` (C8) and the launcher and
// engine refresh (C9). run-setup.sh compiles it with Stubs.swift. Exit 0 = all green.
//
// Every path is under a temp folder. Nothing touches ~/.pong, ~/bin or launchctl.

var failures = 0
var checks = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(label)" + (d.isEmpty ? "" : "\n       \(d)"))
    }
}

func section(_ name: String) { print("\n\(name)") }

let fm = FileManager.default
/// The checkout, from run-setup.sh: install-control-plane.sh is read from it (never run).
let repoRoot = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

func freshDir(_ tag: String) -> String {
    let dir = NSTemporaryDirectory() + "setup-harness-\(tag)-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func freshState(_ tag: String) -> String {
    let d = freshDir(tag)
    Pong.stateDirOverride = d
    Pong.logLines = []
    return d
}

func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

func leftovers(_ dir: String) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains(".tmp-") || $0.contains("-new-") || $0.contains("-old-") }
}

// MARK: - 1. files only their owner can read

section("S1  SecureFile: 0600 from the start, replaced in one step, folders 0700")
do {
    let dir = freshDir("s1")
    let p = dir + "/a.json"
    check(SecureFile.write(Data("one".utf8), to: p), "first write succeeds")
    check(SecureFile.mode(p) == 0o600, "file is 0600", "mode \(String(describing: SecureFile.mode(p)))")
    check(SecureFile.write(Data("two".utf8), to: p), "second write succeeds")
    check(read(p) == "two", "second write replaced the first", read(p))
    check(leftovers(dir).isEmpty, "no temp files left behind", "\(leftovers(dir))")
    check(SecureFile.write(Data("x".utf8), to: dir + "/l", mode: 0o755) && SecureFile.mode(dir + "/l") == 0o755,
          "another mode is honoured exactly (0755 for a launcher)")
    let sec = dir + "/deep/secrets"
    check(SecureFile.ensureDir(sec), "ensureDir makes missing parents")
    check(SecureFile.mode(sec) == 0o700, "the folder is 0700", "mode \(String(describing: SecureFile.mode(sec)))")
    chmod(sec, 0o755)
    check(SecureFile.ensureDir(sec) && SecureFile.mode(sec) == 0o700, "an existing loose folder is tightened to 0700")
    check(!SecureFile.ensureDir(p), "a file in the way is refused")
}

// MARK: - 2. settings.json

section("S2  AppSettings: defaults, merge, unknown keys kept, 0600, garbage kept aside")
do {
    let st = freshState("s2")
    let path = st + "/settings.json"
    check(AppSettings.limits == AppSettings.Limits(), "no file: every limit at its default")
    let d = AppSettings.Limits()
    check(d.rideOut5h && d.weekStopPct == 97 && d.helperAI && d.jev && d.perplexity && d.perplexityDailyUSD == 15,
          "defaults are ride_out true, 97 %, helper on, Jev on, Perplexity on, $15")
    check(AppSettings.aiEnabled("grok"), "ai_enabled absent = on")
    check(AppSettings.seatPermissions == nil, "seat_permissions absent = never chosen")
    check(!AppSettings.setupDone, "setup absent = not done")
    check(AppSettings.architect == nil, "architect absent = the lead policy")
    check(AppSettings.ownerName == "", "owner_name absent = empty")
    check(!AppSettings.developer, "developer absent = false")

    // a file the app doesn't fully know: its keys must survive every write
    try? "{\"hide_island\": true, \"app_ai\": {\"provider\": \"grok\"}, \"future_key\": [1, 2]}".write(toFile: path, atomically: true, encoding: .utf8)
    AppSettings.setAIEnabled("codex", false)
    AppSettings.setLimit("week_stop_pct", 90)
    AppSettings.setLimit("helper_ai", false)
    AppSettings.setSeatPermissions(auto: true)
    AppSettings.setArchitect(runtime: "grok", model: "grok-4.7")
    AppSettings.setOwnerName("  Sam \n")
    AppSettings.markSetupDone(at: Date(timeIntervalSince1970: 1_791_400_000))
    let root = Pong.loadJSON(path)
    check((root["hide_island"] as? Bool) == true, "an existing key is kept")
    check((root["future_key"] as? [Int]) == [1, 2], "an unknown key is kept as it was")
    check(((root["app_ai"] as? [String: Any])?["provider"] as? String) == "grok", "a nested section is kept")
    check(SecureFile.mode(path) == 0o600, "settings.json is 0600 after a write", "mode \(String(describing: SecureFile.mode(path)))")
    check(!AppSettings.aiEnabled("codex") && AppSettings.aiEnabled("claude"), "ai_enabled: codex off, others still on")
    check(AppSettings.limits.weekStopPct == 90 && !AppSettings.limits.helperAI && AppSettings.limits.jev,
          "limits merge key by key")
    check(AppSettings.seatPermissions == "auto", "seat_permissions auto")
    check(AppSettings.architect?.runtime == "grok" && AppSettings.architect?.model == "grok-4.7", "architect saved")
    check(AppSettings.ownerName == "Sam", "owner name trimmed", AppSettings.ownerName)
    let setup = root["setup"] as? [String: Any]
    check((setup?["version"] as? Int) == 1 && (setup?["completed_at"] as? Int) == 1_791_400_000,
          "setup is {version: 1, completed_at: <int>}", "\(String(describing: setup))")
    check(AppSettings.setupDone, "setupDone reads it back")

    AppSettings.setArchitect(runtime: nil, model: nil)
    check(Pong.loadJSON(path)["architect"] == nil, "Recommended removes the architect key")
    AppSettings.setArchitect(runtime: "hermes", model: nil)
    check((Pong.loadJSON(path)["architect"] as? [String: Any])?["model"] == nil && AppSettings.architect?.model == "",
          "an AI with no model choice saves no model")
    AppSettings.setOwnerName("")
    check(Pong.loadJSON(path)["owner_name"] == nil, "an empty name removes owner_name")
    check(AppSettings.cleanName(String(repeating: "x", count: 80)).count == 40, "names are cut at 40 characters")
    AppSettings.setSeatPermissions(auto: false)
    check(AppSettings.seatPermissions == "ask", "seat_permissions ask")

    // the setup's switch saves what it shows the moment it shows it, and never over a choice
    AppSettings.set("seat_permissions", nil)
    check(AppSettings.seatPermissions == nil, "seat_permissions cleared for the next checks")
    check(AppSettings.saveSeatPermissionsShown(auto: true) && AppSettings.seatPermissions == "auto",
          "never chosen: the value shown (on) is saved at once, so Skip or Esc can't leave it on ask")
    check(!AppSettings.saveSeatPermissionsShown(auto: false) && AppSettings.seatPermissions == "auto",
          "shown again: a value already saved is not changed")
    AppSettings.setSeatPermissions(auto: false)
    check(!AppSettings.saveSeatPermissionsShown(auto: true) && AppSettings.seatPermissions == "ask",
          "the person's own choice (ask) is never changed by showing the step")
    AppSettings.set("seat_permissions", nil)
    check(AppSettings.saveSeatPermissionsShown(auto: false) && AppSettings.seatPermissions == "ask",
          "shown off (someone who used CyberPong before): ask is saved, matching the switch")

    // tolerant reading
    try? "{\"limits\": {\"ride_out_5h\": 0, \"week_stop_pct\": \"80\", \"perplexity_daily_usd\": 7.5, \"jev\": \"yes\"}}"
        .write(toFile: path, atomically: true, encoding: .utf8)
    let l = AppSettings.limits
    check(!l.rideOut5h && l.weekStopPct == 80 && l.perplexityDailyUSD == 7.5 && l.jev,
          "numbers as strings, 0/1 as switches; a value of the wrong kind keeps the default", "\(l)")

    // garbage is kept beside the new file, not silently lost
    try? "{not json".write(toFile: path, atomically: true, encoding: .utf8)
    AppSettings.setOwnerName("Ana")
    let aside = ((try? fm.contentsOfDirectory(atPath: st)) ?? []).filter { $0.hasPrefix("settings.json.unreadable-") }
    check(aside.count == 1, "an unreadable settings.json is kept aside", "\(aside)")
    check(aside.first.map { read(st + "/" + $0) } == "{not json", "with its content intact")
    check(AppSettings.ownerName == "Ana", "and the new value is written")
}

// MARK: - 3. key files

section("S3  SetupKeys: clean, write 0600 in a 0700 folder, remove only the Settings file")
do {
    let st = freshState("s3")
    check(SetupKeys.clean("  tsk_abc123  \n", for: .jev) == "tsk_abc123", "spaces and newlines come off")
    check(SetupKeys.clean("TYPESAFE_API_KEY=tsk_abcdef", for: .jev) == "tsk_abcdef", "a pasted VAR= prefix comes off")
    check(SetupKeys.clean("export PERPLEXITY_API_KEY=\"pplx-12345\"", for: .perplexity) == "pplx-12345", "export, prefix and quotes come off")
    check(SetupKeys.clean("'abcdefgh=='", for: .jev) == "abcdefgh==", "single quotes come off, '=' inside a key stays")
    check(SetupKeys.clean("", for: .jev) == nil, "empty is not a key")
    check(SetupKeys.clean("two words here", for: .jev) == nil, "a space inside is not a key")
    check(SetupKeys.clean("abcdefgh\nijklmnop", for: .jev) == nil, "a newline inside is not a key (the file stays one line)")
    check(SetupKeys.clean(String(repeating: "k", count: 600), for: .jev) == nil, "over 512 characters is not a key")
    check(SetupKeys.clean("abc1234", for: .jev) == nil && SetupKeys.clean("abc12345", for: .jev) == "abc12345",
          "under 8 characters is not a key (the engine's own rule)")
    check(SetupKeys.clean("PERPLEXITY_API_KEY=pplx-12345", for: .jev) == nil,
          "the other service's line pasted into Jev's field is refused, not saved as Jev's key")
    check(SetupKeys.clean("export TYPESAFE_API_KEY=tsk_abcdef", for: .perplexity) == nil, "and the other way round")
    check(SetupKeys.otherService("PERPLEXITY_API_KEY=pplx-12345", for: .jev) == .perplexity
          && SetupKeys.otherService("TYPESAFE_API_KEY=x", for: .jev) == nil
          && SetupKeys.otherService("abc==", for: .jev) == nil, "otherService names the service whose line it is")
    check(SetupKeys.problem("PERPLEXITY_API_KEY=pplx-12345", for: .jev) == "That's the Perplexity key: paste it in its own field.",
          "the person is told which field it belongs in", SetupKeys.problem("PERPLEXITY_API_KEY=pplx-12345", for: .jev) ?? "nil")
    check(SetupKeys.problem("  ", for: .jev) == "Paste the key first.", "nothing pasted")
    check(SetupKeys.problem("abc", for: .jev) == "That doesn't look like a key. Paste it again.", "too short")
    check(SetupKeys.problem("tsk_abcdef", for: .jev) == nil, "a good key has no problem")
    check(!(SetupKeys.problem("PERPLEXITY_API_KEY=pplx-SENTINEL", for: .jev) ?? "").contains("SENTINEL"),
          "the message never repeats the key")
    check(SetupKeys.clean("clé_abcdefgh", for: .jev) == nil, "non-ASCII is not a key")

    let secret = "tsk_SENTINEL_0123456789"
    check(SetupKeys.save(.jev, key: secret), "save succeeds")
    let p = SetupKeys.path(.jev)
    check(p == st + "/secrets/jev.env", "the Jev file is <state>/secrets/jev.env", p)
    check(read(p) == "TYPESAFE_API_KEY=\(secret)\n", "one line: TYPESAFE_API_KEY=<key>", read(p))
    check(SecureFile.mode(p) == 0o600, "the key file is 0600")
    check(SecureFile.mode(st + "/secrets") == 0o700, "the secrets folder is 0700")
    check(!Pong.logLines.joined().contains(secret), "the key is never logged")
    check(SetupKeys.save(.perplexity, key: "pplx-1"), "Perplexity save")
    check(read(SetupKeys.path(.perplexity)) == "PERPLEXITY_API_KEY=pplx-1\n", "Perplexity line")
    check(leftovers(st + "/secrets").isEmpty, "no temp files beside the keys")
    check(SetupKeys.remove(.jev) && !fm.fileExists(atPath: p), "remove deletes the Settings file")
    check(fm.fileExists(atPath: SetupKeys.path(.perplexity)), "and only that one")
    check(SetupKeys.remove(.jev), "removing a key that isn't there is fine")
}

section("S3b KeysStatus: set / not set and where from, nothing else")
do {
    _ = freshState("s3b")
    let k = KeysStatus.parse(["jev": ["set": true, "source": "legacy", "enabled": true],
                              "perplexity": ["set": false, "source": "", "enabled": false]])
    check(k.known && k.jev.set && !k.perplexity.set && !k.perplexity.enabled, "parsed")
    check(KeysStatus.words(k.jev) == "Set · from an older setup file", KeysStatus.words(k.jev))
    check(KeysStatus.words(k.perplexity) == "Not set", KeysStatus.words(k.perplexity))
    check(KeysStatus.words(.init(set: true, source: "settings", enabled: true)) == "Set · from Settings", "settings source")
    check(KeysStatus.words(.init(set: true, source: "environment", enabled: true)) == "Set · from the environment", "env source")
    check(KeysStatus.words(.init(set: true, source: "claude_connector", enabled: true)) == "Set · from Claude Code's Perplexity connector",
          "the owner's Claude Code connector key is named", KeysStatus.words(.init(set: true, source: "claude_connector", enabled: true)))
    check(KeysStatus.words(.init(set: true, source: "something_new", enabled: true)) == "Set", "an unknown source: just Set")
    check(!KeysStatus.parse([:]).known, "an empty answer is not known")

    // after Remove: the note says when a key from elsewhere is still used, and what stops it
    let gone = KeysStatus.afterRemove(.perplexity, removed: true, now: .init(set: false, source: "", enabled: true))
    check(gone == "Removed from Settings.", "nothing left: removed", gone)
    let stale = KeysStatus.afterRemove(.perplexity, removed: true, now: .init(set: true, source: "settings", enabled: true))
    check(stale == "Removed from Settings.", "the engine still reading the old file a moment: no claim of another key", stale)
    let conn = KeysStatus.afterRemove(.perplexity, removed: true, now: .init(set: true, source: "claude_connector", enabled: true))
    check(conn == "Removed from Settings, but a Perplexity key is still set from Claude Code's Perplexity connector. Switching off “Perplexity web research” stops CyberPong using it.",
          "a connector key left: said, with the switch that stops it", conn)
    let env = KeysStatus.afterRemove(.jev, removed: true, now: .init(set: true, source: "environment", enabled: false))
    check(env == "Removed from Settings. A Jev key is still set from the environment, but “Jev second opinions” is off, so CyberPong doesn't use it.",
          "a key left but switched off: said it isn't used", env)
    check(KeysStatus.afterRemove(.jev, removed: true, now: .init(set: true, source: "", enabled: true)).contains("somewhere else"),
          "a key left from a source with no words: somewhere else")
    check(KeysStatus.afterRemove(.jev, removed: false, now: .init(set: true, source: "settings", enabled: true)) == "Couldn't remove the key.",
          "a file that couldn't be removed")
    _ = SetupKeys.save(.perplexity, key: "pplx-2")
    let f = KeysStatus.fromFiles()
    check(f.known && f.perplexity.set && f.perplexity.source == "settings" && !f.jev.set, "the app's own look at the files")
}

// MARK: - 4. pong doctor --json

section("S4  DoctorReport.parse: the C4 shape")
do {
    _ = freshState("s4")
    let json = """
    {"version": "2.0.0",
     "python": {"ok": true, "path": "/opt/homebrew/bin/python3", "version": "3.14.3"},
     "tmux": {"ok": false, "path": "", "fix": "brew install tmux"},
     "brew": {"ok": true, "path": "/opt/homebrew/bin/brew"},
     "launcher": {"ok": true, "path": "~/bin/pong"},
     "engine": {"ok": true, "path": "~/.pong/lib/pong", "version": "2.0.0"},
     "runner": {"ok": false, "installed": true, "running": false, "last_beat_s": null},
     "ais": {
       "hermes": {"label": "Hermes", "installed": true, "signed_in": null, "enabled": true, "login": "hermes login", "install": ""},
       "codex": {"label": "Codex", "installed": false, "signed_in": null, "enabled": false, "login": "codex login", "install": "npm install -g @openai/codex"},
       "claude": {"label": "Claude Code", "installed": true, "path": "/x/claude", "signed_in": true, "plan": "max", "enabled": true,
                  "login": "claude auth login", "install": "npm install -g @anthropic-ai/claude-code"},
       "grok": {"installed": true, "signed_in": false, "enabled": true}
     },
     "keys": {"jev": {"set": true, "source": "settings", "enabled": true}, "perplexity": {"set": false, "source": "", "enabled": true}},
     "settings": {"owner_name": "Sam"}}
    """
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let r = DoctorReport.parse(obj)
    check(r.version == "2.0.0" && r.python.ok && r.python.version == "3.14.3", "version and python")
    check(!r.tmux.ok && r.tmux.fix == "brew install tmux" && r.brew.ok, "tmux missing, brew there")
    check(r.launcher.ok && r.engine.ok && r.engine.version == "2.0.0", "launcher and engine")
    check(!r.runner.ok && r.runner.installed && r.runner.running == false && r.runner.lastBeat == nil, "runner installed, not running")
    check(r.ais.map(\.id) == ["claude", "grok", "codex", "hermes"], "AIs in the fixed order", "\(r.ais.map(\.id))")
    let claude = r.ai("claude"), grok = r.ai("grok"), hermes = r.ai("hermes"), codex = r.ai("codex")
    check(claude?.signedIn == true && claude?.plan == "max" && claude?.login == "claude auth login", "Claude signed in, Max")
    check(grok?.label == "Grok Build" && grok?.signedIn == false && grok?.login == "grok login",
          "a missing label and login fall back to the known ones")
    check(hermes?.signedIn == nil, "signed_in null = can't tell")
    check(codex?.installed == false && codex?.enabled == false && codex?.install == "npm install -g @openai/codex", "Codex")
    check(r.keys.known && r.keys.jev.set && r.keys.jev.source == "settings" && !r.keys.perplexity.set, "keys")
    check(DoctorReport.planWords("max") == "Max plan" && DoctorReport.planWords("") == "", "plan words")
    check(DoctorReport.planWords("team_premium") == "Team premium plan", DoctorReport.planWords("team_premium"))
    let empty = DoctorReport.parse([:])
    check(!empty.python.ok && empty.ais.isEmpty && !empty.keys.known, "an empty answer parses to nothing ready")

    // the runner's last beat changes on every check and is never shown: not a change to redraw for
    var later = r
    later.runner.lastBeat = 42
    check(later.sameForDisplay(r) && r.sameForDisplay(later), "a new last beat alone is the same report for the pages")
    var signed = r
    signed.ais[1].signedIn = true
    check(!signed.sameForDisplay(r), "a sign-in is a change")
    check(!r.sameForDisplay(nil), "a first report is a change")
    check(later.forDisplay.runner.lastBeat == nil && later.runner.lastBeat == 42, "forDisplay drops only the beat")
}

section("S4b DoctorReport: the engine's own answer (nulls, install sentences)")
do {
    _ = freshState("s4b")
    // the shape `pong doctor --json` prints: unknowns are null, and an AI with no one-line
    // installer gets a sentence instead of a command
    let json = """
    {"version": "2.0.0",
     "python": {"ok": true, "path": "/opt/homebrew/bin/python3", "version": "3.14.3"},
     "tmux": {"ok": false, "path": null, "fix": "brew install tmux"},
     "brew": {"ok": false, "path": null, "fix": "see https://brew.sh"},
     "launcher": {"ok": false, "path": "~/bin/pong"},
     "engine": {"ok": true, "path": "~/.pong/lib/pong", "version": null, "same_as_this": false},
     "runner": {"ok": false, "installed": false, "running": false, "last_beat_s": null},
     "ais": {
       "claude": {"label": "Claude Code", "installed": false, "path": null, "signed_in": null, "enabled": true,
                  "login": "claude auth login", "install": "curl -fsSL https://claude.ai/install.sh | bash",
                  "install_npm": "npm install -g @anthropic-ai/claude-code", "plan": null},
       "grok": {"label": "Grok Build", "installed": false, "path": null, "signed_in": null, "enabled": true,
                "login": "grok login", "install": "See Grok Build's install page"},
       "codex": {"label": "Codex", "installed": false, "path": null, "signed_in": null, "enabled": false,
                 "login": "codex login", "install": "npm install -g @openai/codex"},
       "hermes": {"label": "Hermes", "installed": true, "path": "~/.local/bin/hermes", "signed_in": null, "enabled": true,
                  "login": "hermes login", "install": "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"}
     },
     "keys": {"jev": {"set": false, "source": "", "enabled": true}, "perplexity": {"set": true, "source": "environment", "enabled": false}},
     "settings": {"owner_name": "the person", "architect": {"runtime": "", "model": ""}, "seat_permissions": "ask", "limits": {}}}
    """
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let r = DoctorReport.parse(obj)
    check(r.tmux.path == "" && !r.brew.ok && r.engine.version == "", "null paths and versions read as empty")
    check(r.ai("claude")?.plan == "" && r.ai("claude")?.signedIn == nil, "null plan and sign-in")
    check(r.ai("hermes")?.installed == true && r.ai("hermes")?.path == "~/.local/bin/hermes", "Hermes installed")
    check(r.keys.perplexity.set && r.keys.perplexity.source == "environment" && !r.keys.perplexity.enabled, "keys from the engine")
    check(DoctorReport.installIsCommand(r.ai("claude")?.install ?? ""), "curl … | bash is a command to copy")
    check(DoctorReport.installIsCommand("npm install -g @openai/codex"), "npm install is a command")
    check(!DoctorReport.installIsCommand(r.ai("grok")?.install ?? "x"), "\"See Grok Build's install page\" is a sentence, not a command")
    check(!DoctorReport.installIsCommand("") && !DoctorReport.installIsCommand("  "), "nothing is not a command")
    // the engine's own Hermes hint (doctor.AIS) is its official installer: a command to copy
    check(r.ai("hermes")?.install == "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
          && DoctorReport.installIsCommand(r.ai("hermes")?.install ?? ""), "Hermes's install hint is a command to copy",
          r.ai("hermes")?.install ?? "nil")
}

section("S4c PlanningAI: the AIs that can run the graph-planning chat")
do {
    _ = freshState("s4c")
    let avail = ["claude", "grok", "codex", "hermes"]
    let on: (String) -> Bool = { _ in true }
    check(PlanningAI.offer(available: avail, enabled: on, installed: nil, signedIn: []) == ["claude", "grok", "codex"],
          "Hermes is never offered: the engine can't start the planning chat on it")
    check(PlanningAI.offer(available: avail, enabled: { $0 != "grok" }, installed: nil, signedIn: []) == ["claude", "codex"],
          "an AI switched off is not offered")
    check(PlanningAI.offer(available: avail, enabled: on, installed: ["grok", "codex", "hermes"], signedIn: []) == ["grok", "codex"],
          "an AI the check didn't find is not offered")
    check(PlanningAI.offer(available: ["claude", "grok"], enabled: on, installed: nil, signedIn: []) == ["claude", "grok"],
          "nor one the catalog doesn't list as available")
    check(PlanningAI.offer(available: avail, enabled: on, installed: nil, signedIn: ["codex"]) == ["codex", "claude", "grok"],
          "signed-in AIs come first")
    check(PlanningAI.blocker("hermes", available: avail, enabled: true, installed: true) == "can't plan graphs", "Hermes says why")
    check(PlanningAI.blocker("grok", available: avail, enabled: false, installed: true) == "off", "off")
    check(PlanningAI.blocker("codex", available: avail, enabled: true, installed: false) == "not installed", "not installed")
    check(PlanningAI.blocker("claude", available: avail, enabled: true, installed: nil) == nil, "ready: nil")

    // New graph's first items: the AI pop-up names only the AI, the Model pop-up the model,
    // and both say the same thing (default or recommended)
    let def = PlanningAI.newGraphTitles(("Claude Code", "Fable 5", true))
    check(def.ai == "AI: Claude Code (your default)" && def.model == "Model: Fable 5", "your default: \(def)")
    let rec = PlanningAI.newGraphTitles(("Codex / OpenAI", "GPT-5.1 Codex", false))
    check(rec.ai == "AI: Codex / OpenAI (recommended)" && rec.model == "Model: GPT-5.1 Codex", "recommended: \(rec)")
    check(!rec.ai.contains("·") && !rec.ai.contains("GPT"), "the AI title carries no model (it must fit 270 pt)", rec.ai)
    let noModel = PlanningAI.newGraphTitles(("Grok Build", "", true))
    check(noModel.model == "Model: your default", "no model known: the model item says the same as the AI item", noModel.model)
    let noModelRec = PlanningAI.newGraphTitles(("Grok Build", "", false))
    check(noModelRec.ai.hasSuffix("(recommended)") && noModelRec.model == "Model: recommended",
          "never \"AI: recommended\" beside \"Model: your default\"", "\(noModelRec)")
    let none = PlanningAI.newGraphTitles(nil)
    check(none.ai == "AI: recommended" && none.model == "Model: recommended", "nothing known yet", "\(none)")
}

section("S4e TeamLead.pick: a new team's lead is an AI that is on and signed in, Claude first")
do {
    let order = ["claude", "grok", "hermes"]
    let all: (String) -> Bool = { _ in true }
    check(TeamLead.pick(order, enabled: all, signedIn: { $0 == "grok" || $0 == "claude" }, installed: { _ in true }) == "claude",
          "Claude signed in: Claude leads")
    check(TeamLead.pick(order, enabled: all, signedIn: { $0 == "grok" }, installed: { _ in true }) == "grok",
          "only Grok signed in: Grok leads")
    check(TeamLead.pick(order, enabled: { $0 != "claude" }, signedIn: all, installed: { _ in true }) == "grok",
          "Claude switched off: the next signed-in AI")
    check(TeamLead.pick(order, enabled: all, signedIn: { _ in false }, installed: { $0 == "hermes" }) == "hermes",
          "nobody signed in: an installed AI")
    check(TeamLead.pick(order, enabled: all, signedIn: { _ in false }, installed: { _ in nil }) == "claude",
          "nothing known: Claude, the one setup says to install first")
}

section("S4f MacChecks and MacReadiness: Automation while Terminal is closed; step 1's words")
do {
    check(MacChecks.automation(status: 0) == .allowed && MacChecks.automation(status: -1743) == .denied
          && MacChecks.automation(status: -1744) == .notAsked, "macOS's three answers")
    check(MacChecks.automation(status: -600) == .unknown, "procNotFound (Terminal not running) is \"can't say\"")
    var s = MacChecks.settle(.allowed, last: nil)
    check(s.shown == .allowed && s.remember == "allowed", "a real answer is remembered")
    s = MacChecks.settle(.unknown, last: "allowed")
    check(s.shown == .allowed && s.remember == nil, "Terminal closed after it was allowed: still allowed")
    s = MacChecks.settle(.unknown, last: "denied")
    check(s.shown == .denied, "Terminal closed after a no: still no")
    s = MacChecks.settle(.unknown, last: "notAsked")
    check(s.shown == .unknown, "never answered: can't say")
    s = MacChecks.settle(.notAsked, last: "allowed")
    check(s.shown == .notAsked && s.remember == "notAsked", "a newer answer replaces an old allowed (permissions reset)")

    var d = DoctorReport()
    d.python.ok = true; d.tmux.ok = true; d.launcher.ok = true; d.engine.ok = true; d.runner.ok = true
    var m = MacChecks(accessibility: true, automation: .unknown)
    check(MacReadiness.gaps(d, m).isEmpty, "Automation unknown (Terminal closed) is not a gap", "\(MacReadiness.gaps(d, m))")
    m.automation = .notAsked
    check(MacReadiness.gaps(d, m) == ["Automation"], "not asked yet is a gap")
    m.automation = .denied
    check(MacReadiness.gaps(d, m) == ["Automation"] && MacReadiness.consequences(d, m, appHasEngine: true) == ["team windows won't open in Terminal"],
          "denied: a gap, and said what it stops")
    m.automation = .allowed
    d.launcher.ok = false
    let withEngine = MacReadiness.consequences(d, m, appHasEngine: true)
    check(withEngine == ["your AIs can't report back or ask you anything"],
          "no pong command, the app has its own engine: its pages still load", "\(withEngine)")
    check(!MacReadiness.launcherLine(appHasEngine: true).contains("can't load"), "and the row doesn't say they can't load")
    check(MacReadiness.consequences(d, m, appHasEngine: false).first?.contains("can't load") == true,
          "no engine anywhere: graphs and chats really can't load")
    d.runner.ok = false
    d.tmux.ok = false
    let note = MacReadiness.continueNote(MacReadiness.consequences(d, m, appHasEngine: true))
    check(note == "If you continue now, no AI can start, your AIs can't report back or ask you anything and graphs stop after their first step. Help › Set up CyberPong… brings this check back any time.",
          "the note lists with \"and\" and doesn't end in \"….\"", note)
    check(!note.contains("….") && !note.contains("…."), "no ellipsis followed by a full stop")
    check(MacReadiness.continueNote([]) == "", "nothing to say: no note")
    let until = MacReadiness.untilFixedNote(["no AI can start", "graphs stop after their first step"])
    check(until == "Until they're fixed, no AI can start and graphs stop after their first step.",
          "Settings › This Mac says what doesn't work yet", until)
    check(MacReadiness.untilFixedNote([]) == "", "and nothing when everything works")
    check(MacReadiness.list(["A"]) == "A" && MacReadiness.list(["A", "B"]) == "A and B"
          && MacReadiness.list(["A", "B", "C"]) == "A, B and C", "lists")
}

section("S4d PollSchedule: a redraw never asks for the next check at once")
do {
    let a = NSObject(), b = NSObject()
    var s = PollSchedule()
    var r = s.add(ObjectIdentifier(a), every: 3)
    check(r.changed && r.isNew && s.interval == 3, "the first page: clock starts, check now")
    r = s.add(ObjectIdentifier(a), every: 3)
    check(!r.changed && !r.isNew, "the same page again (a redraw): no restart, no check")
    r = s.add(ObjectIdentifier(b), every: 4)
    check(!r.changed && r.isNew && s.interval == 3, "a second, slower page: checked once, the clock stays at 3 s")
    check(s.remove(ObjectIdentifier(a)) && s.interval == 4, "the faster page goes: the clock slows to 4 s")
    check(!s.remove(ObjectIdentifier(a)), "removing it twice changes nothing")
    check(s.remove(ObjectIdentifier(b)) && s.interval == nil, "nobody looking: no clock")
}

// MARK: - 5. architect new --json

section("S5  ArchitectStart.read: plain words instead of \"Chat open\" when the chat didn't start")
do {
    _ = freshState("s5")
    check(ArchitectStart.read(out: "{\"ok\": false, \"error\": \"tmux isn't installed on this Mac.\"}", err: "")
          == .failed("tmux isn't installed on this Mac."), "ok:false shows the engine's plain error")
    check(ArchitectStart.read(out: "{\"id\": \"a_1\", \"session\": \"pong-team-3\", \"alive\": true, \"spawn_note\": \"tmux session pong-team-3 created, lead on window 0\"}", err: "")
          == .opened(key: "pong-team-3/a_1", warning: nil), "a live chat opens with no warning")
    if case .opened(let key, let w) = ArchitectStart.read(out: "{\"id\": \"a_2\", \"session\": \"pong-team-4\", \"alive\": false, \"spawn_note\": \"tmux unavailable — error connecting\"}", err: "") {
        check(key == "pong-team-4/a_2", "the saved chat's key comes back")
        check(w?.contains("tmux isn't working") == true && w?.contains("Set up CyberPong") == true,
              "tmux trouble is said in plain words", w ?? "nil")
    } else {
        check(false, "a saved chat whose AI didn't start is still opened")
    }
    if case .opened(_, let w) = ArchitectStart.read(out: "{\"id\": \"a_3\", \"session\": \"s\", \"spawn_note\": \"tmux step skipped: OSError: boom\"}", err: "") {
        check(w != nil, "no alive field: a skipped spawn still warns")
    } else {
        check(false, "opened")
    }
    check(ArchitectStart.read(out: "{\"id\": \"a_4\", \"session\": \"s\", \"spawn_note\": \"tmux session s created, lead on window 0\"}", err: "")
          == .opened(key: "s/a_4", warning: nil), "no alive field and a success note: no warning")
    // the pane came up and died at once (an AI that isn't signed in): plain words, not the engine's note
    if case .opened(_, let w) = ArchitectStart.read(out: "{\"ok\": true, \"id\": \"a_5\", \"session\": \"pong-team-9\", \"alive\": false, \"spawn_note\": \"tmux session pong-team-9 created, lead on window 0\"}", err: "") {
        check(w != nil && !(w ?? "").contains("window 0") && !(w ?? "").contains("pong-team-9") && (w ?? "").contains("signed in"),
              "an AI that stopped at once: plain words, no engine note", w ?? "nil")
    } else {
        check(false, "opened")
    }
    check(ArchitectStart.read(out: "{\"ok\": false, \"error\": \"the project folder '/nope' does not exist\"}", err: "")
          == .failed("The project folder '/nope' does not exist"), "the engine's error starts with a capital")
    check(!ArchitectStart.plainNote("tmux step skipped: OSError: [Errno 2] boom").contains("OSError"),
          "an exception's name never reaches the person")
    // nothing restarts a chat's AI on its own: the words must not promise it
    for n in ["tmux unavailable — x", "claude not installed", "tmux session s created, lead on window 0"] {
        let w = ArchitectStart.plainNote(n)
        check(!w.contains("open the chat") && !w.contains("starts once") && w.hasPrefix("The chat was saved"),
              "no promise of a restart: \(w)")
    }
    check(ArchitectStart.startAgainHint.contains("Try again"), "New graph says how to start it again")
    check(ArchitectStart.retryProblem("pong-team-4 is already running").contains("Open the chat"),
          "Try again on a team still open: say so, and what to do")
    check(ArchitectStart.retryProblem("tmux could not open the session: error connecting").contains("tmux"),
          "tmux still broken")
    check(ArchitectStart.retryProblem("").contains("signed in"), "anything else: check the sign-in")
    check(!ArchitectStart.retryProblem("no team 'pong-team-4'").contains("pong-team"), "the engine's ids never reach the person")
    check(ArchitectStart.read(out: "", err: "Traceback…\nerror: the project folder '/nope' does not exist\n")
          == .failed("The project folder '/nope' does not exist"), "the CLI's error line, capitalised")
    if case .failed(let why) = ArchitectStart.read(out: "garbage", err: "") {
        check(why.hasPrefix("Couldn't open the chat"), "anything else: the old plain message", why)
    } else {
        check(false, "garbage fails")
    }
}

section("S5b RunnerInstall: install-agent's answer in plain words, and the one launch question")
do {
    _ = freshState("s5b")
    let ok = RunnerInstall.words(code: 0, out: "{\"ok\": true, \"plist\": \"/x\", \"loaded\": true}", err: "", place: .rows)
    check(ok.ok && ok.words == "The graph runner is on.", "on", "\(ok)")
    let noEngine = "{\"ok\": false, \"plist\": \"/x\", \"loaded\": false, \"reason\": \"no_engine\", \"error\": \"CyberPong's engine isn't installed in ~/.pong/lib yet\"}"
    let ne = RunnerInstall.words(code: 1, out: noEngine, err: "", place: .rows)
    check(!ne.ok && ne.words == "CyberPong's engine isn't in place yet. Press Fix on “The pong command” first, then Turn on.",
          "no_engine beside the rows: press Fix first", ne.words)
    let neElse = RunnerInstall.words(code: 1, out: noEngine, err: "", place: .elsewhere)
    check(neElse.words.contains("Settings › This Mac") && !neElse.words.contains("~/.pong"),
          "no_engine elsewhere: says where Fix is, and never the engine's path", neElse.words)
    let home = RunnerInstall.words(code: 1, out: "{\"ok\": false, \"reason\": \"not_this_home\", \"error\": \"CyberPong's folder here is not this Mac's own (~/.pong)\"}",
                                   err: "", place: .rows)
    check(!home.ok && home.words.contains("test folder") && !home.words.contains("~/.pong"), "not_this_home: plain words", home.words)
    let lc = RunnerInstall.words(code: 1, out: "{\"ok\": false, \"error\": \"the runner could not be loaded (Bootstrap failed: 5: Input/output error)\"}",
                                 err: "", place: .rows)
    check(!lc.ok && lc.words == "Couldn't turn the graph runner on. Try again in a moment." && !lc.words.contains("Bootstrap"),
          "launchctl's own words stay in the log", lc.words)
    let tb = RunnerInstall.words(code: 1, out: "", err: "Traceback (most recent call last):\n  File \"x\"\nOSError: boom\n", place: .rows)
    check(tb.words == "Couldn't turn the graph runner on. Try again in a moment.", "an exception never reaches the person", tb.words)
    let launcher = RunnerInstall.words(code: 127, out: "",
                                       err: "pong: Python isn't installed yet. Install Apple's command line tools (xcode-select --install), then try again.\n",
                                       place: .rows)
    check(launcher.words == "Python isn't installed yet. Install Apple's command line tools (xcode-select --install), then try again.",
          "the launcher's own one line passes through, without its \"pong:\"", launcher.words)
    check(RunnerInstall.noPython(.rows).hasPrefix("Install Apple's command line tools first")
          && RunnerInstall.noPython(.elsewhere).contains("Settings › This Mac"), "no Python: install the tools first")
    check(RunnerInstall.plistPath(home: "/h") == "/h/Library/LaunchAgents/com.cyberpong.runtime.plist", "the runner's plist")

    var q = RunnerInstall.launchQuestion(installed: false, asked: false)
    check(q.ask && q.remember == true, "not installed, never asked: ask once and remember")
    q = RunnerInstall.launchQuestion(installed: false, asked: true)
    check(!q.ask && q.remember == nil, "asked already: not again")
    q = RunnerInstall.launchQuestion(installed: true, asked: true)
    check(!q.ask && q.remember == false, "installed again: forget, so losing it later asks again")
    q = RunnerInstall.launchQuestion(installed: true, asked: false)
    check(!q.ask && q.remember == nil, "installed: nothing to ask or change")
}

section("S5c CLIDirs: the same folders the engine searches for the AI CLIs (models.cli_dirs)")
do {
    let home = freshDir("s5c")
    func mk(_ rel: String) { try? fm.createDirectory(atPath: home + "/" + rel, withIntermediateDirectories: true) }
    for v in ["v18.20.0", "v22.11.0", "v20.1.0", "v9.0.0"] { mk(".nvm/versions/node/\(v)/bin") }
    mk(".nvm/versions/node/not-a-version")          // no bin folder: skipped
    mk(".nvm/alias")
    mk(".volta/bin"); mk(".claude/local"); mk(".asdf/shims")
    mk("tools/bin"); mk("odd:dir"); mk("odd$(x)"); mk("odd`x`")
    let cache = home + "/cli-path.json"
    try? "{\"dirs\": [\"\(home)/tools/bin\", \"relative/bin\", \"\(home)/missing/bin\", \"\(home)/odd:dir\", \"\(home)/odd$(x)\", \"\(home)/odd`x`\", \"\(home)/.volta/bin\", \"/opt/homebrew/bin\"], \"at\": 1}"
        .write(toFile: cache, atomically: true, encoding: .utf8)
    let nvm = home + "/.nvm/versions/node"
    check(CLIDirs.nvm(home: home, nvmDir: nil) == ["\(nvm)/v22.11.0/bin", "\(nvm)/v20.1.0/bin", "\(nvm)/v18.20.0/bin", "\(nvm)/v9.0.0/bin"],
          "nvm's versions newest first, by number not by text", "\(CLIDirs.nvm(home: home, nvmDir: nil))")
    try? "20\n".write(toFile: home + "/.nvm/alias/default", atomically: true, encoding: .utf8)
    check(CLIDirs.nvm(home: home, nvmDir: nil).first == "\(nvm)/v20.1.0/bin", "nvm's default alias goes first (a new Terminal's node)")
    try? "lts/*\n".write(toFile: home + "/.nvm/alias/default", atomically: true, encoding: .utf8)
    check(CLIDirs.nvm(home: home, nvmDir: nil).first == "\(nvm)/v22.11.0/bin", "an alias that isn't a version is ignored")
    check(CLIDirs.nvm(home: home, nvmDir: home + "/elsewhere").isEmpty, "NVM_DIR is followed")
    let all = CLIDirs.list(home: home, cliPathFile: cache)
    check(Array(all.prefix(5)) == CLIDirs.base(home: home), "the app's five come first, there or not")
    check(all.dropFirst(5).first == "\(nvm)/v22.11.0/bin", "then nvm", "\(all)")
    let rest = Array(all.dropFirst(9))
    check(rest == ["\(home)/.volta/bin", "\(home)/.claude/local", "\(home)/.asdf/shims", "\(home)/tools/bin"],
          "then the managers that are there, then the login shell's: absolute, there, no ':' and no repeats", "\(rest)")
    check(!all.contains { $0.contains("$") || $0.contains("`") },
          "a folder whose name would run something in the Terminal scripts' PATH line is left out", "\(all)")
    check(Set(all).count == all.count, "no folder twice")
    check(CLIDirs.loginShell(home + "/nope.json").isEmpty && CLIDirs.list(home: freshDir("s5c2"), cliPathFile: "/nope").count == 5,
          "no cache, nothing installed: the five")
    check(CLIDirs.versionKey("v22.11.0") == [22, 11, 0] && CLIDirs.versionKey("node") == [0], "version numbers")
}

// MARK: - 6. versions and stamps

section("S6  EngineVersion: compare, read, stamps")
do {
    let c = EngineVersion.compare
    check(c("2.0.0-alpha", "2.0.0") == -1, "a pre-release is older than its release")
    check(c("2.0.0", "2.0.0-alpha") == 1, "and the other way round")
    check(c("1.9.3", "2.0.0-alpha") == -1, "1.9.3 < 2.0.0-alpha")
    check(c("2.0.0", "2.0") == 0, "2.0.0 == 2.0")
    check(c("2.0.1", "2.0.0") == 1 && c("2.10.0", "2.9.9") == 1, "numeric, not text")
    check(c("2.0.0-alpha", "2.0.0-beta") == -1, "pre-releases by name")
    let dir = freshDir("s6")
    try? "\"\"\"doc\"\"\"\nfrom .schema import X\n\n__version__ = \"2.0.0-alpha\"\n".write(toFile: dir + "/__init__.py", atomically: true, encoding: .utf8)
    check(EngineVersion.read(packageDir: dir) == "2.0.0-alpha", "__version__ read from __init__.py")
    check(EngineVersion.read(packageDir: dir + "/nope") == nil, "no package: nil")
    try? "version=2.0.0\nsource=/x/y\ninstalled_at=2026-10-07T00:00:00Z\n".write(toFile: dir + "/STAMP", atomically: true, encoding: .utf8)
    let s = EngineVersion.stamp(dir + "/STAMP")
    check(s["version"] == "2.0.0" && s["source"] == "/x/y" && s["installed_at"] == "2026-10-07T00:00:00Z", "stamp lines")
}

// MARK: - 7. the refresh decision

section("S7  EngineInstall.decide: never a downgrade, never over the owner's own install")
do {
    let app = EngineInstall.appSource
    let d = EngineInstall.decide
    check(d(nil, [:], "2.0.0", "b1").seeds, "nothing installed: seed")
    check(d("2.0.0-alpha", [:], "2.0.0", "b1").seeds, "older installed: seed")
    check(!d("2.0.1", ["source": app, "build": "b0"], "2.0.0", "b1").seeds, "newer installed: keep, even one the app made")
    check(!d("2.0.0", ["source": "/repo/checkout"], "2.0.0", "b1").seeds, "same version from a checkout: keep")
    check(!d("2.0.0", [:], "2.0.0", "b1").seeds, "same version, no stamp: keep")
    check(d("2.0.0", ["source": app, "build": "b0"], "2.0.0", "b1").seeds, "same version the app put there from another build: seed")
    check(!d("2.0.0", ["source": app, "build": "b1"], "2.0.0", "b1").seeds, "same build: keep")
    check(!d("2.0.0", [:], nil, "b1").seeds, "an app without an engine never seeds")
}

// MARK: - 8. the launcher and the whole launch check

func makeBundle(_ root: String, version: String, built: String, kit: Bool = true) -> String {
    let res = root + "/Resources"
    let pkg = res + "/python/pong"
    try? fm.createDirectory(atPath: pkg + "/cli", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: pkg + "/__pycache__", withIntermediateDirectories: true)
    try? "__version__ = \"\(version)\"\n".write(toFile: pkg + "/__init__.py", atomically: true, encoding: .utf8)
    try? "print('main')\n".write(toFile: pkg + "/cli/main.py", atomically: true, encoding: .utf8)
    try? "junk".write(toFile: pkg + "/__pycache__/x.cpython-39.pyc", atomically: true, encoding: .utf8)
    try? "version=\(version)\nbuilt_at=\(built)\n".write(toFile: pkg + "/BUILD_STAMP", atomically: true, encoding: .utf8)
    if kit {
        try? fm.createDirectory(atPath: res + "/graph-kit", withIntermediateDirectories: true)
        try? "# kit \(version)\n".write(toFile: res + "/graph-kit/pplx.py", atomically: true, encoding: .utf8)
    }
    return res
}

section("S8  EngineInstall: ~/bin/pong, the engine and the graph kit (temp folders only)")
do {
    let home = freshDir("s8home")
    let st = freshState("s8state")
    let launcher = EngineInstall.launcherPath(home: home)
    check(!EngineInstall.ensureLauncher(home: home, create: false) && !fm.fileExists(atPath: launcher),
          "no usable Python yet: a missing ~/bin/pong stays missing")
    check(EngineInstall.ensureLauncher(home: home), "writes ~/bin/pong when missing")
    check(read(launcher) == EngineInstall.launcherText, "the launcher text", read(launcher))
    check(SecureFile.mode(launcher) == 0o755, "mode 0755")
    // install-control-plane.sh writes the same text, to the byte
    let script = read(repoRoot + "/scripts/install-control-plane.sh")
    var heredoc: [String] = [], inDoc = false
    for line in script.components(separatedBy: "\n") {
        if inDoc { if line == "EOF" { break }; heredoc.append(line) }
        if line == "cat > \"$HOME/bin/pong\" <<'EOF'" { inDoc = true }
    }
    check(!heredoc.isEmpty && heredoc.joined(separator: "\n") + "\n" == EngineInstall.launcherText,
          "install-control-plane.sh's launcher is the app's, to the byte", heredoc.joined(separator: "\n"))
    check(EngineInstall.launcherText.contains("exec python3 -m pong.cli.main \"$@\""),
          "it still ends in `exec python3`, so the app's own check (EngineCheck.launchesPathPython) still sees it")

    // the launcher run for real, with bash, in a temp home: it never runs Apple's stub
    func runLauncher(_ text: String, path: String) -> (code: Int32, out: String, err: String) {
        let f = freshDir("s8run") + "/pong"
        try? text.write(toFile: f, atomically: true, encoding: .utf8)
        chmod(f, 0o755)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [f, "graph", "list"]
        p.environment = ["PATH": path, "HOME": home]
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: od, encoding: .utf8) ?? "", String(data: ed, encoding: .utf8) ?? "")
    }
    let fakeBin = freshDir("s8py")
    try? "#!/bin/sh\necho \"ran $* with $PYTHONPATH\"\n".write(toFile: fakeBin + "/python3", atomically: true, encoding: .utf8)
    chmod(fakeBin + "/python3", 0o755)
    var r = runLauncher(EngineInstall.launcherText, path: fakeBin + ":/usr/bin:/bin")
    check(r.code == 0 && r.out == "ran -m pong.cli.main graph list with \(home)/.pong/lib\n",
          "a real python3 on PATH: the engine runs with the arguments", "\(r)")
    // Apple's stub, with no command line tools: xcode-select stood in for by one that finds none
    let noTools = EngineInstall.launcherText.replacingOccurrences(of: "/usr/bin/xcode-select -p", with: "/usr/bin/false")
    check(noTools != EngineInstall.launcherText, "the stand-in replaced xcode-select")
    r = runLauncher(noTools, path: "/usr/bin:/bin")
    check(r.code == 127 && r.out.isEmpty
          && r.err == "pong: Python isn't installed yet. Install Apple's command line tools (xcode-select --install), then try again.\n",
          "only Apple's python3 and no tools: one plain line, exit 127, the stub never runs", "\(r)")
    r = runLauncher(noTools, path: fakeBin + ":/usr/bin:/bin")
    check(r.code == 0 && r.out.hasPrefix("ran -m pong.cli.main"), "another python3 first on PATH: it runs, tools or not", "\(r)")

    // an older launcher of ours (it ran Apple's stub) is brought up to date; anything else stays
    let oldHome = freshDir("s8old")
    try? fm.createDirectory(atPath: oldHome + "/bin", withIntermediateDirectories: true)
    let oldPath = EngineInstall.launcherPath(home: oldHome)
    try? EngineInstall.olderLauncherTexts[0].write(toFile: oldPath, atomically: true, encoding: .utf8)
    chmod(oldPath, 0o755)
    check(EngineInstall.isOlderLauncher(home: oldHome), "the old three lines are recognised")
    check(EngineInstall.ensureLauncher(home: oldHome, create: false) && read(oldPath) == EngineInstall.launcherText,
          "an older launcher of ours is updated (with or without Python: the new one is safe)", read(oldPath))
    check(SecureFile.mode(oldPath) == 0o755, "still 0755")
    check(!EngineInstall.isOlderLauncher(home: oldHome) && EngineInstall.ensureLauncher(home: oldHome)
          && read(oldPath) == EngineInstall.launcherText, "the new one is left as it is")
    try? (EngineInstall.olderLauncherTexts[0] + "# mine\n").write(toFile: oldPath, atomically: true, encoding: .utf8)
    check(!EngineInstall.isOlderLauncher(home: oldHome) && EngineInstall.ensureLauncher(home: oldHome)
          && read(oldPath).hasSuffix("# mine\n"), "one line more is the person's own: untouched")
    let oldTarget = freshDir("s8oldt") + "/pong"
    try? EngineInstall.olderLauncherTexts[0].write(toFile: oldTarget, atomically: true, encoding: .utf8)
    chmod(oldTarget, 0o755)
    try? fm.removeItem(atPath: oldPath)
    try? fm.createSymbolicLink(atPath: oldPath, withDestinationPath: oldTarget)
    check(!EngineInstall.isOlderLauncher(home: oldHome) && EngineInstall.ensureLauncher(home: oldHome)
          && read(oldTarget) == EngineInstall.olderLauncherTexts[0]
          && (try? fm.attributesOfItem(atPath: oldPath))?[.type] as? FileAttributeType == .typeSymbolicLink,
          "a link to the old text is the person's own: untouched")
    let noPy = EngineInstall.refresh(home: freshDir("s8nopy"), stateDir: freshDir("s8nopyst"), bundleResources: nil,
                                     writeLauncher: false) { }
    check(!noPy.launcher, "the launch check with no Python writes no launcher")
    try? "#!/bin/sh\n# the owner's own\n".write(toFile: launcher, atomically: true, encoding: .utf8)
    chmod(launcher, 0o755)
    check(EngineInstall.ensureLauncher(home: home) && read(launcher).contains("owner's own"), "an existing launcher is never touched")
    check(EngineInstall.launcherState(home: home) == .ready, "a runnable launcher is ready")

    // the person's own link to a checkout on a drive that isn't mounted: left alone
    let linkHome = freshDir("s8link")
    try? fm.createDirectory(atPath: linkHome + "/bin", withIntermediateDirectories: true)
    let linkPath = EngineInstall.launcherPath(home: linkHome)
    try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: "/Volumes/not-mounted-\(UUID().uuidString)/bin/pong")
    check(EngineInstall.launcherState(home: linkHome) == .danglingLink, "a link whose file is gone reads as the person's link, not missing")
    check(!EngineInstall.ensureLauncher(home: linkHome), "ensureLauncher says there is no working command")
    let kind = (try? fm.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType
    check(kind == .typeSymbolicLink, "and the link is still the person's link", "\(String(describing: kind))")
    check((try? fm.destinationOfSymbolicLink(atPath: linkPath))?.hasPrefix("/Volumes/not-mounted-") == true, "pointing where it pointed")
    let linkOutcome = EngineInstall.refresh(home: linkHome, stateDir: freshDir("s8linkstate"), bundleResources: nil) { }
    check(!linkOutcome.launcher && (try? fm.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType == .typeSymbolicLink,
          "the launch check leaves it alone too")
    // a link to a file that is there and runs: ready, untouched
    let target = freshDir("s8target") + "/pong"
    try? "#!/bin/sh\n".write(toFile: target, atomically: true, encoding: .utf8)
    chmod(target, 0o755)
    try? fm.removeItem(atPath: linkPath)
    try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    check(EngineInstall.ensureLauncher(home: linkHome) && EngineInstall.launcherState(home: linkHome) == .ready
          && (try? fm.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType == .typeSymbolicLink,
          "a working link is ready and stays a link")
    chmod(target, 0o644)
    check(EngineInstall.launcherState(home: linkHome) == .notRunnable && !EngineInstall.ensureLauncher(home: linkHome),
          "a link to a file that can't run: not runnable, left alone")

    var kicks = 0
    let res = makeBundle(freshDir("s8b1"), version: "2.0.0", built: "2026-10-07T10:00:00Z")
    var o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res, now: Date(timeIntervalSince1970: 1_791_400_000)) { kicks += 1 }
    let pkg = st + "/lib/pong"
    check(o.seeded && o.decision.seeds, "no engine yet: seeded", "\(o)")
    check(read(pkg + "/cli/main.py") == "print('main')\n", "the package is copied")
    check(!fm.fileExists(atPath: pkg + "/__pycache__"), "bytecode is left behind")
    let stamp = EngineVersion.stamp(pkg + "/INSTALL_STAMP")
    check(stamp["version"] == "2.0.0" && stamp["source"] == EngineInstall.appSource && stamp["build"] == "2026-10-07T10:00:00Z"
          && (stamp["installed_at"] ?? "").hasPrefix("2026-10-"), "INSTALL_STAMP says which build put it there", "\(stamp)")
    check(o.kitSeeded && read(st + "/lib/graph-kit/pplx.py") == "# kit 2.0.0\n", "the graph kit is copied too")
    check(kicks == 1, "the runner is restarted once after a re-seed", "kicks=\(kicks)")
    check(leftovers(st + "/lib").isEmpty, "no staging folders left", "\(leftovers(st + "/lib"))")

    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res) { kicks += 1 }
    check(!o.seeded && !o.kitSeeded && kicks == 1, "the same build again: nothing copied, no restart", "\(o)")

    // a new build of the same version replaces the app's own copy
    try? "print('local edit')\n".write(toFile: pkg + "/cli/main.py", atomically: true, encoding: .utf8)
    let res2 = makeBundle(freshDir("s8b2"), version: "2.0.0", built: "2026-10-08T10:00:00Z")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res2) { kicks += 1 }
    check(o.seeded && read(pkg + "/cli/main.py") == "print('main')\n" && kicks == 2, "another build of the same version: refreshed")

    // the owner installs from a checkout: same version, left alone
    try? "version=2.0.0\nsource=/somewhere/checkout\ninstalled_at=x\n".write(toFile: pkg + "/INSTALL_STAMP", atomically: true, encoding: .utf8)
    try? "print('checkout')\n".write(toFile: pkg + "/cli/main.py", atomically: true, encoding: .utf8)
    let res3 = makeBundle(freshDir("s8b3"), version: "2.0.0", built: "2026-10-09T10:00:00Z")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res3) { kicks += 1 }
    check(!o.seeded && read(pkg + "/cli/main.py") == "print('checkout')\n" && kicks == 2, "a checkout install of the same version is kept")

    // a newer engine is never downgraded
    try? "__version__ = \"2.1.0\"\n".write(toFile: pkg + "/__init__.py", atomically: true, encoding: .utf8)
    let res4 = makeBundle(freshDir("s8b4"), version: "2.0.0", built: "2026-10-10T10:00:00Z")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res4) { kicks += 1 }
    check(!o.seeded && EngineVersion.read(packageDir: pkg) == "2.1.0" && kicks == 2, "a newer installed engine stays")

    // a newer app replaces an older engine; a missing kit comes back on its own
    try? fm.removeItem(atPath: st + "/lib/graph-kit")
    let res5 = makeBundle(freshDir("s8b5"), version: "2.2.0", built: "2026-11-01T10:00:00Z")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res5) { kicks += 1 }
    check(o.seeded && EngineVersion.read(packageDir: pkg) == "2.2.0" && o.kitSeeded && kicks == 3, "a newer app refreshes engine and kit")
    try? fm.removeItem(atPath: st + "/lib/graph-kit")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res5) { kicks += 1 }
    check(!o.seeded && o.kitSeeded && fm.fileExists(atPath: st + "/lib/graph-kit/pplx.py") && kicks == 3,
          "only the kit missing: the kit is copied, the runner left alone")
    check(SecureFile.mode(st + "/lib/graph-kit/pplx.py") == 0o755, "kit files are 0755, as the install script sets them")

    // the person's own tool in the kit folder survives a re-seed: only the app's files are copied
    let kit = st + "/lib/graph-kit"
    try? "# mine\n".write(toFile: kit + "/my-own-tool.py", atomically: true, encoding: .utf8)
    try? "# old\n".write(toFile: kit + "/pplx.py", atomically: true, encoding: .utf8)
    let res6 = makeBundle(freshDir("s8b6"), version: "2.3.0", built: "2026-12-01T10:00:00Z")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res6) { kicks += 1 }
    check(o.seeded && o.kitSeeded && read(kit + "/pplx.py") == "# kit 2.3.0\n", "a re-seed copies the app's kit files over")
    check(read(kit + "/my-own-tool.py") == "# mine\n", "and leaves the person's own file in the kit folder alone")
    check(leftovers(kit).isEmpty && leftovers(st + "/lib").isEmpty, "no temp files left in the kit", "\(leftovers(kit))")
    // one of the app's files missing (deleted by hand): put back, nothing else touched
    try? fm.removeItem(atPath: kit + "/pplx.py")
    o = EngineInstall.refresh(home: home, stateDir: st, bundleResources: res6) { kicks += 1 }
    check(!o.seeded && o.kitSeeded && fm.fileExists(atPath: kit + "/pplx.py") && read(kit + "/my-own-tool.py") == "# mine\n",
          "a missing kit file comes back on its own")

    // a loose dev binary carries no engine: only the launcher
    let home2 = freshDir("s8home2")
    let kicksBefore = kicks
    o = EngineInstall.refresh(home: home2, stateDir: freshDir("s8st2"), bundleResources: nil) { kicks += 1 }
    check(o.launcher && !o.seeded && kicks == kicksBefore, "no bundle: launcher only")
    check(EngineInstall.bundleBuild(bundlePackage: res5 + "/python/pong") == "2026-11-01T10:00:00Z", "build id from BUILD_STAMP")
    try? fm.removeItem(atPath: res5 + "/python/pong/BUILD_STAMP")
    check(EngineInstall.bundleBuild(bundlePackage: res5 + "/python/pong").hasPrefix("mtime-"), "no BUILD_STAMP: the package's time")
}

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
