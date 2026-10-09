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
    /// Who wants the feed read fast (2.1): "window" while the main window is in front, "island" while
    /// the notch panel is open. Anyone → every 2.5 s; no one → every 15 s, with the file watch
    /// (`watch()`) bringing a change in between.
    private(set) var fastReasons: Set<String> = ["window"]

    /// The main window's reason (PanelController sets it, as before 2.1).
    var fast: Bool {
        get { !fastReasons.isEmpty }
        set { wantFast("window", newValue) }
    }

    /// Ask for the fast rate (or give it up) for one reason. Turning it on reads the feed at once when
    /// the last read is older than a fast tick, so an opened panel shows what is true now.
    func wantFast(_ reason: String, _ on: Bool) {
        let was = !fastReasons.isEmpty
        if on { fastReasons.insert(reason) } else { fastReasons.remove(reason) }
        let now = !fastReasons.isEmpty
        guard now != was else { return }
        if timer != nil { schedule() }
        if now && Date().timeIntervalSince(lastLoad) > 2.5 { refresh() }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        schedule()
        watch()
    }

    // MARK: File watch (2.1, spec §10.1)

    private var stream: FSEventStreamRef?
    private let watchQueue = DispatchQueue(label: "pong.graphstore.watch", qos: .utility)
    /// When the watch last read the feed, and whether a read is already on its way.
    private var lastWatchRead: Date = .distantPast
    private var watchReadPending = false
    private var rereadAfterFlight = false

    /// Read the feed when a graph, a question or the limits change on disk: an FSEvents stream on the
    /// state folder (file events, 0.5 s latency), filtered to `*/work_graph.json`, `*/asks.json` and
    /// `limits-state.json`. One read per change, 0.7 s after it, at most one per 2 s, so a question
    /// reaches the notch panel in a second or two and no `pong` runs unless something changed. The
    /// 15 s timer stays as a backstop.
    func watch() {
        guard stream == nil else { return }
        let root = Pong.stateDir
        var paths = [root]
        let sessions = root + "/sessions"
        // the sessions folder is inside the state folder unless it is a link to somewhere else
        let real = (sessions as NSString).resolvingSymlinksInPath
        if !real.hasPrefix((root as NSString).resolvingSymlinksInPath + "/") { paths.append(sessions) }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let store = Unmanaged<GraphStore>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: GraphStore.watched) {
                DispatchQueue.main.async { store.watchedFileChanged() }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            Pong.log("graph store: the file watch didn't start; the 15 s read carries on")
            return
        }
        FSEventStreamSetDispatchQueue(s, watchQueue)
        FSEventStreamStart(s)
        stream = s
    }

    /// The files whose change is news: a graph's state, a team's questions, the limits.
    static func watched(_ path: String) -> Bool {
        path.hasSuffix("/work_graph.json") || path.hasSuffix("/asks.json") || path.hasSuffix("/limits-state.json")
    }

    private func watchedFileChanged() {
        guard !watchReadPending else { return }
        watchReadPending = true
        let due = max(0.7, 2.0 - Date().timeIntervalSince(lastWatchRead))
        DispatchQueue.main.asyncAfter(deadline: .now() + due) { [weak self] in
            guard let self else { return }
            self.watchReadPending = false
            self.lastWatchRead = Date()
            // a read already on its way may have started before the change: read once more after it
            if self.inFlight { self.rereadAfterFlight = true } else { self.refresh() }
        }
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
            if self.rereadAfterFlight {
                self.rereadAfterFlight = false
                self.refresh()
            }
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
