import AppKit

// Plain words and states for graphs and steps (1.9): the wording review's status-line
// template ("[State]: [what] · [progress] · [time]"), names instead of ids, and one
// PongStatus per graph and step so a state looks the same on every page.

enum Words {
    /// "baseline-review" → "Baseline review"; "c1.arch" stays as it is. The person's own step (a graph's
    /// `me`) is "Your answer": a step is never called "Me" on screen.
    static func name(_ id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains("."), !t.contains("/") else { return t }
        if isYourAnswer(t) { return "Your answer" }
        let spaced = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return t }
        return first.uppercased() + spaced.dropFirst()
    }

    /// A step named for the person rather than for what is decided there ("me", "you", "human"):
    /// its name adds nothing to "Needs your answer".
    static func isYourAnswer(_ id: String) -> Bool {
        ["me", "you", "human", "person", "owner"].contains(id.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// A step's report without the verdict word its AI put first ("win: The plan is ready." → "The plan
    /// is ready."): the state is shown on its own, in words.
    static func report(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = t.lowercased()
        // longest first: "passed:" is not "pass" followed by "ed:"
        let verdicts = ["approved", "rejected", "abstain", "timeout", "passed", "failed", "error", "pass", "fail", "done",
                        "lost", "win", "ok"]
        let cut: String.Index
        if low.hasPrefix("route:") {
            let after = t.index(t.startIndex, offsetBy: 6)
            cut = t[after...].firstIndex(where: { $0.isWhitespace || $0 == ":" }) ?? t.endIndex  // the route's own word
        } else if let w = verdicts.first(where: { low.hasPrefix($0) }) {
            cut = t.index(t.startIndex, offsetBy: w.count)
        } else {
            return t
        }
        var rest = t[cut...].drop { $0 == " " }
        guard let c = rest.first, [":", "—", "–", "-"].contains(c) else { return t }
        rest = rest.dropFirst()
        // "done-ness", "error-free": a hyphen inside a word is not a verdict's dash
        if c == "-", let next = rest.first, !next.isWhitespace { return t }
        rest = rest.drop { $0.isWhitespace }
        guard let first = rest.first else { return t }
        return first.uppercased() + rest.dropFirst()  // a sentence again
    }

    /// An outcome in the words a person reads: "win" → "Passed", "route:fix" → "Chose Fix".
    static func outcome(_ o: String) -> String {
        switch o.lowercased() {
        case "": return ""
        case "win", "pass", "passed": return "Passed"
        case "fail", "failed": return "Didn't pass"
        case "done", "ok": return "Done"
        case "approved": return "Approved"
        case "rejected": return "Sent back"
        case "error": return "Hit an error"
        case "timeout": return "Ran out of time"
        case "lost": return "Lost its work"
        case "abstain": return "Left it to you"  // Jev wasn't asked or didn't answer: a person decides
        case "cancelled": return "Stopped by you"
        default:
            let low = o.lowercased()
            if low.hasPrefix("route:") { return "Chose " + name(String(o.dropFirst(6))) }
            // a graph's stop reasons, the way its status line says them
            if low.hasPrefix("failed_bounded") {
                let b = bounded(o)
                return b.prefix(1).uppercased() + b.dropFirst()
            }
            if low.hasPrefix("no_edge") {
                let after = o.replacingOccurrences(of: "no_edge:", with: "").replacingOccurrences(of: "no_edge", with: "")
                return "No next step" + (after.isEmpty ? "" : " after " + name(after))
            }
            return name(o)
        }
    }

    /// What a graph ran out of, from its "failed_bounded:<what>" stop reason, in lower case: "out of
    /// rounds", "out of jobs", "out of time", "failed the same way twice". Never the engine's own word
    /// ("wall", "no_progress").
    static func bounded(_ reason: String) -> String {
        let what = reason.lowercased().replacingOccurrences(of: "failed_bounded:", with: "")
            .replacingOccurrences(of: "failed_bounded", with: "").trimmingCharacters(in: .whitespaces)
        switch what {
        case "": return "out of budget"
        case "wall", "time", "timeout": return "out of time"
        case "no_progress", "no-progress": return "failed the same way twice"
        default: return "out of " + name(what).lowercased()
        }
    }

    /// The engine's own words for a failure, when they already read as a sentence a person can use
    /// ("Its terminal has closed."): a JSON reply's `error` or `note`, else the text after its last
    /// "error:", else its only line. A capital first, a stop at the end, and no ids, flags, paths,
    /// brackets or exception names. nil: say something plain instead (and log what the engine said).
    static func engineSentence(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s: String
        if t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] {
            s = ((o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["note"] as? String) ?? "")
        } else {
            let lines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let e = lines.last(where: { $0.contains("error:") }), let r = e.range(of: "error:", options: .backwards) {
                s = String(e[r.upperBound...])
            } else if lines.count == 1 {
                s = lines[0]
            } else {
                return nil
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8, s.count <= 240, let first = s.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
              let last = s.last, ".!?".contains(last) else { return nil }
        // engine words a person can't use: ids and flags (g_1, --extend), paths, brackets, exception names
        let jargon = #"[_/\\{}\[\]<>`=|$]|--|[A-Za-z]*(Error|Exception)\b|Errno|Traceback"#
        return s.range(of: jargon, options: .regularExpression) == nil ? s : nil
    }

    /// "claude" + "fable" → "Claude Fable"; "grok" + "grok-4.7" → "Grok 4.7".
    static func ai(_ runtime: String, _ model: String) -> String {
        let rt = runtime.isEmpty ? "" : runtime.prefix(1).uppercased() + runtime.dropFirst()
        var m = model
        if m.lowercased().hasPrefix(runtime.lowercased() + "-") { m = String(m.dropFirst(runtime.count + 1)) }
        m = m.isEmpty ? "" : (m.prefix(1).uppercased() + m.dropFirst())
        return [rt, m].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) " + (n == 1 ? one : (many ?? one + "s"))
    }

    /// What a step's AI is doing, in words a person reads (2.1, spec §10.3), from the line the engine
    /// read off its screen: "Read(src/app.swift)" → "Reading app.swift", "Bash(make test)" → "Running a
    /// command". Other tool syntax ("Skill(…)") is nil: raw tool text is never shown, and the row falls
    /// back to when the step started. A plain sentence passes through, cut at 80 characters on a word.
    static func doing(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // a step bullet the engine left on ("-" and "*" only before a space: "-5% faster" keeps its sign),
        // and Claude's "(ctrl+o to expand)" hint
        while let c = t.first,
              "⏺•●∙·".contains(c) || ("-*>".contains(c) && t.dropFirst().first.map { $0.isWhitespace } == true) {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let r = t.range(of: #"\s*\((?:ctrl|cmd|⌃|⌘)\+?\w+ to (?:expand|see all|collapse)\)\s*$"#,
                           options: [.regularExpression, .caseInsensitive]) {
            t = String(t[..<r.lowerBound])
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // nothing to show, or a line the engine hid because a key was on the screen
        guard t.count >= 3, !t.hasPrefix("(hidden") else { return nil }
        // the same table as the engine's plain_doing: an MCP tool ("notes - list_files (MCP)(…)") is tool
        // text too, and Claude Code's to-do list has its own line
        if t.range(of: #"^[\w.-]+ - [\w .-]+ \(MCP\)"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if t.range(of: #"^Update Todos\b"#, options: .regularExpression) != nil { return "Updating its to-do list" }
        if let open = t.range(of: #"^[A-Za-z_][\w.]*(?: [A-Z][A-Za-z]+)?\("#, options: .regularExpression) {
            let tool = t[open.lowerBound..<t.index(before: open.upperBound)].replacingOccurrences(of: " ", with: "")
            let args = String(t[open.upperBound...])
            switch tool {
            case "Read": return doingFile(args).map { "Reading " + $0 } ?? "Reading a file"
            case "Write", "Update", "Edit", "MultiEdit", "NotebookEdit", "EditNotebook":
                return doingFile(args).map { "Editing " + $0 } ?? "Editing a file"
            case "Bash", "BashOutput", "Shell": return "Running a command"
            case "Search", "Grep", "Glob": return "Searching the files"
            case "WebSearch", "WebFetch", "Fetch": return "Looking on the web"
            case "Task", "Agent": return "Asking a helper"
            default: return nil
            }
        }
        guard t.count > 80 else { return t }
        var cut = String(t.prefix(80))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) >= 40 { cut = String(cut[..<sp]) }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:·-")) + "…"
    }

    /// The file a tool line names, by its name only: "src/app.swift)" → "app.swift",
    /// `file_path: "/x/PLAN.md")` → "PLAN.md". nil when there is none.
    private static func doingFile(_ args: String) -> String? {
        var a = args
        if let end = a.firstIndex(where: { $0 == ")" || $0 == "," }) { a = String(a[..<end]) }
        if let dot = a.range(of: " · ") { a = String(a[..<dot.lowerBound]) }
        a = a.trimmingCharacters(in: .whitespaces)
        for key in ["file_path:", "path:", "notebook_path:", "file:"] where a.lowercased().hasPrefix(key) {
            a = String(a.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        }
        a = a.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        let name = (a as NSString).lastPathComponent
        guard !name.isEmpty, name != "/", name.count <= 60, !name.contains(" ") else { return nil }
        return name
    }

    /// Why Jev wasn't asked or gave no answer, as a sentence in the words Settings uses ("Jev key",
    /// Limits & keys). The engine's own line when it already is one; its older and technical lines
    /// ("no TypeSafe key", "unreachable: URLError", "HTTP 401") in plain words.
    static func jevNotAsked(_ error: String) -> String {
        let e = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = engineSentence(e) { return s }
        let low = e.lowercased()
        if e.isEmpty { return "Jev didn't answer." }
        if low.contains("typesafe key") || low.hasPrefix("jev is not available") {
            return "No Jev key on this Mac, or Jev is switched off in Settings › Limits & keys."
        }
        if low.contains("turned off") { return "Jev is switched off in Settings › Limits & keys." }
        if low.contains("client-facing") { return "This graph's work goes to a client, so it isn't sent to Jev." }
        if low.hasPrefix("unreachable") { return "Jev couldn't be reached." }
        if low.hasPrefix("unavailable") { return "Jev failed several times in a row, so CyberPong waits a few minutes before asking again." }
        if low.hasPrefix("http 401") || low.hasPrefix("http 403") { return "Jev refused the key." }
        if low.hasPrefix("http") { return "Jev's service had a problem." }
        if low.contains("too large") { return "The work was too large to send to Jev." }
        return "Jev couldn't give an answer this time."
    }
}

/// A running graph's one state, from what the engine says and whether its team is up. Home, the
/// Graphs list, a graph's steps, the Plan view and the sidebar all go by it, so a graph on a stopped
/// team (its terminals are gone, after a restart say) is never "working" on one page while Teams says
/// it "waits for it" (Teams counts the engine's own states). Plain values in and out
/// (tests/swift/questions checks it).
enum RunState {
    /// At work now: running, not waiting on the person, not paused, and its team's terminals are there.
    static func working(running: Bool, waitingOnYou: Bool, paused: Bool, teamUp: Bool) -> Bool {
        running && !waitingOnYou && !paused && teamUp
    }

    /// Running and not paused, but its team is stopped: nothing moves until the team starts again.
    static func waitsForTeam(running: Bool, waitingOnYou: Bool, paused: Bool, teamUp: Bool) -> Bool {
        running && !waitingOnYou && !paused && !teamUp
    }

    /// Whether a step at work holds still (no spinner, no timer): its team is stopped, or a pause for
    /// Claude's limits holds it. The person's own pause lets steps at work finish.
    static func holdStill(running: Bool, waitingOnYou: Bool, paused: Bool, pauseReason: String, teamUp: Bool) -> Bool {
        running && !waitingOnYou && (!teamUp || (paused && pauseReason.lowercased().contains("limit")))
    }
}

/// Where each step sits in its graph (2.1, spec §10.3), so a graph can say "step 3 of 4": its place on
/// the longest path from the start steps, with the edges that go back removed (a send-back or a retry
/// never pushes a step later), and the graph's total, the deepest place. Parallel copies share their
/// original's place; the end step isn't counted. With no start step to count from (an old record whose
/// steps all point at each other) there is no total, and the places count from the first step. The
/// engine's own numbers (`nodes[].rank`) win when it sends them. Plain values in and out
/// (tests/swift/island checks it).
enum StepPlaces {
    struct Result: Equatable {
        /// Step id → place, from 1. A step the start can't reach has none.
        var place: [String: Int] = [:]
        /// The deepest place; nil when it isn't known.
        var total: Int?

        /// The step ids at one place, in the graph's order.
        func ids(at p: Int, order: [String]) -> [String] { order.filter { place[$0] == p } }
    }

    struct Step {
        let id: String
        let role: String
        let copyOf: String
        /// The engine's place for it (nil: not sent).
        let rank: Int?
    }

    static func of(_ g: GGraph) -> Result {
        compute(steps: g.nodes.map { Step(id: $0.id, role: $0.role, copyOf: $0.copyOf, rank: $0.rank) },
                edges: g.edges.map { ($0.from, $0.to) }, start: g.start)
    }

    static func compute(steps: [Step], edges: [(String, String)], start: String) -> Result {
        let counted = steps.filter { $0.role != "end" }
        guard !counted.isEmpty else { return Result() }
        // the engine's places, when it sent them for every step it counts (from 0 or from 1)
        let ranks = counted.compactMap { $0.rank }
        if ranks.count == counted.count, let low = ranks.min(), low >= 0 {
            let shift = low == 0 ? 1 : 0
            var r = Result()
            for s in counted { r.place[s.id] = (s.rank ?? 0) + shift }
            r.total = r.place.values.max()
            return r
        }
        // copies are one step here: "write#2" counts as "write"
        let base: [String: String] = Dictionary(counted.map { ($0.id, $0.copyOf.isEmpty ? $0.id : $0.copyOf) },
                                                uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        for s in counted { let b = base[s.id] ?? s.id; if !order.contains(b) { order.append(b) } }
        var outs: [String: [String]] = [:]
        var hasIn = Set<String>()
        for (f, t) in edges {
            guard let bf = base[f], let bt = base[t], bf != bt else { continue }
            if !(outs[bf]?.contains(bt) ?? false) { outs[bf, default: []].append(bt) }
            hasIn.insert(bt)
        }
        var starts: [String] = []
        let s0 = start.trimmingCharacters(in: .whitespaces)
        if !s0.isEmpty, let b = base[s0] ?? (order.contains(s0) ? s0 : nil) { starts = [b] }
        if starts.isEmpty { starts = order.filter { !hasIn.contains($0) } }
        let known = !starts.isEmpty
        if !known { starts = [order[0]] }
        // depth first from the starts: an edge to a step still on the path goes back, and is dropped
        var colour: [String: Int] = [:]   // 1 on the path, 2 finished
        var post: [String] = []
        var back = Set<String>()          // "from>to"
        func visit(_ v: String) {
            colour[v] = 1
            for w in outs[v] ?? [] {
                switch colour[w] {
                case nil: visit(w)
                case 1: back.insert(v + ">" + w)
                default: break
                }
            }
            colour[v] = 2
            post.append(v)
        }
        for s in starts where colour[s] == nil { visit(s) }
        // longest path over what is left: in reverse finishing order every forward edge goes later
        var place: [String: Int] = [:]
        for s in starts { place[s] = 1 }
        for v in post.reversed() {
            guard let p = place[v] else { continue }
            for w in outs[v] ?? [] where !back.contains(v + ">" + w) {
                place[w] = max(place[w] ?? 0, p + 1)
            }
        }
        var r = Result()
        for s in counted { if let p = place[base[s.id] ?? s.id] { r.place[s.id] = p } }
        r.total = known ? place.values.max() : nil
        return r
    }
}

/// Team display names from pairs.json, read at most every few seconds.
enum TeamNames {
    private static var cache: [String: String] = [:]
    private static var at: Date = .distantPast

    static func name(_ session: String) -> String {
        if Date().timeIntervalSince(at) > 5 {
            at = Date()
            cache = [:]
            for (k, v) in PairState.loadPairsDb() {
                if let n = (v as? [String: Any])?["display_name"] as? String {
                    let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { cache[k] = t }
                }
            }
        }
        return cache[session] ?? session
    }
}

extension GGraph {
    var displayTitle: String { title.isEmpty ? Words.name(id) : title }
    var teamName: String { teamLabel.isEmpty ? TeamNames.name(session) : teamLabel }

    /// The graph's one state. One on a stopped team waits for it (never cyan): Teams says "waits for it".
    var pongStatus: PongStatus {
        if isRunning {
            if waitingOnYou { return .needsYou }
            if manualPause { return .paused }
            return teamUp ? .working : .pending
        }
        if stopReason == "win" || stopReason.isEmpty { return .done }
        if stopReason == "cancelled" { return .stopped }
        // "error:<step>": the graph ended because a step hit an error
        if stopReason.hasPrefix("failed") || stopReason.hasPrefix("no_edge") || stopReason.hasPrefix("error")
            || !lastError.isEmpty { return .failed }
        return .done
    }

    /// Minutes it has run, from its budget.
    var runMinutes: Double { wallMin }

    /// Running and not held: not waiting on the person, not paused. A paused graph is never counted or
    /// listed as working (2.0 walkthrough #4). This is the engine's state: Teams counts it as "waits for
    /// it" when the team is stopped; every other page goes by `isWorkingNow`.
    var isWorking: Bool { isRunning && !waitingOnYou && !manualPause }
    /// Running but held by a pause: the person's, or the runner's at Claude's limits.
    var isPausedNow: Bool { isRunning && !waitingOnYou && manualPause }

    /// Its team's terminals are there (the test Teams and Schedules use). A graph on a stopped team
    /// does nothing until the team starts again.
    var teamUp: Bool { SchedulesPageView.runningTeams.contains(session) }
    /// At work now: running, not waiting on the person, not paused, and its team is up.
    var isWorkingNow: Bool { RunState.working(running: isRunning, waitingOnYou: waitingOnYou, paused: manualPause, teamUp: teamUp) }
    /// Running and not paused, but its team is stopped: it waits for the team, as Teams says.
    var waitsForTeam: Bool { RunState.waitsForTeam(running: isRunning, waitingOnYou: waitingOnYou, paused: manualPause, teamUp: teamUp) }

    /// Whether a step at work in this graph holds still. The person's pause lets steps at work finish
    /// ("nothing new starts until you resume"), so one keeps going while its team is up; a pause for
    /// Claude's limits, or a stopped team (paused or not), holds it still.
    func stepsHoldStill(teamUp: Bool) -> Bool {
        RunState.holdStill(running: isRunning, waitingOnYou: waitingOnYou, paused: manualPause, pauseReason: pauseReason, teamUp: teamUp)
    }

    /// "Paused", "Paused for Claude's 5-hour limit", "Paused near Claude's weekly limit".
    var pausedWords: String {
        let r = pauseReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.lowercased().hasPrefix("paused "), r.lowercased() != "paused by you" else { return "Paused" }
        return "Paused" + r.dropFirst(6)
    }

    /// "Working: Baseline review · step 3 of 7 · 26 min".
    var plainStatus: String {
        if isRunning, let gate = gates.first {
            return "Needs your answer" + (Words.isYourAnswer(gate.node) ? "" : ": " + Words.name(gate.node))
        }
        if isRunning, let n = nodes.first(where: { !$0.attention.isEmpty && $0.status == "running" }) {
            return "Needs you: \(Words.name(n.id)) \(n.attention)"
        }
        let steps = nodes.filter { $0.role != "end" }
        if isRunning {
            if manualPause { return pausedWords + (held > 0 ? " · \(held) waiting to start" : "") }
            // its terminals are gone: nothing moves until its team starts (the team's name follows)
            if !teamUp { return "Waits for its team to start" }
            let live = nodes.filter { $0.status == "running" }
            var parts: [String] = []
            if live.isEmpty {
                parts.append("Working")
            } else if live.count == 1, let n = live.first {
                parts.append("Working: " + Words.name(n.id))
                if let i = steps.firstIndex(where: { $0.id == n.id }), steps.count > 1 {
                    parts.append("step \(i + 1) of \(steps.count)")
                }
            } else {
                parts.append("Working: " + live.prefix(3).map { Words.name($0.id) }.joined(separator: ", ")
                             + (live.count > 3 ? " +\(live.count - 3)" : ""))
            }
            if wallMin >= 1 { parts.append(PongUI.duration(wallMin * 60)) }
            return parts.joined(separator: " · ")
        }
        switch pongStatus {
        case .done: return stopReason == "win" ? "Finished · passed" : "Finished"
        case .stopped: return "Stopped by you"
        case .failed:
            if stopReason.hasPrefix("failed_bounded") { return "Stopped · " + Words.bounded(stopReason) }
            if stopReason.hasPrefix("error") {
                let id = stopReason.hasPrefix("error:") ? String(stopReason.dropFirst(6)) : ""
                let step = nodes.first { $0.id == id }?.displayName ?? (id.isEmpty ? "" : Words.name(id))
                return "Failed" + (step.isEmpty ? "" : " · " + step + " hit an error")
            }
            if stopReason.hasPrefix("no_edge") {
                return "Stopped · no next step after " + Words.name(stopReason.replacingOccurrences(of: "no_edge:", with: ""))
            }
            // "failed_check" → "Failed · check"; any other reason (an engine error's "done") adds nothing
            let rest = stopReason.lowercased().hasPrefix("failed") ? String(stopReason.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "_: ")) : ""
            return "Failed" + (rest.isEmpty ? "" : " · " + Words.name(rest).lowercased())
        default: return "Finished"
        }
    }

    /// When it last moved: its latest event, or when it finished or started.
    var lastActivity: Double {
        max(recent.last?.at ?? 0, finishedAt ?? 0, createdAt)
    }
}

extension GNode {
    /// The step's name on screen: its title when the graph gives one, else its id in words ("me" is
    /// "Your answer"). A parallel copy carries its number: "Write 2".
    var displayName: String {
        let base = title.isEmpty ? Words.name(copyOf.isEmpty ? id : copyOf) : title
        guard !copyOf.isEmpty, let hash = id.lastIndex(of: "#"), let n = Int(id[id.index(after: hash)...]) else { return base }
        return base + " \(n)"
    }

    /// A step's state in words, the way a graph's Steps list says it. In a graph that has stopped, a step
    /// that never ran was not reached. (The Steps view and the notch panel's step list both use it.)
    func stepWords(running: Bool = true, paused: Bool = false, finishing: Bool = false, teamDown: Bool = false) -> String {
        if !running && ["pending", "ready", "waiting", ""].contains(status) { return "not reached" }
        if teamDown && status == "running" { return "waits for its team to start" }
        if paused && status == "running" { return "paused with the graph" }
        if finishing && status == "running" { return "finishing, then the graph waits" }
        switch status {
        case "pending", "": return "not started"
        case "ready": return "about to start"
        case "waiting": return "waiting for the steps before it"
        case "waiting_human": return "waiting for your answer"
        case "held": return "held by the pause"
        case "bounded": return "stopped: its rounds are spent"
        case "awaiting_critic": return "waiting for the reviewer"
        case "done":
            switch lastOutcome {
            case "", "done", "ok": return "finished"
            case "win", "pass", "passed": return "finished · passed"
            case "fail", "failed": return "finished · didn't pass"
            case "approved": return "approved"
            case "rejected": return "sent back"
            default: return "finished · " + Words.outcome(lastOutcome).lowercased()  // "hit an error", "chose fix"
            }
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A step's one state. In a paused graph a step that was at work shows paused, not a spinner.
    func pongStatus(graphRunning running: Bool, graphPaused paused: Bool = false) -> PongStatus {
        if !attention.isEmpty && status == "running" { return .needsYou }
        switch status {
        case "running":
            if paused { return .paused }
            return liveState == "quiet" ? .stale : .working
        case "waiting_human": return .needsYou
        case "failed": return .failed
        case "held": return .paused
        case "done":
            return ["fail", "failed", "error", "timeout", "lost"].contains(lastOutcome) ? .failed : .done
        case "cancelled": return .stopped
        default: return running ? .pending : .stopped
        }
    }
}

extension GArchitect {
    var displayTitle: String { title.isEmpty ? Words.name(id) : title }
    /// "Chat · Claude Fable · 3 graphs" (the app calls an architect a chat).
    var plainLine: String {
        var parts = ["Chat", Words.ai(runtime, model)]
        if alive {
            parts.append(graphs.isEmpty ? "no graph yet" : Words.plural(graphs.count, "graph"))
            if queued > 0 { parts.append(Words.plural(queued, "update") + " waiting") }
        } else {
            parts.append("stopped")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
