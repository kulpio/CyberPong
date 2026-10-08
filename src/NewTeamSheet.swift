import AppKit

/// New team (1.9): one sheet in the new look in place of the floating "pill" window and its
/// always-dark Launch palette. How big, what it's called, who leads, which AI each helper is,
/// and (when there are any) a recap to start from. Starts the team exactly as the pill did.
final class NewTeamSheet: PongSheet {
    enum Size: Int, CaseIterable {
        case solo = 0, pair, squad
        var title: String { ["Solo", "Pair", "Squad"][rawValue] }
        var blurb: String { ["A lead and a builder", "A builder and a reviewer", "Builder, reviewer, operator"][rawValue] }
        var labels: [String] { [["Builder"], ["Builder", "Reviewer"], ["Builder", "Reviewer", "Operator"]][rawValue] }
        var roles: [String] {
            [[MissionRole.coder.rawValue],
             [MissionRole.coder.rawValue, MissionRole.reviewer.rawValue],
             [MissionRole.coder.rawValue, MissionRole.reviewer.rawValue, MissionRole.`operator`.rawValue]][rawValue]
        }
    }

    private static let leads = [("claude", "Claude"), ("grok", "Grok"), ("hermes", "Hermes")]
    private static let helpers = [("claude", "Claude"), ("grok", "Grok"), ("codex", "Codex"), ("hermes", "Hermes")]
    private static let W: CGFloat = 540

    private var size: Size = .pair
    private var cards: [ChoiceCard] = []
    private let nameField = NSTextField()
    private let leadPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var helperPops: [NSPopUpButton] = []
    private var helperLabels: [NSTextField] = []
    private var helperTypes = ["claude", "claude", "claude"]
    private let recapEyebrow = PongUI.eyebrow("Start from a recap")
    private let recapPop = NSPopUpButton(frame: .zero, pullsDown: false)
    private var recaps: [SessionArchive.Entry] = []
    private let errorLine = PongUI.label("", PongType.secondary, PongColor.fail, lines: 2)
    private let startBtn = PongButton(title: "Start team", style: .primary, size: .large)
    private let cancelBtn = PongButton(title: "Cancel", style: .secondary, size: .large)
    private let savedBtn = PongButton(title: "Open a saved team…", style: .quiet, size: .large)
    private var onDone: (() -> Void)?
    private var boxes: [NSView] = []

    static func present(on parent: NSWindow?, onDone: (() -> Void)? = nil) {
        let s = NewTeamSheet(width: W, height: 560)
        s.onDone = onDone
        s.build()
        s.present(on: parent)
        s.window.makeFirstResponder(s.nameField)
        s.nameField.currentEditor()?.selectAll(nil)
    }

    private func build() {
        let W = Self.W, pad: CGFloat = 24
        let title = PongUI.label("Start a team", PongType.question, PongColor.textPrimary)
        title.frame = NSRect(x: pad, y: 24, width: W - pad * 2, height: 24)
        content.addSubview(title)
        let sub = PongUI.label("A lead AI and its helpers, each in its own terminal on this Mac.",
                               PongType.secondary, PongColor.textSecondary)
        sub.frame = NSRect(x: pad, y: 52, width: W - pad * 2, height: 16)
        content.addSubview(sub)

        // how big
        let cw = (W - pad * 2 - 16) / 3
        for s in Size.allCases {
            let c = ChoiceCard(title: s.title, sub: s.blurb)
            c.frame = NSRect(x: pad + CGFloat(s.rawValue) * (cw + 8), y: 84, width: cw, height: 64)
            c.onSelect = { [weak self] in self?.pick(s) }
            cards.append(c)
            content.addSubview(c)
        }

        // name
        let nameEyebrow = PongUI.eyebrow("Name")
        nameEyebrow.frame = NSRect(x: pad, y: 164, width: 200, height: 16)
        content.addSubview(nameEyebrow)
        let nameBox = box(NSRect(x: pad, y: 184, width: W - pad * 2, height: 28))
        nameField.font = PongType.body
        nameField.textColor = PongColor.textPrimary
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.cell?.isScrollable = true
        nameField.cell?.usesSingleLineMode = true
        nameField.stringValue = "My team"
        nameField.setAccessibilityLabel("Team name")
        nameField.frame = nameBox.frame.insetBy(dx: 8, dy: 5)
        content.addSubview(nameField)

        // who leads
        let leadEyebrow = PongUI.eyebrow("Who leads")
        leadEyebrow.frame = NSRect(x: pad, y: 228, width: 200, height: 16)
        content.addSubview(leadEyebrow)
        for (id, label) in Self.leads {
            leadPop.addItem(withTitle: label)
            leadPop.lastItem?.representedObject = id
        }
        selectDefaultLead()
        PongTheme.stylePopUp(leadPop)
        leadPop.target = self
        leadPop.action = #selector(leadChanged)
        leadPop.frame = NSRect(x: pad - 2, y: 248, width: 200, height: 28)
        leadPop.setAccessibilityLabel("Who leads")
        content.addSubview(leadPop)
        let leadNote = PongUI.label("It reads your messages and hands out work.", PongType.secondary, PongColor.textTertiary)
        leadNote.frame = NSRect(x: pad + 214, y: 254, width: W - pad * 2 - 214, height: 16)
        content.addSubview(leadNote)

        // helpers: one row each, made in pick()
        let helpEyebrow = PongUI.eyebrow("Helpers")
        helpEyebrow.frame = NSRect(x: pad, y: 292, width: 200, height: 16)
        content.addSubview(helpEyebrow)
        for i in 0..<3 {
            let l = PongUI.label("", PongType.body, PongColor.textSecondary)
            l.frame = NSRect(x: pad, y: 318 + CGFloat(i) * 36, width: 100, height: 18)
            let p = NSPopUpButton(frame: NSRect(x: pad + 108, y: 312 + CGFloat(i) * 36, width: 180, height: 28), pullsDown: false)
            for (id, label) in Self.helpers {
                p.addItem(withTitle: label)
                p.lastItem?.representedObject = id
            }
            PongTheme.stylePopUp(p)
            p.tag = i
            p.target = self
            p.action = #selector(helperChanged(_:))
            helperLabels.append(l)
            helperPops.append(p)
            content.addSubview(l)
            content.addSubview(p)
        }

        // a recap to start from, shown only when there are any (read off the main thread)
        recapEyebrow.isHidden = true
        recapPop.isHidden = true
        PongTheme.stylePopUp(recapPop)
        content.addSubview(recapEyebrow)
        content.addSubview(recapPop)
        DispatchQueue.global(qos: .userInitiated).async {
            let all = SessionArchive.loadAll()
            DispatchQueue.main.async { [weak self] in self?.showRecaps(all) }
        }

        errorLine.isHidden = true
        content.addSubview(errorLine)

        // footer
        let H: CGFloat = 560
        content.addSubview(footerRule(y: H - 57))
        let fy = H - 44
        let sw = startBtn.intrinsicContentSize.width, cw2 = cancelBtn.intrinsicContentSize.width
        startBtn.frame = NSRect(x: W - pad - sw, y: fy, width: sw, height: 32)
        cancelBtn.frame = NSRect(x: W - pad - sw - 8 - cw2, y: fy, width: cw2, height: 32)
        startBtn.keyEquivalent = "\r"
        startBtn.onPress = { [weak self] in self?.start() }
        cancelBtn.onPress = { [weak self] in self?.close(); self?.onDone?() }
        content.addSubview(startBtn)
        content.addSubview(cancelBtn)
        if !SavedTeams.loadAll().isEmpty {
            savedBtn.frame = NSRect(x: pad - 12, y: fy, width: savedBtn.intrinsicContentSize.width, height: 32)
            savedBtn.toolTip = "Start a team you saved before, with its names, folder and schedules"
            savedBtn.onPress = { [weak self] in
                self?.close()
                DispatchQueue.main.async {
                    if AppDelegate.pickAndSpawnSavedTeam() {
                        PanelController.shared.refreshUI()
                        // its terminals are up now: ask tmux again, so its row doesn't say "Stopped" (see start())
                        CronSchedule.refreshRunning { PanelController.shared.refreshUI() }
                    }
                    self?.onDone?()
                }
            }
            content.addSubview(savedBtn)
        }
        pick(.pair)
    }

    private func box(_ r: NSRect) -> NSView {
        let b = NSView(frame: r)
        b.wantsLayer = true
        b.layer?.backgroundColor = PongColor.field.cgColor
        b.layer?.cornerRadius = PongRadius.control
        b.layer?.borderWidth = 1
        b.layer?.borderColor = PongColor.control.cgColor
        content.addSubview(b)
        boxes.append(b)
        return b
    }

    private func pick(_ s: Size) {
        size = s
        for (i, c) in cards.enumerated() { c.selected = i == s.rawValue }
        for i in 0..<3 {
            let on = i < s.labels.count
            helperLabels[i].isHidden = !on
            helperPops[i].isHidden = !on
            if on {
                helperLabels[i].stringValue = s.labels[i]
                helperPops[i].setAccessibilityLabel("\(s.labels[i]) AI")
                if let j = helperPops[i].itemArray.firstIndex(where: { ($0.representedObject as? String) == helperTypes[i] }) {
                    helperPops[i].selectItem(at: j)
                }
            }
        }
        // the recap row and the error line sit under the last helper
        let below = 318 + CGFloat(s.labels.count) * 36 + 8
        recapEyebrow.frame = NSRect(x: 24, y: below, width: 200, height: 16)
        recapPop.frame = NSRect(x: 22, y: below + 20, width: Self.W - 48 + 4, height: 28)
        errorLine.frame = NSRect(x: 24, y: recapPop.isHidden ? below : below + 56, width: Self.W - 48, height: 32)
    }

    /// The lead starts on an AI that is on and signed in, Claude first (TeamLead.pick). The check
    /// that says so may still be running: when it answers, the pick follows it, unless the person
    /// already chose.
    private func selectDefaultLead() {
        let model = SetupModel.shared
        let d = model.doctor
        let id = TeamLead.pick(Self.leads.map(\.0), enabled: AppSettings.aiEnabled,
                               signedIn: { d?.ai($0)?.signedIn == true || ProviderAuth.isMarkedReady(typeId: $0) },
                               installed: { d?.ai($0)?.installed })
        if let i = leadPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) { leadPop.selectItem(at: i) }
        guard d == nil, doctorObserver == nil else { return }
        doctorObserver = NotificationCenter.default.addObserver(forName: SetupModel.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, SetupModel.shared.doctor != nil else { return }
            self.dropDoctorObserver()
            if !self.leadPicked {
                self.selectDefaultLead()
                PongTheme.stylePopUp(self.leadPop)
            }
        }
        model.refreshDoctor()
    }

    private var doctorObserver: NSObjectProtocol?
    private var leadPicked = false

    private func dropDoctorObserver() {
        if let o = doctorObserver { NotificationCenter.default.removeObserver(o) }
        doctorObserver = nil
    }

    @objc private func leadChanged() {
        leadPicked = true
        PongTheme.stylePopUpItemTitles(leadPop)
    }

    override func close() {
        dropDoctorObserver()
        super.close()
    }

    @objc private func helperChanged(_ p: NSPopUpButton) {
        if let id = p.selectedItem?.representedObject as? String, p.tag < helperTypes.count { helperTypes[p.tag] = id }
    }

    private func showRecaps(_ all: [SessionArchive.Entry]) {
        recaps = all
        guard !all.isEmpty else { return }
        recapPop.removeAllItems()
        recapPop.addItem(withTitle: "Start fresh")
        for e in all.prefix(20) {
            recapPop.addItem(withTitle: e.rowLabel)
            recapPop.lastItem?.representedObject = e.id
        }
        recapPop.setAccessibilityLabel("Start from a recap")
        recapPop.toolTip = "A recap holds a team's goals, decisions and what is next: the new lead starts from it."
        recapEyebrow.isHidden = false
        recapPop.isHidden = false
        pick(size)
    }

    private func start() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorLine.stringValue = "Give the team a name."
            errorLine.isHidden = false
            return
        }
        let lead = (leadPop.selectedItem?.representedObject as? String) ?? "claude"
        let types = Array(helperTypes.prefix(size.labels.count))
        let recapId = recapPop.isHidden ? nil : (recapPop.selectedItem?.representedObject as? String)
        let plan = AppAIMutator.FirstTeamPlan(teamName: name, projectRoot: "", teamBrief: "\(size.title) team: \(size.blurb.lowercased())",
                                              conductorId: lead, workerTypes: types, missionRoles: size.roles,
                                              workerLabels: size.labels)
        startBtn.isEnabled = false
        startBtn.title = "Starting…"
        errorLine.isHidden = true
        Pong.log("NewTeamSheet start name=\(name) lead=\(lead) helpers=\(types.joined(separator: ",")) recap=\(recapId ?? "-")")
        let size = self.size
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AppAIMutator.apply([.createFirstTeam(plan: plan)])
            if let sess = result.session {
                // The team list is re-read from tmux at most every 4 s: have it look again now, while the
                // terminals are themed, so it lists the new team by the time the pages redraw (below). Not
                // at the redraw itself: until that look lands, the list falls back to every saved team,
                // and a stopped one would show twice.
                DispatchQueue.main.async { PairState.invalidatePairsCache() }
                TerminalTheme.applyPair(sess)
                if let aid = recapId {
                    SessionContinuity.setPendingArchive(session: sess, archiveId: aid)
                    var ctx = ConductorKickoff.contextFromPairState(session: sess)
                    ctx.continuityRecap = SessionArchive.loadRecap(id: aid)
                    ConductorKickoff.scheduleInject(session: sess, context: ctx, initialDelay: 1.5)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if result.failed.isEmpty {
                    self.close()
                    Toast.show("\(name) is starting: a lead and \(Words.plural(size.labels.count, "helper")).")
                    // Which teams are up is a tmux question the pages ask at most every 10 s: ask it again
                    // before anything redraws, so the new team doesn't show "Stopped" and a Start button
                    // under its own "is starting" (as TeamStart does).
                    let done = self.onDone
                    CronSchedule.refreshRunning {
                        PanelController.shared.refreshUI()
                        if let sess = result.session { PanelController.shared.openTeam(sess) }
                        done?()
                    }
                } else {
                    self.startBtn.isEnabled = true
                    self.startBtn.title = "Start team"
                    self.errorLine.stringValue = result.failed.map(\.1).joined(separator: " ")
                    self.errorLine.isHidden = false
                }
            }
        }
    }

    @objc func cancelOperation(_ sender: Any?) {
        close()
        onDone?()
    }
}

/// A selectable card: a title and a line; selected is a brighter fill and a 1.5 pt edge.
final class ChoiceCard: NSView {
    var onSelect: (() -> Void)?
    var selected = false { didSet { restyle() } }
    private let title: NSTextField
    private let sub: NSTextField

    init(title t: String, sub s: String) {
        title = PongUI.label(t, PongType.bodyStrong, PongColor.textPrimary)
        sub = PongUI.label(s, PongType.secondary, PongColor.textSecondary, lines: 2)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PongRadius.control
        addSubview(title)
        addSubview(sub)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(t): \(s)")
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: 10, width: bounds.width - 24, height: 18)
        sub.frame = NSRect(x: 12, y: 30, width: bounds.width - 24, height: 30)
    }

    private func restyle() {
        layer?.backgroundColor = (selected ? PongColor.overlay : PongColor.base).cgColor
        layer?.borderWidth = selected ? 1.5 : 1
        layer?.borderColor = (selected ? PongColor.textPrimary : PongColor.hairline).cgColor
        setAccessibilityValue(selected)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}
