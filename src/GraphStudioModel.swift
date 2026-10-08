import AppKit
import Foundation

// MARK: - The graph surface's data: `pong graph list --json`, parsed tolerantly.
//
// Every field the studio draws comes from the control plane's snapshot of a
// graph (python/pong/graph_engine.py `snapshot_fields` / `snapshot_node`).
// Nothing here decides anything; a missing field reads as empty, never as a
// guess.

enum GJ {
    static func str(_ a: Any?) -> String {
        if let s = a as? String { return s }
        if let n = a as? NSNumber { return n.stringValue }
        return ""
    }
    static func int(_ a: Any?) -> Int {
        if let n = a as? NSNumber { return n.intValue }
        if let s = a as? String, let v = Int(s) { return v }
        return 0
    }
    static func dbl(_ a: Any?) -> Double? {
        if let n = a as? NSNumber { return n.doubleValue }
        if let s = a as? String, let v = Double(s) { return v }
        return nil
    }
    static func bool(_ a: Any?) -> Bool {
        if let b = a as? Bool { return b }
        if let n = a as? NSNumber { return n.boolValue }
        return false
    }
    static func dict(_ a: Any?) -> [String: Any] { (a as? [String: Any]) ?? [:] }
    static func list(_ a: Any?) -> [[String: Any]] { (a as? [[String: Any]]) ?? [] }
    static func strings(_ a: Any?) -> [String] { ((a as? [Any]) ?? []).map { str($0) }.filter { !$0.isEmpty } }
}

/// One rubric line as Jev scored it (probabilities are for people; builders never see them).
struct GJevLine {
    let id: String
    let text: String
    let verdict: String      // pass | under | uncertain | not_assessable | info | unanswered
    let pMeets: Double?
    let expected: Double?
    let levels: Int
    let floorName: String
    let assessable: Double?
    let status: String       // gate | ranker | unusable | too_few_examples | unproven ("" when trust is "all")
    let advisory: Bool       // the question has not earned the right to decide: it advises only
    let type: String         // score | noul | choice
    /// Every level's P (a score, lowest level first) or every option's (a choice, most likely first).
    let probabilities: [(String, Double)]
    let levelNames: [String] // a score's levels, lowest first
    let floor: Int?          // the lowest level that meets the bar

    init(_ d: [String: Any]) {
        status = GJ.str(d["status"])
        advisory = GJ.bool(d["advisory"])
        type = GJ.str(d["type"])
        levelNames = GJ.strings(d["level_names"])
        floor = GJ.dbl(d["floor"]).map { Int($0) }
        let pr = GJ.dict(d["probabilities"]).compactMap { k, v in GJ.dbl(v).map { (k, $0) } }
        probabilities = GJ.str(d["type"]) == "score" ? pr.sorted { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) } : pr.sorted { $0.1 > $1.1 }
        id = GJ.str(d["id"])
        text = GJ.str(d["text"])
        verdict = GJ.str(d["verdict"])
        pMeets = GJ.dbl(d["p_meets"])
        expected = GJ.dbl(d["expected"])
        levels = GJ.int(d["levels"])
        floorName = GJ.str(d["floor_name"])
        assessable = GJ.dbl(d["assessable"])
    }
}

/// Jev's last answer on a node: a grade (lines), a route choice, or a ranking.
struct GJev {
    let mode: String
    let outcome: String
    let summary: String
    let ok: Bool
    let error: String
    let model: String
    let ms: Int
    let lowest: String
    let pick: String
    let winner: String
    let p: Double?
    let probabilities: [(String, Double)]
    let take: Double?
    let ordersAgree: Bool?
    let runnerUp: String
    let withheld: [(String, String)]
    let redactions: [(String, Int)]
    let truncated: Bool
    let lines: [GJevLine]
    let attached: Bool
    let critic: String
    let combined: String
    let jevVerdict: String
    /// What Jev was asked (a route choice or a ranking) and what each option means.
    let question: String
    let optionText: [String: String]

    init?(_ a: Any?) {
        guard let d = a as? [String: Any], !d.isEmpty else { return nil }
        question = GJ.str(d["question"])
        optionText = GJ.dict(d["option_text"]).mapValues { GJ.str($0) }
        mode = GJ.str(d["mode"])
        outcome = GJ.str(d["outcome"])
        summary = GJ.str(d["summary"])
        ok = GJ.bool(d["ok"])
        error = GJ.str(d["error"])
        model = GJ.str(d["model"])
        ms = GJ.int(d["ms"])
        lowest = GJ.str(d["lowest"])
        pick = GJ.str(d["pick"])
        winner = GJ.str(d["winner"])
        p = GJ.dbl(d["p"])
        probabilities = GJ.dict(d["probabilities"]).compactMap { k, v in GJ.dbl(v).map { (k, $0) } }.sorted { $0.1 > $1.1 }
        take = GJ.dbl(d["take"])
        ordersAgree = d["orders_agree"] == nil || d["orders_agree"] is NSNull ? nil : GJ.bool(d["orders_agree"])
        runnerUp = GJ.str(d["runner_up"])
        withheld = GJ.list(d["withheld"]).map { (GJ.str($0["file"]), GJ.str($0["why"])) }
        redactions = GJ.dict(d["redactions"]).map { ($0.key, GJ.int($0.value)) }.sorted { $0.0 < $1.0 }
        truncated = GJ.bool(d["truncated"])
        lines = GJ.list(d["lines"]).map { GJevLine($0) }
        attached = GJ.bool(d["attached"])
        critic = GJ.str(d["critic"])
        combined = GJ.str(d["combined"])
        jevVerdict = GJ.str(d["jev_verdict"])
    }

    /// The lines that decide, weakest first (the snapshot already orders them).
    var gatingLines: [GJevLine] { lines.filter { $0.verdict != "info" } }
}

/// Jev's recommendation at a gate. Blind on one gate in five: shown only after you answer.
struct GAdvice {
    let pending: Bool
    let blind: Bool
    let pick: String
    let p: Double?
    let probabilities: [(String, Double)]
    let error: String
    /// What Jev was asked at the gate and what each answer means.
    let question: String
    let optionText: [String: String]

    init?(_ a: Any?) {
        guard let d = a as? [String: Any], !d.isEmpty else { return nil }
        question = GJ.str(d["question"])
        optionText = GJ.dict(d["option_text"]).mapValues { GJ.str($0) }
        pending = GJ.bool(d["pending"])
        blind = GJ.bool(d["blind"])
        pick = GJ.str(d["pick"])
        p = GJ.dbl(d["p"])
        probabilities = GJ.dict(d["probabilities"]).compactMap { k, v in GJ.dbl(v).map { (k, $0) } }.sorted { $0.1 > $1.1 }
        error = GJ.str(d["error"])
    }
}

struct GNode {
    let id: String
    let role: String
    let status: String
    let seat: String
    let visits: Int
    let lastOutcome: String
    let runtime: String
    let model: String
    let why: String
    let rule: String
    let rejected: [(String, String)]
    let pin: String
    let taskPreview: String
    let jobId: String
    let startedAt: Double?
    let finishedAt: Double?
    let copyOf: String
    let wait: String
    let arrivals: Int
    let retryCount: Int
    let fresh: Bool
    let waitingFor: [String]
    let attention: String
    let ask: String
    let jev: GJev?
    let jevMode: String      // a critic's Jev block: both | shadow | jev ("" = none)
    let claimRead: String
    /// Jev's reading of a closing message that gave no verdict word: the question, every option's P,
    /// and whether the engine took it (only at P >= 0.9).
    let claimQuestion: String
    let claimProbs: [(String, Double)]
    let claimPick: String
    let claimTaken: Bool
    let adviceLog: [(pick: String, p: Double, answer: String)]   // a gate: what Jev suggested, what you said
    let loopId: String       // the innermost loop this node is in ("" = none)
    let loopRound: Int
    let loopMax: Int
    // What the seat's screen showed on the engine's last look (every 30 s; running steps only).
    let liveState: String    // working | quiet | no_model ("" = not read yet)
    let liveDoing: String    // its latest step line
    let liveBusy: Bool       // mid-turn (a spinner, "esc to interrupt")
    let liveChangedAt: Double?
    let liveSeenAt: Double?

    init(_ d: [String: Any]) {
        id = GJ.str(d["id"])
        role = GJ.str(d["role"]).lowercased()
        status = GJ.str(d["status"]).lowercased()
        seat = GJ.str(d["seat"])
        visits = GJ.int(d["visits"])
        lastOutcome = GJ.str(d["last_outcome"])
        runtime = GJ.str(d["runtime"])
        model = GJ.str(d["model"])
        why = GJ.str(d["why"])
        rule = GJ.str(d["rule"])
        rejected = GJ.dict(d["rejected"]).map { ($0.key, GJ.str($0.value)) }.sorted { $0.0 < $1.0 }
        pin = GJ.str(d["pin"])
        taskPreview = GJ.str(d["task_preview"])
        jobId = GJ.str(d["job_id"])
        startedAt = GJ.dbl(d["started_at"])
        finishedAt = GJ.dbl(d["finished_at"])
        copyOf = GJ.str(d["copy_of"])
        wait = GJ.str(d["wait"])
        arrivals = GJ.int(d["arrivals"])
        retryCount = GJ.int(d["retry_count"])
        fresh = GJ.bool(d["fresh"])
        waitingFor = GJ.strings(d["waiting_for"])
        attention = GJ.str(d["attention"])
        ask = GJ.str(d["ask"])
        jev = GJev(d["jev"])
        jevMode = GJ.str(GJ.dict(d["jev_block"])["mode"])
        let lp = GJ.dict(d["loop"])
        loopId = GJ.str(lp["id"])
        loopRound = GJ.int(lp["round"])
        loopMax = GJ.int(lp["max_iters"])
        adviceLog = GJ.list(d["advice_log"]).map { (pick: GJ.str($0["pick"]), p: GJ.dbl($0["p"]) ?? 0, answer: GJ.str($0["answer"])) }
        let lv = GJ.dict(d["live"])
        liveState = GJ.str(lv["state"])
        liveDoing = GJ.str(lv["doing"])
        liveBusy = GJ.bool(lv["busy"])
        liveChangedAt = GJ.dbl(lv["changed_at"])
        liveSeenAt = GJ.dbl(lv["seen_at"])
        let cr = GJ.dict(d["claim_read"])
        claimRead = cr.isEmpty ? "" : "Jev read the verdict-less claim as \(GJ.str(cr["outcome"])) (P \(String(format: "%.2f", GJ.dbl(cr["p"]) ?? 0)))"
        claimQuestion = GJ.str(cr["question"])
        claimProbs = GJ.dict(cr["probabilities"]).compactMap { k, v in GJ.dbl(v).map { (k, $0) } }.sorted { $0.1 > $1.1 }
        claimPick = GJ.str(cr["outcome"])
        claimTaken = cr["taken"] == nil ? true : GJ.bool(cr["taken"])  // older records: only taken readings were kept
    }

    /// "working", "quiet 14m", "no model" — a running seat's state in a word or two ("" when not read yet).
    var liveWord: String {
        guard status == "running" else { return "" }
        switch liveState {
        case "working": return "working"
        case "no_model": return "no model"
        case "quiet":
            let m = Int(max(0, Date().timeIntervalSince1970 - (liveChangedAt ?? Date().timeIntervalSince1970)) / 60)
            return "quiet \(m)m"
        default: return ""
        }
    }

    /// A person, a join or an engine step, not a terminal.
    var isSeatless: Bool { ["human", "join", "end", "check", "jev"].contains(role) }
    var platformGlyph: String {
        if role == "jev" { return "J" }
        switch runtime.lowercased() {
        case "claude": return "C"
        case "grok": return "G"
        case "codex": return "X"
        case "hermes": return "H"
        case "": return ""
        default: return String(runtime.prefix(1)).uppercased()
        }
    }
}

/// A loop the engine found in the topology: an agent loop (a header and the edges back to it)
/// or a person loop (a gate whose answer sends the work round). Each has its own rounds.
struct GLoop {
    let id: String
    let kind: String
    let members: [String]
    let parent: String
    let depth: Int
    let round: Int
    let maxIters: Int
    let status: String

    init(_ d: [String: Any]) {
        id = GJ.str(d["id"])
        kind = GJ.str(d["kind"])
        members = GJ.strings(d["members"])
        parent = GJ.str(d["parent"])
        depth = GJ.int(d["depth"])
        round = GJ.int(d["round"])
        maxIters = GJ.int(d["max_iters"])
        status = GJ.str(d["status"])
    }

    /// A loop in the words its steps use: "Draft · round 1 of 4", "Your answer · round 2 of 4 · finished"
    /// (a step's name, never its id; a person's loop that isn't named for them says it is yours).
    var label: String {
        let r = max(1, round)
        var s = Words.name(id) + " · " + (maxIters > 0 ? "round \(r) of \(maxIters)" : "round \(r)")
        if kind == "person" && !Words.isYourAnswer(id) { s += " · your answer" }
        if status == "bounded" { s += " · out of rounds" } else if status == "done" { s += " · finished" }
        return s
    }
}

struct GEdge: Hashable {
    let from: String
    let to: String
    let on: String
}

struct GGate {
    let node: String
    /// The step whose end opened it ("" on an old record): its report is `summary`.
    let from: String
    let reason: String
    let summary: String
    let artifacts: [String]
    let at: Double?
    let options: [String]
    let advice: GAdvice?
    let jev: GJev?          // the Jev grade that led here (lines, weakest first)
    let ask: GAsk?          // the question in plain words, and what each answer does
    let askPending: Bool    // a plain-words rewrite is on its way
}

/// One fact a person needs to decide a question, and where it comes from (2.0, contract C1):
/// "Edit 19 changes the quote on page 2…" · UPDATE-2026-10-05.md · Edit 19.
struct GDetail: Hashable {
    let text: String
    /// The file the fact comes from, a full path ("" = none).
    let file: String
    /// Where in that file: a heading, an item number, a section ("" = none). The contract's `where`.
    let location: String

    static let maxPoints = 6
    static let maxText = 280
    static let maxTotal = 1_400
    static let maxLocation = 60

    /// Points from a card or an ask: a list of {text, file, where}, a list of strings, one string
    /// (a point per line) or one {text, file, where}, as the engine reads them. Clamped to the
    /// contract's limits; empty points are dropped.
    static func parse(_ a: Any?) -> [GDetail] {
        var raw: [(text: String, file: String, location: String)] = []
        if let s = a as? String {
            raw = s.components(separatedBy: .newlines).map { ($0, "", "") }
        } else if let d = a as? [String: Any] {
            raw = [(GJ.str(d["text"]), GJ.str(d["file"]), GJ.str(d["where"]))]
        } else if let list = a as? [Any] {
            for item in list {
                if let s = item as? String {
                    raw.append((s, "", ""))
                } else if let d = item as? [String: Any] {
                    raw.append((GJ.str(d["text"]), GJ.str(d["file"]), GJ.str(d["where"])))
                }
            }
        }
        var out: [GDetail] = []
        var total = 0
        for r in raw where out.count < maxPoints {
            var text = collapse(r.text)
            // a bullet the writer typed is not part of the fact
            if let m = text.range(of: #"^[•·*\-–]\s+"#, options: .regularExpression) { text.removeSubrange(m) }
            guard !text.isEmpty else { continue }
            if text.count > maxText { text = String(text.prefix(maxText - 1)) + "…" }
            guard total + text.count <= maxTotal else { break }
            total += text.count
            var loc = collapse(r.location)
            if loc.count > maxLocation { loc = String(loc.prefix(maxLocation - 1)) + "…" }
            out.append(GDetail(text: text, file: r.file.trimmingCharacters(in: .whitespacesAndNewlines), location: loc))
        }
        return out
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// A gate's question for a person, in plain words: the engine's first version from the graph's shape,
/// or a small model's rewrite of it (`by` says which). The buttons stay the gate's own answers.
struct GAsk {
    let question: String
    let context: [String]
    let choices: [String: String]
    let by: String
    let root: String         // the project folder the question's files are in
    let files: [String]      // the question's files, full paths that exist
    /// What is being decided, in more depth (C1): the facts, each with its file.
    let detail: [GDetail]
    /// Who wrote the detail: "CyberPong", "Claude Haiku", "the graph's designer".
    let detailBy: String
    /// A helper AI is still writing the detail.
    let detailPending: Bool

    init?(_ a: Any?) {
        guard let d = a as? [String: Any], !GJ.str(d["question"]).isEmpty else { return nil }
        question = GJ.str(d["question"])
        context = GJ.strings(d["context"])
        choices = GJ.dict(d["choices"]).mapValues { GJ.str($0) }
        by = GJ.str(d["by"])
        root = GJ.str(d["root"])
        files = GJ.strings(d["files"])
        detail = GDetail.parse(d["detail"])
        detailBy = GJ.str(d["detail_by"])
        detailPending = GJ.bool(d["detail_pending"])
    }
}

struct GEvent {
    let round: Int
    let node: String
    let outcome: String
    let event: String
    let summary: String
    let at: Double
}

/// A file in the graph's working folder that changed since the graph started.
struct GFile {
    let path: String      // relative to GGraph.filesRoot
    let kb: Double
    let at: Double
    let node: String      // the running step it most likely belongs to ("" = could not tell)
}

struct GRefusal {
    let node: String
    let reason: String
    let at: Double
}

/// A graph architect: a Claude session that designs, launches, watches and edits a project's graphs.
struct GArchitect {
    let id: String
    let session: String
    let title: String
    let seat: String
    let cwd: String
    let graphs: [String]
    let alive: Bool
    let queued: Int
    let createdAt: Double
    /// The AI the architect runs (claude, grok, codex, hermes), its model, and its tmux pane.
    let runtime: String
    let model: String
    let paneId: String

    init(_ d: [String: Any]) {
        id = GJ.str(d["id"])
        session = GJ.str(d["session"])
        title = GJ.str(d["title"])
        seat = GJ.str(d["seat"])
        runtime = GJ.str(d["runtime"]).isEmpty ? "claude" : GJ.str(d["runtime"])
        model = GJ.str(d["model"])
        paneId = GJ.str(d["pane_id"])
        cwd = GJ.str(d["cwd"])
        graphs = GJ.strings(d["graphs"])
        alive = GJ.bool(d["alive"])
        queued = GJ.int(d["queued"])
        createdAt = GJ.dbl(d["created_at"]) ?? 0
    }

    var key: String { session + "/" + id }
}

/// A question an AI asked the person with `pong ask` (1.9): shown as the same card a gate gets.
struct GChatAsk {
    struct Option { let key: String; let label: String; let what: String }
    let id: String
    let session: String
    let seat: String
    let architect: String
    let question: String
    let context: [String]
    let options: [Option]
    let files: [String]
    let createdAt: Double
    /// What is being decided, in more depth (C1): the chat's own points, or a helper AI's.
    let detail: [GDetail]
    /// "the chat" or "Claude Haiku".
    let detailBy: String
    /// A helper AI is still writing the detail.
    let detailPending: Bool

    init(_ d: [String: Any]) {
        id = GJ.str(d["id"])
        session = GJ.str(d["session"])
        seat = GJ.str(d["seat"])
        architect = GJ.str(d["architect"])
        question = GJ.str(d["question"])
        context = GJ.strings(d["context"])
        options = GJ.list(d["options"]).map { Option(key: GJ.str($0["key"]), label: GJ.str($0["label"]), what: GJ.str($0["what"])) }
        files = GJ.strings(d["files"])
        createdAt = GJ.dbl(d["created_at"]) ?? 0
        detail = GDetail.parse(d["detail"])
        detailBy = GJ.str(d["detail_by"])
        detailPending = GJ.bool(d["detail_pending"])
    }

    var key: String { session + "/" + id }
    /// The chat that asked ("session/a_id"), when an architect did.
    var chatKey: String? { architect.isEmpty ? nil : session + "/" + architect }
}

/// Claude's usage limits as the graph runner sees them (2.0, contract C6): whether it paused
/// the running graphs for the 5-hour or the weekly limit, and its last read of the usage screen.
struct GLimits {
    let state: String          // ok | paused_5h | paused_week
    /// When a 5-hour pause lifts by itself.
    let until: Double?
    /// How many graphs the runner paused (it resumes only those).
    let paused: Int
    let sessionPct: Int?
    let weekPct: Int?
    let sessionReset: Double?
    let weekReset: Double?
    /// When the usage screen was last read (nil: never).
    let readAt: Double?
    /// Claude's own "usage credits": "on", "off", or "" when unknown. Shown, never changed.
    let credits: String
    /// The runner's own words for the state.
    let note: String

    init?(_ a: Any?) {
        guard let d = a as? [String: Any], !d.isEmpty else { return nil }
        state = GJ.str(d["state"]).isEmpty ? "ok" : GJ.str(d["state"])
        until = GLimits.time(d["until"])
        paused = (d["paused"] as? [Any])?.count ?? 0
        let u = GJ.dict(d["usage"])
        sessionPct = GJ.dbl(u["session_pct"]).map { Int($0.rounded()) }
        weekPct = GJ.dbl(u["week_pct"]).map { Int($0.rounded()) }
        sessionReset = GLimits.time(u["session_reset"])
        weekReset = GLimits.time(u["week_reset"])
        readAt = GLimits.time(u["read_at"])
        credits = GJ.str(d["credits"])
        note = GJ.str(d["note"])
    }

    var isPaused: Bool { state == "paused_5h" || state == "paused_week" }

    /// Home's line while the runner holds graphs for a limit, and whether it offers "Resume anyway"
    /// (the weekly stop only: the 5-hour pause lifts by itself). nil: nothing is paused.
    /// `clock` words a time the way the Mac shows it.
    func pausedWords(now: Double = Date().timeIntervalSince1970, clock: (Double) -> String) -> (text: String, resume: Bool)? {
        switch state {
        case "paused_5h":
            if let u = until ?? sessionReset, u > now { return ("Graphs paused for Claude's 5-hour limit · back at " + clock(u), false) }
            return ("Graphs paused for Claude's 5-hour limit · back after the reset", false)
        case "paused_week":
            let pct = weekPct.map { "is at \($0)%" } ?? "passed your limit"
            // the weekly reset lifts the pause by itself: say when, the way the 5-hour line does
            let back = (until ?? weekReset).flatMap { $0 > now ? " · back " + clock($0) : nil } ?? ""
            return ("This week's Claude use \(pct) · graphs paused" + back, true)
        default:
            return nil
        }
    }

    /// "Claude this week: 84%": the week was read, is at 80% or more, and nothing is paused.
    var weekWords: String? {
        guard !isPaused, let w = weekPct, w >= 80 else { return nil }
        return "Claude this week: \(w)%"
    }

    /// A time the runner wrote: seconds since 1970, or an ISO 8601 date.
    private static func time(_ a: Any?) -> Double? {
        if let v = GJ.dbl(a), v > 0 { return v }
        guard let s = a as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)?.timeIntervalSince1970
    }
}

/// One read of `pong graph list --json`: the graphs, the graph architects, the open questions,
/// the runner's limits state and whether the runner is on.
struct GFeed {
    let graphs: [GGraph]
    let architects: [GArchitect]
    let asks: [GChatAsk]
    let limits: GLimits?
    /// The graph runner (launchd) that moves graphs on after their first step: nil when the engine
    /// didn't say (an older engine), else whether it is installed and beating.
    let runnerOK: Bool?
}

/// What the app checks before and after running the engine, in plain values (tests/swift/questions
/// checks them): whether a `pong` launcher would run whatever `python3` is on PATH, and whether the
/// graph runner is on.
enum EngineCheck {
    /// What every engine call answers when no usable Python is on this Mac.
    static let noPythonMessage = "Python isn't installed yet: install Apple's command line tools (Help › Set up CyberPong…)."

    /// A launcher that ends in a bare `exec python3 …` (the app's ~/bin/pong, install-control-plane's,
    /// the repo's scripts/pong) runs Apple's stub when no other Python is there; one that names its own
    /// interpreter does not. A Python script whose first line is `#!/usr/bin/env python3` (or Apple's
    /// /usr/bin/python3) reaches the stub the same way.
    static func launchesPathPython(_ script: String) -> Bool {
        let bare: (String) -> Bool = { $0 == "python3" || $0 == "python" || $0 == "/usr/bin/python3" }
        for (n, raw) in script.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if n == 0, line.hasPrefix("#!") {
                let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    .filter { $0 != "/usr/bin/env" && $0 != "-S" }
                if let cmd = words.first, bare(cmd) { return true }
            }
            guard !line.hasPrefix("#") else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let i = words.firstIndex(of: "exec") else { continue }
            // `exec python3 …` or `exec /usr/bin/env python3 …`
            let rest = words.dropFirst(i + 1).filter { $0 != "/usr/bin/env" && $0 != "env" }
            if let cmd = rest.first, bare(cmd) { return true }
        }
        return false
    }

    /// `"runner": {"ok", "installed", "running", "last_beat_s"}` → whether the runner is on; nil when
    /// the engine didn't say.
    static func runnerOK(_ a: Any?) -> Bool? {
        guard let d = a as? [String: Any], let ok = d["ok"] else { return nil }
        if let b = ok as? Bool { return b }
        return (ok as? NSNumber)?.boolValue
    }
}

struct GGraph {
    let id: String
    let session: String
    let teamLabel: String
    let owner: String
    let title: String
    let goalText: String
    let status: String
    let stopReason: String
    let round: Int
    let maxRounds: Int
    let nodes: [GNode]
    let edges: [GEdge]
    let loops: [GLoop]
    let gates: [GGate]
    let recent: [GEvent]
    let files: [GFile]
    let filesRoot: String
    let refusals: [GRefusal]
    let jobs: Int
    let jevCalls: Int
    let maxJobs: Int
    let wallMin: Double
    let maxWallMin: Double
    let manualPause: Bool
    /// Why it is paused: "paused by you", "paused for Claude's 5-hour limit", … ("" when not paused).
    let pauseReason: String
    let held: Int
    let notesPath: String
    let createdAt: Double
    let finishedAt: Double?
    let lastError: String
    /// The graph architect whose chat gets this graph's news ("" when none).
    let architectId: String

    init(_ d: [String: Any]) {
        id = GJ.str(d["id"])
        session = GJ.str(d["session"])
        architectId = GJ.str(GJ.dict(d["architect"])["id"])
        teamLabel = GJ.str(d["team_label"])
        owner = GJ.str(d["owner"])
        let t = GJ.str(d["title"])
        goalText = GJ.str(d["goal_text"]).isEmpty ? GJ.str(d["goal"]) : GJ.str(d["goal_text"])
        title = t.isEmpty ? String(goalText.prefix(60)) : t
        status = GJ.str(d["status"]).lowercased()
        stopReason = GJ.str(d["stop_reason"])
        round = GJ.int(d["round"])
        maxRounds = GJ.int(d["max_rounds"])
        nodes = GJ.list(d["nodes"]).map { GNode($0) }
        loops = GJ.list(d["loops"]).map { GLoop($0) }
        edges = GJ.list(d["edges"]).map { GEdge(from: GJ.str($0["from"]), to: GJ.str($0["to"]), on: GJ.str($0["on"]).isEmpty ? "done" : GJ.str($0["on"])) }
        gates = GJ.list(d["gates"]).map {
            GGate(node: GJ.str($0["node"]), from: GJ.str($0["from"]), reason: GJ.str($0["reason"]), summary: GJ.str($0["summary"]),
                  artifacts: GJ.strings($0["artifacts"]), at: GJ.dbl($0["at"]),
                  options: GJ.strings($0["options"]), advice: GAdvice($0["advice"]), jev: GJev($0["jev"]),
                  ask: GAsk($0["ask"]), askPending: GJ.bool($0["ask_pending"]))
        }
        recent = GJ.list(d["recent"]).map {
            GEvent(round: GJ.int($0["round"]), node: GJ.str($0["node"]), outcome: GJ.str($0["outcome"]),
                   event: GJ.str($0["event"]).isEmpty ? "claim" : GJ.str($0["event"]),
                   summary: GJ.str($0["summary"]), at: GJ.dbl($0["at"]) ?? 0)
        }
        files = GJ.list(d["files"]).map {
            GFile(path: GJ.str($0["path"]), kb: GJ.dbl($0["kb"]) ?? 0, at: GJ.dbl($0["at"]) ?? 0, node: GJ.str($0["node"]))
        }
        filesRoot = GJ.str(d["files_root"])
        refusals = GJ.list(d["refusal_items"]).map {
            GRefusal(node: GJ.str($0["node"]), reason: GJ.str($0["reason"]), at: GJ.dbl($0["at"]) ?? 0)
        }
        let b = GJ.dict(d["budget"])
        jevCalls = GJ.int(b["jev_calls"])
        jobs = GJ.int(b["jobs"])
        maxJobs = GJ.int(b["max_jobs"])
        wallMin = GJ.dbl(b["wall_min"]) ?? 0
        maxWallMin = GJ.dbl(b["max_wall_min"]) ?? 0
        manualPause = GJ.bool(d["manual_pause"])
        pauseReason = GJ.str(d["pause_reason"])
        held = GJ.int(d["held"])
        notesPath = GJ.str(d["notes_path"])
        createdAt = GJ.dbl(d["created_at"]) ?? 0
        finishedAt = GJ.dbl(d["finished_at"])
        lastError = GJ.str(GJ.dict(d["last_error"])["error"])
    }

    var key: String { session + "/" + id }
    var isRunning: Bool { status == "running" }
    var waitingOnYou: Bool { isRunning && (!gates.isEmpty || nodes.contains { !$0.attention.isEmpty && $0.status == "running" }) }
    func node(_ id: String) -> GNode? { nodes.first { $0.id == id } }

    /// What the deck draws. When this string is unchanged the scene is not rebuilt.
    var visualSignature: String {
        var s = "\(id)|\(status)|\(stopReason)|\(round)|\(gates.map { $0.node }.joined(separator: ","))|"
        for n in nodes {
            s += "\(n.id):\(n.status):\(n.visits):\(n.lastOutcome):\(n.runtime):\(n.model):\(n.arrivals):\(n.attention):\(n.jev?.outcome ?? "");"
        }
        for e in edges { s += "\(e.from)>\(e.to)@\(e.on);" }
        for l in loops { s += "L\(l.id):\(l.round)/\(l.maxIters):\(l.status);" }
        return s
    }

    /// One plain-words line for the HUD and the rail.
    var statusLine: String {
        if isRunning && !gates.isEmpty { return "waiting on you at " + gates.map { $0.node }.joined(separator: ", ") }
        if let asking = nodes.first(where: { !$0.attention.isEmpty && $0.status == "running" }) {
            return "\(asking.id) \(asking.attention)"
        }
        if manualPause && isRunning { return "paused by you" + (held > 0 ? " · \(held) held" : "") }
        if isRunning {
            let live = nodes.filter { $0.status == "running" }
            if live.isEmpty { return "running" }
            if live.count == 1, let n = live.first {
                return "running: \(n.id)" + (n.liveWord.isEmpty ? "" : " · " + n.liveWord)
            }
            let quiet = live.filter { $0.liveState == "quiet" }.map { $0.id }
            return "running: " + live.map { $0.id }.joined(separator: ", ") + (quiet.isEmpty ? "" : " · quiet: " + quiet.joined(separator: ", "))
        }
        switch stopReason {
        case "win": return "finished — passed"
        case "cancelled": return "cancelled"
        case "": return status
        default:
            if stopReason.hasPrefix("failed_bounded") { return "stopped — budget: " + stopReason.replacingOccurrences(of: "failed_bounded:", with: "") }
            if stopReason.hasPrefix("no_edge") { return "stopped — no edge for " + stopReason.replacingOccurrences(of: "no_edge:", with: "") }
            return "finished — " + stopReason
        }
    }

    var budgetLine: String {
        var parts = loops.isEmpty ? ["round \(round)/\(maxRounds)"] : ["\(loops.count) loop\(loops.count == 1 ? "" : "s")"]
        parts.append(maxJobs > 0 ? "jobs \(jobs)/\(maxJobs)" : "jobs \(jobs)")
        parts.append(maxWallMin > 0 ? String(format: "%.0f/%.0f min", wallMin, maxWallMin) : String(format: "%.0f min", wallMin))
        if jevCalls > 0 { parts.append("Jev \(jevCalls)") }
        return parts.joined(separator: " · ")
    }

    /// Outcome words a person can give at this gate. The control plane's list
    /// (the snapshot) is the truth; the edges are only a fallback for old records.
    func gateOutcomes(_ node: String) -> [String] {
        if let g = gates.first(where: { $0.node == node }), !g.options.isEmpty { return g.options }
        var out: [String] = []
        for e in edges where e.from == node {
            let o = (e.on == "done" || e.on == "*") ? "approved" : e.on
            if !out.contains(o) { out.append(o) }
        }
        if !out.contains("approved") { out.insert("approved", at: 0) }
        if !out.contains("rejected") { out.append("rejected") }
        return out
    }
}

// MARK: - Running `pong` without a shell string

enum GraphCLI {
    struct Result { let code: Int32; let out: String; let err: String }

    /// Run `pong <args>` off the main thread; the completion runs on main.
    static func run(_ args: [String], timeout: TimeInterval = 30, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runSync(args, timeout: timeout)
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Blocking. Never call on the main thread.
    static func runSync(_ args: [String], timeout: TimeInterval = 30) -> Result {
        let p = Process()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pong.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // The app is not a seat: never let an inherited identity bind these calls (a
        // PONG_SESSION for another team made a gate's next job a refused cross-team write).
        for k in ["PONG_SEAT", "PONG_SESSION", "HERMES_PONG_SESSION", "PONG_TOKEN", "PONG_SESSION_TOKEN"] {
            env.removeValue(forKey: k)
        }
        // A preview reads a made-up state folder: the engine must read the same one, never ~/.pong.
        if UIPreview.isOn, let fake = UIPreview.env["PONG_PREVIEW_STATE"], !fake.isEmpty {
            env["PONG_HOME"] = fake
        }
        if let pong = onPath("pong", env["PATH"] ?? "") {
            // A launcher that runs whatever `python3` is on PATH reaches Apple's stub on a Mac without the
            // command line tools, and the stub asks to install them: every poll brought the dialog back.
            if !pythonReady(env["PATH"] ?? ""), launchesPathPython(pong) {
                return Result(code: 127, out: "", err: EngineCheck.noPythonMessage)
            }
            p.executableURL = URL(fileURLWithPath: pong)
            p.arguments = args
        } else {
            // No `pong` command yet (an app-only install has no ~/bin/pong): run the engine the app
            // seeded into the state folder, then the copy inside the app, the way SessionArchive does.
            guard let py = python(env["PATH"] ?? "") else {
                return Result(code: 127, out: "", err: EngineCheck.noPythonMessage)
            }
            let roots = [Pong.stateDir + "/lib", Bundle.main.resourcePath.map { $0 + "/python" } ?? ""]
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0 + "/pong/cli/main.py") }
            guard !roots.isEmpty else {
                return Result(code: 127, out: "", err: "CyberPong's engine isn't installed on this Mac.")
            }
            env["PYTHONPATH"] = (roots + [env["PYTHONPATH"] ?? ""].filter { !$0.isEmpty }).joined(separator: ":")
            p.executableURL = URL(fileURLWithPath: py)
            p.arguments = ["-m", "pong.cli.main"] + args
        }
        p.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return Result(code: -1, out: "", err: "could not run pong: \(error.localizedDescription)")
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        // Read to EOF before waiting: a large answer would otherwise block the child.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return Result(code: p.terminationStatus,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// The first executable called `name` in a PATH string, the way `/usr/bin/env` finds it.
    static func onPath(_ name: String, _ path: String) -> String? {
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let p = (String(dir) as NSString).appendingPathComponent(name)
            if runnable(p) { return p }
        }
        return nil
    }

    /// An executable file (a folder with its x bit set is not one).
    private static func runnable(_ p: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: p)
    }

    /// Whether a usable Python is there, looked at again at most every 5 s (the graph poll runs every
    /// 2.5 s, off the main thread): file checks only, so it never runs the stub itself.
    private static let pyLock = NSLock()
    private static var pyCache: (at: Date, path: String, ok: Bool)?

    static func pythonReady(_ path: String) -> Bool {
        pyLock.lock()
        defer { pyLock.unlock() }
        if let c = pyCache, c.path == path, Date().timeIntervalSince(c.at) < 5 { return c.ok }
        let ok = python(path) != nil
        pyCache = (Date(), path, ok)
        return ok
    }

    /// Whether the `pong` found on PATH ends in a bare `exec python3` (read once per file and size).
    private static var launcherKinds: [String: (size: Int, bare: Bool)] = [:]

    private static func launchesPathPython(_ pong: String) -> Bool {
        let real = (pong as NSString).resolvingSymlinksInPath
        let size = ((try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? NSNumber)?.intValue ?? -1
        pyLock.lock()
        if let k = launcherKinds[real], k.size == size { pyLock.unlock(); return k.bare }
        pyLock.unlock()
        // a launcher is a few lines; a large file is a real program that found its own interpreter
        guard size >= 0, size < 16_384, let text = try? String(contentsOfFile: real, encoding: .utf8) else { return false }
        let bare = EngineCheck.launchesPathPython(text)
        pyLock.lock()
        launcherKinds[real] = (size, bare)
        pyLock.unlock()
        return bare
    }

    /// A Python 3 that runs: Homebrew's or another on PATH first. Apple's /usr/bin/python3 only when
    /// the command line tools are there; without them it is a stub that asks to install them.
    static func python(_ path: String) -> String? {
        let fm = FileManager.default
        for c in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where runnable(c) { return c }
        for dir in path.split(separator: ":") where !dir.isEmpty && dir != "/usr/bin" {
            let p = String(dir) + "/python3"
            if runnable(p) { return p }
        }
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                     "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        if tools.contains(where: { fm.isExecutableFile(atPath: $0) }), fm.isExecutableFile(atPath: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        return nil
    }

    /// The graphs, the graph architects, the open questions and the limits, from one `pong graph list --json`.
    static func listFeed(completion: @escaping (GFeed?, String) -> Void) {
        run(["graph", "list", "--json", "--done", "24"], timeout: 20) { r in
            guard r.code == 0, let data = r.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, r.err.isEmpty ? "pong graph list failed (exit \(r.code))" : r.err)
                return
            }
            completion(GFeed(graphs: GJ.list(obj["graphs"]).map { GGraph($0) },
                             architects: GJ.list(obj["architects"]).map { GArchitect($0) },
                             asks: GJ.list(obj["asks"]).map { GChatAsk($0) },
                             limits: GLimits(obj["limits"]),
                             runnerOK: EngineCheck.runnerOK(obj["runner"])), "")
        }
    }

    /// The graphs, the graph architects and the open questions, from one `pong graph list --json`.
    static func listGraphsAndArchitects(completion: @escaping ([GGraph]?, [GArchitect], [GChatAsk], String) -> Void) {
        listFeed { feed, err in
            completion(feed?.graphs, feed?.architects ?? [], feed?.asks ?? [], err)
        }
    }

    static func listGraphs(completion: @escaping ([GGraph]?, String) -> Void) {
        run(["graph", "list", "--json", "--done", "24"], timeout: 20) { r in
            guard r.code == 0, let data = r.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, r.err.isEmpty ? "pong graph list failed (exit \(r.code))" : r.err)
                return
            }
            completion(GJ.list(obj["graphs"]).map { GGraph($0) }, "")
        }
    }

    /// Open Terminal on a command (the way the island opens `pong graph new`).
    static func openInTerminal(_ command: String) {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(esc)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

// MARK: - Layout: layers from the start, cycles kept as back edges

enum GraphLayout {
    struct Result {
        var pos: [String: CGPoint] = [:]     // x = layer, y = lane (deck units)
        var backEdges: Set<GEdge> = []
        var layers: Int = 1
        var lanes: Int = 1
        var cycles: [[String]] = []
    }

    static func compute(_ g: GGraph) -> Result {
        var r = Result()
        let ids = g.nodes.map { $0.id }
        guard !ids.isEmpty else { return r }
        var outs: [String: [GEdge]] = [:]
        var indeg: [String: Int] = [:]
        for e in g.edges where ids.contains(e.from) && ids.contains(e.to) {
            outs[e.from, default: []].append(e)
            if e.from != e.to { indeg[e.to, default: 0] += 1 }
        }
        // Roots: nodes nothing points at; else the first node.
        var roots = ids.filter { (indeg[$0] ?? 0) == 0 }
        if roots.isEmpty { roots = [ids[0]] }
        // Depth from the start, breadth first. An edge back to a step no deeper than the one it
        // leaves is a loop back. (Depth first, a retry edge met before the forward one put a whole
        // branch after the step that retries it: writers 2 to 4 drawn after the check.)
        var depth: [String: Int] = [:]
        var queue: [String] = []
        var head = 0
        func spread() {
            while head < queue.count {
                let n = queue[head]
                head += 1
                for e in outs[n] ?? [] where depth[e.to] == nil {
                    depth[e.to] = (depth[n] ?? 0) + 1
                    queue.append(e.to)
                }
            }
        }
        for root in roots where depth[root] == nil {
            depth[root] = 0
            queue.append(root)
        }
        spread()
        for n in ids where depth[n] == nil {
            depth[n] = 0
            queue.append(n)
            spread()
        }
        for e in g.edges where e.from != e.to && depth[e.from] != nil && depth[e.to] != nil
            && depth[e.to]! <= depth[e.from]! {
            r.backEdges.insert(e)
        }
        // Longest-path layering on the DAG that remains: every forward edge goes deeper, so
        // taking the steps by depth is a topological order.
        var layer: [String: Int] = [:]
        let byDepth = queue.enumerated().sorted { (depth[$0.element] ?? 0, $0.offset) < (depth[$1.element] ?? 0, $1.offset) }.map { $0.element }
        for n in byDepth {
            let l = layer[n] ?? 0
            layer[n] = l
            for e in outs[n] ?? [] where !r.backEdges.contains(e) && e.from != e.to {
                layer[e.to] = max(layer[e.to] ?? 0, l + 1)
            }
        }
        // Lanes: order each layer by the mean lane of its parents.
        var byLayer: [Int: [String]] = [:]
        for n in ids { byLayer[layer[n] ?? 0, default: []].append(n) }
        let maxL = byLayer.keys.max() ?? 0
        var lane: [String: Double] = [:]
        var parents: [String: [String]] = [:]
        for e in g.edges where !r.backEdges.contains(e) && e.from != e.to { parents[e.to, default: []].append(e.from) }
        for l in 0...maxL {
            var row = byLayer[l] ?? []
            row.sort { a, b in
                let pa = (parents[a] ?? []).compactMap { lane[$0] }
                let pb = (parents[b] ?? []).compactMap { lane[$0] }
                let ma = pa.isEmpty ? 0 : pa.reduce(0, +) / Double(pa.count)
                let mb = pb.isEmpty ? 0 : pb.reduce(0, +) / Double(pb.count)
                if ma != mb { return ma < mb }
                return (ids.firstIndex(of: a) ?? 0) < (ids.firstIndex(of: b) ?? 0)
            }
            let c = Double(row.count - 1) / 2.0
            for (i, n) in row.enumerated() { lane[n] = Double(i) - c }
            r.lanes = max(r.lanes, row.count)
        }
        for n in ids { r.pos[n] = CGPoint(x: CGFloat(layer[n] ?? 0), y: CGFloat(lane[n] ?? 0)) }
        r.layers = maxL + 1
        r.cycles = stronglyConnected(ids: ids, edges: g.edges).filter { comp in
            comp.count > 1 || g.edges.contains { $0.from == comp[0] && $0.to == comp[0] }
        }
        return r
    }

    /// Tarjan's strongly connected components.
    static func stronglyConnected(ids: [String], edges: [GEdge]) -> [[String]] {
        var index = 0
        var stack: [String] = []
        var onStack: Set<String> = []
        var idx: [String: Int] = [:]
        var low: [String: Int] = [:]
        var out: [[String]] = []
        var adj: [String: [String]] = [:]
        for e in edges { adj[e.from, default: []].append(e.to) }
        func strong(_ v: String) {
            idx[v] = index; low[v] = index; index += 1
            stack.append(v); onStack.insert(v)
            for w in adj[v] ?? [] {
                if idx[w] == nil { strong(w); low[v] = min(low[v]!, low[w]!) }
                else if onStack.contains(w) { low[v] = min(low[v]!, idx[w]!) }
            }
            if low[v] == idx[v] {
                var comp: [String] = []
                while let w = stack.popLast() {
                    onStack.remove(w); comp.append(w)
                    if w == v { break }
                }
                out.append(comp)
            }
        }
        for v in ids where idx[v] == nil { strong(v) }
        return out
    }
}

// MARK: - Colors the studio shares (status first, platform second)

/// Colours for graph and step states: one colour, one job (1.9).
enum GraphPalette {
    static func status(_ s: String, outcome: String = "") -> NSColor {
        switch s {
        case "running": return PongColor.live
        case "waiting_human": return PongColor.you
        case "held": return PongColor.textSecondary
        case "failed": return PongColor.fail
        case "cancelled": return PongColor.textTertiary
        case "waiting": return PongColor.textTertiary
        case "done", "ready":
            if ["fail", "failed", "rejected", "timeout", "lost"].contains(outcome) { return PongColor.fail }
            return PongColor.textSecondary
        default: return PongColor.textTertiary
        }
    }

    static func graphStatus(_ g: GGraph) -> NSColor { g.pongStatus.color }

    /// The AI a step runs on: a quiet identity tint, never a signal colour.
    static func platform(_ glyph: String) -> NSColor {
        switch glyph {
        case "C": return NSColor(srgbRed: 0.91, green: 0.72, blue: 0.56, alpha: 1)
        case "G": return NSColor(srgbRed: 0.66, green: 0.80, blue: 0.93, alpha: 1)
        case "X": return NSColor(srgbRed: 0.63, green: 0.85, blue: 0.72, alpha: 1)
        case "H": return NSColor(srgbRed: 0.80, green: 0.73, blue: 0.95, alpha: 1)
        case "J": return PongColor.textPrimary
        default: return PongColor.textSecondary
        }
    }

    static func role(_ r: String) -> NSColor {
        switch r {
        case "human": return PongColor.you
        case "join", "end": return PongColor.textTertiary
        default: return PongColor.textSecondary
        }
    }
}

enum GraphTime {
    /// "5 min ago", "2 h ago", then the day.
    static func ago(_ t: Double?) -> String {
        guard let t, t > 0 else { return "" }
        return PongUI.ago(t)
    }

    /// The clock in the Mac's own 12- or 24-hour setting; another day adds the date.
    static func clock(_ t: Double) -> String {
        guard t > 0 else { return "" }
        let d = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(d) { return PongUI.clock(t) }
        return PongUI.dayStamp(t) + " " + PongUI.clock(t)
    }

    /// When something comes back: "3:10 PM" today, "Thursday 11:00 AM" this week, else the date.
    static func comesBack(_ t: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard t > 0 else { return "" }
        let d = Date(timeIntervalSince1970: t)
        if Calendar.current.isDateInToday(d) { return PongUI.clock(t) }
        if t > now, t - now < 6 * 86_400 {
            let f = DateFormatter()
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("EEEE")
            return f.string(from: d) + " " + PongUI.clock(t)
        }
        return PongUI.dayStamp(t) + " " + PongUI.clock(t)
    }
}
