import AppKit

/// A team as the Teams pages show it: from the snapshot when it runs, from pairs.json otherwise.
struct TeamInfo {
    struct Member {
        let id: String
        let name: String
        let ai: String
        let isLead: Bool
        let parent: String?
        let status: PongStatus
        let word: String
        let openJobs: Int
    }

    let id: String
    let name: String
    let running: Bool
    let folder: String
    let brief: String
    let members: [Member]
    let openTasks: Int
    /// Its running graphs, by state: at work, waiting on the person, held by a pause.
    let graphsWorking: Int
    let graphsWaiting: Int
    let graphsPaused: Int
    let chats: Int

    static func status(_ hint: String) -> (PongStatus, String) {
        let h = hint.lowercased()
        if h.contains("human") || h.contains("takeover") { return (.needsYou, "Needs you") }
        if h.contains("busy") || h.contains("running") { return (.working, "Working") }
        if h.contains("hidden") || h.contains("hide") { return (.stale, "Hidden") }
        return (.pending, "Idle")
    }

    static func load(_ id: String, snapshot: [String: Any]?, up: Set<String>? = nil) -> TeamInfo {
        let db = PairState.loadPairsDb()
        let entry = db[id] as? [String: Any] ?? [:]
        // up means its terminals are there: the same test Schedules uses, so the pages say one thing
        let running = (up ?? SchedulesPageView.runningTeams).contains(id)
        let snapTeam = ((snapshot?["teams"] as? [[String: Any]]) ?? []).first { ($0["session"] as? String) == id }
        let display = ((snapTeam?["display_name"] as? String) ?? (entry["display_name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var members: [Member] = []
        let cond = (snapTeam?["conductor"] as? [String: Any]) ?? (entry["conductor"] as? [String: Any]) ?? [:]
        if !cond.isEmpty {
            let (st, word) = running ? status((cond["status_hint"] as? String) ?? "") : (.stopped, "Stopped")
            let type = (cond["type"] as? String) ?? ""
            members.append(Member(id: (cond["id"] as? String) ?? "c1", name: "Lead", ai: Words.ai(type == "custom" ? "" : type, ""),
                                  isLead: true, parent: nil, status: st, word: word, openJobs: 0))
        }
        let workers = (snapTeam?["workers"] as? [[String: Any]]) ?? Workers.list(from: entry)
        var helper = 0
        for w in workers {
            let wid = (w["id"] as? String) ?? ""
            guard !wid.isEmpty, (w["map_visible"] as? Bool) != false else { continue }
            let (st, word) = running ? status((w["status_hint"] as? String) ?? "") : (.stopped, "Stopped")
            let label = ((w["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            helper += 1
            // a helper without a name is numbered in the order shown, never called by its seat id ("w1")
            members.append(Member(id: wid, name: label.isEmpty ? "Helper \(helper)" : label,
                                  ai: Words.ai((w["type"] as? String) ?? "", ""), isLead: false,
                                  parent: (w["parent_id"] as? String).flatMap { $0.isEmpty || $0 == "c1" ? nil : $0 },
                                  status: st, word: word, openJobs: (w["open_jobs"] as? Int) ?? 0))
        }
        let jobs = snapTeam?["jobs"] as? [String: Any]
        let open = (jobs?["open"] as? Int) ?? 0
        let st = GraphStore.shared
        let mine = st.graphs.filter { $0.session == id }
        return TeamInfo(id: id, name: display.isEmpty ? id : display, running: running,
                        folder: (snapTeam?["project_root"] as? String) ?? (entry["project_root"] as? String) ?? "",
                        brief: (snapTeam?["team_brief"] as? String) ?? "",
                        members: members, openTasks: open,
                        graphsWorking: mine.filter { $0.isWorking }.count,
                        graphsWaiting: mine.filter { $0.waitingOnYou }.count,
                        graphsPaused: mine.filter { $0.isPausedNow }.count,
                        chats: st.architects.filter { $0.session == id && $0.alive }.count)
    }

    var leadAI: String { members.first { $0.isLead }?.ai ?? "" }
    var helpers: Int { members.filter { !$0.isLead }.count }
    /// Graphs that are on and not finished, whatever their state.
    var graphsOpen: Int { graphsWorking + graphsWaiting + graphsPaused }

    /// What its graphs are doing: "1 graph needs you · 1 working · 1 paused". A stopped team's graphs
    /// do nothing until it starts: "1 graph waits for it".
    var graphsLine: [String] {
        guard running else {
            return graphsOpen == 0 ? [] : [Words.plural(graphsOpen, "graph") + (graphsOpen == 1 ? " waits" : " wait") + " for it"]
        }
        var parts: [String] = []
        if graphsWaiting > 0 { parts.append(Words.plural(graphsWaiting, "graph") + (graphsWaiting == 1 ? " needs" : " need") + " you") }
        if graphsWorking > 0 { parts.append((parts.isEmpty ? Words.plural(graphsWorking, "graph") + " " : "\(graphsWorking) ") + "working") }
        if graphsPaused > 0 { parts.append((parts.isEmpty ? Words.plural(graphsPaused, "graph") + " " : "\(graphsPaused) ") + "paused") }
        return parts
    }

    /// "Lead: Claude · 2 helpers · 1 graph needs you · 1 working", "… · stopped · 1 graph waits for it".
    var plainLine: String {
        var parts: [String] = []
        if !leadAI.isEmpty { parts.append("Lead: " + leadAI) }
        parts.append(helpers == 0 ? "no helpers" : Words.plural(helpers, "helper"))
        if running { parts += graphsLine }
        if openTasks > 0 { parts.append(Words.plural(openTasks, "task") + " in progress") }
        if !running {
            parts.append("stopped")
            parts += graphsLine
        }
        return parts.joined(separator: " · ")
    }

    var pongStatus: PongStatus {
        if !running { return .stopped }
        if graphsWaiting > 0 || members.contains(where: { $0.status == .needsYou }) { return .needsYou }
        if graphsWorking > 0 || members.contains(where: { $0.status == .working }) { return .working }
        return .pending
    }
}

/// Start a stopped team again under its own name (`pong team start`): its lead and helpers as set
/// up, a chat's lead on its chat's prompt again. Says how it went in a toast.
enum TeamStart {
    private static var starting = Set<String>()

    static func start(_ session: String, name: String, done: (() -> Void)? = nil) {
        guard !starting.contains(session) else { return }
        starting.insert(session)
        Toast.show("Starting \(name)…")
        GraphCLI.run(["-s", session, "team", "start", "--json"], timeout: 60) { r in
            starting.remove(session)
            let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
            if (obj["ok"] as? Bool) == true {
                PairState.invalidatePairsCache()
                Toast.show("\(name) is running again.")
            } else {
                // the engine's refusal, or tmux's or Python's own output: plain words for the person, the rest
                // to the log (GraphActions.failure keeps what was said there)
                let error = (obj["error"] as? String) ?? ""
                let said = !error.isEmpty ? error : (r.err.isEmpty ? r.out : r.err)
                Toast.show(GraphActions.failure(said, refusal(name, said), log: "team start \(session)"), warn: true)
            }
            // which teams are up is a tmux question: ask it again, so every page says "running" at once
            CronSchedule.refreshRunning {
                GraphStore.shared.refresh()
                done?()
            }
        }
    }

    /// What a refused start means, in plain words (`composer.start_team`'s refusals aren't sentences):
    /// the team was already up, or this copy of the app looks at a test folder; else try again.
    static func refusal(_ name: String, _ said: String) -> String {
        if said.contains("is already running") { return "\(name) is already running." }
        if said.contains("not the live one") {
            return "This copy of CyberPong is looking at a test folder: it starts no teams from it."
        }
        return "\(name) didn't start. Try again in a moment."
    }
}

/// Which teams are up, the way every page says it: their terminals are there (the test Schedules uses,
/// so Teams, a team's page and Schedules never disagree). tmux is asked again at most every 10 s.
enum TeamsUp {
    private static var askedAt: TimeInterval = 0

    /// The teams up now; `changed` runs after a fresh look at tmux (only when one was due).
    static func now(changed: @escaping () -> Void) -> Set<String> {
        let t = Date().timeIntervalSince1970
        if t - askedAt > 10 {
            askedAt = t
            CronSchedule.refreshRunning(changed)
        }
        return SchedulesPageView.runningTeams
    }
}

/// Teams (⌘4): every team, running first. A team opens on its members and its map.
final class TeamsListView: NSView {
    var onOpen: ((String) -> Void)?
    var onNewTeam: (() -> Void)?
    /// A team was started from its row: redraw.
    var onChange: (() -> Void)?
    private let scroll = NSScrollView()
    private let doc = Doc()
    private var lastSig = ""
    private final class Doc: NSView { override var isFlipped: Bool { true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.base.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutDoc()
    }

    func render(snapshot: [String: Any]?) {
        let ids = PairState.listPairs() + PairState.listStoppedPairs()
        let up = TeamsUp.now { [weak self] in self?.lastSig = ""; self?.onChange?() }
        let teams = ids.map { TeamInfo.load($0, snapshot: snapshot, up: up) }
        let sig = teams.map { "\($0.id)|\($0.name)|\($0.plainLine)|\($0.pongStatus)" }.joined(separator: ",") + "\(Int(bounds.width))"
        guard sig != lastSig else { return }
        lastSig = sig
        doc.subviews.forEach { $0.removeFromSuperview() }
        let head = PageHeaderView()
        head.identifier = NSUserInterfaceItemIdentifier("header")
        let running = teams.filter { $0.running }
        head.set(title: "Teams", status: teams.isEmpty ? "A team is a lead AI and its helpers, working in terminals on this Mac."
                 : "\(running.count) running · \(teams.count - running.count) stopped")
        doc.addSubview(head)
        if teams.isEmpty {
            let e = EmptyStateView(headline: "No teams yet.",
                                   body: "A team is a lead AI plus helpers. A new graph starts one for you, or start a Pair: a builder and a reviewer.",
                                   button: "New team", action: { [weak self] in self?.onNewTeam?() })
            e.identifier = NSUserInterfaceItemIdentifier("empty")
            doc.addSubview(e)
        }
        for group in [("Running", running), ("Stopped", teams.filter { !$0.running })] where !group.1.isEmpty {
            let e = PongUI.eyebrow(group.0)
            e.identifier = NSUserInterfaceItemIdentifier("eyebrow")
            doc.addSubview(e)
            for t in group.1 {
                let row = ListRowView(status: t.pongStatus)
                row.set(title: t.name, subtitle: t.plainLine, status: t.pongStatus,
                        word: t.running ? (t.pongStatus == .working ? "Working" : (t.pongStatus == .needsYou ? "Needs you" : "Running"))
                                        : "Stopped")
                row.word.textColor = t.pongStatus == .working ? PongColor.live
                    : (t.pongStatus == .needsYou ? PongColor.you : PongColor.textSecondary)
                row.onClick = { [weak self] in self?.onOpen?(t.id) }
                if !t.running {
                    let start = PongButton(title: "Start", style: .secondary, size: .small)
                    start.toolTip = "Start \(t.name) again: its lead and helpers, as it was set up"
                    start.onPress = { [weak self] in
                        TeamStart.start(t.id, name: t.name) { self?.lastSig = ""; self?.onChange?() }
                    }
                    row.accessory = start
                    row.accessoryOnHover = true
                    start.isHidden = true
                }
                doc.addSubview(row)
            }
        }
        layoutDoc()
    }

    private func layoutDoc() {
        let W = scroll.contentSize.width
        let margin: CGFloat = W >= 1000 ? 32 : 24
        let colW = min(900, W - margin * 2)
        var y: CGFloat = 12
        for v in doc.subviews {
            switch v.identifier?.rawValue {
            case "header":
                v.frame = NSRect(x: margin, y: y, width: colW, height: PageHeaderView.height)
                y += PageHeaderView.height + 8
            case "empty":
                v.frame = NSRect(x: margin, y: y + 16, width: colW, height: EmptyStateView.preferredHeight)
                y += EmptyStateView.preferredHeight + 32
            case "eyebrow":
                y += 20
                v.frame = NSRect(x: margin, y: y, width: colW, height: 16)
                y += 24
            default:
                v.frame = NSRect(x: margin - 4, y: y, width: colW + 8, height: 52)
                y += 52
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 32, scroll.contentSize.height))
    }
}

/// One team: who is on it and what each AI is doing, its map, and a line to message the lead
/// (ux-review.md §4, Team). The map is the Teams page's 3D map, hosted in `mapHost`.
final class TeamPageView: NSView, NSTextFieldDelegate {
    var onOpenChat: ((String) -> Void)?
    private(set) var team: TeamInfo?
    let mapHost = NSView()
    private let header = PageHeaderView()
    private let membersEyebrow = PongUI.eyebrow("Members")
    private var rows: [ListRowView] = []
    private let mapEyebrow = PongUI.eyebrow("Map")
    private let composer = NSTextField()
    private let composerBox = NSView()
    private let sendBtn = PongButton(title: "Send", style: .primary)
    private let composerRule = NSView()
    private var lastSig = ""
    private let messagesEyebrow = PongUI.eyebrow("Messages")
    private let messages = TeamMessagesView()
    /// Started from the page: redraw.
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.base.cgColor
        addSubview(header)
        addSubview(membersEyebrow)
        addSubview(mapEyebrow)
        mapHost.wantsLayer = true
        mapHost.setAccessibilityElement(true)
        mapHost.setAccessibilityRole(.image)
        mapHost.setAccessibilityHelp("The Members list above names every AI and what it is doing.")
        mapHost.layer?.backgroundColor = PongColor.void.cgColor
        mapHost.layer?.cornerRadius = PongRadius.card
        mapHost.layer?.masksToBounds = true
        addSubview(mapHost)
        composer.placeholderAttributedString = NSAttributedString(string: "Message the lead…", attributes: [
            .font: PongType.body, .foregroundColor: PongColor.textTertiary])
        composer.font = PongType.body
        composer.textColor = PongColor.textPrimary
        composer.isBezeled = false
        composer.drawsBackground = false
        composer.focusRingType = .none
        composer.delegate = self
        composer.target = self
        composer.action = #selector(send)
        composer.cell?.isScrollable = true
        composer.cell?.wraps = false
        composerBox.wantsLayer = true
        composerBox.layer?.backgroundColor = PongColor.field.cgColor
        composerBox.layer?.cornerRadius = PongRadius.control
        composerBox.layer?.borderWidth = 1
        composerBox.layer?.borderColor = PongColor.control.cgColor
        addSubview(composerBox)
        addSubview(composer)
        sendBtn.onPress = { [weak self] in self?.send() }
        sendBtn.isEnabled = false
        addSubview(sendBtn)
        composerRule.wantsLayer = true
        composerRule.layer?.backgroundColor = PongColor.hairline.cgColor
        addSubview(composerRule)
        addSubview(messagesEyebrow)
        messages.onOpenAll = { [weak self] in
            guard let id = self?.team?.id else { return }
            TeamFocusController.shared.show(session: id)
        }
        addSubview(messages)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ obj: Notification) {
        sendBtn.isEnabled = !(team?.running ?? false) || !composer.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func send() {
        guard let t = team else { return }
        guard t.running else {
            // stopped, the button is Start
            TeamStart.start(t.id, name: t.name) { [weak self] in
                self?.lastSig = ""
                self?.onChange?()
            }
            return
        }
        let text = composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composer.stringValue = ""
        sendBtn.isEnabled = false
        let session = t.id
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HumanConsoleController.deliver(session: session, text: text)
            DispatchQueue.main.async { [weak self] in
                Toast.show(ok ? "Sent to the lead." : "Message not sent: the team isn't running.", warn: !ok)
                self?.messages.reload(session)
            }
        }
    }

    func render(_ id: String, snapshot: [String: Any]?) {
        let up = TeamsUp.now { [weak self] in self?.lastSig = ""; self?.onChange?() }
        let t = TeamInfo.load(id, snapshot: snapshot, up: up)
        let sig = "\(t.id)|\(t.name)|\(t.plainLine)|" + t.members.map { "\($0.id)\($0.word)\($0.openJobs)" }.joined() + "\(Int(bounds.width))"
        team = t
        messages.reload(t.id)
        guard sig != lastSig else { return }
        lastSig = sig
        header.set(title: t.name, status: t.plainLine, marker: t.pongStatus,
                   color: t.running ? PongColor.textSecondary : PongColor.textTertiary)
        mapHost.setAccessibilityLabel("Map of \(t.name): \(t.plainLine)")
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        for m in t.members {
            let row = ListRowView(status: m.status)
            var sub = [m.ai.isEmpty ? "" : m.ai, m.openJobs > 0 ? Words.plural(m.openJobs, "task") + " in progress" : ""].filter { !$0.isEmpty }
            if m.isLead && t.running { sub += t.graphsLine }
            row.set(title: m.name + (m.parent != nil ? "" : ""), subtitle: sub.joined(separator: " · "), status: m.status, word: m.word)
            row.word.textColor = m.status == .working ? PongColor.live : (m.status == .needsYou ? PongColor.you : PongColor.textSecondary)
            if t.running {
                let open = PongButton(title: "Open terminal", style: .quiet, size: .small)
                open.toolTip = "Open this AI's terminal in the Terminal app"
                open.onPress = {
                    DispatchQueue.global(qos: .userInitiated).async {
                        if m.isLead { Pairing.frontConductor(t.id) } else { Workers.frontWorker(pair: t.id, workerId: m.id) }
                    }
                }
                row.accessory = open
                row.accessoryOnHover = true
                open.isHidden = true
            }
            row.identifier = NSUserInterfaceItemIdentifier(m.parent == nil ? "member" : "sub")
            rows.append(row)
            addSubview(row)
        }
        composer.isEnabled = t.running
        composer.placeholderAttributedString = NSAttributedString(string: t.running ? "Message the lead…" : "Start the team to message its lead",
                                                                  attributes: [.font: PongType.body, .foregroundColor: PongColor.textTertiary])
        // stopped, the one button starts it
        sendBtn.title = t.running ? "Send" : "Start team"
        sendBtn.style = t.running ? .primary : .secondary   // one primary per view: the window bar's Start
        sendBtn.toolTip = t.running ? "Send to the lead" : "Start \(t.name) again: its lead and helpers, as it was set up"
        sendBtn.isEnabled = !t.running || !composer.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        messages.reload(t.id)
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let margin: CGFloat = W >= 1000 ? 32 : 24
        let colW = W - margin * 2
        var y: CGFloat = 12
        header.frame = NSRect(x: margin, y: y, width: colW, height: PageHeaderView.height)
        y += PageHeaderView.height + 16
        membersEyebrow.frame = NSRect(x: margin, y: y, width: 200, height: 16)
        y += 24
        // members: at most 5 rows before the map; the rest scroll inside the list (rare)
        let shown = rows.prefix(5)
        for r in rows { r.isHidden = !shown.contains(where: { $0 === r }) }
        for r in shown {
            let indent: CGFloat = r.identifier?.rawValue == "sub" ? 20 : 0
            r.frame = NSRect(x: margin - 4 + indent, y: y, width: colW + 8 - indent, height: 52)
            y += 52
        }
        y += 16
        let composerH: CGFloat = 56
        mapEyebrow.frame = NSRect(x: margin, y: y, width: 200, height: 16)
        // Messages beside the map when there is room, else under it
        let side = colW >= 900
        let msgW: CGFloat = side ? min(360, colW * 0.36) : colW
        messagesEyebrow.frame = side ? NSRect(x: margin + colW - msgW, y: y, width: msgW, height: 16)
                                     : .zero
        y += 24
        let bottom = H - composerH - 12
        if side {
            mapHost.frame = NSRect(x: margin, y: y, width: colW - msgW - 16, height: max(160, bottom - y))
            messages.frame = NSRect(x: margin + colW - msgW, y: y, width: msgW, height: max(160, bottom - y))
        } else {
            let msgH = min(messages.preferredHeight, 170)
            mapHost.frame = NSRect(x: margin, y: y, width: colW, height: max(140, bottom - y - msgH - 32))
            messagesEyebrow.frame = NSRect(x: margin, y: mapHost.frame.maxY + 12, width: 200, height: 16)
            messages.frame = NSRect(x: margin, y: mapHost.frame.maxY + 36, width: colW, height: msgH)
        }
        composerRule.frame = NSRect(x: 0, y: H - composerH, width: W, height: 1)
        let sw = sendBtn.intrinsicContentSize.width
        sendBtn.frame = NSRect(x: W - margin - sw, y: H - composerH + 14, width: sw, height: 28)
        composerBox.frame = NSRect(x: margin, y: H - composerH + 14, width: colW - sw - 8, height: 28)
        composer.frame = composerBox.frame.insetBy(dx: 8, dy: 5)
    }
}

/// The team's conversation with its lead, newest last: what you wrote and what the lead said back
/// (the lines the old Conversation window showed). Screen chrome the reader picked up is left out.
final class TeamMessagesView: NSView {
    struct Line {
        let you: Bool
        let text: String
        let at: Double
    }

    var onOpenAll: (() -> Void)?
    private var lines: [Line] = []
    private var session = ""
    private var loadedAt: TimeInterval = 0
    private var views: [NSView] = []
    private let openAll = PongButton(title: "The whole conversation", style: .quiet, size: .small)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.raised.cgColor
        layer?.cornerRadius = PongRadius.card
        openAll.onPress = { [weak self] in self?.onOpenAll?() }
        addSubview(openAll)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Messages with the lead")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat { CGFloat(max(1, lines.count)) * 22 + 52 }

    /// Words a screen reader picked up from the lead's terminal chrome, not something it said.
    static func isChrome(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("enter to select") || l.contains("to navigate") || l.contains("esc to") || l.hasPrefix("⎿")
            || l.contains("? for shortcuts") || l.contains("bypass permissions")
            || (l.contains(" tokens") && l.contains("·") && (l.contains("thinking") || l.contains("…") || l.contains("...")))
    }

    static func load(_ session: String, limit: Int = 8) -> [Line] {
        let path = Pong.stateDir + "/human/\(session)/chat.jsonl"
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Line] = []
        for row in text.split(separator: "\n").suffix(120) {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(row.utf8))) as? [String: Any] else { continue }
            let kind = d["kind"] as? String ?? ""
            guard kind == "from_you" || kind == "from_orch" else { continue }
            let t = ((d["text"] as? String) ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !t.isEmpty, !isChrome(t) else { continue }
            out.append(Line(you: kind == "from_you", text: t, at: (d["ts"] as? Double) ?? 0))
        }
        return Array(out.suffix(limit))
    }

    /// "now", "12 min", "3 h", then "27 Sep": short enough for its column.
    static func when(_ at: Double) -> String {
        guard at > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - at
        if d < 60 { return "now" }
        if d < 3600 { return "\(Int(d / 60)) min" }
        if d < 86_400 { return "\(Int(d / 3600)) h" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: Date(timeIntervalSince1970: at))
    }

    /// Re-read the log (at most every 3 s unless the team changed).
    func reload(_ id: String) {
        let now = Date().timeIntervalSince1970
        guard id != session || now - loadedAt > 3 else { return }
        session = id
        loadedAt = now
        let fresh = Self.load(id)
        guard fresh.map({ "\($0.at)" }) != lines.map({ "\($0.at)" }) || views.isEmpty else { return }
        lines = fresh
        build()
    }

    private func build() {
        views.forEach { $0.removeFromSuperview() }
        views = []
        if lines.isEmpty {
            let e = PongUI.label("No messages yet. Write to the lead below; its replies show here.", PongType.secondary, PongColor.textTertiary, lines: 2)
            views.append(e)
            addSubview(e)
        }
        for l in lines {
            let who = PongUI.label(l.you ? "You" : "Lead", PongType.metaStrong, l.you ? PongColor.textSecondary : PongColor.textPrimary)
            let text = PongUI.label(l.text, PongType.secondary, l.you ? PongColor.textSecondary : PongColor.textPrimary)
            text.lineBreakMode = .byTruncatingTail
            text.toolTip = l.text
            let when = PongUI.label(Self.when(l.at), PongType.meta, PongColor.textTertiary)
            when.alignment = .right
            for v in [who, text, when] { views.append(v); addSubview(v) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        var y: CGFloat = 12
        if lines.isEmpty, let e = views.first {
            e.frame = NSRect(x: 14, y: y, width: W - 28, height: 34)
            y += 40
        } else {
            // newest last, and the newest kept when the panel is short
            let fit = max(1, Int((bounds.height - 52) / 22))
            let shown = Array(stride(from: 0, to: views.count, by: 3)).suffix(fit)
            for (i, start) in stride(from: 0, to: views.count, by: 3).enumerated() {
                let visible = shown.contains(start)
                for v in views[start..<min(start + 3, views.count)] { v.isHidden = !visible }
                _ = i
            }
            for start in shown {
                views[start].frame = NSRect(x: 14, y: y + 2, width: 38, height: 16)
                views[start + 2].frame = NSRect(x: W - 14 - 64, y: y + 3, width: 64, height: 14)
                views[start + 1].frame = NSRect(x: 56, y: y + 2, width: W - 56 - 14 - 70, height: 16)
                y += 22
            }
        }
        let bw = openAll.intrinsicContentSize.width
        openAll.frame = NSRect(x: 8, y: bounds.height - 34, width: bw, height: 24)
    }
}
