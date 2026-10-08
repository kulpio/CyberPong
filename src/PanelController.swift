import AppKit

/// Canvas host that prefers the left HUD splitter strip over full-bleed SceneKit/map.
/// Without this, map3D (fills the page) can win hit-testing after layout reorders.
private final class CanvasPageView: NSView {
    weak var map3D: Agent3DMapView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let split = map3D?.hitTestLeftHUDSplitter(in: self, point: point) {
            return split
        }
        return super.hitTest(point)
    }
}

/// Lasting control panel: top tabs + primary stage (Canvas · Mission · Setup).
/// Design: docs/UI-VISION.md — orchestration surface, not a list form.
final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    // Window
    private var window: NSWindow?
    private var root: NSView!

    // Chrome (1.9): a sidebar, a 52 pt window bar, the page under it
    private var sidebar: SidebarView!
    private var windowBar: WindowBarView!
    private var sidebarHidden = UserDefaults.standard.bool(forKey: "shell.sidebarHidden")
    private var shownOnce = false
    /// The team whose window-bar actions are showing, and whether it was up then: when that changes, the
    /// actions are built again ("Start team" becomes "Open a chat here").
    private var teamActionsFor: (team: String, up: Bool)?
    /// The width the old Setup page's cards were drawn at.
    private var setupPaintedWidth: CGFloat = 0

    // Stage
    private var stage: NSView!
    private var canvasPage: CanvasPageView!
    private var canvasScroll: NSScrollView!
    private var canvas: AgentCanvasView!
    private var map3D: Agent3DMapView!
    private var canvasToolbar: NSView!
    private var canvasEmpty: NSView!
    private var missionPage: NSView!
    private var missionScroll: NSScrollView!
    private var missionBody: NSView!
    private var setupPage: NSView!
    private var setupScroll: NSScrollView!
    private var setupBody: NSView!
    /// Graphs: every graph loop on this Mac, one scene, three altitudes (1.7).
    private var graphsPage: GraphStudioView!
    /// Needs you (1.9): the questions, what is working, what finished.
    private var homePage: HomePageView!
    /// Schedules (1.9): everything that runs on its own.
    private var schedulesPage: SchedulesPageView!
    /// Teams (1.9): the list of teams, and one team's members, map and composer.
    private var teamsList: TeamsListView!
    private var teamPage: TeamPageView!
    /// The Teams list shown as one 3D map of every team.
    private var showTeamsMap = UserDefaults.standard.bool(forKey: "teams.showMap")

    private var selected: Destination = .canvas
    private var selectedSession: String?
    private var lastSnapshot: [String: Any]?
    private var canvasDragging = false
    /// true = 3D constellation (default special view); false = flat map
    /// Prefer product default 3D so first open shows the promise of the map.
    private var use3DMap: Bool = AppAISettings.prefer3DMap
    private var poll: Timer?
    private let guide = LinkGuideController()
    /// Mission ask strip — last grounded reply survives paintMission rebuilds.
    private var missionAskLastReply: String = ""
    private var hardRefreshInFlight = false

    /// The window bar's height; the traffic lights sit centred in it.
    private let barH: CGFloat = 52
    private let minSize = NSSize(width: 720, height: 520)
    private let defaultSize = NSSize(width: 960, height: 680)

    /// Where the window is. `canvas` is the Teams page, `mission` the old dashboard
    /// (now Diagnostics), `setup` the old Setup page (until Settings has it all).
    enum Destination: Int { case canvas = 0, mission = 1, setup = 2, graphs = 3, home = 4, chats = 5, schedules = 6 }
    /// The map's own drawing of graph nodes (1.6.0). Off: the Graphs page owns graphs.
    static let drawGraphsOnMap = false

    // MARK: Public

    func show() {
        if window == nil { build() }
        use3DMap = AppAISettings.prefer3DMap
        applyMapMode()
        // First open lands on Needs you; after that the window keeps its place.
        if !shownOnce {
            shownOnce = true
            go(.home)
        }
        startPoll()
        GraphStore.shared.fast = true
        if UIPreview.isOn {
            window?.orderBack(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open the app on the Graphs page (menu bar item, notifications).
    func showGraphs() {
        show()
        go(.graphs)
    }

    func refreshUI() { reload() }

    /// Force 3D map visible (empty-state preview seats if no team yet).
    func ensure3DVisible() {
        use3DMap = true
        AppAISettings.setPrefer3DMap(true)
        selected = .canvas
        go(.canvas)
        applyMapMode()
        refreshCanvas()
        if use3DMap {
            map3D?.resetCamera()
            map3D?.setMapPlaying(true)
        }
        DispatchQueue.main.async {
            AppAIChatBubble.shared.attachIfNeeded(to: self.canvasPage)
        }
    }

    /// The old Guide set-up entry point: the first-run setup now covers it (2.0).
    @objc private func openAppAIGuide() {
        FirstRunSetup.present(force: true)
    }

    /// Host for floating Guide bubble (FAB on map page).
    func _mapHostForBubble() -> NSView? {
        canvasPage
    }

    /// Expanded Guide attaches here so it stacks above stage and top bar chrome.
    func guideOverlayHost() -> NSView? {
        root ?? window?.contentView
    }

    /// Distance from top of contentView down past top bar (keeps expanded Guide below chrome).
    var guideTopBarClearance: CGFloat {
        barH
    }

    static func label(_ text: String, frame: NSRect, bold: Bool = false,
                      size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = bold ? PongTheme.font(size, weight: .semibold) : PongTheme.font(size)
        f.textColor = secondary ? PongTheme.textSecondary : PongTheme.textPrimary
        f.frame = frame
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 8
        f.isBezeled = false
        f.drawsBackground = false
        f.backgroundColor = .clear
        return f
    }

    /// A team just started: say so quietly.
    static func showPairPersistTip(_ name: String) {
        Toast.show("“\(name)” is running.")
    }

    // MARK: Build

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = PongTheme.productName
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // An empty unified toolbar gives the 52 pt title area with the traffic lights centred in it.
        let tb = NSToolbar(identifier: "cyberpong.shell")
        tb.showsBaselineSeparator = false
        tb.allowsUserCustomization = false
        win.toolbar = tb
        win.toolbarStyle = .unified
        win.isReleasedWhenClosed = false
        win.backgroundColor = PongColor.base
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = minSize
        win.isMovableByWindowBackground = true
        win.center()
        win.delegate = self

        root = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongColor.base.cgColor
        root.autoresizingMask = [.width, .height]

        buildShell()
        buildStage()
        root.addSubview(stage)
        root.addSubview(windowBar)
        root.addSubview(sidebar)

        win.contentView = root
        window = win
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: GraphStore.didChange, object: nil)
        applyChrome()
        layoutAll()
        updateSidebar()
    }

    /// Night chrome for the pages that still paint themselves (the map, Diagnostics, Setup).
    private func applyChrome() {
        window?.backgroundColor = PongColor.base
        root?.layer?.backgroundColor = PongColor.base.cgColor
        stage?.layer?.backgroundColor = PongColor.base.cgColor
        restyleCanvasToolbar()
        canvas?.retheme()
        map3D?.applyChromeTheme()
        graphsPage?.retheme()
    }

    // MARK: Shell

    private func buildShell() {
        sidebar = SidebarView(frame: .zero)
        sidebar.onSelect = { [weak self] a in self?.goArea(a) }
        sidebar.onSelectTeam = { [weak self] id in self?.openTeam(id) }
        sidebar.onShowAllTeams = { [weak self] in self?.openTeam("__all__") }
        sidebar.onNewGraph = { [weak self] in self?.newGraph() }
        sidebar.onFixEngine = { [weak self] in self?.go(.mission) }
        windowBar = WindowBarView(frame: .zero)
        windowBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        windowBar.onSearch = { [weak self] in self?.openPalette() }
        windowBar.onToggleInspector = { [weak self] in self?.graphsPage?.toggleInspectorFromShell() }
    }

    /// ⌘1–5 and the sidebar's items.
    func goArea(_ a: ShellArea) {
        if window == nil { show() }
        switch a {
        case .home: go(.home)
        case .chats, .graphs:
            let d: Destination = a == .chats ? .chats : .graphs
            // pressing the area you are in goes back to its list
            if selected == d && graphsPage.showingDetail { graphsPage.showList() } else { go(d) }
        case .teams: openTeam("__all__")
        case .schedules: go(.schedules)
        }
    }

    /// A team's page; "__all__" shows every team on one map.
    func openTeam(_ id: String) {
        if window == nil { show() }
        selectedSession = id
        syncHumanFocusToMap()
        go(.canvas)
    }

    /// ⌘N: a new graph starts with a chat.
    func newGraph() {
        if window == nil { show() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        NewGraphSheet.present(from: window) { [weak self] key in
            guard let self else { return }
            self.go(.chats)
            self.graphsPage.openChat(key)
        }
    }

    /// A ready-made graph on a team that exists.
    func startFromTemplate() {
        if window == nil { show() }
        go(.graphs)
        graphsPage.startFromTemplate()
    }

    /// ⇧⌘N
    func newTeam() {
        if window == nil { show() }
        newTeamPressed()
    }

    func openGraph(_ key: String, tab: GraphStudioView.Tab? = nil) {
        if window == nil { show() }
        go(.graphs)
        graphsPage.openGraph(key, tab: tab)
    }

    func openChat(_ key: String) {
        if window == nil { show() }
        go(.chats)
        graphsPage.openChat(key)
    }

    /// ⌘J: the next question, wherever it is.
    func nextQuestion() {
        if window == nil { show() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if selected != .home { go(.home) }
        homePage.focusNextQuestion()
    }

    /// ⌘1–3 answers the focused question (Home or an open graph). False when there is none,
    /// so the keys fall through to the areas.
    func answerFocused(_ i: Int) -> Bool {
        if selected == .home { return homePage.answerFocused(i) }
        if selected == .graphs || selected == .chats { return graphsPage.answerBanner(i) }
        return false
    }

    /// ⌥⌘1–3: a graph's Steps, Plan and Screen.
    func setGraphTab(_ t: GraphStudioView.Tab) {
        guard selected == .graphs else { return }
        graphsPage.setTab(t)
    }

    func linkTerminals() { if window == nil { show() }; linkPressed() }
    func showSavedTeams() { showTeamsPressed() }
    func showRecaps() { showSessionsPressed() }

    /// ⌘,
    func openSettings() {
        if window == nil { show() }
        SettingsWindow.shared.show()
    }

    func newSchedule() {
        if window == nil { show() }
        go(.schedules)
        schedulesPage.newSchedule()
    }

    /// ⌘K: jump anywhere, run anything, or ask.
    func openPalette() {
        if window == nil { show() }
        CommandPalette.shared.present(in: window)
    }

    /// ⌥⌘S
    @objc func toggleSidebar() {
        sidebarHidden.toggle()
        UserDefaults.standard.set(sidebarHidden, forKey: "shell.sidebarHidden")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PongMotion.reduced ? 0 : PongMotion.panel
            self.layoutAll()
        }
        // Diagnostics draws its cards to the page's width, as a window resize redraws it
        if selected == .mission { paintMission() }
    }

    /// ⌥⌘I
    @objc func toggleInspector() {
        graphsPage?.toggleInspectorFromShell()
    }

    /// The page that is showing, for menus and the palette.
    var currentDestination: Destination { selected }

    @objc private func storeChanged() {
        updateSidebar()
        if selected == .home { homePage?.render() }
    }

    private func teamName(_ p: String, _ db: [String: Any]) -> String {
        let n = ((db[p] as? [String: Any])?["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? p : n
    }

    /// The sidebar's counts and team list, from the graph feed and pairs.json.
    private func updateSidebar() {
        guard let sidebar else { return }
        let st = GraphStore.shared
        let db = PairState.loadPairsDb()
        // Running is the test Teams and Schedules use (its terminals are there), so the sidebar never says
        // a team runs while those pages say it is stopped; working is a graph at work, never a paused one.
        // A fresh look at tmux redraws the Teams list or the team's page too (updateStatus), at the same moment.
        let up = TeamsUp.now { [weak self] in self?.updateStatus() }
        let busy = Set(st.graphs.filter { $0.isWorking }.map { $0.session })
        let ids = PairState.listPairs() + PairState.listStoppedPairs()
        var teams = ids.filter { up.contains($0) }.map {
            ShellTeam(id: $0, name: teamName($0, db), running: true, working: busy.contains($0))
        }
        teams += ids.filter { !up.contains($0) }.map { ShellTeam(id: $0, name: teamName($0, db), running: false, working: false) }
        if let shown = teamActionsFor, selected == .canvas, selectedSession == shown.team, up.contains(shown.team) != shown.up {
            syncShell()
        }
        let engineOff = st.loadedOnce && !st.loadError.isEmpty && st.graphs.isEmpty
        sidebar.update(needsYou: st.needsYouCount, chats: st.liveChats.count,
                       graphs: st.running.count + st.waiting.count, teams: teams, engineOff: engineOff)
    }

    /// The sidebar's selection and the window bar's breadcrumb follow the page.
    private func syncShell() {
        guard let sidebar, let windowBar else { return }
        var crumbs: [WindowBarView.Crumb] = []
        switch selected {
        case .home: sidebar.select(area: .home)
        case .chats: sidebar.select(area: .chats)
        case .graphs: sidebar.select(area: .graphs)
        case .schedules: sidebar.select(area: .schedules)
        case .canvas:
            if let s = selectedSession, s != "__all__" {
                sidebar.select(area: nil, team: s)
                crumbs = [.init(title: "Teams") { [weak self] in self?.openTeam("__all__") }]
            } else {
                sidebar.select(area: .teams)
            }
        case .mission:
            sidebar.select(area: nil)
            crumbs = [.init(title: "Settings", go: nil), .init(title: "Diagnostics", go: nil)]
        case .setup:
            sidebar.select(area: nil)
            crumbs = [.init(title: "Settings", go: nil)]
        }
        var actions: [NSView] = []
        switch selected {
        case .graphs, .chats:
            crumbs = graphsPage?.crumbs ?? []
            actions = graphsPage?.pageActions ?? []
        case .schedules:
            let b = PongButton(title: "New schedule", style: .primary)
            b.symbol = "plus"
            b.onPress = { [weak self] in self?.schedulesPage.newSchedule() }
            actions = [b]
        case .canvas:
            if let s = selectedSession, s != "__all__" {
                actions = teamActions(s)
            } else {
                let map = PongButton(title: showTeamsMap ? "Show as a list" : "Show on the map", style: .quiet)
                map.symbol = showTeamsMap ? "list.bullet" : "cube"
                map.onPress = { [weak self] in
                    guard let self else { return }
                    self.showTeamsMap.toggle()
                    UserDefaults.standard.set(self.showTeamsMap, forKey: "teams.showMap")
                    self.go(.canvas)
                }
                let b = PongButton(title: "New team", style: .secondary)
                b.symbol = "plus"
                b.toolTip = "A lead AI and its helpers (⇧⌘N)"
                b.onPress = { [weak self] in self?.newTeamPressed() }
                actions = [map, b]
            }
        default:
            break
        }
        windowBar.setCrumbs(crumbs)
        windowBar.setActions(actions)
        windowBar.showsInspectorToggle = (selected == .graphs || selected == .chats) && graphsPage?.hasInspector == true
    }

    private func restyleCanvasToolbar() {
        guard let canvasToolbar else { return }
        // Floating HUD like Lattice Tracking panel
        canvasToolbar.layer?.backgroundColor = PongTheme.bgElevated.cgColor
        canvasToolbar.layer?.borderColor = PongTheme.border.cgColor
        canvasToolbar.layer?.cornerRadius = PongTheme.radiusCard
        for b in canvasToolbar.subviews.compactMap({ $0 as? NSButton }) {
            let title = b.attributedTitle.string
            let upper = title.uppercased()
            // Only the real New team CTA — never rewrite titles that merely contain "team".
            let isNewTeamCTA =
                b.action == #selector(newTeamPressed)
                || upper == "NEW TEAM"
            if isNewTeamCTA {
                // White line-work CTA (not role colors)
                b.layer?.backgroundColor = PongTheme.ink.cgColor
                b.layer?.borderWidth = 0
                b.attributedTitle = NSAttributedString(string: "New team", attributes: [
                    .foregroundColor: PongTheme.bg,
                    .font: PongTheme.labelFont(11),
                    .paragraphStyle: centered(),
                ])
            } else {
                b.layer?.backgroundColor = NSColor.clear.cgColor
                b.layer?.borderWidth = PongTheme.hairline
                b.layer?.borderColor = PongTheme.lineSoft.cgColor
                b.attributedTitle = NSAttributedString(string: title.capitalized == title ? title : title.lowercased().capitalized,
                    attributes: [
                    .foregroundColor: PongTheme.textPrimary,
                    .font: PongTheme.labelFont(11),
                    .paragraphStyle: centered(),
                ])
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutAll()
        if selected == .canvas { refreshCanvas(light: true) }
        if selected == .mission { paintMission() }
        graphsPage?.needsLayout = true
    }

    private func layoutAll() {
        guard let root, let sidebar, let windowBar else { return }
        let W = root.bounds.width
        let H = root.bounds.height
        // Below 900 pt the sidebar folds to a 56 pt icon rail; at 1400 it widens to 232.
        let compact = W < 900
        let sw: CGFloat = sidebarHidden ? 0 : (compact ? 56 : (W >= 1400 ? 232 : 200))
        sidebar.isHidden = sidebarHidden
        sidebar.compact = compact
        sidebar.frame = NSRect(x: 0, y: 0, width: sw, height: H)
        // The traffic lights take ~72 pt: leave room when nothing else is under them.
        windowBar.leadingInset = sidebarHidden ? 72 : (compact ? 20 : 0)
        windowBar.frame = NSRect(x: sw, y: H - barH, width: W - sw, height: barH)
        stage.frame = NSRect(x: sw, y: 0, width: W - sw, height: H - barH)
        for page in [missionPage, setupPage] {
            page?.frame = stage.bounds
        }
        graphsPage?.frame = stage.bounds
        homePage?.frame = stage.bounds
        schedulesPage?.frame = stage.bounds
        teamsList?.frame = stage.bounds
        teamPage?.frame = stage.bounds
        teamPage?.layoutSubtreeIfNeeded()
        if let canvasPage {
            canvasPage.frame = canvasPage.superview === teamPage?.mapHost ? teamPage.mapHost.bounds : stage.bounds
        }
        layoutCanvasPage()
        layoutMissionPage()
        layoutSetupPage()
    }

    private func centered() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    // MARK: Stage pages

    private func buildStage() {
        stage = NSView(frame: .zero)
        stage.wantsLayer = true
        stage.layer?.backgroundColor = PongTheme.bg.cgColor

        // Canvas page (hit-tests left HUD splitter above SceneKit)
        canvasPage = CanvasPageView(frame: .zero)
        canvasScroll = NSScrollView(frame: .zero)
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.borderType = .noBorder
        canvasScroll.drawsBackground = false
        canvasScroll.backgroundColor = .clear
        // Comfortable workplace — sized to content on reload (not a continent)
        canvas = AgentCanvasView(frame: NSRect(origin: .zero, size: CanvasLayout.minCanvas))
        canvas.onFront = { [weak self] m in self?.frontModel(m) }
        canvas.onKill = { [weak self] m in self?.killModel(m) }
        canvas.onSaveSession = { m in
            let name = m.title.isEmpty ? m.session : m.title
            SessionContinuityUI.confirmSaveSession(session: m.session, displayName: name)
        }
        canvas.onNewSessionRecap = { m in
            let name = m.title.isEmpty ? m.session : m.title
            SessionContinuityUI.confirmNewSessionWithRecap(session: m.session, displayName: name) {
                PanelController.shared.reload()
            }
        }
        canvas.onOptions = { [weak self] m in
            TeamOptionsSheetController.shared.show(for: m.session) { self?.reload() }
        }
        canvas.onPerms = { [weak self] m in
            PermissionsSheetController.shared.show(for: m.session, workerId: m.id) { self?.reload() }
        }
        canvas.onChangeModel = { [weak self] m in
            self?.changeSeatModel(m)
        }
        canvas.onFocus = { m in
            TeamFocusController.shared.show(session: m.session)
        }
        canvas.onAddWorker = { [weak self] m in
            self?.handleAdd(from: m)
        }
        canvas.onAddSub = { [weak self] m in
            self?.addWorker(to: m.session, parentId: m.id, parentLabel: m.title, guide: true)
        }
        canvas.onHuman = { [weak self] m in
            // YOU console lives on the HUD (re-parented to canvasPage for both modes)
            self?.map3D?.openHumanDock(session: m.session)
        }
        canvas.onRename = { [weak self] m in
            self?.renameSeat(m)
        }
        canvas.onDragStateChanged = { [weak self] dragging in
            self?.canvasDragging = dragging
            // Keep scrollers during pan; only suppress autoscroll fight while moving nodes
            if self?.canvas.isPanning != true {
                self?.canvasScroll.hasVerticalScroller = !dragging
                self?.canvasScroll.hasHorizontalScroller = !dragging
            }
        }
        // Pinch / toolbar zoom; trackpad pan uses native NSScrollView momentum
        canvasScroll.allowsMagnification = true
        canvasScroll.minMagnification = 0.5
        canvasScroll.maxMagnification = 2.0
        canvasScroll.magnification = 1.0
        canvasScroll.scrollerStyle = .overlay
        canvasScroll.horizontalScrollElasticity = .allowed
        canvasScroll.verticalScrollElasticity = .allowed
        canvasScroll.autohidesScrollers = true
        canvasScroll.documentView = canvas
        canvasPage.addSubview(canvasScroll)

        // 3D constellation map (default) — glowing hierarchy of seats
        map3D = Agent3DMapView(frame: .zero)
        map3D.onOpen = { [weak self] s in
            self?.frontModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: s.role == "conductor" ? PongTheme.blue : PongTheme.magenta,
                origin: .zero
            ))
        }
        map3D.onFocus = { s in
            TeamFocusController.shared.show(session: s.session)
        }
        map3D.onHuman = { s in
            // Docked YOU panel is primary; floating sheet still available as fallback expand
            _ = s
        }
        map3D.onRename = { [weak self] s in
            self?.renameSeat(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.blue, origin: .zero
            ))
        }
        map3D.onKill = { [weak self] s in
            self?.killModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "conductor" ? "conductor" : "worker",
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        map3D.onSaveSession = { s in
            let name = s.title.isEmpty ? s.session : s.title
            SessionContinuityUI.confirmSaveSession(session: s.session, displayName: name)
        }
        map3D.onNewSessionRecap = { s in
            let name = s.title.isEmpty ? s.session : s.title
            SessionContinuityUI.confirmNewSessionWithRecap(session: s.session, displayName: name) {
                PanelController.shared.reload()
            }
        }
        map3D.onOptions = { s in
            TeamOptionsSheetController.shared.show(for: s.session) { PanelController.shared.reload() }
        }
        map3D.onPerms = { s in
            PermissionsSheetController.shared.show(for: s.session, workerId: s.id) {
                PanelController.shared.reload()
            }
        }
        map3D.onChangeModel = { [weak self] s in
            self?.changeSeatModel(AgentNodeModel(
                session: s.session, id: s.id, role: s.role == "subagent" ? "worker" : s.role,
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        // Side pad: peer on the same plane
        // - orch/worker → new top-level agent
        // - subagent → another sub under the same parent (same SUB level, not nested)
        map3D.onPlus = { [weak self] s in
            guard let self else { return }
            if s.role == "conductor" || s.role == "worker" {
                self.addWorker(to: s.session, parentId: nil, parentLabel: nil, guide: true)
            } else if s.role == "subagent" {
                let parent = s.parentId
                let entry = PairState.loadPairsDb()[s.session] as? [String: Any] ?? [:]
                let lab = parent.flatMap { pid in
                    Workers.list(from: entry).first(where: { ($0["id"] as? String) == pid })?["label"] as? String
                }
                self.addWorker(to: s.session, parentId: parent, parentLabel: lab ?? parent, guide: true)
            }
        }
        // Under-cube pad: only top-level agents → SUB deck under them
        map3D.onAddSub = { [weak self] s in
            guard s.role == "worker" else { return }
            self?.addWorker(to: s.session, parentId: s.id, parentLabel: s.title, guide: true)
        }
        map3D.onMinus = { [weak self] s in
            self?.killModel(AgentNodeModel(
                session: s.session, id: s.id,
                role: s.role == "conductor" ? "conductor" : "worker",
                title: s.title, subtitle: s.subtitle, detail: s.detail, status: s.status,
                teamLabel: "", accent: PongTheme.magenta, origin: .zero
            ))
        }
        canvasPage.addSubview(map3D)
        canvasPage.map3D = map3D
        // Phase 0: left HUD + legend float over both 2D and 3D (not trapped in map3D)
        map3D.promoteSharedHUD(to: canvasPage)

        canvasToolbar = glassBar()
        canvasPage.addSubview(canvasToolbar)
        // One bar: Orbit/Move · 2D/3D · zoom · Link · Architecture · Reset position (2D) · New team
        // (Guide lives on the map sparkle FAB / app menu — not on this toolbar)
        canvasToolbar.addSubview(pillButton("Orbit", #selector(orbitModePressed)))
        canvasToolbar.addSubview(pillButton("Move", #selector(moveModePressed)))
        canvasToolbar.addSubview(pillButton("3D", #selector(toggleMapMode)))
        canvasToolbar.addSubview(pillButton("−", #selector(zoomOutPressed)))
        canvasToolbar.addSubview(pillButton("+", #selector(zoomInPressed)))
        canvasToolbar.addSubview(pillButton("Link terminals", #selector(linkPressed)))
        canvasToolbar.addSubview(pillButton("Architecture", #selector(architecturePressed)))
        canvasToolbar.addSubview(pillButton("Island", #selector(islandPressed)))
        canvasToolbar.addSubview(pillButton("Reset position", #selector(arrangeTeamsPressed)))
        canvasToolbar.addSubview(accentButton("New team", #selector(newTeamPressed)))

        canvasEmpty = emptyState(
            title: "No teams yet",
            body: "Create a team to place a conductor and workers on the constellation.\nYou can also link terminals you already have open.",
            cta: "New team",
            action: #selector(newTeamPressed)
        )
        canvasPage.addSubview(canvasEmpty)
        stage.addSubview(canvasPage)
        applyMapMode()

        // Mission page
        missionPage = NSView(frame: .zero)
        missionScroll = NSScrollView(frame: .zero)
        missionScroll.hasVerticalScroller = true
        missionScroll.autohidesScrollers = true
        missionScroll.borderType = .noBorder
        missionScroll.drawsBackground = false
        missionBody = NSView(frame: .zero)
        missionScroll.documentView = missionBody
        missionPage.addSubview(missionScroll)
        missionPage.isHidden = true
        stage.addSubview(missionPage)

        // Setup page
        setupPage = NSView(frame: .zero)
        setupScroll = NSScrollView(frame: .zero)
        setupScroll.hasVerticalScroller = true
        setupScroll.autohidesScrollers = true
        setupScroll.borderType = .noBorder
        setupScroll.drawsBackground = false
        setupBody = NSView(frame: .zero)
        setupScroll.documentView = setupBody
        setupPage.addSubview(setupScroll)
        setupPage.isHidden = true
        stage.addSubview(setupPage)
        paintSetup()

        // Graphs and Chats pages
        graphsPage = GraphStudioView(frame: .zero)
        graphsPage.isHidden = true
        graphsPage.onCrumbsChanged = { [weak self] in self?.syncShell() }
        graphsPage.onNavigate = { [weak self] mode in self?.go(mode == .chats ? .chats : .graphs) }
        stage.addSubview(graphsPage)

        // Needs you
        homePage = HomePageView(frame: .zero)
        homePage.isHidden = true
        homePage.onOpenGraph = { [weak self] key in
            self?.go(.graphs)
            self?.graphsPage.openGraph(key)
        }
        homePage.onOpenChat = { [weak self] key in
            self?.go(.chats)
            self?.graphsPage.openChat(key)
        }
        homePage.onNewGraph = { [weak self] in self?.newGraph() }
        homePage.onWatchGraph = { [weak self] key in self?.openGraph(key, tab: .screen) }
        homePage.onScrolled = { [weak self] scrolled in self?.windowBar?.showsRule = scrolled }
        stage.addSubview(homePage)

        // Teams
        teamsList = TeamsListView(frame: .zero)
        teamsList.isHidden = true
        teamsList.onOpen = { [weak self] id in self?.openTeam(id) }
        teamsList.onNewTeam = { [weak self] in self?.newTeamPressed() }
        teamsList.onChange = { [weak self] in self?.hardRefresh() }
        stage.addSubview(teamsList)
        teamPage = TeamPageView(frame: .zero)
        teamPage.isHidden = true
        teamPage.onChange = { [weak self] in self?.hardRefresh() }
        stage.addSubview(teamPage)

        // Schedules
        schedulesPage = SchedulesPageView(frame: .zero)
        schedulesPage.isHidden = true
        schedulesPage.onOpenTeam = { [weak self] id in self?.openTeam(id) }
        stage.addSubview(schedulesPage)
    }

    private func layoutCanvasPage() {
        let b = canvasPage.bounds
        // Map nearly full-bleed — chrome (toolbar + hint) floats tight at bottom
        let mapFrame = b.insetBy(dx: 6, dy: 6)
        canvasScroll.frame = mapFrame
        canvasScroll.frame.size.height = max(100, b.height - 12)
        map3D.frame = mapFrame
        // Stack: [toolbar] then [hint under it] — no dead 124pt band
        let barH: CGFloat = 40
        let gap: CGFloat = 1
        let hintH = Agent3DMapView.hintStripHeight
        let bottomPad: CGFloat = 4
        // Toolbar sits just above the map’s hint strip (hint is inside map3D at y≈2)
        let barY = mapFrame.minY + bottomPad + hintH + gap
        let contentW = layoutGlassBar(canvasToolbar)
        let tw = min(b.width - 20, max(120, contentW))
        canvasToolbar.frame = NSRect(x: (b.width - tw) / 2, y: barY, width: tw, height: barH)
        _ = layoutGlassBar(canvasToolbar)
        // Keep chrome above SceneKit; HUD/splitter last so widen grip stays hittable
        canvasPage.addSubview(canvasToolbar)
        canvasEmpty.frame = NSRect(x: (b.width - 360) / 2, y: (b.height - 160) / 2, width: 360, height: 160)
        map3D?.layoutPromotedHUD(in: b)
        // After layoutPromotedHUD, re-assert toolbar above map but under? No — toolbar
        // may cover bottom; splitter is on the left column edge so OK under toolbar.
        // Ensure map3D is not re-added above HUD (frame set only).
    }

    private func applyMapMode() {
        map3D?.isHidden = !use3DMap
        canvasScroll?.isHidden = use3DMap
        // Update mode pill label + Orbit/Move selection chrome
        if let canvasToolbar {
            let moveOn = map3D?.isMoveMode == true
            for b in canvasToolbar.subviews.compactMap({ $0 as? NSButton }) {
                let t = b.attributedTitle.string
                let u = t.uppercased()
                if u == "3D" || u == "2D" || u == "FLAT" {
                    let label = use3DMap ? "2D" : "3D"
                    b.attributedTitle = NSAttributedString(string: label, attributes: [
                        .foregroundColor: PongTheme.textPrimary,
                        .font: PongTheme.labelFont(11),
                        .paragraphStyle: centered(),
                    ])
                    b.toolTip = use3DMap ? "Switch to flat map" : "Switch to 3D constellation"
                }
                // Orbit / Move only meaningful on 3D map
                if u == "ORBIT" || u == "MOVE" {
                    b.isHidden = !use3DMap
                    let selected = (u == "MOVE" && moveOn) || (u == "ORBIT" && !moveOn && use3DMap)
                    b.layer?.backgroundColor = (selected
                        ? PongTheme.ink.withAlphaComponent(0.18)
                        : NSColor.clear).cgColor
                }
                if u == "ARCHITECTURE" {
                    b.isHidden = !use3DMap
                }
                // Reset position is 2D-only (flat multi grid)
                if u == "RESET POSITION" || u == "ARRANGE TEAMS" || b.action == #selector(arrangeTeamsPressed) {
                    b.isHidden = use3DMap
                }
            }
            // Re-center after hide/show changes content width
            layoutCanvasPage()
        }
    }

    @objc private func toggleMapMode() {
        use3DMap.toggle()
        AppAISettings.setPrefer3DMap(use3DMap)
        applyMapMode()
        if use3DMap {
            map3D.resetCamera()
            refreshCanvas(light: true)
        } else {
            refreshCanvas(light: true)
            // Fit seats in view so 2D opens usable (not lost in empty space)
            DispatchQueue.main.async { [weak self] in
                self?.fitViewportToNodes()
            }
        }
    }

    /// Ghost seats so first-open 3D still sells the product (not a blank void).
    private static func previewConstellationSeats() -> [Seat3D] {
        let sess = "preview"
        return [
            Seat3D(
                session: sess, id: "c1", role: "conductor",
                title: "Orchestrator", subtitle: "plans · routes · verifies",
                detail: "Your conductor seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "orchestrator"
            ),
            Seat3D(
                session: sess, id: "w1", role: "worker",
                title: "Coder", subtitle: "implements · tests",
                detail: "Worker seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "coder"
            ),
            Seat3D(
                session: sess, id: "w2", role: "worker",
                title: "Reviewer", subtitle: "reviews · rejects soft claims",
                detail: "Worker seat", status: "idle", parentId: nil,
                openJobs: 0, flowHint: "", missionRole: "reviewer"
            ),
            Seat3D(
                session: sess, id: "you", role: "human",
                title: "You", subtitle: "human console",
                detail: "Stay in the loop", status: "idle", parentId: "c1",
                openJobs: 0, flowHint: "", missionRole: "human"
            ),
        ]
    }

    private func layoutMissionPage() {
        missionScroll.frame = missionPage.bounds.insetBy(dx: 20, dy: 16)
    }

    private func layoutSetupPage() {
        setupScroll.frame = setupPage.bounds.insetBy(dx: 20, dy: 16)
        // its cards are drawn to the page's width: draw them again when that changes (the sidebar hid or
        // came back, the window grew), so the content widens with the room it has
        if selected == .setup, abs(setupScroll.contentSize.width - setupPaintedWidth) > 1 { paintSetup() }
    }

    private func glassBar() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        PongTheme.applyFloating(v)
        return v
    }

    /// Lays out visible pills left→right with tight padding. Returns total bar content width.
    @discardableResult
    private func layoutGlassBar(_ bar: NSView) -> CGFloat {
        let buttons = bar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        guard !buttons.isEmpty else { return 40 }
        let pad: CGFloat = 6
        let side: CGFloat = 10
        var x: CGFloat = side
        for b in buttons {
            let title = b.attributedTitle.string.uppercased()
            let w: CGFloat
            switch title {
            case "−", "+", "–", "3D", "2D": w = 36
            case "ORBIT", "MOVE": w = 56
            case "LINK TERMINALS": w = 118
            case "ARCHITECTURE": w = 100
            // Sized to sit with Orbit/Move rather than falling to the default,
            // which happens not to clip at six characters but is not a decision.
            case "ISLAND": w = 62
            case "RESET POSITION", "ARRANGE TEAMS": w = 118
            case "NEW TEAM": w = 96
            default: w = max(48, CGFloat(title.count) * 8 + 20)
            }
            b.frame = NSRect(x: x, y: 8, width: w, height: 28)
            x += w + pad
        }
        // Trim trailing pad; keep symmetric side insets
        return x - pad + side
    }

    // MARK: Navigation

    @objc private func railPressed(_ sender: NSButton) {
        guard let d = Destination(rawValue: sender.tag) else { return }
        go(d)
    }

    private func go(_ d: Destination) {
        if d != selected {
            // a card focused for ⌘1–3 lets go when the page changes
            homePage?.clearFocus()
            graphsPage?.clearBannerFocus()
        }
        selected = d
        let oneTeam = d == .canvas && selectedSession != nil && selectedSession != "__all__"
        let teamsMap = d == .canvas && !oneTeam && showTeamsMap
        placeMap(inTeamPage: oneTeam)
        teamPage.isHidden = !oneTeam
        teamsList.isHidden = !(d == .canvas && !oneTeam && !showTeamsMap)
        canvasPage.isHidden = !(oneTeam || teamsMap)
        missionPage.isHidden = d != .mission
        setupPage.isHidden = d != .setup
        graphsPage.isHidden = !(d == .graphs || d == .chats)
        homePage.isHidden = d != .home
        schedulesPage.isHidden = d != .schedules
        windowBar?.showsRule = false
        if d == .graphs || d == .chats {
            graphsPage.mode = d == .chats ? .chats : .graphs
            graphsPage.start()
        } else {
            graphsPage.stop()
        }
        if d == .home { homePage.render() }
        if d == .schedules { schedulesPage.render() }
        // Pause the 3D map while another page is showing
        if use3DMap {
            let mapShown = !canvasPage.isHidden
            map3D.setMapPlaying(mapShown)
            map3D.isHidden = !mapShown
        }
        syncShell()
        reload()
    }

    /// The 3D map lives in one team's page (under its members), or fills the Teams area.
    private func placeMap(inTeamPage: Bool) {
        guard let canvasPage, let teamPage else { return }
        let host: NSView = inTeamPage ? teamPage.mapHost : stage
        if canvasPage.superview !== host {
            canvasPage.removeFromSuperview()
            if inTeamPage {
                host.addSubview(canvasPage)
            } else {
                stage.addSubview(canvasPage, positioned: .below, relativeTo: missionPage)
            }
        }
        // in a team's page the map is only the map: its old toolbar, HUD and legend step aside
        for v in canvasPage.subviews where v !== map3D && v !== canvasScroll {
            v.isHidden = inTeamPage || (v === canvasEmpty && true)
        }
        layoutAll()
    }

    func previewOpenGraph(_ key: String) { graphsPage.openGraph(key) }
    func previewOpenChat(_ key: String) { graphsPage.openChat(key) }
    func previewGraphTab(_ i: Int) { graphsPage.setTab(GraphStudioView.Tab(rawValue: i) ?? .steps) }
    func previewSelectNode(_ id: String) { graphsPage.previewSelectNode(id) }
    func previewToggleActivity() { graphsPage.previewToggleActivity() }

    /// One team's window-bar actions: open a chat on it (the way work starts now), and ⋯. A stopped
    /// team's first action starts it again as it was set up.
    private func teamActions(_ session: String) -> [NSView] {
        // the team page's own test: its terminals are there
        let running = SchedulesPageView.runningTeams.contains(session)
        teamActionsFor = (session, running)
        let name = ((PairState.loadPairsDb()[session] as? [String: Any])?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
        // running: open a chat on it; stopped: start it again (a chat on it is in ⋯)
        let first: PongButton
        if running {
            first = PongButton(title: "Open a chat here", style: .secondary)
            first.toolTip = "A chat on this team: tell it what you want done and it plans a graph"
            first.onPress = { [weak self] in self?.openChatOnTeam(session) }
        } else {
            first = PongButton(title: "Start team", style: .primary)
            first.toolTip = "Start \(name) again: its lead and helpers, as it was set up"
            first.onPress = { [weak self] in TeamStart.start(session, name: name) { self?.hardRefresh() } }
        }
        let more = PongButton(title: "", style: .quiet)
        more.symbol = "ellipsis"
        more.setAccessibilityLabel("More actions")
        let menu = NSMenu()
        func item(_ t: String, _ fn: @escaping () -> Void) {
            let box = ClosureBox(fn)
            let i = NSMenuItem(title: t, action: #selector(ClosureBox.fire), keyEquivalent: "")
            i.target = box
            i.representedObject = box
            menu.addItem(i)
        }
        if running {
            item("Open the lead's terminal") { DispatchQueue.global(qos: .userInitiated).async { Pairing.frontConductor(session) } }
            item("Conversation with the lead") { TeamFocusController.shared.show(session: session) }
        } else {
            item("Start with a chat") { [weak self] in self?.openChatOnTeam(session) }
            menu.addItem(.separator())
        }
        item("Team layout…") { [weak self] in self?.map3D?.openArchitectureSheet() }
        item("Team options…") { [weak self] in TeamOptionsSheetController.shared.show(for: session) { self?.reload() } }
        item("Use terminals already open…") { [weak self] in self?.linkPressed() }
        if running {
            menu.addItem(.separator())
            item("Stop team…") { [weak self] in self?.confirmKillTeam(session: session, displayName: name) }
        }
        more.onPress = { [weak more] in
            guard let more else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        return [first, more]
    }

    /// A chat (an architect) on an existing team; it opens the team's terminal session if it was closed.
    func openChatOnTeam(_ session: String) {
        Toast.show("Opening a chat on this team…")
        GraphCLI.run(["-s", session, "architect", "start", "--json"], timeout: 60) { [weak self] r in
            switch ArchitectStart.read(out: r.out, err: r.err) {
            case .failed(let why):
                // the toast wraps to three lines, so the fix at the end of the sentence is read too
                Toast.show(why, warn: true)
                Pong.log("architect start on \(session) failed: \(r.err.isEmpty ? r.out : r.err)")
            case .opened(let key, let warning):
                if let warning {
                    Pong.log("architect start on \(session): \(warning)")
                    Toast.show(warning, warn: true)
                }
                GraphStore.shared.refresh()
                self?.openChat(key)
            }
        }
    }

    /// Open Diagnostics (the old Mission page).
    func goDiagnostics() {
        if window == nil { show() }
        go(.mission)
    }

    /// Open the old Setup page (Settings moves into its own window).
    func goSetup() {
        if window == nil { show() }
        go(.setup)
    }

    /// Human chat job chip → Mission tab.
    func goToMission() {
        go(.home)
    }

    /// Push top-bar team focus into the human console (lock orch target).
    private func syncHumanFocusToMap() {
        map3D?.setFocusedTeamSession(selectedSession)
    }

    private func pairsEmptyOrNoMap() -> Bool {
        // Empty teams still show 3D preview constellation (product promise)
        !use3DMap
    }

    // MARK: Data reload

    @objc private func reloadPressed() { hardRefresh() }

    /// Soft reload (poll / navigation) — file cache + light canvas.
    private func reload() {
        updateStatus()
        switch selected {
        case .canvas:
            refreshCanvas()
            renderTeams()
        case .mission: paintMission()
        case .setup: paintSetup()
        case .graphs, .chats: GraphStore.shared.refresh()
        case .home: homePage.render()
        case .schedules: schedulesPage.render()
        }
        layoutAll()
    }

    /// ⌘R — force a fresh snapshot and graph list, then rebuild the page.
    @objc func hardRefresh() {
        guard !hardRefreshInFlight else { return }
        hardRefreshInFlight = true
        PairState.invalidatePairsCache()
        // Allow a concurrent async writer to finish; we force our own snapshot pass
        snapshotRefreshInFlight = false
        GraphStore.shared.refresh()
        Pong.log("refresh hard begin selected=\(selected.rawValue)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Force regenerate snapshot.json (not only re-read a stale file)
            let out = Pong.sh(
                "export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; " +
                "pong snapshot --compact 2>/dev/null | head -c 500000"
            )
            var obj: [String: Any]?
            if let data = out.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               parsed["contract_version"] != nil || parsed["teams"] != nil {
                obj = parsed
            }
            // Best-effort write path if compact stdout failed but CLI still refreshed the file
            if obj == nil {
                _ = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot >/dev/null 2>&1")
                let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
                if !file.isEmpty { obj = file }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let obj { self.lastSnapshot = obj }
                self.updateStatus()
                switch self.selected {
                case .canvas: self.refreshCanvas(light: false)
                case .mission: self.paintMission()
                case .setup: self.paintSetup()
                case .graphs, .chats: break
                case .home: self.homePage.render()
                case .schedules: self.schedulesPage.render()
                }
                self.layoutAll()
                self.hardRefreshInFlight = false
                Pong.log("refresh hard done teams=\((obj?["teams"] as? [Any])?.count ?? -1)")
            }
        }
    }

    private func startPoll() {
        poll?.invalidate()
        // 4s poll on .default (not .common) so it pauses during live resize/drag
        let t = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.canvasDragging { return }
            // Skip heavy map rebuild while user is orbiting / moving seats
            if self.use3DMap, self.map3D?.isUserInteracting == true { return }
            // Power: when panel is fully occluded / app inactive, only light status
            let win = self.window
            let fullyOccluded = win.map { !$0.occlusionState.contains(.visible) } ?? false
            let appInactive = !NSApp.isActive
            // the graph feed polls fast only while someone can see it
            GraphStore.shared.fast = !(fullyOccluded || appInactive) && win?.isVisible == true
            if fullyOccluded || appInactive {
                self.updateStatus()
                return
            }
            // Window recovery OFF main (osascript freezes UI)
            let sess = self.selectedSession
            DispatchQueue.global(qos: .utility).async {
                if let s = sess, s != "__all__" {
                    _ = WindowRecovery.recover(session: s)
                } else {
                    // Throttle full scan: only every 3rd poll (~12s)
                    if Int(Date().timeIntervalSince1970 / 4) % 3 == 0 {
                        WindowRecovery.recoverAll()
                    }
                }
            }
            self.updateStatus()
            if self.selected == .mission { self.paintMission() }
            if self.selected == .canvas {
                // Light map poll — coalesce + no snapshot re-entry storm
                self.refreshCanvas(light: true)
                // Human console: cheaper than full map; still throttle inside
                self.map3D?.pollHumanConsole()
            }
            // Proactive Guide: situation detectors (ghosts, no-subs, stalled jobs)
            let pairs = PairState.listPairs()
            let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
            GuideCoach.tick(snapshot: snap.isEmpty ? nil : snap, pairs: pairs)
        }
        t.tolerance = 0.8
        RunLoop.main.add(t, forMode: .default)
        poll = t
    }

    private func updateStatus() {
        updateSidebar()
        if selected == .canvas { renderTeams() }
    }

    /// The Teams list, or one team's page, from the latest snapshot.
    private func renderTeams() {
        let snap = lastSnapshot ?? Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if let s = selectedSession, s != "__all__" {
            teamPage.render(s, snapshot: snap)
        } else if !showTeamsMap {
            teamsList.render(snapshot: snap)
        }
    }

    // MARK: Canvas

    /// - Parameters:
    ///   - light: poll path — skip topology seed + use dirty-only 3D apply
    ///   - kickSnapshot: false when applying an async snapshot result (avoids feedback loop)
    private func refreshCanvas(light: Bool = false, kickSnapshot: Bool = true) {
        if canvasDragging { return }
        // Coalesce stacked light refreshes (poll + snapshot callback same tick)
        if light {
            if lightCanvasRefreshPending { return }
            lightCanvasRefreshPending = true
            // Run body on next main turn so multiple callers merge into one
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lightCanvasRefreshPending = false
                self.refreshCanvasBody(light: true, kickSnapshot: kickSnapshot)
            }
            return
        }
        refreshCanvasBody(light: false, kickSnapshot: kickSnapshot)
    }

    private func refreshCanvasBody(light: Bool, kickSnapshot: Bool) {
        if canvasDragging { return }
        let pairs = PairState.listPairs()
        // Empty state: keep 3D constellation + toolbar; hide flat empty card
        canvasEmpty.isHidden = true
        canvasToolbar.isHidden = canvasPage.superview === teamPage?.mapHost
        map3D.isHidden = !use3DMap || selected != .canvas
        // Keep 2D scroll visible even with zero teams so the workplace is always panable
        canvasScroll.isHidden = use3DMap || selected != .canvas
        if pairs.isEmpty {
            if use3DMap {
                map3D.reload(seats: Self.previewConstellationSeats(), multiTeam: false, light: light)
                map3D.setMapPlaying(true)
            }
            if !use3DMap {
                canvas.setFrameSize(CanvasLayout.minCanvas)
            }
            return
        }

        let multi = selectedSession == "__all__" || (selectedSession == nil && pairs.count > 1)
        let showPairs: [String] = multi ? pairs : [selectedSession ?? pairs[0]].compactMap { $0 }

        // Start from a modest document; grow to fit seats after layout
        var size = CanvasLayout.minCanvas
        if multi {
            // Grid pitch (see CanvasLayout.multiPitch*) — orch + workers column without overlap
            let cols = CanvasLayout.multiCols
            let rows = max(1, (showPairs.count + cols - 1) / cols)
            size.width = min(
                CanvasLayout.maxCanvas.width,
                max(CanvasLayout.minCanvas.width,
                    CanvasLayout.hudClearX + CGFloat(min(cols, showPairs.count)) * CanvasLayout.multiPitchX + CanvasLayout.workplacePad)
            )
            size.height = min(
                CanvasLayout.maxCanvas.height,
                max(CanvasLayout.minCanvas.height,
                    CanvasLayout.hudClearY + CGFloat(rows) * CanvasLayout.multiPitchY + CanvasLayout.workplacePad)
            )
        }
        // Light poll: avoid thrashing 2D document size every 4s if already sized
        if !light || !use3DMap {
            canvas.setFrameSize(size)
        }

        // Poll: kickSnapshot=true (throttled async shell). Async apply: kickSnapshot=false.
        let snap = snapshot(kickAsync: kickSnapshot)
        var models: [AgentNodeModel] = []
        var seats3D: [Seat3D] = []
        // Work-graph wiring — plotlines the roster cannot derive. Drawn, never saved.
        var graphLinks3D: [FlowLink3D] = []
        var posMap = CanvasLayout.positions(for: multi ? nil : showPairs.first)
        // Multi: unstack teams that share nearly-identical conductor slots (bare-key bug residue)
        // Skip disk writes on light poll — only heal layout on full refresh / user action
        if !light, multi {
            if CanvasLayout.unstackOverlappingTeams(&posMap, sessions: showPairs) {
                for (key, p) in posMap where key.contains("::") {
                    let parts = key.components(separatedBy: "::")
                    if parts.count >= 2 {
                        CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
                    }
                }
            }
        } else if !light, CanvasLayout.compactIfSpread(&posMap, multi: false) {
            // Single-team only: heal pathological void scatter
            for (key, p) in posMap {
                if key.contains("::") {
                    let parts = key.components(separatedBy: "::")
                    if parts.count >= 2 {
                        CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
                    }
                } else if let sess = showPairs.first {
                    CanvasLayout.saveSeat(session: sess, nodeId: key, origin: p)
                }
            }
        }

        for (ti, session) in showPairs.enumerated() {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let display = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let cond = entry["conductor"] as? [String: Any]
            let condId = (cond?["id"] as? String) ?? "c1"
            let condLabel = (cond?["label"] as? String) ?? "Orchestrator"
            let condType = (cond?["type"] as? String) ?? "grok"
            let stowed = (entry["stowed"] as? Bool) == true
            let brief = (entry["team_brief"] as? String) ?? ""
            let rootPath = (entry["project_root"] as? String) ?? ""
            let detail: String = {
                if !brief.isEmpty { return Self.clampDetail(brief) }
                return Self.seatBlurb(role: "conductor", type: condType, openJobs: 0, root: rootPath)
            }()
            let cOrigin = CanvasLayout.origin(
                session: session, nodeId: condId, multi: multi, map: posMap,
                teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size)
            let cAccent = TerminalTheme.Colors.from(entry["colors"])?.asNSColors.hi ?? PongTheme.blue
            // Orchestrator active only for real in-flight work (same rule as floor dots).
            // Queued jobs → calm “busy”; finished → idle (no pulse/ACTIVE face).
            let teamSnapEarly = (snap?["teams"] as? [[String: Any]])?
                .first(where: { ($0["session"] as? String) == session })
            // Prefer activity_open (age-filtered in snapshot); fall back to open.
            let jobsBag = teamSnapEarly?["jobs"] as? [String: Any]
            let openJobsList: [[String: Any]] = {
                if let act = jobsBag?["activity_open"] as? [[String: Any]] { return act }
                return (jobsBag?["open"] as? [[String: Any]]) ?? []
            }()
            var condOpen = 0
            var condBusy = false       // queued / soft (no pulse)
            var condRunning = false    // real in-flight → packets + primitive pulse
            var condHuman = false
            var condHint = ""
            for j in openJobsList {
                condOpen += 1
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st == "running" || st == "notified" || st.contains("working") {
                    condBusy = true
                    condRunning = true
                }
                if st == "queued" || st == "pending" { condBusy = true }
                if st.contains("human") || st == "human_takeover" {
                    condHuman = true; condBusy = true; condRunning = true
                }
                if condHint.isEmpty {
                    condHint = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? ""
                }
            }
            for w in (teamSnapEarly?["workers"] as? [[String: Any]]) ?? [] {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    condHuman = true; condBusy = true; condRunning = true
                }
                // sticky "busy" alone is not in-flight — only running/working hints
                if h.contains("running") || h.contains("working") || h.contains("notified") {
                    condBusy = true; condRunning = true
                } else if h.contains("busy") {
                    condBusy = true
                }
            }
            let cStatus: String = {
                if stowed { return "hidden" }
                if condHuman { return "human" }
                // "running" → pulse + packets; "busy" → quiet; none → idle
                if condRunning { return "running" }
                if condBusy { return "busy" }
                return "idle"
            }()
            models.append(AgentNodeModel(
                session: session, id: condId, role: "conductor",
                title: condLabel, subtitle: "\(condType) · conductor seat",
                detail: detail, status: cStatus,
                // Always show team display name over the orchestrator (single + multi)
                teamLabel: display,
                accent: cAccent, origin: cOrigin,
                parentId: nil, openJobs: condOpen, flowHint: condHint,
                missionRole: "orchestrator"
            ))
            seats3D.append(Seat3D(
                session: session, id: condId, role: "conductor",
                title: condLabel, subtitle: "\(condType) · conductor",
                detail: detail, status: cStatus, parentId: nil,
                openJobs: condOpen, flowHint: condHint,
                missionRole: "orchestrator",
                accent: cAccent
            ))

            let teamSnap = (snap?["teams"] as? [[String: Any]])?.first(where: { ($0["session"] as? String) == session })
            let snapWorkers = teamSnap?["workers"] as? [[String: Any]] ?? []
            let ws = Workers.list(from: entry)
            for (i, w) in ws.enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let lab = (w["label"] as? String) ?? wid
                let typ = (w["type"] as? String) ?? "worker"
                var status = "idle"
                var openN = 0
                var flowHint = ""
                var mapVisible = true
                var isEphWorker = (w["ephemeral"] as? Bool) == true
                if let match = snapWorkers.first(where: { ($0["id"] as? String) == wid }) {
                    status = (match["status_hint"] as? String) ?? status
                    openN = match["open_jobs"] as? Int ?? 0
                    if let mv = match["map_visible"] as? Bool { mapVisible = mv }
                    if let e = match["ephemeral"] as? Bool { isEphWorker = e }
                }
                // Ephemeral permanent-roster workers vanish from the map when idle
                if isEphWorker && !mapVisible { continue }

                // Job preview + precise status for map (dots + primitive pulse share this):
                // running/notified → "running", human → "human",
                // queued only → "busy" (calm seat — no pulse/dots), none → "idle".
                // Prefer activity_open (age-filtered) so stale notified jobs don't keep seats ACTIVE.
                let workerJobsBlob = teamSnap?["jobs"] as? [String: Any]
                let workerOpenList: [[String: Any]]? = {
                    if let act = workerJobsBlob?["activity_open"] as? [[String: Any]] { return act }
                    return workerJobsBlob?["open"] as? [[String: Any]]
                }()
                if let openList = workerOpenList {
                    let mine = openList.filter {
                        (($0["worker"] as? String) ?? ($0["worker_id"] as? String)) == wid
                    }
                    if let first = mine.first {
                        flowHint = (first["task_preview"] as? String)
                            ?? (first["task"] as? String)
                            ?? ""
                    }
                    let hasHuman = mine.contains {
                        let st = (($0["status"] as? String) ?? "").lowercased()
                        return st.contains("human") || st.contains("ask") || st.contains("takeover")
                    }
                    let hasRunning = mine.contains {
                        let st = (($0["status"] as? String) ?? "").lowercased()
                        return st == "running" || st == "notified" || st.contains("working")
                    }
                    if hasHuman {
                        status = "human"
                    } else if hasRunning {
                        status = "running"
                    } else if openN > 0 || !mine.isEmpty {
                        // Queued / waiting — quiet seat (no bob/ACTIVE)
                        status = "busy"
                    } else {
                        // Work finished — force calm (clear sticky busy/live hints)
                        status = "idle"
                    }
                } else if openN > 0 {
                    status = "busy"
                } else if !status.lowercased().contains("human") {
                    status = "idle"
                }
                let wdetail = Self.seatBlurb(role: "worker", type: typ, openJobs: openN, root: nil)
                let origin = CanvasLayout.origin(
                    session: session, nodeId: wid, multi: multi, map: posMap,
                    teamIndex: ti, role: "worker", workerIndex: i, canvas: size)
                let accent = TerminalTheme.Colors.from(w["colors"])?.asNSColors.hi ?? PongTheme.magenta
                // parent_id → subagent level in 3D (also treat empty string as nil)
                let rawParent = (w["parent_id"] as? String) ?? (w["parent"] as? String)
                let parentId = rawParent.flatMap { $0.isEmpty ? nil : $0 }
                // Flow graph sub edges are a second source of truth if parent_id was lost
                let isSubEdge: Bool = {
                    guard parentId == nil else { return false }
                    let edges = FlowGraph.load(from: entry)
                    return edges.contains { $0.kind == "sub" && $0.to == wid }
                }()
                let role3 = (parentId != nil || isSubEdge) ? "subagent" : "worker"
                let resolvedParent: String? = {
                    if let parentId { return parentId }
                    if isSubEdge {
                        return FlowGraph.load(from: entry).first { $0.kind == "sub" && $0.to == wid }?.from
                    }
                    return nil
                }()
                let resolved = MissionRole.resolveWorker(
                    missionRole: (w["mission_role"] as? String) ?? (w["role"] as? String),
                    label: lab,
                    workerIndex: i
                )
                let missionRole = resolved.rawValue
                models.append(AgentNodeModel(
                    session: session, id: wid, role: role3,
                    title: lab, subtitle: "\(typ) · \(resolved.title)",
                    detail: wdetail, status: status,
                    teamLabel: multi ? display : "",
                    accent: accent, origin: origin,
                    parentId: resolvedParent, openJobs: openN, flowHint: flowHint,
                    missionRole: missionRole
                ))
                seats3D.append(Seat3D(
                    session: session, id: wid, role: role3,
                    title: lab, subtitle: "\(typ) · \(resolved.title)",
                    detail: wdetail, status: status, parentId: resolvedParent,
                    openJobs: openN, flowHint: flowHint,
                    missionRole: missionRole,
                    ephemeral: isEphWorker,
                    accent: accent
                ))
            }

            // Live-spawned subagents (Claude Task agents, pong subagent up, ephemeral jobs)
            // Appear on SUB layer under parent; gone on next poll when job/registry clears.
            if let ephList = teamSnap?["ephemeral_subs"] as? [[String: Any]] {
                for e in ephList {
                    guard let eid = e["id"] as? String, !eid.isEmpty else { continue }
                    // Skip if already present as a permanent worker with same id
                    if seats3D.contains(where: { $0.session == session && $0.id == eid }) { continue }
                    let parentId = (e["parent_id"] as? String) ?? condId
                    let lab = (e["label"] as? String) ?? "Subagent"
                    let preview = (e["task_preview"] as? String) ?? ""
                    let st = (e["status"] as? String) ?? "busy"
                    let mission = (e["mission_role"] as? String) ?? "coder"
                    seats3D.append(Seat3D(
                        session: session, id: eid, role: "subagent",
                        title: lab,
                        subtitle: "spawned · under \(parentId)",
                        detail: preview.isEmpty
                            ? "Ephemeral subagent — vanishes when done"
                            : Self.clampDetail(preview),
                        status: st, parentId: parentId,
                        openJobs: 1, flowHint: preview,
                        missionRole: mission,
                        ephemeral: true
                    ))
                }
            }

            // Work graphs (loops) under this team — read-only projection of the snapshot.
            // Every node becomes an ephemeral seat on the SUB layer beneath the graph's
            // owner, and every edge a plotline named for the outcome that fires it.
            // 1.7: graphs have their own page (Graphs), drawn from `pong graph list`.
            // This interim projection drew each running node twice, greyed live
            // nodes out and offered roster actions that did nothing on a graph
            // seat, so the map leaves graphs to the Graphs page.
            if Self.drawGraphsOnMap, let graphs = (teamSnap?["work_graph"] as? [String: Any])?["graphs"] as? [[String: Any]] {
                let now = Date().timeIntervalSince1970
                for g in graphs {
                    guard let gid = (g["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                    else { continue }
                    let gStatus = ((g["status"] as? String) ?? "").lowercased()
                    let finishedAt = Self.epochSeconds(g["finished_at"])
                    // Finished loops linger ten minutes: the shape of what just ran is
                    // the most useful thing on the map right after it stops.
                    let lingering = gStatus == "done"
                        && (finishedAt.map { now - $0 < 600 } ?? false)
                    guard gStatus == "running" || gStatus == "waiting" || lingering else { continue }

                    let owner = (g["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? condId
                    let ownerGid = "\(session)::\(owner)"
                    let nodes = (g["nodes"] as? [[String: Any]]) ?? []
                    let wiring = (g["wiring"] as? [String: Any]) ?? [:]
                    let round = Self.intValue(g["round"])
                    let maxRounds = Self.intValue(g["max_rounds"])
                    let stopReason = (g["stop_reason"] as? String) ?? ""
                    let paused = g["paused"] as? [String: Any]
                    let goal = (g["goal"] as? String) ?? ""

                    var gidForNode: [String: String] = [:]
                    var statusForNode: [String: String] = [:]
                    var roleForNode: [String: String] = [:]
                    for n in nodes {
                        guard let nid = (n["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
                        else { continue }
                        let nRole = ((n["role"] as? String) ?? "").lowercased()
                        let nSeat = (n["seat"] as? String) ?? ""
                        let nStatus = ((n["status"] as? String) ?? "").lowercased()
                        roleForNode[nid] = nRole
                        statusForNode[nid] = nStatus
                        // A join/end that sits on the owner's own seat IS the owner —
                        // draw the seat already on the map instead of a twin beside it.
                        let foldedIntoOwner = nSeat == owner && (nRole == "join" || nRole == "end")
                        gidForNode[nid] = foldedIntoOwner ? ownerGid : "\(session)::\(gid):\(nid)"
                        guard !foldedIntoOwner else { continue }

                        let wire = wiring[nid] as? [String: Any] ?? [:]
                        let why = (wire["why"] as? String) ?? ""
                        seats3D.append(Seat3D(
                            session: session, id: "\(gid):\(nid)", role: "subagent",
                            title: nid,
                            subtitle: Self.platformBadge(
                                runtime: (wire["runtime"] as? String) ?? "",
                                model: (wire["model"] as? String) ?? "",
                                status: nStatus),
                            detail: Self.graphNodeDetail(
                                why: why,
                                rejected: (wire["rejected"] as? [String: Any]) ?? [:],
                                round: round, maxRounds: maxRounds,
                                stopReason: stopReason, paused: paused),
                            status: Self.graphSeatStatus(nStatus),
                            parentId: owner,
                            openJobs: nStatus == "running" ? 1 : 0,
                            flowHint: why.isEmpty ? goal : why,
                            missionRole: Self.graphMissionRole(nRole),
                            ephemeral: true
                        ))
                    }

                    // GOAL: owner hands the loop its task at whichever node is live
                    // (or, before anything runs, at the first one).
                    let startNode = nodes.first {
                        (($0["status"] as? String) ?? "").lowercased() == "running"
                    } ?? nodes.first
                    if let startId = startNode?["id"] as? String,
                       let startGid = gidForNode[startId], startGid != ownerGid {
                        graphLinks3D.append(FlowLink3D(
                            id: "\(session)|wg:\(gid):goal>\(startId)",
                            fromGid: ownerGid, toGid: startGid,
                            label: "GOAL", kind: .delegate,
                            active: statusForNode[startId] == "running",
                            human: false, fromRole: "worker"
                        ))
                    }
                    for e in (g["edges"] as? [[String: Any]]) ?? [] {
                        guard let from = e["from"] as? String, let to = e["to"] as? String,
                              let fromGid = gidForNode[from], let toGid = gidForNode[to]
                        else { continue }
                        let on = (e["on"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "done"
                        graphLinks3D.append(FlowLink3D(
                            id: "\(session)|wg:\(gid):\(from)>\(to):\(on)",
                            fromGid: fromGid, toGid: toGid,
                            label: "ON \(on.uppercased())", kind: .sub,
                            // Packets only where data actually moves: out of a live node.
                            active: statusForNode[from] == "running",
                            human: roleForNode[to] == "human",
                            fromRole: "worker"
                        ))
                    }
                }
            }

            models.append(AgentNodeModel(
                session: session, id: "add", role: "add",
                title: "+", subtitle: "worker", detail: "Add worker",
                status: "idle", teamLabel: "", accent: PongTheme.magenta,
                origin: CGPoint(x: cOrigin.x + AgentNodeView.size.width + 6,
                                y: cOrigin.y + AgentNodeView.size.height / 2 - 14)
            ))
        }

        // Ensure flow_graph exists for editable topology — full refresh only
        // (light poll must not write pairs.json every 4s)
        if !light {
            for session in showPairs {
                let db = PairState.loadPairsDb()
                if let entry = db[session] as? [String: Any] {
                    let g = entry["flow_graph"] as? [String: Any]
                    let arr = g?["edges"] as? [[String: Any]] ?? []
                    if arr.isEmpty {
                        FlowGraph.save(pair: session, edges: FlowGraph.defaultEdges(entry: entry))
                    }
                }
            }
        }

        // Single shared YOU seat (never one-per-team)
        if !showPairs.isEmpty {
            var needsHuman = false
            var claimsWaiting = 0
            var primarySession = showPairs[0]
            if let teams = snap?["teams"] as? [[String: Any]] {
                for session in showPairs {
                    guard let team = teams.first(where: { ($0["session"] as? String) == session }) else { continue }
                    let wq = (team["waitroom_queued"] as? Int)
                        ?? (team["waitroom_queued"] as? Double).map { Int($0) }
                        ?? 0
                    if wq > claimsWaiting {
                        claimsWaiting = wq
                        primarySession = session
                    }
                    for w in (team["workers"] as? [[String: Any]]) ?? [] {
                        let h = ((w["status_hint"] as? String) ?? "").lowercased()
                        if h.contains("human") || h.contains("takeover") {
                            needsHuman = true
                            primarySession = session
                        }
                    }
                    for j in ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                        let st = ((j["status"] as? String) ?? "").lowercased()
                        if st.contains("human") || st.contains("ask") {
                            needsHuman = true
                            primarySession = session
                        }
                    }
                }
            }
            let primaryCond = (PairState.loadPairsDb()[primarySession] as? [String: Any])
                .flatMap { ($0["conductor"] as? [String: Any])?["id"] as? String } ?? "c1"
            let claimHint = claimsWaiting > 0
                ? "Claims waiting: \(claimsWaiting) · auto-deliver when orch free"
                : ""
            seats3D.append(Seat3D(
                session: primarySession, id: "you", role: "human",
                title: "You",
                subtitle: needsHuman
                    ? "A team needs input"
                    : (claimsWaiting > 0
                        ? claimHint
                        : (multi ? "All teams · one human console" : "Send prompts · answer asks")),
                detail: multi
                    ? "One human seat for every team. Dock chat routes to the focused team."
                    : (claimsWaiting > 0
                        ? "\(claimHint). No TUI interrupt while orchestrator is busy."
                        : "Human console — talk to the orchestrator without hunting Terminal windows."),
                status: needsHuman ? "human" : (claimsWaiting > 0 ? "busy" : "idle"),
                parentId: primaryCond, openJobs: claimsWaiting,
                flowHint: needsHuman ? "NEEDS YOU" : (claimsWaiting > 0 ? "CLAIMS \(claimsWaiting)" : ""),
                missionRole: "human"
            ))
        }

        if use3DMap {
            map3D.reload(seats: seats3D, multiTeam: multi, light: light,
                         extraLinks: graphLinks3D)
        } else if !light {
            // Size document to seat cluster + pan padding (fast draw, easy navigation)
            let pts = models.filter { $0.role != "add" && $0.role != "add-sub" }.map(\.origin)
            let fitted = CanvasLayout.workplaceSize(fitting: pts, card: AgentNodeView.size)
            if fitted.width > size.width || fitted.height > size.height {
                size = fitted
                canvas.setFrameSize(size)
            }
            canvas.reload(models: models, multiTeam: multi)
        } else {
            // 2D light: still update cards without resize thrash
            canvas.reload(models: models, multiTeam: multi)
        }
    }

    // MARK: - Work-graph (loop) projection

    /// Epoch seconds from a JSON number written by Python's `time.time()`.
    private static func epochSeconds(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    /// Platform badge for a wired node — letter first, then the model: `C · opus`.
    private static func platformBadge(runtime: String, model: String, status: String) -> String {
        let letter: String = {
            switch runtime.lowercased() {
            case "claude": return "C"
            case "grok": return "G"
            case "codex": return "X"
            case "hermes": return "H"
            default: return runtime.isEmpty ? "?" : String(runtime.uppercased().prefix(1))
            }
        }()
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let badge = m.isEmpty ? letter : "\(letter) · \(m)"
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return st.isEmpty ? badge : "\(badge) · \(st)"
    }

    /// Graph node status → the seat vocabulary the map already colors.
    private static func graphSeatStatus(_ raw: String) -> String {
        switch raw {
        case "running", "awaiting_critic": return "busy"
        case "waiting_human", "paused": return "human"
        default: return "idle"
        }
    }

    /// Graph node role → mission role (glyph + label the map already knows).
    private static func graphMissionRole(_ raw: String) -> String {
        switch raw {
        case "critic": return MissionRole.reviewer.rawValue
        case "builder", "writer": return MissionRole.coder.rawValue
        case "scout", "researcher": return MissionRole.researcher.rawValue
        case "router", "join", "end": return MissionRole.taskRunner.rawValue
        case "operator": return MissionRole.operator.rawValue
        case "orchestrator": return MissionRole.orchestrator.rawValue
        case "human": return "human"
        default: return MissionRole.coder.rawValue
        }
    }

    /// The module card's text for a loop node: why this platform, what was turned
    /// down and for what reason, where the loop is in its rounds, and how it stopped.
    private static func graphNodeDetail(
        why: String, rejected: [String: Any],
        round: Int?, maxRounds: Int?,
        stopReason: String, paused: [String: Any]?
    ) -> String {
        var lines: [String] = []
        let w = clampDetail(why, max: 84)
        if !w.isEmpty { lines.append(w) }
        for key in rejected.keys.sorted() {
            let raw = rejected[key]
            let reason = clampDetail((raw as? String) ?? (raw.map { String(describing: $0) } ?? ""),
                                     max: 60)
            lines.append(reason.isEmpty ? "not \(key)" : "not \(key): \(reason)")
        }
        if let round {
            lines.append(maxRounds.map { "round \(round)/\($0)" } ?? "round \(round)")
        }
        if let paused {
            let reason = clampDetail((paused["reason"] as? String) ?? "", max: 52)
            let gate = (paused["gate"] as? String) ?? ""
            var line = reason.isEmpty ? "paused" : "paused: \(reason)"
            if !gate.isEmpty { line += " · gate \(gate)" }
            if let next = paused["next_node"] as? String, !next.isEmpty { line += " → \(next)" }
            lines.append(line)
        } else if !stopReason.isEmpty {
            lines.append("stopped: \(clampDetail(stopReason, max: 52))")
        }
        return lines.joined(separator: "\n")
    }

    /// Short seat blurbs for canvas cards (wrap-safe length).
    private static func clampDetail(_ s: String, max: Int = 72) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max - 1)) + "…"
    }

    private static func seatBlurb(role: String, type: String, openJobs: Int, root: String?) -> String {
        let t = type.lowercased()
        if role == "conductor" {
            if let root, !root.isEmpty {
                let leaf = (root as NSString).lastPathComponent
                return clampDetail("Plans jobs · verdicts · \(leaf)")
            }
            switch t {
            case "grok": return "Plans & verifies · Grok Build seat"
            case "hermes": return "Plans & verifies · Hermes seat"
            case "claude": return "Plans & verifies · Claude seat"
            default: return "Plans jobs · verifies claims"
            }
        }
        if openJobs > 0 {
            return "\(openJobs) open job\(openJobs == 1 ? "" : "s") · building"
        }
        switch t {
        case "claude": return "Implements code · files & tests"
        case "grok": return "Implements · Grok Build worker"
        case "codex": return "Implements · Codex worker"
        case "kimi": return "Implements · Kimi worker"
        case "opencode": return "Implements · OpenCode worker"
        case "linked": return "Linked terminal · live session"
        default: return "Executes assigned jobs"
        }
    }

    // MARK: - Mission dashboard

    private var snapshotRefreshInFlight = false
    /// Throttle shell `pong snapshot` — was re-kicked on every canvas paint → thrash loop.
    private var lastSnapshotKickAt: TimeInterval = 0
    /// Skip canvas re-apply when activity signature unchanged.
    private var lastAppliedSnapshotSig: String = ""
    /// Coalesce stacked light canvas refreshes onto one main-queue pass.
    private var lightCanvasRefreshPending = false

    /// Never block main on `pong snapshot` — paint from file/cache; refresh async.
    /// - Parameter kickAsync: false when applying an already-fresh async result (breaks
    ///   refreshCanvas → snapshot → refreshCanvas feedback loop).
    private func snapshot(kickAsync: Bool = true) -> [String: Any]? {
        let file = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        if !file.isEmpty { lastSnapshot = file }
        if kickAsync { refreshSnapshotAsync() }
        return lastSnapshot ?? (file.isEmpty ? nil : file)
    }

    /// Compact sig of map-relevant snapshot activity (not full JSON).
    private func snapshotActivitySig(_ snap: [String: Any]) -> String {
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        var parts: [String] = []
        for t in teams {
            let sess = (t["session"] as? String) ?? "?"
            let jobs = t["jobs"] as? [String: Any]
            let open = (jobs?["activity_open"] as? [[String: Any]])
                ?? (jobs?["open"] as? [[String: Any]])
                ?? []
            let openSig = open.map { j in
                let id = (j["id"] as? String) ?? ""
                let st = (j["status"] as? String) ?? ""
                let w = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? ""
                return "\(id):\(st):\(w)"
            }.sorted().joined(separator: ",")
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            let wSig = workers.map { w in
                let id = (w["id"] as? String) ?? ""
                let h = (w["status_hint"] as? String) ?? ""
                let n = w["open_jobs"] as? Int ?? 0
                return "\(id):\(h):\(n)"
            }.sorted().joined(separator: ",")
            let eph = ((t["ephemeral_subs"] as? [[String: Any]]) ?? [])
                .compactMap { $0["id"] as? String }.sorted().joined(separator: ",")
            parts.append("\(sess){\(openSig)|\(wSig)|\(eph)}")
        }
        return parts.sorted().joined(separator: ";")
    }

    private func refreshSnapshotAsync() {
        guard !snapshotRefreshInFlight else { return }
        let now = Date().timeIntervalSince1970
        // At most one shell snapshot every ~3.5s (poll is 4s; avoid re-entry from paint)
        if now - lastSnapshotKickAt < 3.5 { return }
        lastSnapshotKickAt = now
        snapshotRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = Pong.sh("export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; pong snapshot --compact 2>/dev/null | head -c 500000")
            var obj: [String: Any]?
            if let data = out.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               parsed["contract_version"] != nil {
                obj = parsed
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotRefreshInFlight = false
                guard let obj else { return }
                let sig = self.snapshotActivitySig(obj)
                let changed = sig != self.lastAppliedSnapshotSig
                self.lastSnapshot = obj
                if self.selected == .mission {
                    self.paintMission()
                }
                // Only re-paint map when activity changed — never kick another snapshot
                if changed, self.selected == .canvas {
                    self.lastAppliedSnapshotSig = sig
                    self.refreshCanvas(light: true, kickSnapshot: false)
                } else if !changed {
                    self.lastAppliedSnapshotSig = sig
                }
            }
        }
    }

    private func paintMission() {
        // Preserve scroll while repainting (async snapshot used to jump the page)
        let savedScroll = missionScroll.contentView.bounds.origin
        missionBody.subviews.forEach { $0.removeFromSuperview() }
        let boxW = max(400, missionScroll.contentSize.width > 20 ? missionScroll.contentSize.width - 4 : 560)
        let snap = snapshot() ?? [:]
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        let ledger = (snap["ledger"] as? [String: Any]) ?? [:]
        let bridgeOn = (snap["bridge_on"] as? Bool) == true
        let events = (snap["events_tail"] as? [[String: Any]]) ?? []

        var yCursor: CGFloat = 0
        var blocks: [(NSView, CGFloat)] = []

        func push(_ v: NSView, _ h: CGFloat) {
            blocks.append((v, h))
            yCursor += h + 12
        }

        // Scan for human-needed seats / jobs
        var humanSessions: [String] = []
        var openJobs = 0, agentCount = 0
        for t in teams {
            let sess = (t["session"] as? String) ?? ""
            openJobs += (t["jobs"] as? [String: Any]).flatMap { ($0["counts"] as? [String: Any])?["open"] as? Int } ?? 0
            agentCount += 1 + ((t["workers"] as? [[String: Any]])?.count ?? 0)
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            for w in workers {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    if !sess.isEmpty, !humanSessions.contains(sess) { humanSessions.append(sess) }
                }
            }
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            for j in openList {
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st.contains("human") || st.contains("ask") {
                    if !sess.isEmpty, !humanSessions.contains(sess) { humanSessions.append(sess) }
                }
            }
        }
        let rounds = ledger["rounds"] as? Int ?? 0
        let rate = Int(((ledger["accept_rate"] as? Double) ?? 0) * 100)
        let streak = ledger["reject_streak"] as? Int ?? 0

        // Header — design: large title + CONTROL PLANE status
        let head = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 72))
        head.wantsLayer = true
        let titleL = Self.label("Diagnostics", frame: NSRect(x: 0, y: 30, width: 320, height: 36), bold: true, size: 22)
        titleL.font = PongType.title
        titleL.textColor = PongColor.textPrimary
        head.addSubview(titleL)
        let bridgeText = bridgeOn ? "Numbers, problems and the event log, for engineers." : "No helpers are working. Numbers, problems and the event log, for engineers."
        let bridgeLbl = Self.label(bridgeText, frame: NSRect(x: 0, y: 10, width: boxW - 8, height: 14), size: 11, secondary: true)
        bridgeLbl.font = PongType.secondary
        bridgeLbl.textColor = PongColor.textSecondary
        head.addSubview(bridgeLbl)
        let rule = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        head.addSubview(rule)
        push(head, 72)

        // The Gauntlet, first thing on the page. Mission is already jobs & flow,
        // and the bar is what those jobs are graded against, so its status sits
        // above the list rather than behind a menu item nobody opens.
        let gaunt = gauntletStrip(width: boxW)
        push(gaunt, gaunt.frame.height)

        // Mission Q&A + cron entry (Guide-grounded; chips use live snapshot)
        let askH: CGFloat = 118
        let askCard = tacticalCard(width: boxW, height: askH, accent: PongTheme.blue)
        let askTitle = Self.label("Ask about this mission…",
            frame: NSRect(x: 16, y: askH - 28, width: 240, height: 16), size: 12, secondary: false)
        askTitle.font = PongTheme.font(12, weight: .semibold)
        askCard.addSubview(askTitle)
        let cronBtn = NSButton(title: "Describe a schedule…", target: self, action: #selector(missionDescribeCron))
        cronBtn.bezelStyle = .rounded
        cronBtn.font = PongTheme.font(11, weight: .medium)
        cronBtn.frame = NSRect(x: boxW - 168, y: askH - 32, width: 152, height: 24)
        askCard.addSubview(cronBtn)
        let chips = ["Who is idle?", "Any rogue/stale jobs?", "What should I do next?", "Why is orch active?"]
        var chipX: CGFloat = 16
        for (i, chip) in chips.enumerated() {
            let b = NSButton(title: chip, target: self, action: #selector(missionAskChip(_:)))
            b.bezelStyle = .rounded
            b.font = PongTheme.font(10, weight: .medium)
            b.identifier = NSUserInterfaceItemIdentifier(chip)
            b.tag = i
            let w = max(88, CGFloat(chip.count) * 6.2 + 20)
            b.frame = NSRect(x: chipX, y: askH - 58, width: min(w, 160), height: 22)
            askCard.addSubview(b)
            chipX += b.frame.width + 6
        }
        let askField = NSTextField(frame: NSRect(x: 16, y: 36, width: boxW - 100, height: 24))
        askField.placeholderString = "Ask about idle seats, stuck jobs, orch pulse…"
        askField.font = PongTheme.font(12)
        askField.isBordered = true
        askField.bezelStyle = .roundedBezel
        askField.identifier = NSUserInterfaceItemIdentifier("missionAskField")
        askCard.addSubview(askField)
        let askSend = NSButton(title: "Ask", target: self, action: #selector(missionAskSend))
        askSend.bezelStyle = .rounded
        askSend.font = PongTheme.font(11, weight: .semibold)
        askSend.frame = NSRect(x: boxW - 76, y: 34, width: 60, height: 26)
        askCard.addSubview(askSend)
        let replyText = missionAskLastReply.isEmpty
            ? "Answers use live snapshot (status_hint, open jobs, ages)."
            : missionAskLastReply
        let replyL = Self.label(replyText,
            frame: NSRect(x: 16, y: 6, width: boxW - 32, height: 26), size: 11, secondary: true)
        replyL.maximumNumberOfLines = 2
        replyL.lineBreakMode = .byTruncatingTail
        replyL.identifier = NSUserInterfaceItemIdentifier("missionAskReply")
        askCard.addSubview(replyL)
        // Stash field for send action (paint rebuilds; re-find by identifier when sending)
        push(askCard, askH)

        // Human-needed banner (orange path → Focus)
        if !humanSessions.isEmpty {
            let banH: CGFloat = 56
            let ban = tacticalCard(width: boxW, height: banH, accent: PongTheme.orange)
            let humanT = Self.label("\(humanSessions.count) question\(humanSessions.count == 1 ? "" : "s") need you",
                frame: NSRect(x: 16, y: 30, width: boxW - 140, height: 16), size: 13, secondary: false)
            humanT.font = PongTheme.font(13, weight: .semibold)
            humanT.textColor = PongTheme.amber
            ban.addSubview(humanT)
            ban.addSubview(Self.label("A team is waiting for your answer.",
                frame: NSRect(x: 16, y: 12, width: boxW - 140, height: 14), size: 12, secondary: true))
            let fb = accentButton("Answer", #selector(missionFocusFirstHuman))
            fb.frame = NSRect(x: boxW - 118, y: 14, width: 100, height: 28)
            ban.addSubview(fb)
            push(ban, banH)
        }

        // What’s happening — cyan left rule
        let digest = missionDigest(openJobs: openJobs, teams: teams.count, streak: streak, human: !humanSessions.isEmpty)
        let digH: CGFloat = 72
        let dig = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: digH))
        dig.wantsLayer = true
        dig.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.9).cgColor
        dig.layer?.cornerRadius = 6
        dig.layer?.borderWidth = 1
        dig.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        let cyanBar = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: digH))
        cyanBar.wantsLayer = true
        cyanBar.layer?.backgroundColor = PongTheme.blue.cgColor
        dig.addSubview(cyanBar)
        dig.addSubview(Self.label("What’s happening",
            frame: NSRect(x: 16, y: 46, width: 200, height: 14), size: 11, secondary: true))
        let digBody = Self.label(digest.text,
            frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 26), bold: true, size: 14)
        digBody.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        dig.addSubview(digBody)
        push(dig, digH)

        // KPI 4-up — large values (design)
        let metricsH: CGFloat = 100
        let metrics = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: metricsH))
        let titles = ["Tasks in progress", "Passed review", "AIs", "Sent back in a row"]
        let values = ["\(openJobs)", "\(rate)%", "\(agentCount)", "\(streak)"]
        let subs = ["In flight", "\(rounds) rounds", "\(teams.count) teams", "Current"]
        let metricGap: CGFloat = 12
        let tw = (boxW - metricGap * 3) / 4
        for i in 0..<4 {
            let tile = NSView(frame: NSRect(x: CGFloat(i) * (tw + metricGap), y: 0, width: tw, height: metricsH))
            tile.wantsLayer = true
            tile.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.85).cgColor
            tile.layer?.cornerRadius = 6
            tile.layer?.borderWidth = 1
            tile.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.14).cgColor
            if i == 3 {
                let top = NSView(frame: NSRect(x: 0, y: metricsH - 2, width: tw, height: 2))
                top.wantsLayer = true
                top.layer?.backgroundColor = PongTheme.amber.withAlphaComponent(0.55).cgColor
                tile.addSubview(top)
            }
            let tL = Self.label(titles[i], frame: NSRect(x: 14, y: 72, width: tw - 28, height: 14), size: 11, secondary: true)
            tL.font = PongTheme.mono(10)
            tile.addSubview(tL)
            let v = Self.label(values[i], frame: NSRect(x: 14, y: 28, width: tw - 28, height: 36), bold: true, size: 28)
            v.font = PongTheme.font(28, weight: .bold)
            v.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
            tile.addSubview(v)
            tile.addSubview(Self.label(subs[i], frame: NSRect(x: 14, y: 10, width: tw - 28, height: 14), size: 11, secondary: true))
            metrics.addSubview(tile)
        }
        push(metrics, metricsH)

        // ── Design handoff: data-viz row 1 — throughput + jobs by status ──
        let gap: CGFloat = 12
        let half = (boxW - gap) / 2
        let chartH: CGFloat = 168
        let row1 = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: chartH))
        let throughputSeries = missionThroughputSeries(events: events)
        let throughputCard = missionChartCard(
            title: "Job throughput", subtitle: "LAST 24H",
            width: half, height: chartH
        )
        drawAreaLineChart(in: throughputCard, series: throughputSeries,
                          plot: NSRect(x: 14, y: 14, width: half - 28, height: chartH - 48),
                          color: PongTheme.blue)
        row1.addSubview(throughputCard)

        // Aggregate real job status counts across teams
        var statusCounts: [String: Int] = [:]
        for t in teams {
            let counts = ((t["jobs"] as? [String: Any])?["counts"] as? [String: Any]) ?? [:]
            if let by = counts["by_status"] as? [String: Any] {
                for (k, v) in by {
                    let n = (v as? Int) ?? Int("\(v)") ?? 0
                    statusCounts[k, default: 0] += n
                }
            } else {
                statusCounts["done", default: 0] += counts["done"] as? Int ?? 0
                statusCounts["failed", default: 0] += counts["failed"] as? Int ?? 0
                statusCounts["open", default: 0] += counts["open"] as? Int ?? 0
            }
            for j in ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                let st = (j["status"] as? String) ?? "queued"
                // Prefer by_status when present; else tally open statuses
                if counts["by_status"] == nil {
                    statusCounts[st, default: 0] += 1
                }
            }
        }
        let statusOrder = ["done", "notified", "running", "queued", "failed", "rejected", "cancelled"]
        var statusRows: [(String, Int, NSColor)] = []
        for key in statusOrder {
            if let n = statusCounts[key], n > 0 {
                let col: NSColor = {
                    switch key {
                    case "done": return PongTheme.blue
                    case "notified", "running": return PongTheme.cyanBright
                    case "failed", "rejected": return PongTheme.orange
                    default: return PongTheme.line
                    }
                }()
                statusRows.append((key, n, col))
            }
        }
        if statusRows.isEmpty {
            statusRows = [("done", 0, PongTheme.blue), ("queued", 0, PongTheme.line)]
        }
        let statusCard = missionChartCard(title: "Jobs by status", subtitle: "", width: half, height: chartH)
        statusCard.frame.origin.x = half + gap
        drawHorizontalBars(in: statusCard, rows: statusRows,
                           plot: NSRect(x: 14, y: 12, width: half - 28, height: chartH - 44))
        row1.addSubview(statusCard)
        push(row1, chartH)

        // ── Design handoff: data-viz row 2 — accept trend + seat utilization ──
        let row2 = NSView(frame: NSRect(x: 0, y: 0, width: boxW, height: chartH))
        let acceptSeries = missionAcceptTrend(events: events, ledger: ledger)
        let acceptCard = missionChartCard(
            title: "Accept rate trend", subtitle: "\(rounds) ROUNDS",
            width: half, height: chartH
        )
        drawAreaLineChart(in: acceptCard, series: acceptSeries,
                          plot: NSRect(x: 14, y: 14, width: half - 28, height: chartH - 48),
                          color: NSColor(calibratedWhite: 0.55, alpha: 1),
                          fill: false)
        row2.addSubview(acceptCard)

        let seatBars = missionSeatUtilization(teams: teams)
        let seatCard = missionChartCard(title: "Seat utilization", subtitle: "", width: half, height: chartH)
        seatCard.frame.origin.x = half + gap
        drawVerticalBars(in: seatCard, bars: seatBars,
                         plot: NSRect(x: 14, y: 28, width: half - 28, height: chartH - 56))
        row2.addSubview(seatCard)
        push(row2, chartH)

        // ── Agent / team watchlist (rogue · mistakes · runtime · sharpness) ──
        let watch = missionAgentWatchlist(teams: teams, events: events, ledger: ledger)
        let watchH: CGFloat = 44 + CGFloat(max(watch.count, 1)) * 52 + 8
        let watchCard = missionChartCard(title: "Problems", subtitle: "STUCK · SLOW · FAILING",
                                         width: boxW, height: watchH)
        if watch.isEmpty {
            let ok = Self.label("Nothing is stuck, slow or failing.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 18), size: 12, secondary: true)
            watchCard.addSubview(ok)
        } else {
            var wy = watchH - 48
            for item in watch.prefix(8) {
                let row = NSView(frame: NSRect(x: 12, y: wy - 44, width: boxW - 24, height: 48))
                row.wantsLayer = true
                row.layer?.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.055, blue: 0.07, alpha: 1).cgColor
                row.layer?.cornerRadius = 5
                row.layer?.borderWidth = 1
                row.layer?.borderColor = item.severity.withAlphaComponent(0.35).cgColor
                let rail = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 48))
                rail.wantsLayer = true
                rail.layer?.backgroundColor = item.severity.cgColor
                row.addSubview(rail)
                let badge = Self.label(item.tag, frame: NSRect(x: 14, y: 26, width: 100, height: 14), size: 10, secondary: false)
                badge.font = PongTheme.mono(10, weight: .semibold)
                badge.textColor = item.severity
                row.addSubview(badge)
                let who = Self.label(item.title, frame: NSRect(x: 120, y: 26, width: boxW - 160, height: 14), bold: true, size: 12)
                who.textColor = NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.96, alpha: 1)
                row.addSubview(who)
                let detail = Self.label(item.detail, frame: NSRect(x: 14, y: 8, width: boxW - 50, height: 14), size: 11, secondary: true)
                detail.lineBreakMode = .byTruncatingTail
                row.addSubview(detail)
                watchCard.addSubview(row)
                wy -= 52
            }
        }
        push(watchCard, watchH)

        // ACTIVITY log (design mono rows)
        let show = Array(events.suffix(12).reversed())
        let actH: CGFloat = 44 + CGFloat(max(show.count, 1)) * 28
        let act = missionChartCard(title: "Event log", subtitle: "FOR ENGINEERS", width: boxW, height: actH)
        if show.isEmpty {
            act.addSubview(Self.label("Jobs and verdicts appear here from the control plane.",
                frame: NSRect(x: 16, y: 16, width: boxW - 32, height: 14), size: 12, secondary: true))
        } else {
            var ey = actH - 44
            for e in show {
                let t = (e["type"] as? String) ?? "event"
                let extra = [(e["job_id"] as? String), (e["status"] as? String), (e["verdict"] as? String), (e["session"] as? String)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
                let line = Self.label("\(t)   \(extra)",
                    frame: NSRect(x: 16, y: ey - 4, width: boxW - 32, height: 16), size: 11, secondary: true)
                line.font = PongTheme.mono(11)
                line.lineBreakMode = .byTruncatingTail
                act.addSubview(line)
                ey -= 28
            }
        }
        push(act, actH)

        // Team boards + Focus CTA
        for team in teams {
            let session = (team["session"] as? String) ?? "?"
            let display = (team["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? session
            let openList = ((team["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            let workers = (team["workers"] as? [[String: Any]]) ?? []
            let condLabel = ((team["conductor"] as? [String: Any])?["label"] as? String) ?? "Conductor"
            let needsHuman = humanSessions.contains(session)
            let h: CGFloat = 72 + CGFloat(max(openList.count, 1)) * 28 + 8
            let card = tacticalCard(width: boxW, height: h, accent: needsHuman ? PongTheme.amber : PongTheme.ink)
            card.addSubview(Self.label(display,
                frame: NSRect(x: 14, y: h - 28, width: boxW - 130, height: 18), bold: true, size: 14))
            card.addSubview(Self.label("\(workers.isEmpty ? "Lead only" : "\(workers.count) helper\(workers.count == 1 ? "" : "s")") · \(openList.isEmpty ? "nothing in progress" : "\(openList.count) task\(openList.count == 1 ? "" : "s") in progress")",
                frame: NSRect(x: 14, y: h - 46, width: boxW - 130, height: 14), size: 12, secondary: true))
            let focusBtn = pillButton("Open team", #selector(missionFocusTeam(_:)))
            focusBtn.identifier = NSUserInterfaceItemIdentifier(session)
            focusBtn.frame = NSRect(x: boxW - 90, y: h - 38, width: 72, height: 26)
            card.addSubview(focusBtn)
            var ly = h - 58
            if openList.isEmpty {
                card.addSubview(Self.label("Nothing in progress.",
                    frame: NSRect(x: 14, y: 14, width: boxW - 28, height: 14), size: 12, secondary: true))
            } else {
                for j in openList.prefix(8) {
                    ly -= 28
                    let st = (j["status"] as? String) ?? "?"
                    let prev = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? ""
                    let workerId = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "w1"
                    let sk = PongTheme.statusKind(st)
                    let row = MissionJobRow(frame: NSRect(x: 10, y: ly, width: boxW - 20, height: 24))
                    row.session = session
                    row.workerId = workerId
                    row.target = self
                    row.action = #selector(missionSelectJob(_:))
                    row.wantsLayer = true
                    row.layer?.backgroundColor = PongTheme.bgInput.cgColor
                    row.layer?.cornerRadius = 4
                    let badge = NSTextField(labelWithString: sk.label)
                    badge.font = PongTheme.labelFont(9)
                    badge.textColor = sk.color
                    badge.isBordered = false
                    badge.backgroundColor = .clear
                    badge.frame = NSRect(x: 8, y: 4, width: 52, height: 14)
                    row.addSubview(badge)
                    let preview = Self.label(String(prev.prefix(80)),
                        frame: NSRect(x: 64, y: 4, width: boxW - 120, height: 14), size: 12, secondary: true)
                    preview.lineBreakMode = .byTruncatingTail
                    row.addSubview(preview)
                    card.addSubview(row)
                }
            }
            push(card, h)
        }

        if teams.isEmpty {
            let empty = emptyState(title: "No mission data",
                                   body: "Start a team on the canvas. Jobs and verdicts from the control plane show up here.",
                                   cta: "Canvas", action: #selector(goCanvas))
            empty.frame = NSRect(x: 0, y: 0, width: min(400, boxW), height: 150)
            push(empty, 150)
        }

        let contentH = max(yCursor + 40, missionScroll.contentSize.height)
        missionBody.setFrameSize(NSSize(width: boxW, height: contentH))
        var y = contentH - 8
        for (v, h) in blocks {
            y -= h
            v.setFrameOrigin(NSPoint(x: 0, y: y))
            if v.frame.width < 10 { v.setFrameSize(NSSize(width: boxW, height: h)) }
            missionBody.addSubview(v)
            y -= 12
        }
        let cv = missionScroll.contentView
        // Keep user's scroll position (async snapshot was resetting it → scroll bug)
        let maxY = max(0, contentH - cv.bounds.height)
        let restoreY = min(max(0, savedScroll.y), maxY)
        cv.scroll(to: NSPoint(x: 0, y: restoreY))
        missionScroll.reflectScrolledClipView(cv)
    }

    /// Shared tactical card shell: lime/role accent rail.
    private func tacticalCard(width: CGFloat, height: CGFloat, accent: NSColor) -> NSView {
        PongSheetChrome.plate(frame: NSRect(x: 0, y: 0, width: width, height: height), accent: accent)
    }

    /// The Gauntlet strip — every bar that is actually grading work, and the
    /// two different ways in.
    ///
    /// It lists what `load_bars` returns, factory defaults included, because
    /// those are the bars attaching to real jobs today whether or not anyone
    /// set them. Each row carries its own Edit; creating a new bar is a separate
    /// button, so Edit never quietly means create.
    private func gauntletStrip(width: CGFloat) -> NSView {
        let session = boundSession()
        let read = session.isEmpty
            ? GauntletRead(bars: [], error: "No team bound — pair one from Setup.")
            : Gauntlet.bars(session: session)
        gauntletBars = read.bars

        let rowH: CGFloat = 46
        let height = max(92, 58 + CGFloat(max(1, read.bars.count)) * rowH)
        let card = tacticalCard(width: width, height: height, accent: PongSheetChrome.lime)

        let head = Self.label("GAUNTLET", frame: NSRect(x: 16, y: height - 26, width: 200, height: 14),
                              size: 10, secondary: true)
        head.font = PongTheme.labelFont(10)
        head.textColor = PongTheme.textSecondary
        card.addSubview(head)

        // Always here, always meaning the same thing: make a NEW bar.
        let newBtn = PongSheetChrome.primaryButton("Set the bar", target: self,
                                                   action: #selector(openGauntlet))
        newBtn.frame = NSRect(x: width - 132, y: height - 34, width: 116, height: 28)
        card.addSubview(newBtn)

        var y = height - 58

        if let error = read.error {
            // A failed read is not "no bars". Saying so is the difference
            // between a card that is empty and a card that is broken.
            let t = Self.label(error, frame: NSRect(x: 16, y: y, width: width - 160, height: 32),
                               size: 12)
            t.textColor = PongTheme.danger
            card.addSubview(t)
            return card
        }

        if read.bars.isEmpty {
            let t = Self.label("No bar set.", frame: NSRect(x: 16, y: y, width: width - 160, height: 16),
                               size: 12)
            t.font = PongTheme.font(12, weight: .semibold)
            t.textColor = PongTheme.textPrimary
            card.addSubview(t)
            card.addSubview(Self.label("The team is running without a definition of great.",
                                       frame: NSRect(x: 16, y: y - 18, width: width - 160, height: 14),
                                       size: 11, secondary: true))
            return card
        }

        for (i, bar) in read.bars.enumerated() {
            let t = Self.label(bar.title, frame: NSRect(x: 16, y: y, width: width - 160, height: 16),
                               size: 12)
            t.font = PongTheme.font(12, weight: .semibold)
            t.textColor = PongTheme.textPrimary
            card.addSubview(t)

            // Who it covers and who holds it, both resolved the way a real job
            // resolves them, and both already in owner language.
            var line = bar.lanes.isEmpty ? "covers nobody on this team"
                                         : bar.lanes.joined(separator: " and ")
            if !bar.references.isEmpty {
                line += " · judged against " + bar.references.joined(separator: ", ")
            }
            if !bar.held.isEmpty { line += " · held by " + bar.held }
            card.addSubview(Self.label(line, frame: NSRect(x: 16, y: y - 17, width: width - 160,
                                                           height: 14), size: 11, secondary: true))

            var note = ""
            if bar.shipped { note = "shipped default — you did not set this" }
            if bar.pending {
                // Say what is actually knowable. A placeholder anchor means the
                // bar has a gap in it; whether anyone is out looking for one is
                // not something this card can see, and claiming a search is
                // running when none is would be worse than saying nothing.
                let gap = "no anchor yet — nothing real to point at"
                note = note.isEmpty ? gap : note + " · " + gap
            }
            if !note.isEmpty {
                card.addSubview(Self.label(note, frame: NSRect(x: 16, y: y - 32, width: width - 160,
                                                               height: 14), size: 11, secondary: true))
            }

            let edit = PongSheetChrome.outlineButton("Edit", target: self,
                                                     action: #selector(editGauntlet(_:)))
            edit.tag = i
            edit.frame = NSRect(x: width - 132, y: y - 6, width: 76, height: 26)
            card.addSubview(edit)
            y -= rowH
        }
        return card
    }

    /// The bars the card is currently showing, so an Edit button knows which one
    /// it belongs to without the row having to carry the whole thing.
    private var gauntletBars: [GauntletBar] = []

    /// The team the panel is currently looking at. A bar covers seats on a team,
    /// so with nothing bound there is nothing for the strip to describe.
    private func boundSession() -> String {
        let active = Pong.loadJSON(PairState.activePath)
        return (active["session"] as? String) ?? PairState.listPairs().first ?? ""
    }

    /// Edit the bar on this row — pre-filled, and saved as an override.
    @objc private func editGauntlet(_ sender: NSButton) {
        let session = boundSession()
        guard !session.isEmpty, gauntletBars.indices.contains(sender.tag) else { return }
        GauntletSheet.present(session: session, editing: gauntletBars[sender.tag])
    }

    @objc private func openGauntlet() {
        let session = boundSession()
        guard !session.isEmpty else {
            let a = NSAlert()
            a.messageText = "No team bound"
            a.informativeText = "A bar covers seats on a team. Pair one first."
            a.runModal()
            return
        }
        GauntletSheet.present(session: session)
    }

    /// Somewhere to hang a sheet. Setting the bar is a scoped task inside the
    /// panel's context, so it attaches here instead of floating on its own where
    /// it can end up behind the app.
    var sheetHost: NSWindow? { window }

    private func missionDigest(openJobs: Int, teams: Int, streak: Int, human: Bool) -> (text: String, color: NSColor) {
        if human {
            return ("A team is waiting for your answer.", PongTheme.orange)
        }
        if streak >= 2 {
            return ("\(streak) results in a row were sent back. Check the work.", PongTheme.textPrimary)
        }
        if openJobs > 0 {
            return ("\(openJobs) task\(openJobs == 1 ? "" : "s") in progress across \(teams) team\(teams == 1 ? "" : "s").", PongTheme.blue)
        }
        if teams == 0 {
            return ("No team is running.", PongTheme.textSecondary)
        }
        return ("All clear.", PongTheme.textSecondary)
    }

    // MARK: Mission charts + agent watchlist

    private func missionChartCard(title: String, subtitle: String, width: CGFloat, height: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedRed: 0.039, green: 0.055, blue: 0.071, alpha: 0.92).cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.14).cgColor
        // Soft top hairline for depth
        let topLine = NSView(frame: NSRect(x: 1, y: height - 1, width: width - 2, height: 1))
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        v.addSubview(topLine)
        let t = Self.label(title, frame: NSRect(x: 14, y: height - 30, width: max(80, width - 120), height: 16), bold: true, size: 12)
        t.font = PongTheme.font(12, weight: .semibold)
        t.textColor = NSColor(calibratedRed: 0.949, green: 0.965, blue: 0.973, alpha: 1)
        v.addSubview(t)
        if !subtitle.isEmpty {
            let s = Self.label(subtitle, frame: NSRect(x: width - 118, y: height - 28, width: 104, height: 14), size: 10, secondary: true)
            s.font = PongTheme.mono(10, weight: .medium)
            s.alignment = .right
            s.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
            v.addSubview(s)
        }
        return v
    }

    /// Bucket event activity into evenly spaced samples for area/line charts.
    private func missionThroughputSeries(events: [[String: Any]]) -> [CGFloat] {
        let now = Date().timeIntervalSince1970
        let window: TimeInterval = 24 * 3600
        let buckets = 12
        var counts = [CGFloat](repeating: 0, count: buckets)
        let step = window / Double(buckets)
        for e in events {
            let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
            guard ts > 0, now - ts <= window else { continue }
            let t = (e["type"] as? String) ?? ""
            // Throughput = created + completed work signals
            guard t == "job.created" || t == "job.dispatch"
                || (t == "job.status" && ((e["status"] as? String) == "done" || (e["status"] as? String) == "notified"))
            else { continue }
            let age = now - ts
            let idx = min(buckets - 1, max(0, Int((window - age) / step)))
            counts[idx] += 1
        }
        // Soft baseline so an empty series still draws a flat floor
        if counts.allSatisfy({ $0 == 0 }) { return [0.2, 0.15, 0.18, 0.12, 0.2, 0.15, 0.1, 0.18, 0.14, 0.2, 0.16, 0.12] }
        return counts
    }

    /// Rolling accept rate (0…1) from verdict events, padded with ledger rate.
    private func missionAcceptTrend(events: [[String: Any]], ledger: [String: Any]) -> [CGFloat] {
        let verdicts = events.filter { ($0["type"] as? String) == "verdict" }
            .compactMap { e -> (TimeInterval, Bool)? in
                let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
                let v = (e["verdict"] as? String) ?? ""
                guard ts > 0, v == "accept" || v == "reject" else { return nil }
                return (ts, v == "accept")
            }
            .sorted { $0.0 < $1.0 }
        let base = CGFloat((ledger["accept_rate"] as? Double) ?? 0.75)
        guard !verdicts.isEmpty else {
            // Gentle flatline at ledger rate
            return Array(repeating: max(0.05, min(1, base)), count: 8)
        }
        let window = max(4, min(12, verdicts.count))
        var series: [CGFloat] = []
        for i in 0..<window {
            let end = Int(Double(verdicts.count - 1) * Double(i) / Double(max(window - 1, 1)))
            let start = max(0, end - 4)
            let slice = verdicts[start...end]
            let acc = slice.filter { $0.1 }.count
            let n = max(1, slice.count)
            series.append(CGFloat(acc) / CGFloat(n))
        }
        return series
    }

    /// Per-seat open-job load for vertical bars: (label, value 0…1, color).
    private func missionSeatUtilization(teams: [[String: Any]]) -> [(String, CGFloat, NSColor)] {
        var bars: [(String, CGFloat, NSColor)] = []
        for t in teams {
            let display = (t["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (t["session"] as? String) ?? "?"
            let shortTeam = String(display.prefix(10))
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            var load: [String: Int] = [:]
            for j in openList {
                let w = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
                load[w, default: 0] += 1
            }
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            if workers.isEmpty {
                let n = openList.count
                bars.append((shortTeam, CGFloat(min(1, Double(n) / 3.0)), n > 0 ? PongTheme.magenta : PongTheme.lineSoft))
                continue
            }
            for w in workers.prefix(6) {
                let id = (w["id"] as? String) ?? "?"
                let label = (w["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(8)) } ?? id
                let n = load[id] ?? 0
                let hint = ((w["status_hint"] as? String) ?? "").lowercased()
                let busyBoost: CGFloat = (hint.contains("busy") || hint.contains("run")) && n == 0 ? 0.35 : 0
                let val = min(1, CGFloat(n) / 2.0 + busyBoost)
                let col: NSColor = n >= 2 ? PongTheme.amber : (n > 0 || busyBoost > 0 ? PongTheme.magenta : PongTheme.lineSoft)
                let name = teams.count > 1 ? "\(label)" : label
                bars.append((name, max(0.06, val), col))
            }
            _ = shortTeam
        }
        if bars.isEmpty {
            return [("—", 0.08, PongTheme.lineSoft)]
        }
        return Array(bars.prefix(8))
    }

    private func drawAreaLineChart(in card: NSView, series: [CGFloat], plot: NSRect, color: NSColor, fill: Bool = true) {
        guard series.count >= 2, plot.width > 8, plot.height > 8 else { return }
        let maxV = max(series.max() ?? 1, 0.001)
        let minV = min(series.min() ?? 0, maxV)
        let span = max(maxV - minV, 0.001)
        let n = series.count
        let path = CGMutablePath()
        let line = CGMutablePath()
        for (i, raw) in series.enumerated() {
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1)
            let y = plot.minY + plot.height * ((raw - minV) / span)
            if i == 0 {
                line.move(to: CGPoint(x: x, y: y))
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        path.closeSubpath()

        // Soft plot floor line
        let floor = CAShapeLayer()
        let floorP = CGMutablePath()
        floorP.move(to: CGPoint(x: plot.minX, y: plot.minY))
        floorP.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        floor.path = floorP
        floor.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor
        floor.lineWidth = 1
        floor.fillColor = nil
        card.layer?.addSublayer(floor)

        if fill {
            let fillL = CAShapeLayer()
            fillL.path = path
            fillL.fillColor = color.withAlphaComponent(0.18).cgColor
            fillL.strokeColor = nil
            card.layer?.addSublayer(fillL)
        }
        let stroke = CAShapeLayer()
        stroke.path = line
        stroke.strokeColor = color.cgColor
        stroke.fillColor = nil
        stroke.lineWidth = 1.5
        stroke.lineJoin = .round
        stroke.lineCap = .round
        card.layer?.addSublayer(stroke)

        // Endpoint dots
        if let last = series.last {
            let x = plot.maxX
            let y = plot.minY + plot.height * ((last - minV) / span)
            let dot = CALayer()
            dot.frame = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            dot.cornerRadius = 3
            dot.backgroundColor = color.cgColor
            card.layer?.addSublayer(dot)
        }
    }

    private func drawHorizontalBars(in card: NSView, rows: [(String, Int, NSColor)], plot: NSRect) {
        guard !rows.isEmpty, plot.height > 10 else { return }
        let maxN = max(rows.map(\.1).max() ?? 1, 1)
        let rowH = min(22, plot.height / CGFloat(rows.count))
        let barMaxW = plot.width - 72
        for (i, row) in rows.enumerated() {
            let y = plot.maxY - CGFloat(i + 1) * rowH + 4
            let lab = Self.label(row.0, frame: NSRect(x: plot.minX, y: y, width: 64, height: 14), size: 10, secondary: true)
            lab.font = PongTheme.mono(10)
            card.addSubview(lab)
            let frac = CGFloat(row.1) / CGFloat(maxN)
            let bw = max(4, barMaxW * frac)
            let bar = NSView(frame: NSRect(x: plot.minX + 68, y: y + 2, width: bw, height: 10))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = row.2.withAlphaComponent(0.85).cgColor
            bar.layer?.cornerRadius = 2
            card.addSubview(bar)
            let nL = Self.label("\(row.1)", frame: NSRect(x: plot.minX + 68 + bw + 6, y: y, width: 36, height: 14), size: 10, secondary: true)
            nL.font = PongTheme.mono(10)
            card.addSubview(nL)
        }
    }

    private func drawVerticalBars(in card: NSView, bars: [(String, CGFloat, NSColor)], plot: NSRect) {
        guard !bars.isEmpty, plot.width > 10 else { return }
        let n = bars.count
        let gap: CGFloat = 6
        let bw = max(8, (plot.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, bar) in bars.enumerated() {
            let x = plot.minX + CGFloat(i) * (bw + gap)
            let h = max(3, plot.height * min(1, max(0, bar.1)))
            let rect = NSView(frame: NSRect(x: x, y: plot.minY, width: bw, height: h))
            rect.wantsLayer = true
            rect.layer?.backgroundColor = bar.2.withAlphaComponent(0.9).cgColor
            rect.layer?.cornerRadius = 2
            card.addSubview(rect)
            let lab = Self.label(bar.0, frame: NSRect(x: x - 4, y: plot.minY - 16, width: bw + 8, height: 12), size: 9, secondary: true)
            lab.font = PongTheme.mono(9)
            lab.alignment = .center
            lab.lineBreakMode = .byTruncatingTail
            card.addSubview(lab)
        }
    }

    /// Flags seats/teams that look stuck, reject-heavy, over-runtime, off-topic, or dull.
    private struct MissionWatchItem {
        let tag: String
        let title: String
        let detail: String
        let severity: NSColor
        let rank: Int // lower = more urgent
    }

    private func missionAgentWatchlist(
        teams: [[String: Any]],
        events: [[String: Any]],
        ledger: [String: Any]
    ) -> [MissionWatchItem] {
        let now = Date().timeIntervalSince1970
        var items: [MissionWatchItem] = []

        // Per-worker reject / fail tallies from events
        var rejects: [String: Int] = [:]   // "session::worker"
        var fails: [String: Int] = [:]
        var refuses: [String: Int] = [:]
        var lastActivity: [String: TimeInterval] = [:]

        for e in events {
            let sess = (e["session"] as? String) ?? ""
            let worker = (e["worker"] as? String) ?? ""
            let key = worker.isEmpty ? "\(sess)::*" : "\(sess)::\(worker)"
            let ts = (e["ts"] as? Double) ?? (e["ts"] as? Int).map { Double($0) } ?? 0
            if ts > (lastActivity[key] ?? 0) { lastActivity[key] = ts }
            let t = (e["type"] as? String) ?? ""
            if t == "verdict", (e["verdict"] as? String) == "reject" {
                rejects[key, default: 0] += 1
                if !worker.isEmpty { rejects["\(sess)::*", default: 0] += 0 }
            }
            if t == "job.status", (e["status"] as? String) == "failed" {
                fails[key, default: 0] += 1
            }
            if t == "route.refused" {
                refuses[key, default: 0] += 1
                if worker.isEmpty { refuses["\(sess)::*", default: 0] += 1 }
            }
        }

        let streak = ledger["reject_streak"] as? Int ?? 0
        if streak >= 2 {
            items.append(MissionWatchItem(
                tag: "STREAK",
                title: "Control plane",
                detail: "Reject streak \(streak) — claims need a sharper review before the next handoff.",
                severity: PongTheme.amber,
                rank: 1
            ))
        }

        for t in teams {
            let sess = (t["session"] as? String) ?? "?"
            let display = (t["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sess
            let openList = ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? []
            let recent = ((t["jobs"] as? [String: Any])?["recent"] as? [[String: Any]]) ?? []
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            let condLabel = ((t["conductor"] as? [String: Any])?["label"] as? String) ?? "Conductor"

            // Map worker id → label
            var labels: [String: String] = ["c1": condLabel]
            for w in workers {
                let id = (w["id"] as? String) ?? ""
                let lab = (w["label"] as? String) ?? id
                if !id.isEmpty { labels[id] = lab }
            }

            // Over-runtime open jobs
            for j in openList {
                let st = ((j["status"] as? String) ?? "").lowercased()
                let created = (j["created_at"] as? Double)
                    ?? (j["created_at"] as? Int).map { Double($0) }
                    ?? (j["updated_at"] as? Double)
                    ?? (j["updated_at"] as? Int).map { Double($0) }
                    ?? 0
                let age = created > 0 ? now - created : 0
                let wid = (j["worker"] as? String) ?? (j["worker_id"] as? String) ?? "?"
                let who = labels[wid] ?? wid
                let prev = (j["task_preview"] as? String) ?? (j["task"] as? String) ?? j["id"] as? String ?? "job"
                let mins = Int(age / 60)

                // Runtime thresholds: running > 45m, queued/notified > 20m
                let runTooLong = (st == "running" || st == "notified") && age > 45 * 60
                let queueTooLong = (st == "queued" || st == "notified") && age > 20 * 60
                if runTooLong || queueTooLong {
                    let tag = runTooLong ? "RUNTIME" : "STUCK"
                    items.append(MissionWatchItem(
                        tag: tag,
                        title: "\(who) · \(display)",
                        detail: "\(st) \(mins)m — \(String(prev.prefix(72)))",
                        severity: runTooLong ? PongTheme.danger : PongTheme.amber,
                        rank: runTooLong ? 2 : 3
                    ))
                }

                if (j["human_takeover"] as? Bool) == true || st.contains("human") {
                    items.append(MissionWatchItem(
                        tag: "HUMAN",
                        title: "\(who) · \(display)",
                        detail: "Needs takeover — \(String(prev.prefix(72)))",
                        severity: PongTheme.amber,
                        rank: 0
                    ))
                }

                // High round count = not landing claims (dull / not sharp)
                let round = (j["round"] as? Int) ?? 1
                if round >= 3 {
                    items.append(MissionWatchItem(
                        tag: "BLUNT",
                        title: "\(who) · \(display)",
                        detail: "Round \(round) without clean accept — not sharp enough on this task.",
                        severity: PongTheme.violet,
                        rank: 4
                    ))
                }
            }

            // Per-worker quality from recent terminal jobs + events
            var workerFails: [String: Int] = [:]
            var workerDone: [String: Int] = [:]
            for j in recent {
                let wid = (j["worker"] as? String) ?? "?"
                let st = (j["status"] as? String) ?? ""
                if st == "failed" || st == "rejected" { workerFails[wid, default: 0] += 1 }
                if st == "done" { workerDone[wid, default: 0] += 1 }
            }

            for w in workers {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let key = "\(sess)::\(id)"
                let r = rejects[key] ?? 0
                let f = max(fails[key] ?? 0, workerFails[id] ?? 0)
                let ref = refuses[key] ?? 0
                let hint = ((w["status_hint"] as? String) ?? "").lowercased()

                if f >= 2 || r >= 2 {
                    items.append(MissionWatchItem(
                        tag: "MISTAKES",
                        title: "\(lab) · \(display)",
                        detail: "\(max(f, r)) recent fail/reject signal\(max(f, r) == 1 ? "" : "s") — review outputs before more work.",
                        severity: PongTheme.danger,
                        rank: 2
                    ))
                }

                if ref >= 1 {
                    items.append(MissionWatchItem(
                        tag: "ROUTE",
                        title: "\(lab) · \(display)",
                        detail: "Route refused \(ref)× — seat may be unbound, off-channel, or going rogue on transport.",
                        severity: PongTheme.orange,
                        rank: 2
                    ))
                }

                // Busy forever with no open job = phantom load / off-topic thrash
                let openForW = openList.filter {
                    (($0["worker"] as? String) ?? ($0["worker_id"] as? String)) == id
                }
                if (hint.contains("busy") || hint.contains("run")) && openForW.isEmpty {
                    items.append(MissionWatchItem(
                        tag: "DRIFT",
                        title: "\(lab) · \(display)",
                        detail: "Seat reports busy with no control-plane job — possible off-topic or untracked work.",
                        severity: PongTheme.magenta,
                        rank: 5
                    ))
                }

                // Low sharpness: many done but high fail ratio
                let done = workerDone[id] ?? 0
                if done + f >= 3, f > 0, Double(f) / Double(done + f) >= 0.4 {
                    items.append(MissionWatchItem(
                        tag: "BLUNT",
                        title: "\(lab) · \(display)",
                        detail: "Weak hit rate (\(f) bad / \(done + f) recent) — tighten brief or swap model.",
                        severity: PongTheme.violet,
                        rank: 4
                    ))
                }
            }

            // Team-level refuse flood
            let teamRef = refuses["\(sess)::*"] ?? events.filter {
                ($0["session"] as? String) == sess && ($0["type"] as? String) == "route.refused"
            }.count
            if teamRef >= 2 {
                items.append(MissionWatchItem(
                    tag: "ROGUE",
                    title: display,
                    detail: "\(teamRef) route refusals — team transport or seat binding is failing.",
                    severity: PongTheme.danger,
                    rank: 1
                ))
            }

            // Overloaded seat: 3+ open jobs on one worker
            var byW: [String: Int] = [:]
            for j in openList {
                let wid = (j["worker"] as? String) ?? "?"
                byW[wid, default: 0] += 1
            }
            for (wid, n) in byW where n >= 3 {
                let lab = labels[wid] ?? wid
                items.append(MissionWatchItem(
                    tag: "LOAD",
                    title: "\(lab) · \(display)",
                    detail: "\(n) open jobs stacked — risk of thrash and long runtime.",
                    severity: PongTheme.amber,
                    rank: 3
                ))
            }
        }

        // Deduplicate by tag+title, keep best rank
        var best: [String: MissionWatchItem] = [:]
        for it in items {
            let k = "\(it.tag)|\(it.title)"
            if let prev = best[k] {
                if it.rank < prev.rank { best[k] = it }
            } else {
                best[k] = it
            }
        }
        return best.values.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.title < b.title
        }
    }

    @objc private func goCanvas() { go(.canvas) }

    @objc private func missionDescribeCron() {
        let sess = selectedSession.flatMap { $0 == "__all__" ? nil : $0 } ?? PairState.listPairs().first
        // Switch to map so Guide FAB is on-screen, then open cron chat
        go(.canvas)
        DispatchQueue.main.async {
            AppAIChatBubble.shared.beginCronWizard(session: sess)
        }
    }

    @objc private func missionAskChip(_ sender: NSButton) {
        let q = sender.identifier?.rawValue ?? sender.title
        runMissionAsk(q)
    }

    @objc private func missionAskSend() {
        // Find field on mission body
        var text = ""
        func findField(_ v: NSView) {
            if let f = v as? NSTextField, f.identifier?.rawValue == "missionAskField" {
                text = f.stringValue
            }
            for c in v.subviews { findField(c) }
        }
        findField(missionBody)
        runMissionAsk(text)
    }

    private func runMissionAsk(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // Instant grounded reply on Mission page + open Guide for follow-up
        let grounded = GuideCoach.answerMissionQuestion(q)
        missionAskLastReply = grounded
        AppAIChatBubble.shared.beginMissionAsk(q)
        // Refresh reply line without full paint when possible
        func setReply(_ v: NSView) {
            if let l = v as? NSTextField, l.identifier?.rawValue == "missionAskReply" {
                l.stringValue = grounded
            }
            for c in v.subviews { setReply(c) }
        }
        setReply(missionBody)
        Pong.log("mission ask q=\(String(q.prefix(80)))")
    }

    @objc private func missionFocusFirstHuman() {
        let snap = snapshot() ?? [:]
        let teams = (snap["teams"] as? [[String: Any]]) ?? []
        for t in teams {
            let sess = (t["session"] as? String) ?? ""
            let workers = (t["workers"] as? [[String: Any]]) ?? []
            for w in workers {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") {
                    TeamFocusController.shared.show(session: sess)
                    return
                }
            }
        }
        if let first = PairState.listPairs().first {
            TeamFocusController.shared.show(session: first)
        }
    }

    @objc private func missionFocusTeam(_ sender: NSButton) {
        let session = sender.identifier?.rawValue ?? ""
        guard !session.isEmpty else { return }
        TeamFocusController.shared.show(session: session)
    }

    /// Job row → canvas: highlight that worker seat + switch to canvas.
    @objc private func missionSelectJob(_ sender: MissionJobRow) {
        let session = sender.session
        let wid = sender.workerId
        guard !session.isEmpty else { return }
        selectedSession = session
        go(.canvas)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let gid = "\(session)::\(wid)"
            // Also try bare id for single-team keys
            self.canvas.highlight(globalIds: [gid, wid, "\(session)::c1"])
            self.canvas.select(globalId: gid)
        }
    }

    // MARK: Setup

    private func paintSetup() {
        // keep the place the person was reading, measured from the top: the page opens at its title, and
        // a redraw (the poll, a wider page) doesn't move it
        let clip = setupScroll.contentView
        let fromTop = setupBody.frame.height > 0 ? max(0, setupBody.frame.height - clip.bounds.maxY) : 0
        defer {
            clip.scroll(to: NSPoint(x: 0, y: max(0, setupBody.frame.height - fromTop - clip.bounds.height)))
            setupScroll.reflectScrolledClipView(clip)
        }
        setupBody.subviews.forEach { $0.removeFromSuperview() }
        setupPaintedWidth = setupScroll.contentSize.width
        let W: CGFloat = max(420, setupScroll.contentSize.width > 20 ? setupScroll.contentSize.width - 8 : 480)
        let accessText = Self.accessMapSummary()
        let accessLines = CGFloat(accessText.components(separatedBy: "\n").count)
        let accessH = min(280, max(120, 36 + accessLines * 16))
        var y: CGFloat = 820 + accessH
        setupBody.setFrameSize(NSSize(width: W, height: y))

        // Design: large title + muted subtitle
        let title = Self.label("Teams and access", frame: NSRect(x: 0, y: y - 42, width: 400, height: 38), bold: true, size: 22)
        title.font = PongType.title
        title.textColor = PongColor.textPrimary
        setupBody.addSubview(title)
        y -= 56
        let sub = Self.label("Start and save teams, and see what each AI may do. Everything else is in Settings (⌘,).",
            frame: NSRect(x: 0, y: y, width: W - 20, height: 18), size: 13, secondary: true)
        sub.font = PongType.secondary
        setupBody.addSubview(sub)
        y -= 28
        let rule = NSView(frame: NSRect(x: 0, y: y, width: W - 20, height: 1))
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(calibratedRed: 0.51, green: 0.59, blue: 0.63, alpha: 0.16).cgColor
        setupBody.addSubview(rule)
        y -= 28

        // Access / MCP map — clear view of who can use tools
        let accessCard = tacticalCard(width: W - 20, height: accessH, accent: PongTheme.limeAction.withAlphaComponent(0.45))
        accessCard.setFrameOrigin(NSPoint(x: 0, y: y - accessH))
        accessCard.addSubview(Self.label("What each AI may do", frame: NSRect(x: 16, y: accessH - 28, width: W - 48, height: 18), bold: true, size: 14))
        let accessBody = Self.label(accessText,
            frame: NSRect(x: 16, y: 12, width: W - 48, height: accessH - 44), size: 11, secondary: true)
        accessBody.font = PongTheme.mono(10)
        accessBody.maximumNumberOfLines = 0
        accessCard.addSubview(accessBody)
        setupBody.addSubview(accessCard)
        y -= accessH + 16

        // the page's one primary button; every other card's is secondary
        let card1 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "New team",
            body: "Pick a lead and helpers, name them and set what they may do.",
            button: "New team",
            action: #selector(newTeamPressed),
            accent: PongTheme.limeAction,
            primary: true
        )
        setupBody.addSubview(card1)
        y -= 132

        let card2 = actionCard(
            frame: NSRect(x: 0, y: y - 118, width: W - 20, height: 118),
            title: "Use terminals already open",
            body: "Turn open AI windows into a team. Nothing restarts.",
            button: "Link…",
            action: #selector(linkPressed),
            accent: PongTheme.limeAction.withAlphaComponent(0.55)
        )
        setupBody.addSubview(card2)
        y -= 132

        let n = SavedTeams.loadAll().count
        if n > 0 {
            let card3 = actionCard(
                frame: NSRect(x: 0, y: y - 100, width: W - 20, height: 100),
                title: "Saved teams",
                body: "\(n) saved team\(n == 1 ? "" : "s"), ready to start again.",
                button: "Open",
                action: #selector(showTeamsPressed),
                accent: PongTheme.limeAction.withAlphaComponent(0.4)
            )
            setupBody.addSubview(card3)
            y -= 114
        }

        let nSess = SessionArchive.loadAll().count
        let cardSess = actionCard(
            frame: NSRect(x: 0, y: y - 100, width: W - 20, height: 100),
            title: "Recaps",
            body: "\(nSess) recap\(nSess == 1 ? "" : "s") of past work. Start a team from one to pick up where it left off.",
            button: "Open",
            action: #selector(showSessionsPressed),
            accent: PongTheme.blue.withAlphaComponent(0.35)
        )
        setupBody.addSubview(cardSess)
        y -= 114

        let note = tacticalCard(width: W - 20, height: 96, accent: PongTheme.limeAction.withAlphaComponent(0.35))
        note.setFrameOrigin(NSPoint(x: 0, y: y - 96))
        note.addSubview(Self.label("Command line (for engineers)", frame: NSRect(x: 16, y: 62, width: 300, height: 16), bold: true, size: 14))
        let noteBody = Self.label("pong snapshot · pong graph list · pong -s <team> graph show --id <graph>",
            frame: NSRect(x: 16, y: 14, width: W - 48, height: 44), size: 12, secondary: true)
        noteBody.font = PongTheme.mono(11)
        note.addSubview(noteBody)
        setupBody.addSubview(note)
        y -= 112

        // Sequential account switch (one active login per provider CLI)
        let authCard = tacticalCard(width: W - 20, height: 88, accent: PongTheme.limeAction.withAlphaComponent(0.3))
        authCard.setFrameOrigin(NSPoint(x: 0, y: y - 88))
        authCard.addSubview(Self.label("AI accounts", frame: NSRect(x: 16, y: 58, width: 220, height: 16), bold: true, size: 13))
        authCard.addSubview(Self.label("One sign-in per AI. Changing it opens that AI's sign-in in Terminal.",
            frame: NSRect(x: 16, y: 28, width: W - 48, height: 28), size: 11, secondary: true))
        let switchB = pillButton("Switch account…", #selector(switchAccountPressed))
        switchB.frame = NSRect(x: W - 156, y: 18, width: 120, height: 28)  // right edge in line with the cards' buttons
        authCard.addSubview(switchB)
        setupBody.addSubview(authCard)
    }

    @objc private func switchAccountPressed() {
        if let d = NSApp.delegate as? AppDelegate {
            d.switchProviderAccount()
        }
    }

    /// Who has MCP / tools / env scope — readable for humans.
    private static func accessMapSummary() -> String {
        var lines: [String] = []
        lines.append("Tools are outside apps an AI can use, like a browser, files or email. You can block them per AI.")
        lines.append("")
        let pairs = PairState.listPairs()
        if pairs.isEmpty {
            lines.append("No team is running.")
            return lines.joined(separator: "\n")
        }
        let db = PairState.loadPairsDb()
        var mcpOk = 0, mcpBan = 0
        for sess in pairs {
            let entry = db[sess] as? [String: Any] ?? [:]
            let name = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sess
            let teamPerm = entry["permissions"] as? [String: Any] ?? PairState.defaultPermissions()
            let teamBan = (teamPerm["ban_mcp"] as? Bool) == true
            lines.append("▸ \(name)")
            let cond = entry["conductor"] as? [String: Any] ?? [:]
            let cLab = "Lead"
            let cType = (cond["type"] as? String) ?? "?"
            lines.append("  · \(cLab) (\(cType)): tools \(teamBan ? "blocked" : "allowed")")
            if teamBan { mcpBan += 1 } else { mcpOk += 1 }
            for w in Workers.list(from: entry) {
                let id = (w["id"] as? String) ?? "?"
                let lab = (w["label"] as? String) ?? id
                let typ = (w["type"] as? String) ?? "?"
                let wp = w["permissions"] as? [String: Any] ?? teamPerm
                let ban = (wp["ban_mcp"] as? Bool) == true
                let net = (wp["ban_network"] as? Bool) == true
                let repo = (wp["repo_only"] as? Bool) == true
                var flags: [String] = []
                flags.append(ban ? "tools blocked" : "tools allowed")
                if net { flags.append("no internet downloads") }
                if repo { flags.append("stays in the project folder") }
                lines.append("  · \(lab) (\(typ)): \(flags.joined(separator: " · "))")
                if ban { mcpBan += 1 } else { mcpOk += 1 }
            }
            // Env files hint
            let root = (entry["project_root"] as? String) ?? ""
            if !root.isEmpty {
                lines.append("  · folder: \(root)")
            }
            lines.append("")
        }
        lines.append("\(mcpOk) AI\(mcpOk == 1 ? "" : "s") can use tools · \(mcpBan) blocked.")
        lines.append("To change: open a team, click an AI › Permissions.")
        return lines.joined(separator: "\n")
    }

    /// A card with one button: the page's one primary when `primary`, else a secondary one.
    private func actionCard(frame: NSRect, title: String, body: String, button: String, action: Selector, accent: NSColor = PongTheme.amber,
                            primary: Bool = false) -> NSView {
        let v = PongSheetChrome.plate(frame: NSRect(origin: .zero, size: frame.size), accent: accent)
        v.setFrameOrigin(frame.origin)
        v.addSubview(Self.label(title, frame: NSRect(x: 16, y: frame.height - 34, width: frame.width - 40, height: 20), bold: true, size: 15))
        let bodyL = Self.label(body, frame: NSRect(x: 16, y: 44, width: frame.width - 150, height: frame.height - 86), size: 12, secondary: true)
        bodyL.maximumNumberOfLines = 3
        v.addSubview(bodyL)
        let b = primary ? PongSheetChrome.primaryButton(button, target: self, action: action)
                        : PongSheetChrome.outlineButton(button, target: self, action: action)
        b.frame = NSRect(x: frame.width - 120, y: 14, width: 104, height: 30)
        v.addSubview(b)
        return v
    }

    // MARK: Buttons

    private func accentButton(_ title: String, _ sel: Selector) -> NSButton {
        // Primary chrome CTA = white fill (line-work system), not blue/magenta
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.ink.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.bg,
            .font: PongTheme.labelFont(11),
            .paragraphStyle: centered(),
        ])
        b.target = self
        b.action = sel
        return b
    }

    private func pillButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.clear.cgColor
        b.layer?.cornerRadius = PongTheme.radiusBtn
        b.layer?.borderWidth = PongTheme.hairline
        b.layer?.borderColor = PongTheme.line.cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textPrimary,
            .font: PongTheme.labelFont(11),
            .paragraphStyle: centered(),
        ])
        b.target = self
        b.action = sel
        return b
    }

    private func iconTextButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = pillButton(title, sel)
        b.layer?.cornerRadius = 8
        return b
    }

    private func emptyState(title: String, body: String, cta: String, action: Selector) -> NSView {
        let v = NSView(frame: .zero)
        PongTheme.applyCard(v)
        let t = Self.label(title, frame: NSRect(x: 24, y: 100, width: 300, height: 22), bold: true, size: 16)
        let b = Self.label(body, frame: NSRect(x: 24, y: 48, width: 300, height: 48), size: 12, secondary: true)
        let btn = accentButton(cta, action)
        btn.frame = NSRect(x: 24, y: 14, width: 120, height: 30)
        v.addSubview(t)
        v.addSubview(b)
        v.addSubview(btn)
        return v
    }

    // MARK: Actions

    @objc private func newTeamPressed() {
        // the sheet opens the new team's page itself once it has started
        AppDelegate.launchTeamWithOptionalWizard { [weak self] in self?.reload() }
    }

    @objc private func linkPressed() {
        guide.startLink(parent: self)
    }

    @objc private func showTeamsPressed() {
        TeamsManagerPanel.shared.show { [weak self] in self?.reload() }
    }

    @objc private func showSessionsPressed() {
        SessionsManagerPanel.shared.show { [weak self] in self?.reload() }
    }

    @objc private func orbitModePressed() {
        map3D?.setNavigateMode()
        applyMapMode()
    }

    @objc private func moveModePressed() {
        map3D?.setMoveMode()
        applyMapMode()
    }

    @objc private func architecturePressed() {
        map3D?.openArchitectureSheet()
    }

    /// Open the island from the map.
    ///
    /// Hovering only opens it on the real camera cutout now, so this is the
    /// deliberate way in. Deliberately not mode-gated: the island is the same
    /// island whether the map is flat or 3D.
    @objc private func islandPressed() {
        IslandHelper.expand()
    }

    /// 2D multi: force every team onto distinct default grid slots (persists scoped positions).
    @objc private func arrangeTeamsPressed() {
        guard !use3DMap else { return }
        let pairs = PairState.listPairs()
        guard !pairs.isEmpty else { return }
        // Prefer all-teams view so the re-grid is visible
        if pairs.count > 1 { selectedSession = "__all__" }

        var posMap = CanvasLayout.positions(for: nil)
        let before = posMap
        let didChange = CanvasLayout.arrangeTeams(&posMap, sessions: pairs)

        var moved = 0
        for (key, p) in posMap where key.contains("::") {
            let parts = key.components(separatedBy: "::")
            guard parts.count >= 2 else { continue }
            if let old = before[key] {
                if hypot(old.x - p.x, old.y - p.y) >= 1 { moved += 1 }
            } else {
                moved += 1
            }
            CanvasLayout.saveSeat(session: parts[0], nodeId: parts[1], origin: p)
        }
        CanvasLayout.scrubCanvasAllBareKeys()

        reload()
        DispatchQueue.main.async { [weak self] in
            self?.fitViewportToNodes()
        }
        Pong.log("reset position n=\(pairs.count) changed=\(didChange) moved=\(moved)")
    }

    @objc private func zoomInPressed() {
        if use3DMap {
            // Mild dolly-in on 3D camera if available; otherwise ignore
            map3D?.requestMapRender()
            return
        }
        guard let scroll = canvasScroll else { return }
        let next = min(scroll.maxMagnification, scroll.magnification * 1.15)
        scroll.animator().magnification = next
    }

    @objc private func zoomOutPressed() {
        if use3DMap {
            map3D?.requestMapRender()
            return
        }
        guard let scroll = canvasScroll else { return }
        let next = max(scroll.minMagnification, scroll.magnification / 1.15)
        scroll.animator().magnification = next
    }

    /// (Fit removed from toolbar — kept for any legacy callers.)
    @objc private func fitPressed() {
        if use3DMap {
            map3D.resetCamera()
            return
        }
        let multi = selectedSession == "__all__" || (selectedSession == nil && PairState.listPairs().count > 1)
        let pairs = PairState.listPairs()
        let show = multi ? pairs : [selectedSession].compactMap { $0 }.filter { $0 != "__all__" }
        guard !show.isEmpty else { return }
        let size = canvas.bounds.size.width > 0 ? canvas.bounds.size : NSSize(width: 1400, height: 1000)
        var pos: [String: CGPoint] = [:]
        for (ti, session) in show.enumerated() {
            let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
            let condId = ((entry["conductor"] as? [String: Any])?["id"] as? String) ?? "c1"
            let cOrigin = CanvasLayout.defaultPosition(teamIndex: ti, role: "conductor", workerIndex: 0, canvas: size, multi: multi)
            pos["\(session)::\(condId)"] = cOrigin
            pos[condId] = cOrigin
            CanvasLayout.saveSeat(session: session, nodeId: condId, origin: cOrigin)
            for (i, w) in Workers.list(from: entry).enumerated() {
                let wid = (w["id"] as? String) ?? "w\(i + 1)"
                let o = CanvasLayout.defaultPosition(teamIndex: ti, role: "worker", workerIndex: i, canvas: size, multi: multi)
                pos["\(session)::\(wid)"] = o
                pos[wid] = o
                CanvasLayout.saveSeat(session: session, nodeId: wid, origin: o)
            }
            let ak = CanvasLayout.key(session: session, nodeId: "add", multi: multi)
            pos[ak] = CGPoint(x: cOrigin.x + 200, y: cOrigin.y + 40)
        }
        CanvasLayout.save(session: multi ? nil : show.first, positions: pos, multi: multi)
        refreshCanvas()
        DispatchQueue.main.async { [weak self] in
            self?.fitViewportToNodes()
        }
    }

    /// Magnify + scroll so every seat card is visible with padding.
    private func fitViewportToNodes() {
        guard let scroll = canvasScroll,
              let box = canvas.contentBoundsOfNodes() else {
            canvasScroll?.magnification = 1.0
            return
        }
        let pad: CGFloat = 64
        let target = box.insetBy(dx: -pad, dy: -pad)
        // contentView.bounds.size is already in document coords (post-magnification)
        scroll.magnification = 1.0
        let vis = scroll.contentView.bounds.size
        guard vis.width > 1, vis.height > 1, target.width > 1, target.height > 1 else { return }
        // Prefer 1× if the cluster already fits; only zoom out when needed
        let sx = vis.width / target.width
        let sy = vis.height / target.height
        var mag = min(1.0, min(sx, sy))
        mag = min(scroll.maxMagnification, max(scroll.minMagnification, mag))
        scroll.magnification = mag
        let vis2 = scroll.contentView.bounds.size
        var origin = NSPoint(
            x: target.midX - vis2.width / 2,
            y: target.midY - vis2.height / 2
        )
        let doc = canvas.bounds.size
        let maxX = max(0, doc.width - vis2.width)
        let maxY = max(0, doc.height - vis2.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func frontModel(_ m: AgentNodeModel) {
        // Open re-attaches tmux if the Terminal window was closed (history intact).
        Pong.log("frontModel role=\(m.role) id=\(m.id) session=\(m.session) title=\(m.title)")
        if m.role == "worker" || m.role == "subagent" || m.id.hasPrefix("w") {
            Workers.frontWorker(pair: m.session, workerId: m.id)
        } else if m.role == "conductor" || m.id.hasPrefix("c") {
            Pairing.frontConductor(m.session)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { Pairing.bringToFront(m.session) }
        }
    }

    /// Rename + neon accent pick for conductor or worker (map primitive, glow, Terminal).
    private func renameSeat(_ m: AgentNodeModel) {
        // Subagents are mapped to "worker" by map/canvas callers; also accept raw subagent.
        let isConductor = m.role == "conductor"
        let isAgent = m.role == "worker" || m.role == "subagent"
        guard isConductor || isAgent else { return }
        NSApp.activate(ignoringOtherApps: true)

        let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
        let existingColors: TerminalTheme.Colors? = {
            if isConductor { return TerminalTheme.Colors.from(entry["colors"]) }
            let ws = Workers.list(from: entry)
            return TerminalTheme.Colors.from(ws.first(where: { ($0["id"] as? String) == m.id })?["colors"])
        }()
        var selectedNeonId = PongNeonCatalog.matching(existingColors)?.id
            ?? (isConductor ? "plasma" : "magenta")

        let a = NSAlert()
        a.messageText = isConductor ? "Rename orchestrator" : "Rename agent"
        a.informativeText = "Display name + neon accent for the team's cube on the Team page, plane glow, and Terminal."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let field = NSTextField(frame: NSRect(x: 0, y: 68, width: 320, height: 24))
        field.stringValue = m.title
        field.placeholderString = isConductor ? "e.g. Grok Build" : "e.g. Claude · Auth"
        box.addSubview(field)

        let swatchLabel = NSTextField(labelWithString: "Neon accent")
        swatchLabel.font = PongTheme.labelFont(10)
        swatchLabel.textColor = PongTheme.textSecondary
        swatchLabel.frame = NSRect(x: 0, y: 48, width: 320, height: 14)
        box.addSubview(swatchLabel)

        let chipRow = NSStackView(frame: NSRect(x: 0, y: 8, width: 320, height: 34))
        chipRow.orientation = .horizontal
        chipRow.spacing = 8
        chipRow.alignment = .centerY
        var chipButtons: [NSButton] = []
        let chipSize: CGFloat = 24
        for sw in PongNeonCatalog.all {
            let b = NSButton(frame: NSRect(x: 0, y: 0, width: chipSize, height: chipSize))
            b.title = ""
            b.image = nil
            b.imagePosition = .imageOnly
            b.bezelStyle = .shadowlessSquare
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.wantsLayer = true
            b.layer?.masksToBounds = true
            b.layer?.cornerRadius = chipSize / 2
            b.layer?.backgroundColor = sw.highlightNS.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
            b.toolTip = sw.name
            b.identifier = NSUserInterfaceItemIdentifier(sw.id)
            b.target = NeonChipTarget.shared
            b.action = #selector(NeonChipTarget.chipPressed(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: chipSize).isActive = true
            b.heightAnchor.constraint(equalToConstant: chipSize).isActive = true
            chipRow.addArrangedSubview(b)
            chipButtons.append(b)
        }
        box.addSubview(chipRow)

        func styleChips() {
            for b in chipButtons {
                let on = b.identifier?.rawValue == selectedNeonId
                b.title = ""
                b.imagePosition = .imageOnly
                b.layer?.masksToBounds = true
                b.layer?.cornerRadius = chipSize / 2
                b.layer?.borderColor = (on ? PongSheetChrome.lime.cgColor : NSColor.black.withAlphaComponent(0.35).cgColor)
                b.layer?.borderWidth = on ? 2.5 : 1
                b.layer?.shadowOpacity = 0
            }
        }
        NeonChipTarget.shared.onPick = { id in
            selectedNeonId = id
            styleChips()
        }
        styleChips()

        a.accessoryView = box
        a.window.initialFirstResponder = field
        field.currentEditor()?.selectAll(nil)
        DispatchQueue.main.async { field.selectText(nil) }
        guard a.runModal() == .alertFirstButtonReturn else {
            NeonChipTarget.shared.onPick = nil
            return
        }
        NeonChipTarget.shared.onPick = nil

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !name.isEmpty && name != m.title
        let swatch = PongNeonCatalog.swatch(id: selectedNeonId)
            ?? PongNeonCatalog.all.first!
        // Always persist color on Save (even if name unchanged)
        if nameChanged {
            if isConductor {
                Workers.setConductorLabel(pair: m.session, label: name)
            } else {
                Workers.setWorkerLabel(pair: m.session, workerId: m.id, label: name)
            }
        } else if name.isEmpty {
            return
        }
        let session = m.session
        let seatId = m.id
        let colors = swatch.colors
        DispatchQueue.global(qos: .userInitiated).async {
            if isConductor {
                Workers.setPairColors(session, colors: colors, applyTheme: true)
            } else {
                Workers.setWorkerColors(pair: session, workerId: seatId, colors: colors, applyTheme: true)
            }
            DispatchQueue.main.async {
                let displayName = nameChanged ? name : m.title
                let gid = "\(session)::\(seatId)"
                self.map3D?.applySeatTitle(globalId: gid, title: displayName)
                self.reload()
            }
        }
    }

    /// Live CLI/model switch — workers **or** orchestrator (2D cards + 3D module share this).
    private func changeSeatModel(_ m: AgentNodeModel) {
        if m.role == "conductor" || m.id == "c1" {
            changeConductorModel(m)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
        let ws = Workers.list(from: entry)
        let cur = (ws.first(where: { ($0["id"] as? String) == m.id })?["type"] as? String) ?? ""
        let models = WorkerType.all.filter { $0.id != "custom" }

        let pick = NSAlert()
        pick.messageText = "Switch CLI for \(m.title)"
        pick.informativeText = "Current: \(WorkerType.resolved(cur.isEmpty ? "claude" : cur).label). Pick a new AI / CLI for seat \(m.id)."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for t in models {
            popup.addItem(withTitle: t.label)
            popup.lastItem?.representedObject = t.id
            if t.id == cur { popup.select(popup.lastItem) }
        }
        pick.accessoryView = popup
        pick.addButton(withTitle: "Continue")
        pick.addButton(withTitle: "Cancel")
        guard pick.runModal() == .alertFirstButtonReturn else { return }
        guard let newId = popup.selectedItem?.representedObject as? String else { return }
        if newId.lowercased() == cur.lowercased() {
            let same = NSAlert()
            same.messageText = "Already \(WorkerType.resolved(newId).label)"
            same.informativeText = "Pick a different model to switch."
            same.addButton(withTitle: "OK")
            same.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Switch to \(WorkerType.resolved(newId).label)?"
        confirm.informativeText =
            "Seat \(m.id) will restart its agent process in the same terminal window.\n" +
            "Mission role and architecture stay the same; a seat-prime prompt is re-injected."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Switch")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let hist = NSAlert()
        hist.messageText = "Paste previous model history?"
        hist.informativeText =
            "Capture a bounded scrollback from the current session and paste it into the new CLI with a clear header.\n\n" +
            "Yes — last ~200 lines / ~14KB max.\nNo — clean start with seat prime only."
        hist.addButton(withTitle: "Yes, paste history")
        hist.addButton(withTitle: "No")
        hist.addButton(withTitle: "Cancel")
        let histResp = hist.runModal()
        if histResp == .alertThirdButtonReturn { return }
        let includeHistory = histResp == .alertFirstButtonReturn

        let session = m.session
        let seatId = m.id
        PongLoadingOverlay.show(on: window, message: "Switching CLI…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Workers.switchWorkerModel(
                pair: session,
                workerId: seatId,
                newTypeId: newId,
                includeHistory: includeHistory
            )
            DispatchQueue.main.async {
                // Always clear spinner — never leave panel loading after switch fail
                PongLoadingOverlay.hide()
                if !result.ok {
                    let err = NSAlert()
                    err.messageText = "Model switch failed"
                    err.informativeText = result.message
                    err.addButton(withTitle: "OK")
                    err.runModal()
                }
                self.reload()
            }
        }
    }

    /// Switch orchestrator harness (Grok / Claude / Hermes) without killing workers.
    private func changeConductorModel(_ m: AgentNodeModel) {
        NSApp.activate(ignoringOtherApps: true)
        let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
        let cond = entry["conductor"] as? [String: Any] ?? [:]
        let cur = ((cond["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let models = ConductorType.all.filter { $0.id != "custom" }

        let pick = NSAlert()
        pick.messageText = "Switch orchestrator harness"
        pick.informativeText =
            "Current: \(ConductorType.resolved(cur.isEmpty ? "grok" : cur).label).\n" +
            "Pick Grok, Claude, or Hermes. Workers stay running — only the conductor process restarts."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for t in models {
            let title = t.label.replacingOccurrences(of: " (recommended)", with: "")
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = t.id
            if t.id == cur { popup.select(popup.lastItem) }
        }
        pick.accessoryView = popup
        pick.addButton(withTitle: "Continue")
        pick.addButton(withTitle: "Cancel")
        guard pick.runModal() == .alertFirstButtonReturn else { return }
        guard let newId = popup.selectedItem?.representedObject as? String else { return }
        if newId.lowercased() == cur.lowercased() {
            let same = NSAlert()
            same.messageText = "Already \(ConductorType.resolved(newId).label)"
            same.informativeText = "Pick a different harness to switch."
            same.addButton(withTitle: "OK")
            same.runModal()
            return
        }

        let newLabel = ConductorType.resolved(newId).label
            .replacingOccurrences(of: " (recommended)", with: "")
        let confirm = NSAlert()
        confirm.messageText = "Switch the lead to \(newLabel)?"
        confirm.informativeText = "Only the lead restarts, on the new AI. Its helpers keep working, and a recap is saved first."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Switch AI")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let hist = NSAlert()
        hist.messageText = "Bring its recent history?"
        hist.informativeText = "The new AI reads the last screenfuls of the old one's work as well as the recap. Recommended."
        hist.addButton(withTitle: "Bring history")
        hist.addButton(withTitle: "Recap only")
        hist.addButton(withTitle: "Cancel")
        let histResp = hist.runModal()
        if histResp == .alertThirdButtonReturn { return }
        let includeHistory = histResp == .alertFirstButtonReturn

        let session = m.session
        PongLoadingOverlay.show(on: window, message: "Switching orchestrator…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Workers.switchConductorModel(
                pair: session,
                newTypeId: newId,
                includeHistory: includeHistory,
                saveContinuity: true
            )
            DispatchQueue.main.async {
                PongLoadingOverlay.hide()
                let done = NSAlert()
                if result.ok {
                    done.messageText = "Orchestrator switched"
                    done.informativeText = result.message
                } else {
                    done.messageText = "Orchestrator switch failed"
                    done.informativeText = result.message
                }
                done.addButton(withTitle: "OK")
                done.runModal()
                self.reload()
            }
        }
    }

    private func killModel(_ m: AgentNodeModel) {
        if m.role == "worker" || m.id.hasPrefix("w") {
            let a = NSAlert()
            a.messageText = "Remove worker “\(m.title)”?"
            a.informativeText =
                "This closes that seat’s terminal/session.\n" +
                "In-flight jobs for \(m.id) may be lost or stuck.\n\n" +
                "The rest of the team stays running."
            a.alertStyle = .warning
            a.addButton(withTitle: "Remove worker")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            _ = Workers.removeWorker(pair: m.session, workerId: m.id)
            reload()
        } else {
            confirmKillTeam(session: m.session, displayName: m.title)
        }
    }

    /// Kill entire team with hard warnings + optional Save team first.
    /// "Stop team “X”?": save it to start again later, or just stop. Keep is the loud, safe choice.
    private func confirmKillTeam(session: String, displayName: String) {
        let name = displayName.isEmpty ? session : displayName
        PongAlert.show(on: window, title: "Stop team “\(name)”?",
                       message: "Its AIs stop and their terminals close. Anything they were in the middle of is lost.",
                       buttons: [.init("Stop without saving", .destructive), .init("Save and stop", .secondary), .init("Keep running", .primary)],
                       cancelIndex: 2) { [weak self] i in
            guard let self, i < 2 else { return }
            if i == 1 {
                _ = SavedTeams.saveFromLivePair(session, teamName: name, options: SavedTeams.SaveOptions())
            }
            Pairing.killPair(session)
            self.selectedSession = "__all__"
            Toast.show(i == 1 ? "Saved and stopped. Start it again from Saved teams." : "Stopped.")
            self.go(.canvas)
        }
    }

    private func addWorker(to session: String) {
        addWorker(to: session, parentId: nil, parentLabel: nil, guide: false)
    }

    /// `parentId` when set: helper under that worker seat (3D HELPERS layer + parent_id).
    private func addWorker(to session: String, parentId: String?, parentLabel: String?, guide: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if let parentLabel {
            a.messageText = "Add helper"
            a.informativeText = "Under “\(parentLabel)” — a helper that reports back to them."
        } else {
            a.messageText = "Add agent"
            a.informativeText = "New teammate next to the boss. You’ll name them next."
        }
        for t in WorkerType.all where t.id != "custom" {
            a.addButton(withTitle: t.label)
        }
        a.addButton(withTitle: "Custom…")
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = r.rawValue - first
        let types = WorkerType.all.filter { $0.id != "custom" }
        let picked: WorkerType?
        if idx >= 0 && idx < types.count {
            picked = WorkerType.resolved(types[idx].id)
        } else if idx == types.count {
            picked = AppDelegate.pickCustomWorker()
        } else {
            picked = nil
        }
        guard let wt = picked else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let newId = Workers.addWorker(pair: session, type: wt, parentId: parentId)
            DispatchQueue.main.async {
                self.reload()
                if guide, let newId, !newId.isEmpty {
                    AgentGuideTutorial.present(session: session, seatId: newId)
                }
            }
        }
    }
}

// Extend canvas callback — add-sub uses parent worker context
extension PanelController {
    fileprivate func handleAdd(from m: AgentNodeModel) {
        if m.role == "add-sub" {
            let parentId = m.id.replacingOccurrences(of: "add-sub-", with: "")
            let entry = PairState.loadPairsDb()[m.session] as? [String: Any] ?? [:]
            let lab = Workers.list(from: entry).first(where: { ($0["id"] as? String) == parentId })?["label"] as? String
            addWorker(to: m.session, parentId: parentId, parentLabel: lab ?? parentId)
        } else {
            addWorker(to: m.session, parentId: nil, parentLabel: nil)
        }
    }
}

/// Clickable job row on Mission → highlights seat on canvas.
final class MissionJobRow: NSView {
    var session: String = ""
    var workerId: String = ""
    weak var target: AnyObject?
    var action: Selector?

    override func mouseDown(with event: NSEvent) {
        if let t = target, let a = action {
            _ = t.perform(a, with: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Neon swatch chips in rename accessory (fixed catalog only).
final class NeonChipTarget: NSObject {
    static let shared = NeonChipTarget()
    var onPick: ((String) -> Void)?

    @objc func chipPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !id.isEmpty else { return }
        onPick?(id)
    }
}

