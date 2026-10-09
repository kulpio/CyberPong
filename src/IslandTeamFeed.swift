import Foundation

extension IslandInput {
    /// One read of the app's feeds for the notch panel (main thread): the graph feed, which teams are up,
    /// the team names, and the team feed. The model itself never reaches for these (tests fill the input).
    static func fromApp(store: GraphStore = .shared, feed: IslandTeamFeed = .shared,
                        now: Double = Date().timeIntervalSince1970) -> IslandInput {
        var i = IslandInput()
        i.graphs = store.graphs
        i.asks = store.asks
        i.architects = store.architects
        i.limits = store.limits
        i.runnerOK = store.runnerOK
        // Home's rule: no Python, or the engine didn't answer and no graph is known
        i.engineOff = store.noPython || (store.loadedOnce && !store.loadError.isEmpty && store.graphs.isEmpty)
        // questions open before the first good read are not new: they don't nudge at launch
        i.loaded = store.loadedOnce && store.loadError.isEmpty
        i.runningTeams = SchedulesPageView.runningTeams
        let sessions = Set(store.graphs.map { $0.session } + store.asks.map { $0.session })
        i.teamNames = Dictionary(uniqueKeysWithValues: sessions.map { ($0, TeamNames.name($0)) })
        i.teams = feed.teams
        i.now = now
        return i
    }
}

/// The notch panel's own view of the teams (2.1, spec §10.2), so the Teams view stays true while the
/// main window is in the background (its poll stops then). It reads ~/.pong/snapshot.json, which the
/// engine writes on each pass, while that is under 90 s old. When it is older and Teams is on screen
/// (`wanted`: the open Teams view, or the closed line on Teams), it has the engine write a fresh one
/// (`pong snapshot --write-only`, off the main thread, at most every 10 s) and reads that: the file,
/// never the pipe, so a large snapshot can't fill it. The words come from the Teams page (`TeamInfo`),
/// so both say the same; the engine's 2.1 fields add what each member is doing and the lead's latest
/// message. Until the engine sends `teams[].last_message`, the lead's message comes from the team's
/// chat log, read off the main thread while Teams is open.
final class IslandTeamFeed {
    static let shared = IslandTeamFeed()
    static let didChange = Notification.Name("PongIslandTeamFeedDidChange")

    /// The teams, running first as the Teams page lists them.
    private(set) var teams: [IslandTeamInput] = []
    /// When the snapshot it last read was written (0: never).
    private(set) var snapshotAt: Double = 0

    /// Teams is on screen: read every few seconds and keep the snapshot fresh. Off: nothing runs.
    var wanted = false {
        didSet {
            guard wanted != oldValue else { return }
            if wanted { start() } else { stop() }
        }
    }

    /// A snapshot older than this is stale.
    static let freshFor: Double = 90
    /// At most one `pong snapshot` this often.
    static let runEvery: Double = 10

    private var timer: Timer?
    private var reading = false
    private var running = false
    private var lastRun: Double = 0
    private var lastMTime: Double = -1
    private var snapshot: [String: Any]?
    private let queue = DispatchQueue(label: "pong.island.teams", qos: .utility)

    private var path: String { Pong.stateDir + "/snapshot.json" }

    private func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the snapshot when it changed; have the engine write a fresh one when it is stale. The file
    /// work happens off the main thread; the teams are built on it (TeamInfo reads the graph feed).
    func refresh() {
        guard !reading else { return }
        reading = true
        let path = self.path
        let known = lastMTime
        let wantChat = wanted
        queue.async { [weak self] in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            var snap: [String: Any]?
            var chats: [String: (String, Double)] = [:]
            if mtime != known, mtime > 0, let data = FileManager.default.contents(atPath: path),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                snap = obj
                // the lead's latest message from the chat log, for an engine that doesn't send it yet
                if wantChat {
                    for t in GJ.list(obj["teams"]) {
                        let s = GJ.str(t["session"])
                        // only an engine that doesn't send the field at all; null means it hid the message
                        guard !s.isEmpty, t["last_message"] == nil,
                              let line = TeamMessagesView.load(s, limit: 6).last(where: { !$0.you }) else { continue }
                        chats[s] = (line.text, line.at)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if let snap {
                    self.lastMTime = mtime
                    self.snapshot = snap
                    self.snapshotAt = GJ.dbl(snap["generated_at"]) ?? mtime
                    self.rebuild(chats: chats)
                } else if self.snapshot != nil {
                    self.rebuild(chats: [:])   // who is up changes without the file changing
                }
                self.freshen()
            }
        }
    }

    /// Have the engine write a fresh snapshot when Teams is on screen and the file is stale.
    private func freshen() {
        let now = Date().timeIntervalSince1970
        guard wanted, !running, now - snapshotAt > IslandTeamFeed.freshFor, now - lastRun >= IslandTeamFeed.runEvery else { return }
        // a preview never asks the engine (its state is made up, and fixed)
        guard !UIPreview.isOn else { return }
        running = true
        lastRun = now
        GraphCLI.run(["snapshot", "--write-only"], timeout: 30) { [weak self] r in
            guard let self else { return }
            self.running = false
            if r.code != 0 {
                let err = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                Pong.log("island teams: snapshot didn't refresh (\(r.code)): \(err.prefix(200))")
                return
            }
            self.refresh()
        }
    }

    private var chatCache: [String: (String, Double)] = [:]

    private func rebuild(chats: [String: (String, Double)]) {
        guard let snap = snapshot else { return }
        for (k, v) in chats { chatCache[k] = v }
        let up = SchedulesPageView.runningTeams
        let ids = PairState.listPairs() + PairState.listStoppedPairs()
        let snapTeams = GJ.list(snap["teams"])
        var out: [IslandTeamInput] = []
        for id in ids {
            let info = TeamInfo.load(id, snapshot: snap, up: up)
            let raw = snapTeams.first { GJ.str($0["session"]) == id } ?? [:]
            out.append(IslandTeamFeed.input(info, raw: raw, chat: chatCache[id]))
        }
        // running teams first, the way the Teams page reads
        out = out.filter { $0.running } + out.filter { !$0.running }
        guard out != teams else { return }
        teams = out
        NotificationCenter.default.post(name: IslandTeamFeed.didChange, object: self)
    }

    /// One team for the panel: TeamInfo's words, plus the engine's member doing lines and graph steps
    /// (2.1) when the snapshot carries them, and the lead's latest message.
    static func input(_ info: TeamInfo, raw: [String: Any], chat: (String, Double)?) -> IslandTeamInput {
        let cond = GJ.dict(raw["conductor"])
        let workers = GJ.list(raw["workers"])
        var members: [IslandTeamInput.Member] = []
        for m in info.members {
            let src: [String: Any] = m.isLead ? cond : (workers.first { GJ.str($0["id"]) == m.id } ?? [:])
            let graph = GJ.dict(src["graph"])
            let plain = GJ.str(src["doing_plain"])
            members.append(IslandTeamInput.Member(
                isLead: m.isLead, ai: m.ai, status: m.status, word: m.word,
                doing: plain.isEmpty ? (Words.doing(GJ.str(src["doing"])) ?? "") : plain,
                doingAt: GJ.dbl(src["doing_at"]),
                graphTitle: GJ.str(graph["title"]), stepName: GJ.str(graph["step_name"])))
        }
        let last = GJ.dict(raw["last_message"])
        var message = GJ.str(last["text"])
        var at = GJ.dbl(last["at"])
        // the chat log stands in only for an older engine (no field); a null or empty one was hidden on purpose
        if raw["last_message"] == nil, message.isEmpty, let c = chat { message = c.0; at = c.1 }
        // up or not is the Teams page's own test (its terminals are there), so both pages agree
        return IslandTeamInput(session: info.id, name: info.name, running: info.running, status: info.pongStatus,
                               plainLine: info.plainLine, members: members, lastMessage: message, lastMessageAt: at)
    }
}
