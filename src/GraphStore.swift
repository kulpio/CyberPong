import AppKit

/// One feed of graphs and chats for the whole app (1.9): the sidebar's counts, Home,
/// the Graphs and Chats pages, notifications and the Dock badge all read it, so a
/// question shows up everywhere at once and `pong graph list` runs once per tick.
final class GraphStore {
    static let shared = GraphStore()
    static let didChange = Notification.Name("PongGraphStoreDidChange")

    private(set) var graphs: [GGraph] = []
    private(set) var architects: [GArchitect] = []
    /// Questions AIs asked with `pong ask`, oldest first.
    private(set) var asks: [GChatAsk] = []
    /// The runner's limits state (2.0): graphs paused for Claude's limits, the week's use. nil = nothing to say.
    private(set) var limits: GLimits?
    /// Whether the graph runner is on (2.0): graphs move past their first step only when it is.
    /// nil = the engine didn't say.
    private(set) var runnerOK: Bool?
    private(set) var loadError = ""
    private(set) var loadedOnce = false
    private(set) var lastLoad: Date = .distantPast

    private var timer: Timer?
    private var inFlight = false
    /// Fast while the window is in front; slow otherwise (the badge and notifications still move).
    var fast = true { didSet { if fast != oldValue { schedule() } } }

    func start() {
        guard timer == nil else { return }
        refresh()
        schedule()
    }

    /// No usable Python on this Mac: every call answers the same until the tools are installed, so the
    /// feed is read at the slow rate even with the window in front.
    var noPython: Bool { loadError == EngineCheck.noPythonMessage }

    private func schedule() {
        timer?.invalidate()
        let quick = fast && !noPython
        let t = Timer(timeInterval: quick ? 2.5 : 15, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = quick ? 0.5 : 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        GraphCLI.listFeed { [weak self] feed, err in
            guard let self else { return }
            self.inFlight = false
            let wasNoPython = self.noPython
            if let feed {
                self.graphs = feed.graphs
                self.architects = feed.architects
                self.asks = feed.asks
                self.limits = feed.limits
                self.runnerOK = feed.runnerOK
                self.loadError = ""
            } else {
                self.loadError = err
            }
            if self.noPython != wasNoPython && self.timer != nil { self.schedule() }
            self.loadedOnce = true
            self.lastLoad = Date()
            NotificationCenter.default.post(name: GraphStore.didChange, object: self)
        }
    }

    // MARK: Derived

    var waiting: [GGraph] { graphs.filter { $0.waitingOnYou } }
    /// Running graphs that don't wait on the person: working, or paused (by them or for a limit).
    var running: [GGraph] { graphs.filter { $0.isRunning && !$0.waitingOnYou } }
    /// Running graphs at work now: not waiting on the person, not paused, and their team is up.
    var working: [GGraph] { graphs.filter { $0.isWorkingNow } }
    /// Running graphs that would be at work, but their team is stopped: they wait for it to start.
    var waitingForTeam: [GGraph] { graphs.filter { $0.waitsForTeam } }
    /// Running graphs held by a pause (the person's, or the runner's at Claude's limits).
    var paused: [GGraph] { graphs.filter { $0.isPausedNow } }
    var finished: [GGraph] { graphs.filter { !$0.isRunning } }
    var liveChats: [GArchitect] { architects.filter { $0.alive } }

    /// Every open question, oldest first: one per waiting gate of a running graph.
    var questions: [(graph: GGraph, gate: GGate)] {
        var out: [(graph: GGraph, gate: GGate)] = []
        for g in graphs where g.isRunning {
            for gate in g.gates { out.append((g, gate)) }
        }
        return out.sorted { ($0.gate.at ?? $0.graph.createdAt) < ($1.gate.at ?? $1.graph.createdAt) }
    }

    /// Running steps that need a hand but ask no question (their AI stopped, a step is stuck).
    var problems: [(graph: GGraph, node: GNode)] {
        var out: [(graph: GGraph, node: GNode)] = []
        for g in graphs where g.isRunning {
            for n in g.nodes where !n.attention.isEmpty && n.status == "running" { out.append((g, n)) }
        }
        return out
    }

    /// Every question as a card's model: the gates' and the chats', oldest first.
    var questionModels: [QuestionModel] {
        (questions.map { QuestionModel(graph: $0.graph, gate: $0.gate) } + asks.map { QuestionModel(ask: $0, store: self) })
            .sorted { $0.openedAt < $1.openedAt }
    }

    /// What the sidebar badge, the Dock and the menu bar count.
    var needsYouCount: Int { questions.count + asks.count + problems.count }

    /// Lift the runner's limit pauses now (`pong limits resume`): the person's "Resume anyway".
    /// `done` gets whether it worked and plain words: the engine's own note ("Nothing was paused for a
    /// limit."), or a sentence saying it didn't work. The engine's error (an exception, a path) goes to
    /// the log, never to the person.
    func resumeLimits(done: @escaping (Bool, String) -> Void) {
        GraphCLI.run(["limits", "resume", "--json"], timeout: 30) { [weak self] r in
            let reply = EngineReply.resume(code: r.code, out: r.out, err: r.err)
            if !reply.ok {
                let err = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                Pong.log("limits resume failed \(r.code): \(err.prefix(300))")
            }
            done(reply.ok, reply.words)
            self?.refresh()
        }
    }

    /// Turn the graph runner on (`pong runtime install-agent`) the way Settings › This Mac's Turn on does,
    /// then read the feed again (SetupActions does both). `done` gets whether it worked and the setup's
    /// own plain words (`RunnerInstall`): the engine isn't in place yet, a test folder, no Python, a
    /// preview. The engine's output goes to the log, never to the person.
    func installRunner(done: @escaping (Bool, String) -> Void) {
        SetupActions.installRunner(.elsewhere) { ok, words in
            done(ok, ok ? words + " Graphs go on past their first step now." : words)
        }
    }
}

/// What a person reads after an engine command they pressed: the engine's own note when its JSON reply
/// carries one, else a plain sentence. Raw output (an exception, a path) is never shown; GraphCLI's own
/// refusal (no Python) is already a plain sentence and passes through. Turn on's words are the setup's
/// (`RunnerInstall.words`). Plain values in and out (tests/swift/questions checks them).
enum EngineReply {
    static func resume(code: Int32, out: String, err: String) -> (ok: Bool, words: String) {
        let reply = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
        let ok = code == 0 && (reply?["ok"] as? Bool ?? true)
        let note = ((reply?["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if ok { return (true, String(note.prefix(200))) }
        if code == 127 && err == EngineCheck.noPythonMessage { return (false, err) }
        return (false, note.isEmpty ? "Couldn't resume the graphs. Try again in a moment." : String(note.prefix(200)))
    }
}
