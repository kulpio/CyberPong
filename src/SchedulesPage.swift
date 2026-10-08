import AppKit

/// Schedules (⌘5): everything that runs on its own, for every team, and when it runs next.
/// Replaces the map's cron panel, the Cron Manager's entry points and Mission's
/// "Describe a schedule…" (ux-review.md §3). Editing still opens the schedule sheet.
/// Every running team's schedules fire (CronSchedule.startRunner); a stopped team's wait.
final class SchedulesPageView: NSView {
    var onOpenTeam: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let doc = Doc()
    private let header = PageHeaderView()
    private var lastSig = ""
    private var runningAskedAt: TimeInterval = 0
    private var menuBoxes: [ClosureBox] = []

    private final class Doc: NSView { override var isFlipped: Bool { true } }

    struct Entry {
        let team: String
        let teamName: String
        let job: CronSchedule.Job
        let next: Date
        let fires: Bool
    }

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
        NotificationCenter.default.addObserver(self, selector: #selector(fired), name: CronSchedule.didFire, object: nil)
    }

    @objc private func fired() {
        lastSig = ""
        if !isHidden { render() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutDoc()
    }

    /// Teams that are up, so their schedules fire: the runner's last look, else the team list.
    static var runningTeams: Set<String> {
        CronSchedule.running.map { $0.intersection(Set(PairState.listPairs())) } ?? Set(PairState.listPairs())
    }

    static func teamName(_ team: String) -> String {
        ((PairState.loadPairsDb()[team] as? [String: Any])?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? team
    }

    static func entries() -> [Entry] {
        let db = Pong.loadJSON(Pong.stateDir + "/cron-schedules.json")
        let pairs = PairState.loadPairsDb()
        let up = runningTeams
        var out: [Entry] = []
        for (team, v) in db where team != "updated" {
            guard let arr = v as? [[String: Any]] else { continue }
            let name = ((pairs[team] as? [String: Any])?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? team
            for d in arr {
                guard let j = CronSchedule.Job.from(d) else { continue }
                out.append(Entry(team: team, teamName: name, job: j, next: j.nextRun(after: Date()),
                                 fires: j.enabled && up.contains(team)))
            }
        }
        return out.sorted { $0.next < $1.next }
    }

    /// "Next run 16:30" for Home's health strip ("" when nothing is scheduled to fire).
    static func nextRunLine() -> String {
        guard let e = entries().first(where: { $0.fires }) else { return "" }
        return "Next run " + PongUI.clock(e.next.timeIntervalSince1970)
    }

    /// "every 15m" → "Every 15 min"; "daily 04:00" → "Every day at 4:00".
    static func plainCadence(_ j: CronSchedule.Job) -> String {
        if abs(j.intervalSec - 86_400) < 2 {
            let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            return "Every day at " + PongUI.clock(midnight + j.phaseSec)
        }
        if j.intervalSec >= 86_400, Int(j.intervalSec) % 86_400 == 0 {
            let d = Int(j.intervalSec) / 86_400
            return d == 7 ? "Every week" : "Every \(d) days"
        }
        if j.intervalSec >= 3600, Int(j.intervalSec) % 3600 == 0 {
            let h = Int(j.intervalSec) / 3600
            return h == 1 ? "Every hour" : "Every \(h) hours"
        }
        if j.intervalSec >= 60 { return "Every \(Int(j.intervalSec) / 60) min" }
        return j.cadence
    }

    func render() {
        // which teams are up is a tmux question: ask it now and then, off the main thread
        let now = Date().timeIntervalSince1970
        if now - runningAskedAt > 10 {
            runningAskedAt = now
            CronSchedule.refreshRunning { [weak self] in
                guard let self, !self.isHidden else { return }
                self.render()
            }
        }
        let list = Self.entries()
        let up = Self.runningTeams
        let sig = list.map { "\($0.team)/\($0.job.id)/\($0.job.enabled)/\($0.job.lastFired)/\($0.next.timeIntervalSince1970)" }.joined(separator: ",")
            + "|\(up.sorted().joined(separator: ","))|\(Int(bounds.width))|\(Int(Date().timeIntervalSince1970 / 60))"
        guard sig != lastSig else { return }
        lastSig = sig
        doc.subviews.forEach { $0.removeFromSuperview() }
        boxes.removeAll()

        let on = list.filter { $0.fires }
        let known = Set(PairState.listPairs() + PairState.listStoppedPairs())
        let waiting = list.filter { $0.job.enabled && !$0.fires && known.contains($0.team) }
        var status = list.isEmpty ? "Nothing runs on its own yet." : Words.plural(list.count, "schedule")
        if let n = on.first { status += " · next run " + PongUI.clock(n.next.timeIntervalSince1970) }
        if !waiting.isEmpty { status += " · \(waiting.count) waiting for a stopped team" }
        header.set(title: "Schedules", status: status)
        doc.addSubview(header)

        if list.isEmpty {
            let teams = PairState.listPairs()
            let empty = EmptyStateView(headline: "Nothing runs on its own yet.",
                                       body: teams.isEmpty ? "Start a team first: a schedule gives one of its AIs a task at set times."
                                                           : "A schedule gives one of a team's AIs a task at set times, like a morning check.",
                                       button: teams.isEmpty ? nil : "New schedule",
                                       action: teams.isEmpty ? nil : { [weak self] in self?.newSchedule() })
            empty.identifier = NSUserInterfaceItemIdentifier("empty")
            doc.addSubview(empty)
            layoutDoc()
            return
        }

        if !on.isEmpty {
            doc.addSubview(eyebrow("Next runs"))
            for e in on.prefix(5) {
                let row = ListRowView(status: .pending)
                let inWords = e.next.timeIntervalSinceNow < 60 ? "now" : "in " + PongUI.duration(e.next.timeIntervalSinceNow)
                row.set(title: e.job.name, subtitle: "\(e.teamName) · \(ownerName(e))", status: .pending,
                        word: PongUI.clock(e.next.timeIntervalSince1970), time: inWords)
                row.marker.status = .pending
                row.onClick = { [weak self] in self?.edit(e) }
                row.identifier = NSUserInterfaceItemIdentifier("next")
                doc.addSubview(row)
            }
        }

        // every schedule, under its team; a team that is no longer set up says so
        let byTeam = Dictionary(grouping: list, by: { $0.team })
        // running teams first, then stopped ones, then teams that are gone
        let rank = { (t: String) -> Int in up.contains(t) ? 0 : (known.contains(t) ? 1 : 2) }
        let order = byTeam.keys.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (byTeam[a]?.first?.teamName ?? a) < (byTeam[b]?.first?.teamName ?? b)
        }
        for team in order {
            guard let rows = byTeam[team] else { continue }
            let gone = !known.contains(team)
            let teamUp = up.contains(team)
            let name = rows.first?.teamName ?? team
            doc.addSubview(eyebrow(gone ? "\(name) · no longer set up" : (teamUp ? name : "\(name) · stopped")))
            if gone {
                let rm = PongButton(title: "Remove its \(Words.plural(rows.count, "schedule"))", style: .quiet, size: .small)
                rm.identifier = NSUserInterfaceItemIdentifier("fold")
                rm.toolTip = "This team is gone, so these never run. Removing them changes nothing else."
                rm.onPress = { [weak self] in self?.removeSchedules(of: team, name: name, count: rows.count) }
                doc.addSubview(rm)
            }
            for e in rows.sorted(by: { $0.job.name < $1.job.name }) {
                let st: PongStatus = e.job.enabled && !gone ? (e.fires ? .working : .paused) : .stopped
                let row = ListRowView(status: st)
                let last = e.job.lastFired > 0 ? "last ran " + PongUI.ago(e.job.lastFired) : "hasn't run yet"
                let word = gone ? "Never runs" : (!e.job.enabled ? "Off" : (e.fires ? "On" : "Waiting"))
                row.set(title: e.job.name, subtitle: "\(Self.plainCadence(e.job)) · \(ownerName(e)) · \(last)", status: st, word: word)
                row.marker.status = gone ? .stopped : (e.job.enabled ? (e.fires ? .pending : .paused) : .stopped)
                row.word.textColor = e.job.enabled && e.fires && !gone ? PongColor.textSecondary : PongColor.textTertiary
                if e.job.enabled && !e.fires && !gone {
                    row.toolTip = "\(e.teamName) is stopped, so this waits. It runs again once the team is started."
                }
                if !gone {
                    let toggle = NSSwitch()
                    toggle.state = e.job.enabled ? .on : .off
                    toggle.controlSize = .small
                    toggle.toolTip = e.job.enabled ? "Turn this schedule off" : "Turn this schedule on"
                    toggle.setAccessibilityLabel("\(e.job.name) on")
                    let box = ClosureBox { [weak self] in
                        var j = e.job
                        j.enabled = toggle.state == .on
                        CronSchedule.upsert(session: e.team, job: j)
                        Toast.show(j.enabled ? "\(j.name) is on." : "\(j.name) is off.")
                        self?.lastSig = ""
                        self?.render()
                    }
                    boxes.append(box)
                    toggle.target = box
                    toggle.action = #selector(ClosureBox.fire)
                    var controls: [NSView] = [toggle]
                    if teamUp {
                        let run = PongButton(title: "Run now", style: .quiet, size: .small)
                        run.toolTip = "Give \(ownerPhrase(e)) this task now. The schedule itself doesn't change."
                        run.onPress = { [weak self, weak run] in self?.runNow(e, button: run) }
                        controls.insert(run, at: 0)
                    }
                    let stack = NSStackView(views: controls)
                    stack.orientation = .horizontal
                    stack.spacing = 8
                    stack.alignment = .centerY
                    row.accessory = stack
                    row.onClick = { [weak self] in self?.edit(e) }
                }
                doc.addSubview(row)
            }
        }
        layoutDoc()
    }

    private var boxes: [ClosureBox] = []

    /// A gone team's schedules: they never run, so removing them is only tidying up.
    private func removeSchedules(of team: String, name: String, count: Int) {
        PongAlert.show(on: window, title: "Remove \(Words.plural(count, "schedule")) of “\(name)”?",
                       message: "The team is no longer set up, so they never run. Nothing else changes.",
                       buttons: [.init("Remove", .destructive), .init("Keep them", .primary)], cancelIndex: 1) { [weak self] i in
            guard i == 0 else { return }
            var db = Pong.loadJSON(Pong.stateDir + "/cron-schedules.json")
            db.removeValue(forKey: team)
            db["updated"] = Date().timeIntervalSince1970
            Pong.writeJSON(Pong.stateDir + "/cron-schedules.json", db)
            Toast.show("Removed.")
            self?.lastSig = ""
            self?.render()
        }
    }

    private func ownerName(_ e: Entry) -> String {
        let o = e.job.ownerId.lowercased()
        if o == "c1" || o.hasPrefix("c") && !o.contains(".") { return "Lead" }
        let entry = PairState.loadPairsDb()[e.team] as? [String: Any] ?? [:]
        let label = Workers.list(from: entry).first { ($0["id"] as? String) == e.job.ownerId }?["label"] as? String
        return label.flatMap { $0.isEmpty ? nil : $0 } ?? "Helper \(e.job.ownerId)"
    }

    /// "the Lead", or a helper by its name.
    private func ownerPhrase(_ e: Entry) -> String {
        let n = ownerName(e)
        return n == "Lead" ? "the Lead" : n
    }

    private func runNow(_ e: Entry, button: PongButton?) {
        button?.isEnabled = false
        CronSchedule.runNow(session: e.team, id: e.job.id) { [weak self] err in
            button?.isEnabled = true
            if let err {
                Toast.show(err)
            } else {
                Toast.show("“\(e.job.name)” went to \(self?.ownerPhrase(e) ?? "the Lead").")
            }
            self?.lastSig = ""
            self?.render()
        }
    }

    private func eyebrow(_ s: String) -> NSView {
        let v = PongUI.eyebrow(s)
        v.identifier = NSUserInterfaceItemIdentifier("eyebrow")
        return v
    }

    /// The seats a schedule can be given to, from pairs.json.
    static func seats(for team: String) -> [Seat3D] {
        let entry = PairState.loadPairsDb()[team] as? [String: Any] ?? [:]
        var out = [Seat3D(session: team, id: "c1", role: "conductor", title: "Lead", subtitle: "", detail: "",
                          status: "idle", parentId: nil, openJobs: 0, flowHint: "", missionRole: "orchestrator")]
        for w in Workers.list(from: entry) {
            let id = (w["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            out.append(Seat3D(session: team, id: id, role: "worker", title: (w["label"] as? String) ?? id, subtitle: "",
                              detail: "", status: "idle", parentId: nil, openJobs: 0, flowHint: "", missionRole: ""))
        }
        return out
    }

    private func edit(_ e: Entry) {
        ScheduleSheet.present(team: e.team, job: e.job, on: window) { [weak self] in
            self?.lastSig = ""
            self?.render()
        }
    }

    /// New schedule. A schedule belongs to a team: with one team it goes there, with
    /// several a menu asks which (running teams first; a stopped team's waits for it).
    func newSchedule() {
        let up = Self.runningTeams
        let live = PairState.listPairs().filter { up.contains($0) }
        let teams = live + (PairState.listPairs() + PairState.listStoppedPairs()).filter { !live.contains($0) }
        var seen = Set<String>()
        let unique = teams.filter { seen.insert($0).inserted }
        guard let first = unique.first else {
            Toast.show("Start a team first: a schedule belongs to a team.")
            return
        }
        guard unique.count > 1, let view = window?.contentView, let win = window else {
            openNew(on: first)
            return
        }
        let menu = NSMenu()
        let head = NSMenuItem(title: "New schedule for…", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menuBoxes.removeAll()
        for t in unique {
            let box = ClosureBox { [weak self] in self?.openNew(on: t) }
            menuBoxes.append(box)
            let item = NSMenuItem(title: Self.teamName(t) + (up.contains(t) ? "" : " (stopped)"),
                                  action: #selector(ClosureBox.fire), keyEquivalent: "")
            item.target = box
            menu.addItem(item)
        }
        let at = view.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: at, in: view)
    }

    private func openNew(on team: String) {
        ScheduleSheet.present(team: team, job: nil, on: window) { [weak self] in
            self?.lastSig = ""
            self?.render()
        }
    }

    private func layoutDoc() {
        let W = scroll.contentSize.width
        let margin: CGFloat = W >= 1200 ? 32 : 24
        let colW = min(824, W - margin * 2)
        let x = margin
        var y: CGFloat = 12
        for v in doc.subviews {
            switch v {
            case let h as PageHeaderView:
                h.frame = NSRect(x: x, y: y, width: colW, height: PageHeaderView.height)
                y += PageHeaderView.height + 12
            case let e as EmptyStateView:
                e.frame = NSRect(x: x, y: y + 24, width: colW, height: EmptyStateView.preferredHeight)
                y += EmptyStateView.preferredHeight + 48
            case let r as ListRowView:
                let h: CGFloat = r.identifier?.rawValue == "next" ? 44 : 52
                r.frame = NSRect(x: x - 4, y: y, width: colW + 8, height: h)
                y += h
            case let b as PongButton where b.identifier?.rawValue == "fold":
                b.frame = NSRect(x: x - 8, y: y - 4, width: b.intrinsicContentSize.width, height: 24)
                y += 24
            default:
                y += 20
                v.frame = NSRect(x: x, y: y, width: colW, height: 16)
                y += 24
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 32, scroll.contentSize.height))
    }
}
