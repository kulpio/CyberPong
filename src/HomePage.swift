import AppKit

/// Home, "Needs you" (⌘1): the questions only the person can answer, oldest first, then the
/// problems that need a hand, what is working now, and what finished since they last
/// looked. It replaces Mission's top and the status pill (ux-review.md §4).
final class HomePageView: NSView {
    var onOpenGraph: ((String) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onNewGraph: (() -> Void)?
    var onScrolled: ((Bool) -> Void)?
    /// Open a graph on its Screen tab (Watch).
    var onWatchGraph: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let doc = FlippedDoc()
    private let header = PageHeaderView()
    private let health = HealthStripView()
    private var cards: [QuestionCardView] = []
    private var lastSig = ""
    private var tick: Timer?
    /// When Home was last left: "finished since you last looked" counts from here.
    private var lastLook: Double = UserDefaults.standard.double(forKey: "home.lastLook")

    private final class FlippedDoc: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.base.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.cards.forEach { $0.refreshWaited() } }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHidden: Bool {
        didSet {
            // leaving Home: what finished before now has been seen
            if isHidden && !oldValue {
                lastLook = Date().timeIntervalSince1970
                UserDefaults.standard.set(lastLook, forKey: "home.lastLook")
            }
        }
    }

    @objc private func scrolled() {
        onScrolled?(scroll.contentView.bounds.origin.y > 4)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutDoc()
    }

    // MARK: Render

    func render() {
        let st = GraphStore.shared
        let questions = st.questionModels
        let problems = st.problems
        // paused graphs (by the person, or for Claude's limits) are not working: they get their own rows;
        // nor is one whose team is stopped: it waits for its team, as Teams says
        let working = st.working
        let teamWait = st.waitingForTeam
        let paused = st.paused
        let since = lastLook > 0 ? lastLook : Date().timeIntervalSince1970 - 86_400
        let finished = st.finished.filter { ($0.finishedAt ?? 0) > since }.sorted { ($0.finishedAt ?? 0) > ($1.finishedAt ?? 0) }
        // stopped teams by the test Teams and the sidebar use (its terminals are there), a stowed team included
        let up = TeamsUp.now { [weak self] in self?.lastSig = ""; self?.render() }
        let stoppedTeams = (PairState.listPairs() + PairState.listStoppedPairs()).filter { !up.contains($0) }.count
        // the runner moves graphs past their first step: off, a running graph stays where it is
        let runnerOff = st.loadError.isEmpty && st.runnerOK == false
        // graphs stuck where they are: the problem card says so and offers Turn on (the strip only says it)
        let runnerCard = runnerOff && st.graphs.contains(where: { $0.isRunning })

        var sig = "\(st.loadedOnce)|\(st.loadError.isEmpty)|\(st.noPython)|\(runnerOff)|\(runnerCard)|\(stoppedTeams)|\(Int(bounds.width))|"
        // the card's words, details and "details coming" included, so late plain words show up
        sig += questions.map { "\($0.key)#\($0.redrawKey)#\($0.jevLine?.lead ?? "")" }.joined(separator: ",")
        sig += "|" + HealthStripView.limitsKey(st.limits)
        sig += "|" + problems.map { "\($0.graph.key)#\($0.node.id)#\($0.node.attention)" }.joined(separator: ",")
        sig += "|" + working.map { g in g.key + (g.nodes.filter { $0.status == "running" }.map { $0.id }.joined()) }.joined(separator: ",")
        sig += "|" + paused.map { $0.key + $0.plainStatus }.joined(separator: ",")
        sig += "|" + teamWait.map { $0.key }.joined(separator: ",")
        sig += "|\(Int(Date().timeIntervalSince1970 / 300))"  // the rows' times, every five minutes
        sig += "|" + finished.map { $0.key }.joined(separator: ",")
        guard sig != lastSig else { return }
        // a card someone is typing a note in, or answering, is left alone until it is done
        if cards.contains(where: { $0.isEditingNote }) { return }
        lastSig = sig
        let focusedKey = cards.first { $0.focused }?.model.key
        doc.subviews.forEach { $0.removeFromSuperview() }
        cards = []

        // title and status line
        var bits: [String] = []
        let need = questions.count + problems.count
        if need > 0 { bits.append(Words.plural(need, "thing") + " need" + (need == 1 ? "s" : "") + " you") }
        if !working.isEmpty { bits.append(Words.plural(working.count, "graph") + " working") }
        if !teamWait.isEmpty {
            bits.append(teamWait.count == 1 ? "1 graph waits for its team" : "\(teamWait.count) graphs wait for their teams")
        }
        if !paused.isEmpty { bits.append(Words.plural(paused.count, "graph") + " paused") }
        header.set(title: "Needs you", status: st.loadedOnce ? (bits.isEmpty ? "All quiet." : bits.joined(separator: " · ")) : "Reading your graphs…")
        doc.addSubview(header)

        health.update(needs: need, working: working.count, paused: paused.count, stoppedTeams: stoppedTeams,
                      engineOK: st.loadError.isEmpty, runnerOff: runnerOff, offerTurnOn: !runnerCard,
                      nextRun: SchedulesPageView.nextRunLine(), limits: st.limits)
        doc.addSubview(health)

        if st.noPython {
            // the engine needs Python; Apple's command line tools bring it, and the setup installs them
            let p = ProblemCardView(title: "Python isn't installed yet.",
                                    body: "CyberPong's engine needs Apple's command line tools. Set up CyberPong installs them.",
                                    actions: [("Set up CyberPong…", { _ = FirstRunSetup.present(force: true, step: 1) }),
                                              ("Try again", { GraphStore.shared.refresh() })])
            doc.addSubview(p)
        } else if !st.loadError.isEmpty && st.graphs.isEmpty {
            let p = ProblemCardView(title: "CyberPong can't read your graphs.",
                                    body: "The engine didn't answer. Refreshing usually fixes it; if not, open Diagnostics.",
                                    actions: [("Try again", { GraphStore.shared.refresh() }),
                                              ("Diagnostics", { PanelController.shared.goDiagnostics() })])
            // the engine's own words (often a traceback) go to the log, not to a tooltip
            Pong.log("graphs didn't load: \(st.loadError.prefix(600))")
            doc.addSubview(p)
        }

        if runnerCard {
            let p = ProblemCardView(title: "Graphs stop after their first step: the graph runner is off.",
                                    body: "Turn it on and they go on from where they are.",
                                    actions: [("Turn on", { [weak self] in self?.health.turnOnRunner() }),
                                              ("Set up CyberPong…", { _ = FirstRunSetup.present(force: true, step: 1) })])
            doc.addSubview(p)
        }

        for (i, q) in questions.enumerated() {
            let card = QuestionCardView(q, compact: i > 0)
            card.onOpen = { [weak self] in
                if let k = q.graphKey { self?.onOpenGraph?(k) } else if let c = q.chatKey { self?.onOpenChat?(c) }
            }
            card.onFocus = { [weak self] c in
                self?.cards.forEach { $0.focused = $0 === c }
            }
            card.onAnswered = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self?.lastSig = ""; self?.render() }
            }
            // details opened or folded, a note, Details ›: the cards under it move
            card.onHeightChange = { [weak self] in self?.layoutDoc() }
            card.focused = q.key == focusedKey
            cards.append(card)
            doc.addSubview(card)
        }

        for p in problems {
            let g = p.graph, n = p.node
            var actions: [(String, () -> Void)] = [("Open the graph", { [weak self] in self?.onOpenGraph?(g.key) })]
            if n.liveState == "no_model" || n.status == "failed" {
                actions.insert(("Run the step again", {
                    GraphActions.retry(g, node: n.id) { ok, err in
                        // the engine's own sentence when it has one, else plain words; its output goes to the log
                        Toast.show(ok ? "\(Words.name(n.id)) started again."
                                      : GraphActions.failure(err, "\(Words.name(n.id)) didn't start again. Try again in a moment.",
                                                             log: "retry \(g.key) \(n.id)"), warn: !ok)
                    }
                }), at: 0)
            }
            doc.addSubview(ProblemCardView(title: "\(Words.name(n.id)) \(n.attention)",
                                           body: "\(g.displayTitle) · \(g.teamName)", actions: actions))
        }

        if need == 0 && st.loadedOnce && st.loadError.isEmpty && !runnerCard {
            let empty = EmptyStateView(
                headline: "Nothing needs you.",
                body: working.isEmpty ? "When a graph has a question for you, it shows up here."
                                      : "\(Words.plural(working.count, "graph")) \(working.count == 1 ? "is" : "are") working. Questions show up here.",
                button: "New graph", action: { [weak self] in self?.onNewGraph?() })
            empty.identifier = NSUserInterfaceItemIdentifier("empty")
            if st.graphs.isEmpty {
                empty.setChips([
                    ("Research and summarise", { [weak self] in self?.onNewGraph?() }),
                    ("Build and check", { [weak self] in self?.onNewGraph?() }),
                    ("Review a document", { [weak self] in self?.onNewGraph?() }),
                ])
            }
            doc.addSubview(empty)
        }

        if !working.isEmpty {
            doc.addSubview(eyebrowRow("Working now"))
            for g in working.sorted(by: { $0.lastActivity > $1.lastActivity }) {
                let row = ListRowView(status: g.pongStatus)
                row.set(title: g.displayTitle, subtitle: g.plainStatus + " · " + g.teamName, status: g.pongStatus,
                        time: PongUI.ago(g.lastActivity))
                row.onClick = { [weak self] in self?.onOpenGraph?(g.key) }
                let watch = PongButton(title: "Watch", style: .quiet, size: .small)
                watch.toolTip = "Open the working step's screen"
                watch.onPress = { [weak self] in (self?.onWatchGraph ?? self?.onOpenGraph)?(g.key) }
                row.accessory = watch
                row.accessoryOnHover = true
                watch.isHidden = true
                doc.addSubview(row)
            }
        }

        if !teamWait.isEmpty {
            // their team's terminals are gone (a restart, a closed team): Start team brings it back as it
            // was set up, and the graph goes on from where it is
            doc.addSubview(eyebrowRow("Waiting for a team to start"))
            for g in teamWait.sorted(by: { $0.lastActivity > $1.lastActivity }) {
                let row = ListRowView(status: g.pongStatus)
                row.set(title: g.displayTitle, subtitle: g.plainStatus + " · " + g.teamName, status: g.pongStatus,
                        time: PongUI.ago(g.lastActivity))
                row.onClick = { [weak self] in self?.onOpenGraph?(g.key) }
                let start = PongButton(title: "Start team", style: .quiet, size: .small)
                start.toolTip = "Start \(g.teamName) again, as it was set up: the graph goes on from where it is."
                start.onPress = { [weak self] in
                    TeamStart.start(g.session, name: g.teamName) { self?.lastSig = ""; self?.render() }
                }
                row.accessory = start
                doc.addSubview(row)
            }
        }

        if !paused.isEmpty {
            doc.addSubview(eyebrowRow("Paused"))
            for g in paused.sorted(by: { $0.lastActivity > $1.lastActivity }) {
                let row = ListRowView(status: g.pongStatus)
                row.set(title: g.displayTitle, subtitle: g.plainStatus + " · " + g.teamName, status: g.pongStatus,
                        time: PongUI.ago(g.lastActivity))
                row.onClick = { [weak self] in self?.onOpenGraph?(g.key) }
                doc.addSubview(row)
            }
        }

        if !finished.isEmpty {
            doc.addSubview(eyebrowRow("Finished since you last looked"))
            for g in finished.prefix(8) {
                let row = ListRowView(status: g.pongStatus)
                row.set(title: g.displayTitle, subtitle: g.plainStatus + " · " + g.teamName, status: g.pongStatus,
                        time: g.finishedAt.map { PongUI.ago($0) } ?? "")
                row.onClick = { [weak self] in self?.onOpenGraph?(g.key) }
                doc.addSubview(row)
            }
        }
        layoutDoc()
    }

    private func eyebrowRow(_ s: String) -> NSView {
        let v = PongUI.eyebrow(s)
        v.identifier = NSUserInterfaceItemIdentifier("eyebrow")
        return v
    }

    /// No card holds ⌘1–3 any more.
    func clearFocus() { cards.forEach { $0.focused = false } }

    /// Focus the next question card (⌘J), open it in full (a compact one shows its details too),
    /// and scroll to it.
    func focusNextQuestion() {
        guard !cards.isEmpty else { return }
        let i = (cards.firstIndex { $0.focused }.map { $0 + 1 } ?? 0) % cards.count
        for (j, c) in cards.enumerated() { c.focused = j == i }
        if cards[i].compact && !cards[i].answered { cards[i].compact = false }
        layoutDoc()
        doc.scrollToVisible(cards[i].frame.insetBy(dx: 0, dy: -24))
        window?.makeFirstResponder(cards[i])
    }

    /// ⌘1–3 answers the focused card.
    func answerFocused(_ i: Int) -> Bool {
        guard let c = cards.first(where: { $0.focused && !$0.answered }) else { return false }
        // a compact card has only the buttons it shows
        guard i < c.model.answers.count else { return false }
        c.press(i)
        return true
    }

    private func layoutDoc() {
        let W = scroll.contentSize.width
        let margin: CGFloat = W >= 1200 ? 32 : 24
        let colW = min(760, W - margin * 2)
        let x = margin
        var y: CGFloat = 12
        for v in doc.subviews {
            switch v {
            case let h as PageHeaderView:
                h.frame = NSRect(x: x, y: y, width: colW, height: PageHeaderView.height)
                y += PageHeaderView.height + 16
            case let hs as HealthStripView:
                hs.frame = NSRect(x: x, y: y, width: colW, height: hs.preferredHeight)
                y += hs.preferredHeight + 20
            case let c as QuestionCardView:
                let h = c.height(for: colW)
                c.frame = NSRect(x: x, y: y, width: colW, height: h)
                y += h + 12
            case let p as ProblemCardView:
                let h = p.height(for: colW)
                p.frame = NSRect(x: x, y: y, width: colW, height: h)
                y += h + 12
            case let e as EmptyStateView:
                e.frame = NSRect(x: x, y: y, width: colW, height: EmptyStateView.preferredHeight + 24)
                y += EmptyStateView.preferredHeight + 36
            case let r as ListRowView:
                r.frame = NSRect(x: x - 4, y: y, width: colW + 8, height: 52)
                y += 52
            default:
                if v.identifier?.rawValue == "eyebrow" {
                    y += 20
                    v.frame = NSRect(x: x, y: y, width: colW, height: 16)
                    y += 24
                }
            }
        }
        doc.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 32, scroll.contentSize.height))
    }
}

/// "◆ 2 need you · ◠ 1 working · ‖ 1 paused · ■ 1 stopped" … "✓ Engine OK · Next run 16:30". When the
/// graph runner is off, the right side says "✕ Graph runner off" with Turn on (graphs stop after their
/// first step without it). When the runner paused graphs for Claude's limits, a second line says so in
/// plain words (2.0, contract C6): "◆ Graphs paused for Claude's 5-hour limit · back at 3:10 pm", or the
/// weekly stop with when it lifts and "Resume anyway". A week past 80% shows quietly on the right:
/// "Claude this week: 84%".
final class HealthStripView: NSView {
    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")
    private let limitLine = NSTextField(labelWithString: "")
    private let resume = PongButton(title: "Resume anyway", style: .quiet, size: .small)
    private var resuming = false
    private let turnOn = PongButton(title: "Turn on", style: .quiet, size: .small)
    private var turningOn = false

    /// 32 pt; 60 with the limits line.
    var preferredHeight: CGFloat { limitLine.isHidden ? 32 : 60 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.raised.cgColor
        layer?.cornerRadius = PongRadius.control
        left.lineBreakMode = .byTruncatingTail
        right.alignment = .right
        right.lineBreakMode = .byTruncatingHead
        limitLine.lineBreakMode = .byTruncatingTail
        limitLine.isHidden = true
        resume.isHidden = true
        resume.toolTip = "Start the paused graphs again now. They may stop at Claude's limit."
        resume.setAccessibilityHelp("Starts the graphs that were paused near Claude's weekly limit again now.")
        resume.onPress = { [weak self] in self?.resumeNow() }
        turnOn.isHidden = true
        turnOn.toolTip = "Turn the graph runner on: it moves graphs on after each step, even while CyberPong is closed."
        turnOn.setAccessibilityHelp("Turns the graph runner on, so graphs go on past their first step.")
        turnOn.onPress = { [weak self] in self?.turnOnRunner() }
        addSubview(left)
        addSubview(right)
        addSubview(limitLine)
        addSubview(resume)
        addSubview(turnOn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What Home's redraw compares: the parts of the limits state the strip shows.
    static func limitsKey(_ l: GLimits?) -> String {
        guard let l else { return "-" }
        return "\(l.state)|\(Int(l.until ?? 0))|\(Int(l.sessionReset ?? 0))|\(l.weekPct ?? -1)|\(l.paused)|\(l.note)"
    }

    /// `offerTurnOn`: false when a problem card on the page already offers Turn on (one button, one place).
    func update(needs: Int, working: Int, paused: Int = 0, stoppedTeams: Int, engineOK: Bool, runnerOff: Bool = false,
                offerTurnOn: Bool = true, nextRun: String, limits: GLimits? = nil) {
        let s = NSMutableAttributedString()
        func item(_ glyph: String, _ text: String, _ color: NSColor, dim: Bool) {
            if s.length > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: PongType.secondary])) }
            s.append(NSAttributedString(string: glyph + " ", attributes: [.font: PongType.secondary, .foregroundColor: dim ? PongColor.textTertiary : color]))
            s.append(NSAttributedString(string: text, attributes: [.font: PongType.secondary, .foregroundColor: dim ? PongColor.textTertiary : PongColor.textSecondary]))
        }
        item("◆", "\(needs) need\(needs == 1 ? "s" : "") you", PongColor.you, dim: needs == 0)
        // nothing at work says nothing (never "0 working")
        if working > 0 { item("◠", "\(working) working", PongColor.live, dim: false) }
        if paused > 0 { item("‖", "\(paused) paused", PongColor.textSecondary, dim: false) }
        if stoppedTeams > 0 { item("■", Words.plural(stoppedTeams, "team") + " stopped", PongColor.textTertiary, dim: true) }
        left.attributedStringValue = s
        let r = NSMutableAttributedString()
        if let week = limits?.weekWords {
            r.append(NSAttributedString(string: week + "   ", attributes: [.font: PongType.secondary, .foregroundColor: PongColor.textTertiary]))
        }
        let health = !engineOK ? "✕ Engine off" : (runnerOff ? "✕ Graph runner off" : "✓ Engine OK")
        r.append(NSAttributedString(string: health, attributes: [
            .font: PongType.secondary, .foregroundColor: engineOK && !runnerOff ? PongColor.textTertiary : PongColor.fail]))
        if !nextRun.isEmpty {
            r.append(NSAttributedString(string: "   " + nextRun, attributes: [.font: PongType.secondary, .foregroundColor: PongColor.textTertiary]))
        }
        right.attributedStringValue = r
        right.toolTip = runnerOff && engineOK ? "Graphs stop after their first step until the graph runner is on." : nil
        turnOn.isHidden = !(engineOK && runnerOff && offerTurnOn)
        turnOn.isEnabled = !turningOn
        var spoken = s.string + ". " + r.string
        if let lw = limits?.pausedWords(clock: { GraphTime.comesBack($0) }) {
            let t = NSMutableAttributedString(string: "◆ ", attributes: [.font: PongType.secondary, .foregroundColor: PongColor.you])
            t.append(NSAttributedString(string: lw.text, attributes: [.font: PongType.secondary, .foregroundColor: PongColor.textPrimary]))
            limitLine.attributedStringValue = t
            limitLine.toolTip = limits?.note.isEmpty == false ? limits?.note : nil
            limitLine.isHidden = false
            resume.isHidden = !lw.resume
            resume.isEnabled = !resuming
            spoken += ". " + lw.text
        } else {
            limitLine.isHidden = true
            resume.isHidden = true
        }
        setAccessibilityLabel(spoken)
        needsLayout = true
    }

    /// "Resume anyway": lift the runner's weekly pause now.
    private func resumeNow() {
        guard !resuming else { return }
        resuming = true
        resume.isEnabled = false
        GraphStore.shared.resumeLimits { [weak self] ok, words in
            self?.resuming = false
            self?.resume.isEnabled = true
            // the words are plain either way: the engine's note, or a sentence saying it didn't work
            Toast.show(ok && words.isEmpty ? "The paused graphs are running again." : words, warn: !ok)
        }
    }

    /// "Turn on": install the graph runner (`pong runtime install-agent`), then read the feed again.
    func turnOnRunner() {
        guard !turningOn else { return }
        turningOn = true
        turnOn.isEnabled = false
        GraphStore.shared.installRunner { [weak self] ok, words in
            self?.turningOn = false
            self?.turnOn.isEnabled = true
            Toast.show(words, warn: !ok)
        }
    }

    override func layout() {
        super.layout()
        // NSView is not flipped: the first line is on top, the limits line under it
        let firstY: CGFloat = limitLine.isHidden ? 8 : bounds.height - 24
        let tw = turnOn.isHidden ? 0 : turnOn.intrinsicContentSize.width
        if !turnOn.isHidden {
            turnOn.frame = NSRect(x: bounds.width - 8 - tw, y: firstY - 4, width: tw, height: 24)
        }
        let rightEdge = bounds.width - 12 - (tw > 0 ? tw : 0)
        let rw = min(bounds.width * 0.45, ceil(right.attributedStringValue.size().width) + 4)
        right.frame = NSRect(x: rightEdge - rw, y: firstY, width: rw, height: 16)
        left.frame = NSRect(x: 12, y: firstY, width: max(40, rightEdge - rw - 24), height: 16)
        let bw = resume.isHidden ? 0 : resume.intrinsicContentSize.width
        if !resume.isHidden {
            resume.frame = NSRect(x: bounds.width - 8 - bw, y: 4, width: bw, height: 24)
        }
        limitLine.frame = NSRect(x: 12, y: 8, width: max(40, bounds.width - 24 - bw - (bw > 0 ? 8 : 0)), height: 16)
    }
}

/// Something that needs a hand but asks no question: a plain cause and one or two fixes.
final class ProblemCardView: NSView {
    private let glyph = NSImageView()
    private let title = PongUI.label("", PongType.bodyStrong, PongColor.textPrimary, lines: 2)
    private let body = PongUI.label("", PongType.secondary, PongColor.textSecondary, lines: 2)
    private var buttons: [PongButton] = []

    init(title t: String, body b: String, actions: [(String, () -> Void)]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PongColor.tintFail.cgColor
        layer?.cornerRadius = PongRadius.card
        glyph.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Problem")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        glyph.contentTintColor = PongColor.fail
        addSubview(glyph)
        title.stringValue = t
        body.stringValue = b
        addSubview(title)
        addSubview(body)
        for (i, (name, fn)) in actions.prefix(2).enumerated() {
            let btn = PongButton(title: name, style: i == 0 ? .secondary : .quiet)
            btn.onPress = fn
            buttons.append(btn)
            addSubview(btn)
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("Problem: \(t). \(b)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        let inner = width - 32 - 24
        let th = title.attributedStringValue.boundingRect(with: NSSize(width: inner, height: 100), options: [.usesLineFragmentOrigin]).height
        return 16 + min(40, ceil(th) + 2) + 4 + 16 + 12 + 28 + 16
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 32 - 24
        glyph.frame = NSRect(x: 16, y: 17, width: 16, height: 16)
        let th = min(40, ceil(title.attributedStringValue.boundingRect(with: NSSize(width: inner, height: 100), options: [.usesLineFragmentOrigin]).height) + 2)
        title.frame = NSRect(x: 40, y: 16, width: inner, height: th)
        body.frame = NSRect(x: 40, y: 16 + th + 4, width: inner, height: 16)
        var x: CGFloat = 40
        let y = 16 + th + 4 + 16 + 12
        for b in buttons {
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: x, y: y, width: w, height: 28)
            x += w + 8
        }
    }
}
