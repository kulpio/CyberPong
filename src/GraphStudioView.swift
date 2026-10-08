import AppKit
import SceneKit

// MARK: - The Graphs and Chats pages (1.9)
//
//   Graphs — every graph on this Mac as a list (needs you, working, finished),
//            or on one 3D map. A graph opens on its Steps; Plan is its 3D deck,
//            Screen the working step's terminal. A waiting question sits on top.
//   Chats  — every architect chat. A chat opens on its terminal.
//
// Right: the inspector (docked in wide windows, an overlay otherwise): what is
// selected, a step or the graph, question first, the technical facts folded
// under Details. Bottom: what happened, folded. Everything is read from the
// shared GraphStore (`pong graph list --json`); every press is a `pong` command.

private final class StudioFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ActionButton: NSButton {
    var onPress: (() -> Void)?
    convenience init(_ title: String, style: Style = .plain, onPress: @escaping () -> Void) {
        self.init(frame: .zero)
        self.onPress = onPress
        target = self
        action = #selector(fire)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = PongTheme.radiusBtn
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        restyle(title, style)
    }

    enum Style { case plain, primary, warn, danger }

    func restyle(_ title: String, _ style: Style) {
        let fg: NSColor
        layer?.cornerRadius = PongRadius.control
        switch style {
        case .primary:
            layer?.backgroundColor = PongColor.ink.cgColor
            fg = PongColor.onInk
            layer?.borderWidth = 0
        case .warn, .plain:
            layer?.backgroundColor = PongColor.secondaryFill.cgColor
            layer?.borderColor = PongColor.control.cgColor
            layer?.borderWidth = 1
            fg = PongColor.textPrimary
        case .danger:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            fg = PongColor.fail
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fg, .font: NSFont.systemFont(ofSize: 13, weight: style == .primary ? .semibold : .medium), .paragraphStyle: para,
        ])
        let w = attributedTitle.size().width + 24
        widthAnchor.constraint(greaterThanOrEqualToConstant: max(64, w)).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func fire() { onPress?() }
}

private final class ClickRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    /// The side panes' rows: a rounded highlight inset from the edges and no rule under each row.
    var inset: CGFloat = 0
    var divider = true
    private var hover = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = inset > 0 ? bounds.insetBy(dx: inset, dy: 1) : bounds
        if selected {
            PongColor.overlay.setFill()
            NSBezierPath(roundedRect: r, xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        } else if hover && onClick != nil {
            PongColor.hover.setFill()
            NSBezierPath(roundedRect: r, xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        }
        if divider {
            PongColor.hairline.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

/// A step in the Steps list: its number, its state on a spine that joins the steps, its name, what it is
/// doing, and when. The working step's row is lit.
private final class StepRowView: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var working = false { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let first: Bool
    private let last: Bool
    private let index = NSTextField(labelWithString: "")
    private let marker = StatusMarkerView(.pending)
    private let name = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")

    init(index i: Int, first: Bool, last: Bool) {
        self.first = first
        self.last = last
        super.init(frame: .zero)
        index.stringValue = String(format: "%02d", i)
        index.font = PongType.data
        index.textColor = PongColor.textTertiary
        name.font = PongType.control
        name.textColor = PongColor.textPrimary
        name.lineBreakMode = .byTruncatingTail
        meta.font = PongType.secondary
        meta.textColor = PongColor.textSecondary
        meta.lineBreakMode = .byTruncatingTail
        time.font = PongType.meta
        time.textColor = PongColor.textTertiary
        time.alignment = .right
        for v in [index, marker, name, meta, time] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(name n: String, meta m: String, status: PongStatus, time t: String) {
        name.stringValue = n
        meta.stringValue = m
        meta.toolTip = m
        marker.status = status
        time.stringValue = t
        name.textColor = status == .pending || status == .stopped ? PongColor.textSecondary : PongColor.textPrimary
        if status == .needsYou { meta.textColor = PongColor.you }
        else if status == .failed { meta.textColor = PongColor.fail }
        else { meta.textColor = PongColor.textSecondary }
        setAccessibilityLabel("Step \(index.stringValue), \(n), \(status.word). \(m)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        index.frame = NSRect(x: 8, y: 10, width: 26, height: 16)
        marker.frame = NSRect(x: 38, y: 10, width: 16, height: 16)
        let tw: CGFloat = 80
        time.frame = NSRect(x: W - 8 - tw, y: 11, width: tw, height: 14)
        let nameW = min(220, max(90, (W - 70 - tw) * 0.36))
        name.frame = NSRect(x: 64, y: 9, width: nameW, height: 18)
        meta.frame = NSRect(x: 64 + nameW + 12, y: 10, width: max(40, W - 64 - nameW - 12 - tw - 16), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || working || hover {
            (selected ? PongColor.overlay : (working ? PongColor.overlay.withAlphaComponent(0.7) : PongColor.hover)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        }
        // the spine: a 1 pt line joining the markers
        PongColor.mark.setFill()
        let cx: CGFloat = 46
        if !first { NSRect(x: cx - 0.5, y: 0, width: 1, height: 9).fill() }
        if !last { NSRect(x: cx - 0.5, y: 27, width: 1, height: bounds.height - 27).fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// One option and how likely Jev thinks it is: its name, a bar and a percentage, with an optional line under it.
private final class ProbBarView: NSView {
    override var isFlipped: Bool { true }
    private let p: Double
    private let color: NSColor
    private var barRect = NSRect.zero

    init(name: String, p: Double, width: CGFloat, color: NSColor, chosen: Bool, note: String, tip: String) {
        self.p = max(0, min(1, p))
        self.color = color
        let h: CGFloat = note.isEmpty ? 18 : 32
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: h))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: h).isActive = true
        toolTip = tip.isEmpty ? nil : tip
        let nameW = min(150, (width * 0.46).rounded(.down))
        let nameL = NSTextField(labelWithString: name)
        nameL.font = PongType.sf(12, chosen ? .semibold : .regular)
        nameL.textColor = chosen ? PongTheme.textPrimary : PongTheme.textSecondary
        nameL.lineBreakMode = .byTruncatingTail
        nameL.frame = NSRect(x: 0, y: 1, width: nameW, height: 16)
        addSubview(nameL)
        let pctL = NSTextField(labelWithString: ProbBarView.pct(self.p))
        pctL.font = PongTheme.mono(11, weight: chosen ? .semibold : .regular)
        pctL.textColor = chosen ? PongTheme.textPrimary : PongTheme.textSecondary
        pctL.alignment = .right
        pctL.frame = NSRect(x: width - 40, y: 1, width: 40, height: 16)
        addSubview(pctL)
        barRect = NSRect(x: nameW + 6, y: 7, width: max(20, width - nameW - 6 - 46), height: 4)
        if !note.isEmpty {
            let noteL = NSTextField(labelWithString: note)
            noteL.font = PongType.sf(11)
            noteL.textColor = PongTheme.textTertiary
            noteL.lineBreakMode = .byTruncatingTail
            noteL.frame = NSRect(x: 0, y: 17, width: width, height: 14)
            noteL.toolTip = note
            addSubview(noteL)
        }
    }

    required init?(coder: NSCoder) { return nil }

    static func pct(_ p: Double) -> String {
        if p > 0 && p < 0.005 { return "<1%" }
        if p < 1 && p > 0.995 { return ">99%" }
        return "\(Int((p * 100).rounded()))%"
    }

    override func draw(_ dirtyRect: NSRect) {
        PongColor.overlay.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
        guard p > 0 else { return }
        color.setFill()
        var fill = barRect
        fill.size.width = max(3, barRect.width * CGFloat(p))
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}

/// How Jev spread a score line's answer over its levels, lowest first: one column per level, the levels
/// that meet the bar in the line's colour, a tick where the bar starts.
private final class LevelStripView: NSView {
    private let probs: [Double]
    private let floorLevel: Int?
    private let color: NSColor

    init(probs: [Double], floor: Int?, color: NSColor) {
        self.probs = probs
        self.floorLevel = floor
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        let n = max(1, probs.count)
        let gap: CGFloat = 3
        let colW = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        PongTheme.lineSoft.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for (i, p) in probs.enumerated() {
            let r = NSRect(x: CGFloat(i) * (colW + gap), y: 1, width: colW, height: max(1.5, (bounds.height - 2) * CGFloat(p)))
            let meets = floorLevel.map { i >= $0 } ?? true
            (meets ? color : PongTheme.textTertiary.withAlphaComponent(0.7)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let f = floorLevel, f > 0, f < n {
            PongTheme.textSecondary.setFill()
            NSRect(x: CGFloat(f) * (colW + gap) - gap / 2 - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// Text in which the files it names are links. A click hands the file to `onLink`, which opens it the
/// safe way (a document in its app, anything else shown in Finder); a link never runs anything itself.
private final class LinkTextView: NSTextView, NSTextViewDelegate {
    var onLink: ((Int) -> Void)?

    convenience init(_ text: NSAttributedString, width: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: width, height: 14), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        linkTextAttributes = [.foregroundColor: PongTheme.blue, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        delegate = self
        layout.ensureLayout(for: container)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: max(14, ceil(layout.usedRect(for: container).height))).isActive = true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let key = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
        if key.hasPrefix("pongfile:"), let i = Int(key.dropFirst(9)) { onLink?(i) }
        return true  // handled here: never the system's own opener
    }
}

/// A count on a folded strip: the click goes through it to the strip, which unfolds the pane.
private final class BadgeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A small borderless icon (an SF Symbol) for the side panes' own controls: fold, unfold, new.
private final class IconButton: NSButton {
    var onPress: (() -> Void)?
    convenience init(_ symbol: String, tip: String, onPress: @escaping () -> Void) {
        self.init(frame: .zero)
        self.onPress = onPress
        target = self
        action = #selector(fire)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = true
        setSymbol(symbol, tip: tip)
    }

    func setSymbol(_ symbol: String, tip: String) {
        toolTip = tip
        setAccessibilityLabel(tip)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        contentTintColor = PongTheme.textSecondary
    }

    @objc private func fire() { onPress?() }
}

final class GraphStudioView: NSView {
    /// Which area the page is: the Graphs list and a graph, or the Chats list and a chat.
    enum Mode { case graphs, chats }
    /// A graph's three views: its steps as a list, its plan (the 3D deck), a step's screen.
    enum Tab: Int { case steps = 0, plan = 1, screen = 2 }

    var mode: Mode = .graphs {
        didSet {
            guard mode != oldValue else { return }
            lastListSig = ""
            lastInspectorSig = ""
            closeOverlay()
            render()
            onCrumbsChanged?()
        }
    }
    /// The window bar's breadcrumb and actions follow what is shown.
    var onCrumbsChanged: (() -> Void)?
    /// Move the window to the other area (a chat's graph, a graph's chat).
    var onNavigate: ((Mode) -> Void)?

    private(set) var graphs: [GGraph] = []
    private var architects: [GArchitect] = []
    /// A graph architect's chat, when one is open (Chats).
    private var selectedChat: String?
    private let chatView = ArchitectChatView()
    /// The graph that is open (Graphs); nil shows the list.
    private var selectedKey: String?
    private var selectedNode: String?
    private var tab: Tab = .steps
    /// The Graphs list shown as the 3D map of every graph.
    private var showOrbit = UserDefaults.standard.bool(forKey: "graphs.showOrbit")
    private var active = false
    private var seatPoll: Timer?
    private var peekInFlight = false
    /// The last failed screen read, so the log gets it once rather than every two seconds.
    private var lastPeekError = ""
    private var loadError = ""
    private var lastInspectorSig = ""
    private var lastTimelineSig = ""
    private var lastListSig = ""
    private var lastStepsSig = ""
    private var lastBannerSig = ""
    private var lastHeaderSig = ""
    private var lastInspW: CGFloat = 0
    private var escMonitor: Any?

    // the list (no graph or chat open)
    private let listScroll = NSScrollView()
    private let listDoc = StudioFlippedView()

    // one graph or chat
    private let header = PageHeaderView()
    private let tabs = PongSegmented(["Steps", "Plan", "Screen"],
                                     tips: ["Every step in order: what it is doing, who runs it (⌘⌥1)",
                                            "The graph's plan: its steps and how they connect, in 3D (⌘⌥2)",
                                            "The working step's terminal, live (⌘⌥3)"])
    /// The question docked above a graph's steps or a chat's terminal. Opened in full it grows into the
    /// room the steps or the terminal can give; taller still, its upper part scrolls and its answers stay
    /// pinned under it, in sight.
    private var banner: QuestionCardView?
    /// The card's box: its corners, its focus ring, the scrolling part and the pinned answers.
    private let bannerBox = NSView()
    private let bannerScroll = NSScrollView()
    /// The line between the scrolling part and the pinned answers.
    private let bannerRule = NSView()
    /// Over the foot of the scrolling part while more of the card is below it: a fade and "More ↓" (a
    /// scroller alone is easy to miss), gone once the end is in sight.
    private lazy var bannerFade = MoreBelowFade(on: bannerScroll, color: PongColor.tintYou)
    private let bannerMore = PongButton(title: "More ↓", style: .quiet, size: .small)
    private let stepsScroll = NSScrollView()
    private let stepsDoc = StudioFlippedView()
    private let deck = GraphDeckView(frame: .zero, options: nil)

    private let seatPane = NSView()
    private let seatHeader = NSTextField(labelWithString: "")
    private let seatScroll = NSScrollView()
    private let seatText = NSTextView()
    private var seatOpenBtn: PongButton!

    // the inspector: docked in wide windows, an overlay otherwise
    private let insp = NSView()
    private let inspScroll = NSScrollView()
    private let inspDoc = StudioFlippedView()
    private let inspStack = NSStackView()
    private let inspKind = NSTextField(labelWithString: "")
    private let inspClose = PongButton(title: "", style: .quiet)
    private let inspLine = NSView()
    /// Docked, the inspector shows unless hidden (⌥⌘I). As an overlay it opens on demand.
    private var inspHidden = UserDefaults.standard.bool(forKey: "graphs.inspCollapsed")
    private var overlayOpen = false

    // activity, folded under the graph
    private let timeline = NSView()
    private let timelineHead = ClickRow()
    private let timelineTitle = NSTextField(labelWithString: "")
    private let timelineChevron = NSImageView()
    private let timelineScroll = NSScrollView()
    private let timelineDoc = StudioFlippedView()
    private let timelineLine = NSView()
    private var activityOpen = UserDefaults.standard.bool(forKey: "graphs.activityOpen")

    private var finishedOpen = UserDefaults.standard.bool(forKey: "graphs.finishedOpen")
    private var detailsOpen = UserDefaults.standard.bool(forKey: "graphs.detailsOpen")
    private var stepsOpen = UserDefaults.standard.bool(forKey: "graphs.stepsOpen")

    private let inspW: CGFloat = 320

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // MARK: Lifecycle

    func start() {
        guard !active else { return }
        active = true
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: GraphStore.didChange, object: nil)
        pull()
        GraphStore.shared.refresh()
        if tab == .screen && current != nil { startSeatPoll() }
    }

    func stop() {
        guard active else { return }
        active = false
        NotificationCenter.default.removeObserver(self, name: GraphStore.didChange, object: nil)
        stopSeatPoll()
        chatView.stopPoll()
        closeOverlay()
    }

    func refresh() { GraphStore.shared.refresh() }

    @objc private func storeChanged() { pull() }

    /// Read the shared feed; a graph or chat that left the list goes back to the list.
    private func pull() {
        let st = GraphStore.shared
        graphs = st.graphs
        architects = st.architects
        loadError = st.loadError
        var levelChanged = false
        if let c = selectedChat, st.loadedOnce, !architects.contains(where: { $0.key == c }) {
            selectedChat = nil
            levelChanged = true
        }
        if let k = selectedKey, st.loadedOnce, !graphs.isEmpty, !graphs.contains(where: { $0.key == k }) {
            selectedKey = nil
            selectedNode = nil
            levelChanged = true
        }
        render()
        if levelChanged { onCrumbsChanged?() }
    }

    func retheme() {
        lastListSig = ""; lastInspectorSig = ""; lastTimelineSig = ""; lastStepsSig = ""; lastHeaderSig = ""
        bannerBox.layer?.backgroundColor = PongColor.tintYou.cgColor
        bannerRule.layer?.backgroundColor = PongColor.hairline.cgColor
        deck.retheme()
        chatView.retheme()
        render()
    }

    // MARK: Navigation (the window bar and the sidebar drive these)

    /// Open a graph by key ("session/id").
    func openGraph(_ key: String, tab t: Tab? = nil) {
        selectedKey = key
        selectedNode = nil
        if let t { tab = t }
        if tab == .screen { pickScreenNode() }
        lastInspectorSig = ""
        lastStepsSig = ""
        lastHeaderSig = ""
        if mode == .graphs { render() }
        onCrumbsChanged?()
    }

    /// Open a chat by key ("session/id").
    func openChat(_ key: String) {
        selectedChat = key
        lastInspectorSig = ""
        lastHeaderSig = ""
        if mode == .chats { render() }
        onCrumbsChanged?()
    }

    /// Back to the list of this area.
    func showList() {
        if mode == .graphs { selectedKey = nil; selectedNode = nil } else { selectedChat = nil }
        closeOverlay()
        lastListSig = ""
        render()
        onCrumbsChanged?()
    }

    /// The Steps, Plan and Screen tabs (⌘⌥1–3).
    func setTab(_ t: Tab) {
        guard current != nil, mode == .graphs else { return }
        if t == .screen, !pickScreenNode() {
            Toast.show("No step of this graph has a screen yet.")
            tabs.select(tab.rawValue)
            return
        }
        tab = t
        tabs.select(t.rawValue)
        if t == .screen { startSeatPoll() } else { stopSeatPoll() }
        lastInspectorSig = ""
        render()
    }

    /// The Screen tab needs a step with a terminal: the selected one, else the working one, else the first.
    @discardableResult
    private func pickScreenNode() -> Bool {
        guard let g = current else { return false }
        if let id = selectedNode, let n = g.node(id), !n.isSeatless { return true }
        if let n = g.nodes.first(where: { $0.status == "running" && !$0.isSeatless }) ?? g.nodes.last(where: { !$0.isSeatless && $0.visits > 0 }) ?? g.nodes.first(where: { !$0.isSeatless }) {
            selectedNode = n.id
            return true
        }
        return false
    }

    /// The window bar's parents.
    var crumbs: [WindowBarView.Crumb] {
        switch mode {
        case .graphs:
            guard let g = current else { return [] }
            // the parents: its team, then the chat that looks after it
            var out: [WindowBarView.Crumb] = [.init(title: g.teamName) { PanelController.shared.openTeam(g.session) }]
            if let a = architects.first(where: { $0.id == g.architectId && $0.session == g.session }) {
                out.append(.init(title: a.displayTitle) { [weak self] in
                    self?.selectedChat = a.key
                    self?.onNavigate?(.chats)
                })
            }
            return out
        case .chats:
            guard let a = currentChat else { return [] }
            return [.init(title: teamName(a.session)) { PanelController.shared.openTeam(a.session) }]
        }
    }

    private func teamName(_ session: String) -> String { TeamNames.name(session) }

    /// True when a graph or a chat is open (not the list).
    var showingDetail: Bool { (mode == .graphs && current != nil) || (mode == .chats && currentChat != nil) }

    /// An inspector exists when a graph or a chat is open.
    var hasInspector: Bool { (mode == .graphs && current != nil) || (mode == .chats && currentChat != nil) }

    /// ⌥⌘I and the window bar's button.
    func toggleInspectorFromShell() {
        guard hasInspector else { return }
        if inspectorDocked {
            inspHidden.toggle()
            UserDefaults.standard.set(inspHidden, forKey: "graphs.inspCollapsed")
        } else {
            overlayOpen ? closeOverlay() : openOverlay()
        }
        lastInspectorSig = ""
        needsLayout = true
        render()
    }

    /// The window bar's actions for what is shown (at most two).
    var pageActions: [NSView] {
        switch mode {
        case .graphs:
            guard let g = current else {
                let b = PongButton(title: showOrbit ? "Show as a list" : "Show on the map", style: .quiet)
                b.symbol = showOrbit ? "list.bullet" : "cube"
                b.toolTip = showOrbit ? "Every graph as a list" : "Every graph on one 3D map, grouped by team"
                b.onPress = { [weak self] in
                    guard let self else { return }
                    self.showOrbit.toggle()
                    UserDefaults.standard.set(self.showOrbit, forKey: "graphs.showOrbit")
                    self.lastListSig = ""
                    self.render()
                    self.onCrumbsChanged?()
                }
                return [b]
            }
            var out: [NSView] = []
            if g.waitsForTeam {
                // its team is stopped: nothing moves until it starts, so that is the way on (as on Home);
                // Pause is in ⋯ meanwhile
                let b = PongButton(title: "Start its team", style: .secondary)
                b.symbol = "play.fill"
                b.toolTip = "Start \(g.teamName) again, as it was set up: the graph goes on from where it is."
                b.onPress = { [weak self] in
                    TeamStart.start(g.session, name: g.teamName) {
                        self?.lastHeaderSig = ""
                        self?.refresh()
                    }
                }
                out.append(b)
            } else if g.isRunning {
                let b = PongButton(title: g.manualPause ? "Resume" : "Pause", style: .secondary)
                b.symbol = g.manualPause ? "play.fill" : "pause.fill"
                b.toolTip = g.manualPause ? "New steps start again." : "Steps at work finish; nothing new starts until you resume."
                b.onPress = { [weak self] in self?.togglePause(g) }
                out.append(b)
            } else {
                let hasChat = architects.contains { $0.id == g.architectId && $0.session == g.session }
                let b = PongButton(title: hasChat ? "Open its chat" : "Start a chat", style: .secondary)
                b.toolTip = hasChat ? "Talk with the chat that looks after this graph."
                                    : "A new chat reads this graph first, then you can talk with it."
                b.onPress = { [weak self] in self?.openChat(for: g) }
                out.append(b)
            }
            out.append(moreButton(graphMenu(g)))
            return out
        case .chats:
            guard let a = currentChat else {
                let b = PongButton(title: "New chat", style: .quiet)
                b.symbol = "plus"
                b.toolTip = "A new graph starts with a chat (⌘N)"
                b.onPress = { PanelController.shared.newGraph() }
                return [b]
            }
            var out: [NSView] = []
            // a stopped chat: the way back comes first (its team's Start, or a new chat); its graph is in ⋯
            if !a.alive {
                out.append(restartChatButton(a, teamUp: SchedulesPageView.runningTeams.contains(a.session)))
            } else if let gid = shownGraph(a) {
                let b = PongButton(title: "Show its graph", style: .secondary)
                b.toolTip = "Open the graph this chat looks after. The chat keeps running."
                b.onPress = { [weak self] in self?.showGraph(gid, of: a) }
                out.append(b)
            }
            out.append(moreButton(chatMenu(a)))
            return out
        }
    }

    private func moreButton(_ menu: NSMenu) -> PongButton {
        let b = PongButton(title: "", style: .quiet)
        b.symbol = "ellipsis"
        b.toolTip = "More"
        b.setAccessibilityLabel("More actions")
        b.onPress = { [weak b] in
            guard let b else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
        }
        return b
    }

    private func menuItem(_ title: String, _ fn: @escaping () -> Void) -> NSMenuItem {
        let box = ClosureBox(fn)
        let i = NSMenuItem(title: title, action: #selector(ClosureBox.fire), keyEquivalent: "")
        i.target = box
        i.representedObject = box
        return i
    }

    private func graphMenu(_ g: GGraph) -> NSMenu {
        let m = NSMenu()
        let hasChat = architects.contains { $0.id == g.architectId && $0.session == g.session }
        m.addItem(menuItem(hasChat ? "Open its chat" : "Start a chat") { [weak self] in self?.openChat(for: g) })
        if !g.notesPath.isEmpty {
            m.addItem(menuItem("Open its notes") { [weak self] in self?.openPath(g.notesPath, session: g.session) })
        }
        if let n = g.nodes.first(where: { $0.status == "running" && !$0.isSeatless }) {
            m.addItem(menuItem("Open \(Words.name(n.id)) in Terminal") { [weak self] in
                self?.selectedNode = n.id
                self?.openSeatTerminal()
            })
        }
        m.addItem(menuItem("Start from a template…") { [weak self] in self?.fromTemplate() })
        m.addItem(.separator())
        m.addItem(menuItem("Copy the graph's id") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(g.id, forType: .string)
        })
        if g.isRunning {
            m.addItem(.separator())
            // the window bar offers Start its team instead while the team is stopped
            if g.waitsForTeam {
                m.addItem(menuItem("Pause graph") { [weak self] in self?.togglePause(g) })
            }
            let stop = menuItem("Stop graph…") { [weak self] in self?.confirmCancel(g) }
            stop.attributedTitle = NSAttributedString(string: "Stop graph…", attributes: [.foregroundColor: PongColor.fail, .font: NSFont.menuFont(ofSize: 0)])
            m.addItem(stop)
        }
        return m
    }

    /// The chat's latest graph that is in the list, if any.
    private func shownGraph(_ a: GArchitect) -> String? {
        a.graphs.last(where: { gid in graphs.contains { $0.id == gid && $0.session == a.session } })
    }

    private func showGraph(_ gid: String, of a: GArchitect) {
        selectedKey = a.session + "/" + gid
        selectedNode = nil
        onNavigate?(.graphs)
    }

    private func chatMenu(_ a: GArchitect) -> NSMenu {
        let m = NSMenu()
        if !a.alive, let gid = shownGraph(a) {
            m.addItem(menuItem("Show its graph") { [weak self] in self?.showGraph(gid, of: a) })
            m.addItem(.separator())
        }
        m.addItem(menuItem("Open in Terminal") { [weak self] in self?.chatView.openTerminal() })
        m.addItem(menuItem("History") { [weak self] in self?.chatView.showLog() })
        m.addItem(menuItem("Sign in to \(Words.ai(a.runtime, ""))…") { [weak self] in self?.chatView.signIn() })
        if let models = chatView.models[a.runtime], !models.isEmpty, a.runtime == "claude" {
            let sub = NSMenu()
            for model in models {
                let it = menuItem(model) { [weak self] in self?.chatView.pickModel(model) }
                it.state = model == a.model ? .on : .off
                sub.addItem(it)
            }
            let item = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
            item.submenu = sub
            m.addItem(item)
        }
        return m
    }

    private func togglePause(_ g: GGraph) {
        let resume = g.manualPause
        let act = resume ? GraphActions.resume : GraphActions.pause
        act(g) { ok, err in
            Toast.show(ok ? (resume ? "Resumed." : "Paused. Steps at work finish first.")
                          : GraphActions.failure(err, "Couldn't \(resume ? "resume" : "pause") \(g.displayTitle). Try again in a moment.",
                                                 log: (resume ? "resume " : "pause ") + g.key), warn: !ok)
        }
    }

    // MARK: Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = PongColor.base.cgColor

        // the list
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        listScroll.documentView = listDoc
        addSubview(listScroll)

        // one graph: header, tabs, the question banner, steps / plan / screen
        tabs.onChange = { [weak self] i in self?.setTab(Tab(rawValue: i) ?? .steps) }
        tabs.select(tab.rawValue)
        addSubview(header)
        bannerBox.wantsLayer = true
        bannerBox.layer?.cornerRadius = PongRadius.card  // the card's corners, also where it is cut short
        bannerBox.layer?.masksToBounds = true
        bannerBox.layer?.backgroundColor = PongColor.tintYou.cgColor
        bannerBox.isHidden = true
        bannerScroll.drawsBackground = false
        bannerScroll.hasVerticalScroller = true
        bannerScroll.autohidesScrollers = true
        bannerScroll.borderType = .noBorder
        bannerScroll.automaticallyAdjustsContentInsets = false  // the card starts at its own top
        bannerBox.addSubview(bannerScroll)
        bannerRule.wantsLayer = true
        bannerRule.layer?.backgroundColor = PongColor.hairline.cgColor
        bannerRule.isHidden = true
        bannerBox.addSubview(bannerRule)
        bannerBox.addSubview(bannerFade)
        bannerMore.isHidden = true
        bannerMore.toolTip = "The rest of the question's details"
        bannerMore.setAccessibilityLabel("Show more of the question")
        bannerMore.onPress = { [weak self] in self?.bannerScrollDown() }
        bannerBox.addSubview(bannerMore)
        bannerScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: bannerScroll.contentView,
                                               queue: .main) { [weak self] _ in self?.updateBannerMore() }
        addSubview(bannerBox)

        stepsScroll.drawsBackground = false
        stepsScroll.hasVerticalScroller = true
        stepsScroll.autohidesScrollers = true
        stepsScroll.borderType = .noBorder
        stepsScroll.documentView = stepsDoc
        addSubview(stepsScroll)

        deck.onSelectNode = { [weak self] id in self?.selectNode(id) }
        deck.onSelectGraph = { [weak self] key in
            guard let self else { return }
            self.mode = .graphs
            self.openGraph(key, tab: .plan)
        }
        deck.onOpenSeat = { [weak self] id in
            self?.selectedNode = id
            self?.setTab(.screen)
        }
        addSubview(deck)

        // a step's screen
        seatPane.wantsLayer = true
        seatPane.layer?.backgroundColor = PongColor.void.cgColor
        seatHeader.font = PongType.bodyStrong
        seatHeader.textColor = PongColor.textPrimary
        seatHeader.lineBreakMode = .byTruncatingTail
        seatText.isEditable = false
        seatText.isSelectable = true
        seatText.font = PongType.terminal
        seatText.backgroundColor = PongColor.void
        seatText.textColor = PongColor.terminalText
        seatText.textContainerInset = NSSize(width: 10, height: 10)
        seatText.isVerticallyResizable = true
        // A terminal's lines are already wrapped at its own width: show them as
        // they are and scroll sideways, rather than wrapping them a second time.
        seatText.isHorizontallyResizable = true
        seatText.textContainer?.widthTracksTextView = false
        seatText.textContainer?.containerSize = NSSize(width: 4000, height: CGFloat.greatestFiniteMagnitude)
        seatText.maxSize = NSSize(width: 4000, height: CGFloat.greatestFiniteMagnitude)
        seatText.autoresizingMask = [.height]
        seatText.selectedTextAttributes = [.backgroundColor: PongColor.live.withAlphaComponent(0.25)]
        seatScroll.documentView = seatText
        seatScroll.hasVerticalScroller = true
        seatScroll.hasHorizontalScroller = true
        seatScroll.drawsBackground = true
        seatScroll.backgroundColor = PongColor.void
        seatScroll.scrollerStyle = .overlay
        seatOpenBtn = PongButton(title: "Open in Terminal", style: .secondary)
        seatOpenBtn.toolTip = "The same terminal in the Terminal app, where you can type into it."
        seatOpenBtn.onPress = { [weak self] in self?.openSeatTerminal() }
        seatPane.addSubview(seatHeader)
        seatPane.addSubview(seatScroll)
        seatPane.addSubview(seatOpenBtn)
        seatPane.isHidden = true
        addSubview(seatPane)

        chatView.isHidden = true
        chatView.onToast = { text, warn in Toast.show(text, warn: warn) }
        addSubview(chatView)

        // inspector
        insp.wantsLayer = true
        inspScroll.drawsBackground = false
        inspScroll.hasVerticalScroller = true
        inspScroll.autohidesScrollers = true
        inspScroll.borderType = .noBorder
        inspScroll.documentView = inspDoc
        inspStack.orientation = .vertical
        inspStack.alignment = .leading
        inspStack.spacing = 12
        inspStack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 24, right: 20)
        inspStack.translatesAutoresizingMaskIntoConstraints = false
        inspDoc.addSubview(inspStack)
        NSLayoutConstraint.activate([
            inspStack.topAnchor.constraint(equalTo: inspDoc.topAnchor),
            inspStack.leadingAnchor.constraint(equalTo: inspDoc.leadingAnchor),
            inspStack.trailingAnchor.constraint(equalTo: inspDoc.trailingAnchor),
        ])
        inspKind.attributedStringValue = PongType.eyebrowString("")
        inspKind.lineBreakMode = .byTruncatingTail
        inspClose.symbol = "xmark"
        inspClose.toolTip = "Close the details (Esc)"
        inspClose.setAccessibilityLabel("Close details")
        inspClose.onPress = { [weak self] in self?.toggleInspectorFromShell() }
        insp.addSubview(inspScroll)
        insp.addSubview(inspKind)
        insp.addSubview(inspClose)
        inspLine.wantsLayer = true
        inspLine.layer?.backgroundColor = PongColor.hairline.cgColor

        // activity
        timeline.wantsLayer = true
        timeline.layer?.backgroundColor = PongColor.base.cgColor
        timelineHead.divider = false
        timelineHead.onClick = { [weak self] in
            guard let self else { return }
            self.activityOpen.toggle()
            UserDefaults.standard.set(self.activityOpen, forKey: "graphs.activityOpen")
            self.lastTimelineSig = ""
            self.needsLayout = true
            self.render()
        }
        timelineHead.toolTip = "What happened, newest first"
        timelineChevron.imageScaling = .scaleProportionallyDown
        timelineHead.addSubview(timelineChevron)
        timelineHead.addSubview(timelineTitle)
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.autohidesScrollers = true
        timelineScroll.borderType = .noBorder
        timelineScroll.documentView = timelineDoc
        timeline.addSubview(timelineHead)
        timeline.addSubview(timelineScroll)
        timelineLine.wantsLayer = true
        timelineLine.layer?.backgroundColor = PongColor.hairline.cgColor

        addSubview(timeline)
        addSubview(timelineLine)
        addSubview(insp)
        addSubview(inspLine)
    }

    override var isFlipped: Bool { false }

    /// The inspector docks in windows 1,100 pt and wider; below that it is an overlay.
    private var inspectorDocked: Bool { (window?.frame.width ?? bounds.width + 200) >= 1100 }

    private var inspectorVisible: Bool {
        guard hasInspector else { return false }
        return inspectorDocked ? !inspHidden : overlayOpen
    }

    private func openOverlay() {
        guard !inspectorDocked else { return }
        overlayOpen = true
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, e.keyCode == 53, self.overlayOpen, e.window === self.window,
                      !(self.window?.firstResponder is TerminalTextView) else { return e }
                self.closeOverlay()
                return nil
            }
        }
        needsLayout = true
    }

    private func closeOverlay() {
        overlayOpen = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let docked = inspectorDocked
        let showInsp = inspectorVisible
        let iw: CGFloat = inspW
        // content: the whole width, less a docked inspector
        let cw = showInsp && docked ? W - iw : W
        let margin: CGFloat = cw >= 1000 ? 32 : 24

        listScroll.frame = NSRect(x: 0, y: 0, width: W, height: H)
        layoutListDoc()

        insp.frame = NSRect(x: W - iw, y: 0, width: iw, height: H)
        insp.isHidden = !showInsp
        insp.layer?.backgroundColor = (docked ? PongColor.base : PongColor.overlay).cgColor
        if docked {
            insp.shadow = nil
            insp.layer?.shadowOpacity = 0
        } else {
            insp.layer?.shadowColor = NSColor.black.cgColor
            insp.layer?.shadowOpacity = 0.5
            insp.layer?.shadowRadius = 12
            insp.layer?.shadowOffset = CGSize(width: -8, height: 0)
            insp.layer?.masksToBounds = false
        }
        inspLine.frame = NSRect(x: W - iw, y: 0, width: 1, height: H)
        inspLine.isHidden = !(showInsp && docked)
        inspKind.frame = NSRect(x: 20, y: H - 36, width: iw - 72, height: 16)
        inspClose.frame = NSRect(x: iw - 44, y: H - 42, width: 28, height: 28)
        inspScroll.frame = NSRect(x: 0, y: 0, width: iw, height: max(40, H - 52))
        let docW = iw
        inspDoc.frame = NSRect(x: 0, y: 0, width: docW, height: max(inspScroll.bounds.height, inspStack.fittingSize.height))
        inspStack.widthAnchorConstraint(docW)
        if lastInspW != docW {
            lastInspW = docW
            lastInspectorSig = ""
            DispatchQueue.main.async { [weak self] in self?.renderInspector() }
        }

        // header, 12 pt under the window bar
        let headerY = H - 12 - PageHeaderView.height
        header.frame = NSRect(x: margin, y: headerY, width: cw - margin * 2, height: PageHeaderView.height)
        var top = headerY - 16
        // activity: a 36 pt fold under the content, 240 pt open
        let th: CGFloat = activityOpen ? min(240, H * 0.4) : 36
        if let b = banner, !b.isHidden {
            // the room it may take: what is left over the activity fold, less three steps (they scroll)
            // or the chat's terminal at its smallest
            let onGraph = mode == .graphs
            layoutBanner(b, x: margin, top: top, width: min(720, cw - margin * 2),
                         room: top - (onGraph ? th + 1 : 0) - 16 - (onGraph ? 108 : 160))
            top -= bannerBox.frame.height + 16
        } else {
            bannerBox.isHidden = true
        }
        timeline.frame = NSRect(x: 0, y: 0, width: cw, height: th)
        timelineLine.frame = NSRect(x: 0, y: th, width: cw, height: 1)
        timelineHead.frame = NSRect(x: 0, y: th - 36, width: cw, height: 36)
        timelineChevron.frame = NSRect(x: margin - 2, y: 11, width: 14, height: 14)
        timelineTitle.frame = NSRect(x: margin + 18, y: 10, width: cw - margin * 2 - 18, height: 16)
        timelineScroll.frame = NSRect(x: 0, y: 0, width: cw, height: max(0, th - 36))
        timelineScroll.isHidden = !activityOpen
        layoutTimelineDoc()

        let body = NSRect(x: 0, y: th + 1, width: cw, height: max(60, top - th - 1))
        stepsScroll.frame = body
        layoutStepsDoc()
        deck.frame = body
        seatPane.frame = body
        seatHeader.frame = NSRect(x: margin, y: body.height - 34, width: body.width - margin * 2 - 170, height: 20)
        seatOpenBtn.frame = NSRect(x: body.width - margin - seatOpenBtn.intrinsicContentSize.width, y: body.height - 38,
                                   width: seatOpenBtn.intrinsicContentSize.width, height: 28)
        seatScroll.frame = NSRect(x: 16, y: 16, width: body.width - 32, height: max(40, body.height - 60))

        // a chat: the header, its question if it asked one, then its terminal to the bottom
        chatView.frame = NSRect(x: 0, y: 0, width: cw, height: max(60, top + 8))
        // the orbit (every graph on one map) fills the list level under its header
        if mode == .graphs && current == nil && showOrbit {
            deck.frame = NSRect(x: 0, y: 0, width: W, height: max(60, headerY - 12))
        }
    }

    /// The banner in its place: as tall as the card when that fits in `room`. Taller, the card's upper
    /// part scrolls, stopped between two lines rather than through one, and its answers stay pinned under
    /// it, so the buttons are always in sight.
    private func layoutBanner(_ b: QuestionCardView, x: CGFloat, top: CGFloat, width bw: CGFloat, room: CGFloat) {
        bannerBox.isHidden = false
        let room = max(150, room)
        let natural = b.height(for: bw)
        if natural <= room || b.answered {
            if b.footerPinned { b.footerPinned = false }
            bannerRule.isHidden = true
            bannerFade.isHidden = true
            bannerMore.isHidden = true
            bannerScroll.hasVerticalScroller = false
            if bannerScroll.scrollerStyle != NSScroller.preferredScrollerStyle { bannerScroll.scrollerStyle = NSScroller.preferredScrollerStyle }
            bannerBox.frame = NSRect(x: x, y: top - natural, width: bw, height: natural)
            bannerScroll.frame = bannerBox.bounds
            b.frame = NSRect(x: 0, y: 0, width: bw, height: natural)
            return
        }
        if !b.footerPinned { b.footerPinned = true }
        if b.footer.superview !== bannerBox { bannerBox.addSubview(b.footer) }
        // a scroller that stays drawn (an overlay one hides until a scroll): the rest is plainly there
        if bannerScroll.scrollerStyle != .legacy { bannerScroll.scrollerStyle = .legacy }
        let fh = b.pinnedFooterHeight(for: bw)
        let most = max(60, room - fh)
        // that scroller takes its width from the card: lay the card out at the width left, or its right
        // edge is cut off
        let cardW = NSScrollView.contentSize(forFrameSize: NSSize(width: bw, height: most), horizontalScrollerClass: nil,
                                             verticalScrollerClass: NSScroller.self, borderType: .noBorder,
                                             controlSize: .regular, scrollerStyle: bannerScroll.scrollerStyle).width
        let bodyH = b.bodyHeight(for: cardW)
        b.frame = NSRect(x: 0, y: 0, width: cardW, height: bodyH)
        let shown = min(bodyH, b.cleanCut(atMost: most))
        bannerScroll.hasVerticalScroller = bodyH > shown
        bannerScroll.autohidesScrollers = false
        let h = shown + fh
        bannerBox.frame = NSRect(x: x, y: top - h, width: bw, height: h)
        bannerScroll.frame = NSRect(x: 0, y: fh, width: bw, height: shown)
        b.footer.frame = NSRect(x: 0, y: 0, width: bw, height: fh)
        bannerRule.frame = NSRect(x: 0, y: fh - 1, width: bw, height: 1)
        bannerRule.isHidden = false
        // more below: a fade over the last lines and "More ↓" at its right, left of the scroller
        bannerFade.place(height: 40)
        let mw = bannerMore.intrinsicContentSize.width
        bannerMore.frame = NSRect(x: bw - 14 - 8 - mw, y: fh + 6, width: mw, height: 24)
        updateBannerMore()
    }

    /// "More ↓" shows with the fade: while the card is cut short and its end is out of sight.
    private func updateBannerMore() {
        guard !bannerRule.isHidden, banner != nil else {
            bannerFade.isHidden = true
            bannerMore.isHidden = true
            return
        }
        bannerFade.update()
        bannerMore.isHidden = bannerFade.isHidden
    }

    /// "More ↓": the next part of the card, keeping a line of what was in sight.
    private func bannerScrollDown() {
        guard let doc = bannerScroll.documentView else { return }
        let clip = bannerScroll.contentView
        let most = max(0, doc.frame.height - clip.bounds.height)
        let y = min(most, clip.bounds.origin.y + max(40, clip.bounds.height - 40))
        clip.scroll(to: NSPoint(x: 0, y: y))
        bannerScroll.reflectScrolledClipView(clip)
        updateBannerMore()
    }

    // MARK: Data

    private var current: GGraph? { graphs.first { $0.key == selectedKey } }

    private var currentChat: GArchitect? {
        guard let k = selectedChat else { return nil }
        return architects.first { $0.key == k }
    }

    private func render() {
        let g = mode == .graphs ? current : nil
        let a = mode == .chats ? currentChat : nil
        let listLevel = g == nil && a == nil
        let orbit = listLevel && mode == .graphs && showOrbit

        listScroll.isHidden = !listLevel || orbit
        header.isHidden = !(g != nil || a != nil || orbit)
        stepsScroll.isHidden = !(g != nil && tab == .steps)
        deck.isHidden = !((g != nil && tab == .plan) || orbit)
        seatPane.isHidden = !(g != nil && tab == .screen)
        timeline.isHidden = g == nil
        timelineLine.isHidden = g == nil
        chatView.isHidden = a == nil
        if a == nil { chatView.stopPoll() }

        if listLevel && !orbit {
            renderList()
            dropBanner()
            needsLayout = true
            return
        }
        if orbit {
            header.set(title: "Graphs", status: "Every graph on this Mac, by team. Click one to open it.")
            header.setAccessory(nil)
            deck.showOrbit(graphs, selectedKey: selectedKey)
            dropBanner()
            needsLayout = true
            return
        }
        if let a {
            renderChatHeader(a)
            chatView.show(a)
            renderChatBanner(a)
            renderInspector()
            needsLayout = true
            return
        }
        guard let g else { return }
        renderGraphHeader(g)
        renderBanner(g)
        switch tab {
        case .steps:
            renderSteps(g)
        case .plan:
            deck.showWiring(g, selected: selectedNode)
        case .screen:
            renderSeatHeader()
        }
        renderInspector()
        renderTimeline()
        needsLayout = true
    }

    private func renderGraphHeader(_ g: GGraph) {
        let sig = g.key + g.plainStatus + g.teamName + "\(tab.rawValue)"
        guard sig != lastHeaderSig else { return }
        lastHeaderSig = sig
        header.set(title: g.displayTitle, status: g.plainStatus + " · " + g.teamName, marker: g.pongStatus,
                   color: g.pongStatus == .needsYou ? PongColor.you : (g.pongStatus == .failed ? PongColor.fail : PongColor.textSecondary))
        tabs.select(tab.rawValue)
        header.setAccessory(tabs)
        onCrumbsChanged?()
    }

    private func renderChatHeader(_ a: GArchitect) {
        let teamUp = SchedulesPageView.runningTeams.contains(a.session)
        let sig = "chat" + a.key + a.plainLine + "\(a.alive)\(teamUp)"
        guard sig != lastHeaderSig else { return }
        lastHeaderSig = sig
        let ai = Words.ai(a.runtime, a.model)
        // a chat whose terminal closed hasn't failed: it is stopped (quiet, not red), and can start again
        // (the window bar's first action, pageActions; the signature brings it there when the team starts)
        header.set(title: a.displayTitle, status: "Chat · \(ai) · " + (a.alive ? "Live" : "Stopped: its terminal is gone"),
                   marker: a.alive ? .working : .stopped, color: PongColor.textSecondary)
        header.setAccessory(nil)
        onCrumbsChanged?()
    }

    /// A chat that is its team's lead (seat "c1", not "c1.arch"): starting the team brings its AI back
    /// on this chat.
    private func isLeadChat(_ a: GArchitect) -> Bool { !a.seat.isEmpty && !a.seat.contains(".") }

    /// How a stopped chat starts again: its team's Start when the team is stopped (a chat that is its
    /// team's lead comes back on this chat), else a new chat on its graph, which reads the graph first.
    private func restartChatButton(_ a: GArchitect, teamUp: Bool) -> NSView {
        let name = TeamNames.name(a.session)
        if !teamUp {
            let b = PongButton(title: "Start its team", style: .secondary)
            b.symbol = "play.fill"
            b.toolTip = isLeadChat(a) ? "Start \(name) again, as it was set up: this chat's AI comes back on this chat."
                                      : "Start \(name) again: its lead and helpers, as it was set up."
            b.onPress = { [weak self] in
                TeamStart.start(a.session, name: name) {
                    self?.lastHeaderSig = ""
                    self?.lastInspectorSig = ""
                    self?.refresh()
                }
            }
            return b
        }
        let b = PongButton(title: "Start a new chat", style: .secondary)
        b.symbol = "plus"
        b.toolTip = a.graphs.isEmpty ? "A new chat on \(name)." : "A new chat for its graph: it reads the graph first."
        b.onPress = { [weak self] in self?.restartChat(a) }
        return b
    }

    private func restartChat(_ a: GArchitect) {
        var args = ["-s", a.session, "architect", "start", "--title", a.displayTitle, "--json"]
        if let gid = a.graphs.last { args += ["--graph", gid] }
        if !a.cwd.isEmpty { args += ["--cwd", a.cwd] }
        Toast.show("Starting a new chat…")
        GraphCLI.run(args, timeout: 60) { [weak self] r in
            guard let self else { return }
            switch ArchitectStart.read(out: r.out, err: r.err) {
            case .failed(let why):
                Pong.log("architect start (again) on \(a.session) failed: \(r.err.isEmpty ? r.out : r.err)")
                Toast.show(why, warn: true)
            case .opened(let key, let warning):
                if let warning {
                    Pong.log("architect start (again) on \(a.session): \(warning)")
                    Toast.show(warning, warn: true)
                }
                self.selectedChat = key
                self.lastHeaderSig = ""
                self.refresh()
            }
        }
    }

    /// The question waiting at this graph, docked above its steps as a compact card: the question, its
    /// first line of context and the answers; "Details ›" opens it in place to the full card, so what
    /// is being decided reads here without going to Home.
    private func renderBanner(_ g: GGraph?) {
        guard let g, g.isRunning, let gate = g.gates.first else {
            if banner != nil {
                dropBanner()
                lastBannerSig = ""
                needsLayout = true
            }
            return
        }
        let model = QuestionModel(graph: g, gate: gate)
        // the card's words and details too, so a late plain-words rewrite or its details show up
        let sig = g.key + gate.node + model.redrawKey + (gate.advice?.pick ?? "") + "\(g.gates.count)"
        guard sig != lastBannerSig || banner == nil else { return }
        // a note is being typed: its field may sit in the answers part pinned outside the card, so ask the
        // card, not where the keyboard is. The next redraw after it is done brings the new words.
        if let b = banner, b.isEditingNote { return }
        lastBannerSig = sig
        dock(QuestionCardView(model, compact: true))
    }

    /// A chat's own question (`pong ask`) docks above its terminal the same way.
    private func renderChatBanner(_ a: GArchitect) {
        let ask = GraphStore.shared.asks.first { $0.architect == a.id && $0.session == a.session }
        guard let ask else {
            if banner != nil { dropBanner(); lastBannerSig = ""; needsLayout = true }
            return
        }
        let model = QuestionModel(ask: ask)
        let sig = "ask" + ask.key + model.redrawKey
        guard sig != lastBannerSig || banner == nil else { return }
        if let b = banner, b.isEditingNote { return }  // a reply being typed (its field may be pinned under the card)
        lastBannerSig = sig
        dock(QuestionCardView(model, compact: true))
    }

    /// Put a card in the banner's place, replacing the one there.
    private func dock(_ card: QuestionCardView) {
        dropBanner()
        card.onFocus = { c in c.focused = true }
        card.onAnswered = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self?.lastBannerSig = ""
                self?.render()
            }
        }
        // opened or folded in place: the steps or the terminal under it move
        card.onHeightChange = { [weak self] in self?.needsLayout = true }
        // the focus ring goes round the whole box, pinned answers included
        card.externalBorder = { [weak self] w, c in
            self?.bannerBox.layer?.borderWidth = w
            self?.bannerBox.layer?.borderColor = c
        }
        banner = card
        bannerScroll.documentView = card
        bannerBox.isHidden = false
        needsLayout = true
    }

    private func dropBanner() {
        banner?.footer.removeFromSuperview()
        banner?.removeFromSuperview()
        bannerScroll.documentView = nil
        banner = nil
        bannerBox.isHidden = true
        bannerRule.isHidden = true
        bannerFade.isHidden = true
        bannerMore.isHidden = true
        bannerBox.layer?.borderWidth = 0
    }

    func clearBannerFocus() { banner?.focused = false }

    func previewSelectNode(_ id: String) { selectNode(id) }
    func previewToggleActivity() {
        activityOpen.toggle()
        lastTimelineSig = ""
        needsLayout = true
        render()
    }

    /// ⌘1–3 answers the question on the open graph, once its card was clicked.
    func answerBanner(_ i: Int) -> Bool {
        guard let b = banner, !b.isHidden, !b.answered, b.focused, i < b.model.answers.count else { return false }
        b.press(i)
        return true
    }

    // MARK: The lists

    private func renderList() {
        var sig = "\(mode)|\(finishedOpen)|\(loadError.isEmpty)|\(loadError == EngineCheck.noPythonMessage)|\(GraphStore.shared.loadedOnce)|\(Int(bounds.width))|"
        if mode == .graphs {
            for g in graphs { sig += g.key + g.plainStatus + "\(g.pongStatus)" + "|" }
        } else {
            let asking = chatsAsking
            for a in architects { sig += a.key + a.plainLine + "\(a.alive)\(asking.contains(a.key))|" }
        }
        sig += "\(Int(Date().timeIntervalSince1970 / 60))"
        guard sig != lastListSig else { return }
        lastListSig = sig
        listDoc.subviews.forEach { $0.removeFromSuperview() }
        let head = PageHeaderView()
        head.identifier = NSUserInterfaceItemIdentifier("header")
        listDoc.addSubview(head)

        if mode == .graphs {
            let waiting = graphs.filter { $0.waitingOnYou }
            // working: its team is up too; one on a stopped team waits for it, as Teams says
            let working = graphs.filter { $0.isWorkingNow }
            let teamWait = graphs.filter { $0.waitsForTeam }
            // paused (by the person, or for Claude's limits): never counted or listed as working
            let paused = graphs.filter { $0.isPausedNow }
            let done = graphs.filter { !$0.isRunning }.sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            var bits: [String] = []
            if !waiting.isEmpty { bits.append("\(waiting.count) need\(waiting.count == 1 ? "s" : "") you") }
            if !working.isEmpty { bits.append("\(working.count) working") }
            if !teamWait.isEmpty { bits.append("\(teamWait.count) waiting for \(teamWait.count == 1 ? "its team" : "their teams")") }
            if !paused.isEmpty { bits.append("\(paused.count) paused") }
            if !done.isEmpty { bits.append("\(done.count) finished") }
            // no Python: refreshing can't help; the setup installs Apple's command line tools
            let failed = loadError == EngineCheck.noPythonMessage ? loadError : "Couldn't read the graphs. Refresh with ⌘R."
            head.set(title: "Graphs", status: !loadError.isEmpty ? failed
                     : (bits.isEmpty ? "Work in steps: a chat plans it with you, then runs it." : bits.joined(separator: " · ")),
                     color: loadError.isEmpty ? PongColor.textSecondary : PongColor.fail)
            if graphs.isEmpty && GraphStore.shared.loadedOnce {
                let e = EmptyStateView(headline: "No graphs yet.",
                                       body: "Describe the work, and a chat plans it with you, then runs it.",
                                       button: "New graph", action: { PanelController.shared.newGraph() })
                e.identifier = NSUserInterfaceItemIdentifier("empty")
                listDoc.addSubview(e)
            }
            if !waiting.isEmpty {
                listDoc.addSubview(listEyebrow("Needs you", color: PongColor.you))
                for g in waiting { listDoc.addSubview(graphRow(g)) }
            }
            if !working.isEmpty {
                listDoc.addSubview(listEyebrow("Working"))
                for g in working { listDoc.addSubview(graphRow(g)) }
            }
            if !teamWait.isEmpty {
                listDoc.addSubview(listEyebrow("Waiting for a team to start"))
                for g in teamWait { listDoc.addSubview(graphRow(g)) }
            }
            if !paused.isEmpty {
                listDoc.addSubview(listEyebrow("Paused"))
                for g in paused { listDoc.addSubview(graphRow(g)) }
            }
            if !done.isEmpty {
                listDoc.addSubview(foldRow("Finished", count: done.count))
                if finishedOpen { for g in done { listDoc.addSubview(graphRow(g)) } }
            }
        } else {
            // a chat with a question open is never folded away under "Show stopped": it leads the list
            let asking = chatsAsking
            let needs = architects.filter { asking.contains($0.key) }.sorted { $0.createdAt > $1.createdAt }
            let live = architects.filter { $0.alive && !asking.contains($0.key) }.sorted { $0.createdAt > $1.createdAt }
            let gone = architects.filter { !$0.alive && !asking.contains($0.key) }.sorted { $0.createdAt > $1.createdAt }
            let liveCount = architects.filter { $0.alive }.count, goneCount = architects.count - liveCount
            head.set(title: "Chats", status: architects.isEmpty ? "A chat is where you plan graphs with an AI."
                     : [needs.isEmpty ? "" : "\(needs.count) need\(needs.count == 1 ? "s" : "") you",
                        liveCount == 0 ? "" : "\(liveCount) live", goneCount == 0 ? "" : "\(goneCount) stopped"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
            if architects.isEmpty && GraphStore.shared.loadedOnce {
                let e = EmptyStateView(headline: "No chats yet.",
                                       body: "Describe what you want done; a chat plans it with you and runs it.",
                                       button: "New graph", action: { PanelController.shared.newGraph() })
                e.identifier = NSUserInterfaceItemIdentifier("empty")
                listDoc.addSubview(e)
            }
            if !needs.isEmpty {
                listDoc.addSubview(listEyebrow("Needs you", color: PongColor.you))
                for a in needs { listDoc.addSubview(chatRow(a, asking: true)) }
            }
            if !live.isEmpty {
                listDoc.addSubview(listEyebrow("Live"))
                for a in live { listDoc.addSubview(chatRow(a)) }
            }
            if !gone.isEmpty {
                listDoc.addSubview(foldRow("Stopped", count: gone.count))
                if finishedOpen { for a in gone { listDoc.addSubview(chatRow(a)) } }
            }
        }
        layoutListDoc()
    }

    private func listEyebrow(_ s: String, color: NSColor = PongColor.textTertiary) -> NSView {
        let v = PongUI.eyebrow(s, color: color)
        v.identifier = NSUserInterfaceItemIdentifier("eyebrow")
        return v
    }

    private func foldRow(_ title: String, count: Int) -> NSView {
        let b = PongButton(title: (finishedOpen ? "Hide " : "Show ") + "\(count) \(title.lowercased())", style: .quiet, size: .small)
        b.symbol = finishedOpen ? "chevron.down" : "chevron.right"
        b.identifier = NSUserInterfaceItemIdentifier("fold")
        b.onPress = { [weak self] in
            guard let self else { return }
            self.finishedOpen.toggle()
            UserDefaults.standard.set(self.finishedOpen, forKey: "graphs.finishedOpen")
            self.lastListSig = ""
            self.renderList()
        }
        return b
    }

    private func graphRow(_ g: GGraph) -> ListRowView {
        let st = g.pongStatus
        let row = ListRowView(status: st)
        let when = g.isRunning ? PongUI.ago(g.lastActivity) : (g.finishedAt.map { PongUI.ago($0) } ?? "")
        row.set(title: g.displayTitle, subtitle: g.plainStatus + " · " + g.teamName, status: st, time: when)
        row.toolTip = "\(g.displayTitle)\n\(g.plainStatus)\nTeam: \(g.teamName)"
        row.onClick = { [weak self] in self?.openGraph(g.key) }
        return row
    }

    /// Chats with a question open (`pong ask`), by key.
    private var chatsAsking: Set<String> { Set(GraphStore.shared.asks.compactMap { $0.chatKey }) }

    private func chatRow(_ a: GArchitect, asking: Bool = false) -> ListRowView {
        let st: PongStatus = asking ? .needsYou : (a.alive ? .working : .stopped)
        let row = ListRowView(status: st)
        let sub = asking ? (["Asked you a question", Words.ai(a.runtime, a.model)] + (a.alive ? [] : ["stopped"]))
            .filter { !$0.isEmpty }.joined(separator: " · ") : a.plainLine
        row.set(title: a.displayTitle, subtitle: sub, status: st,
                word: asking ? "Needs you" : (a.alive ? "Live" : "Stopped"), time: PongUI.ago(a.createdAt))
        row.word.textColor = asking ? PongColor.you : (a.alive ? PongColor.textSecondary : PongColor.textTertiary)
        row.leading = ChatGlyphView(live: a.alive)
        row.onClick = { [weak self] in self?.openChat(a.key) }
        return row
    }

    private func layoutListDoc() {
        let W = listScroll.contentSize.width > 0 ? listScroll.contentSize.width : bounds.width
        let margin: CGFloat = W >= 1000 ? 32 : 24
        let colW = min(900, W - margin * 2)
        var y: CGFloat = 12
        for v in listDoc.subviews {
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
            case "fold":
                y += 16
                let w = (v as? PongButton)?.intrinsicContentSize.width ?? 160
                v.frame = NSRect(x: margin - 8, y: y, width: w, height: 24)
                y += 32
            default:
                v.frame = NSRect(x: margin - 4, y: y, width: colW + 8, height: 52)
                y += 52
            }
        }
        listDoc.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 32, listScroll.contentSize.height))
    }

    // MARK: Steps

    /// Every step in order, 36 pt rows: its number, its state, its name, what it is doing, and when.
    private func renderSteps(_ g: GGraph) {
        let steps = g.nodes.filter { $0.role != "end" }
        // a step at work held still (no spinner, no lit row, no timer) for Claude's limits or a stopped
        // team; under the person's own pause it finishes, and says so
        let (paused, finishing, teamDown) = pauseState(g)
        var sig = g.key + "|\(selectedNode ?? "")|\(Int(bounds.width))|\(Int(Date().timeIntervalSince1970 / 30))|\(paused)\(finishing)\(teamDown)|"
        for n in steps { sig += "\(n.id):\(n.status):\(n.lastOutcome):\(n.liveState):\(n.liveDoing):\(n.loopRound):\(n.attention);" }
        guard sig != lastStepsSig else { return }
        lastStepsSig = sig
        stepsDoc.subviews.forEach { $0.removeFromSuperview() }
        for (i, n) in steps.enumerated() {
            let row = StepRowView(index: i + 1, first: i == 0, last: i == steps.count - 1)
            let st = n.pongStatus(graphRunning: g.isRunning, graphPaused: paused)
            var meta: [String] = []
            let words = stepStatus(n, running: g.isRunning, paused: paused, finishing: finishing, teamDown: teamDown)
            if n.status == "running" && !n.liveDoing.isEmpty && !paused && !finishing {
                meta.append(n.liveDoing)
            } else {
                meta.append(words.prefix(1).uppercased() + words.dropFirst())
            }
            if !n.loopId.isEmpty && n.loopMax > 0 { meta.append("round \(max(1, n.loopRound)) of \(n.loopMax)") }
            if !n.isSeatless && !n.runtime.isEmpty { meta.append(Words.ai(n.runtime, n.model)) }
            var when = ""
            if n.status == "running", let s = n.startedAt { when = PongUI.duration(Date().timeIntervalSince1970 - s) }
            else if let f = n.finishedAt { when = PongUI.ago(f) }
            if st == .failed, !meta.isEmpty, meta[0].lowercased().hasPrefix("finished") {
                meta[0] = "Failed"
            }
            if paused && n.status == "running" { when = "" }
            row.set(name: Words.name(n.id), meta: meta.joined(separator: " · "), status: st, time: when)
            row.selected = n.id == selectedNode
            row.working = n.status == "running" && !paused
            row.toolTip = "\(Words.name(n.id)): \(words). Click for what it does and who runs it."
            row.onClick = { [weak self] in self?.selectNode(n.id) }
            stepsDoc.addSubview(row)
        }
        layoutStepsDoc()
        // open on the step that matters: a question, else the working step
        if scrolledFor != g.key, let i = steps.firstIndex(where: { $0.status == "waiting_human" || !$0.attention.isEmpty })
            ?? steps.firstIndex(where: { $0.status == "running" }) {
            scrolledFor = g.key
            let y = CGFloat(i) * 36 + 4
            DispatchQueue.main.async { [weak self] in
                self?.stepsDoc.scrollToVisible(NSRect(x: 0, y: max(0, y - 72), width: 10, height: 180))
            }
        }
    }

    private var scrolledFor = ""

    private func layoutStepsDoc() {
        let W = stepsScroll.contentSize.width > 0 ? stepsScroll.contentSize.width : stepsScroll.bounds.width
        let cw = W
        let margin: CGFloat = cw >= 1000 ? 32 : 24
        var y: CGFloat = 4
        for v in stepsDoc.subviews {
            v.frame = NSRect(x: margin - 8, y: y, width: min(900, cw - margin * 2) + 16, height: 36)
            y += 36
        }
        stepsDoc.frame = NSRect(x: 0, y: 0, width: W, height: max(y + 16, stepsScroll.contentSize.height))
    }

    private func selectNode(_ id: String?) {
        selectedNode = id
        lastInspectorSig = ""
        lastStepsSig = ""
        if id != nil && !inspectorDocked { openOverlay() }
        if id != nil && inspectorDocked && inspHidden {
            inspHidden = false
            UserDefaults.standard.set(false, forKey: "graphs.inspCollapsed")
        }
        if tab == .screen { peekSeat() }
        render()
        onCrumbsChanged?()
    }

    // MARK: Seat

    private func renderSeatHeader() {
        guard let g = current, let nid = selectedNode, let n = g.node(nid) else {
            seatHeader.stringValue = "No step selected"
            return
        }
        let who = n.runtime.isEmpty ? "" : " · " + Words.ai(n.runtime, n.model)
        let ps = pauseState(g)
        let st = stepStatus(n, running: g.isRunning, paused: ps.still, finishing: ps.finishing, teamDown: ps.teamDown)
        seatHeader.stringValue = Words.name(n.id) + who + " · " + st
        if seatPoll == nil && active { startSeatPoll() }
    }

    private func startSeatPoll() {
        stopSeatPoll()
        peekSeat()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.peekSeat() }
        RunLoop.main.add(t, forMode: .common)
        seatPoll = t
    }

    private func stopSeatPoll() {
        seatPoll?.invalidate()
        seatPoll = nil
    }

    private func peekSeat() {
        guard !peekInFlight, let g = current, let nid = selectedNode, let n = g.node(nid), !n.isSeatless else { return }
        peekInFlight = true
        GraphCLI.run(["-s", g.session, "graph", "peek", "--seat", n.seat, "--lines", "160", "--json"], timeout: 10) { [weak self] r in
            guard let self else { return }
            self.peekInFlight = false
            guard let data = r.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // the engine's own sentence, else plain words; what it said goes to the log once
                let said = (r.err.isEmpty ? "exit \(r.code)" : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                if said != self.lastPeekError {
                    self.lastPeekError = said
                    Pong.log("graph peek \(g.session)/\(n.seat) failed: \(said.prefix(300))")
                }
                self.setSeatText(Words.engineSentence(said) ?? "This step's screen couldn't be read just now.")
                return
            }
            self.lastPeekError = ""
            let text = GJ.str(obj["text"])
            let note = GJ.str(obj["note"]).trimmingCharacters(in: .whitespacesAndNewlines)
            // no screen: the engine's note is a sentence ("This step has no screen to show yet."), shown as one
            self.setSeatText(text.isEmpty ? (note.isEmpty ? "Nothing on this step's screen yet."
                                             : Words.engineSentence(note) ?? "This step's screen couldn't be read just now.") : text)
        }
    }

    private func setSeatText(_ s: String) {
        let atBottom = (seatScroll.documentVisibleRect.maxY >= (seatText.frame.height - 30))
        let keepX = seatScroll.contentView.bounds.origin.x
        seatText.string = s
        if atBottom {
            seatText.scrollToEndOfDocument(nil)
            // scrolling to the end also scrolls right, to the end of the last line: the pane's
            // lines showed without their first 40 characters. Keep the person's own column.
            let clip = seatScroll.contentView
            let x = min(keepX, max(0, seatText.frame.width - clip.bounds.width))  // never past a narrower text
            if clip.bounds.origin.x != x {
                clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
                seatScroll.reflectScrolledClipView(clip)
            }
        }
    }

    /// A file a seat wrote is looked at, never run: documents open in their app, anything
    /// else (a script, an executable, an app bundle, a .command) is shown in Finder.
    private func openChangedFile(_ f: GFile, in g: GGraph) {
        openSafely(g.filesRoot.isEmpty ? f.path : (g.filesRoot as NSString).appendingPathComponent(f.path), session: g.session)
    }

    /// Open a file a person clicked: a document in its app; anything else (a script, an executable, an app
    /// bundle, a .command) is shown in Finder, never run. A path that is not on this Mac is copied instead.
    private func openSafely(_ path: String, session: String = "") {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            openPath(path, session: session)  // copies the path and says it is not on this Mac
            return
        }
        let viewable: Set<String> = ["md", "markdown", "txt", "json", "csv", "tsv", "log", "yaml", "yml", "pdf",
                                     "png", "jpg", "jpeg", "gif", "svg", "webp"]
        if viewable.contains(url.pathExtension.lowercased()) && !FileManager.default.isExecutableFile(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func kbWords(_ kb: Double) -> String {
        kb >= 1024 ? String(format: "%.1f MB", kb / 1024) : (kb >= 10 ? String(format: "%.0f KB", kb) : String(format: "%.1f KB", kb))
    }

    private func openSeatTerminal() {
        guard let g = current, let nid = selectedNode, let n = g.node(nid), !n.isSeatless else { return }
        GraphCLI.run(["-s", g.session, "graph", "seat-view", "--seat", n.seat, "--json"], timeout: 15) { r in
            let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
            guard let obj, GJ.bool(obj["ok"]) else {
                // the reply's note ("Its terminal has closed."), never the reply itself
                let note = GJ.str(obj?["note"])
                Toast.show(GraphActions.failure(note.isEmpty ? r.err : note, "Couldn't open its terminal. Try again in a moment.",
                                                log: "seat-view \(g.session)/\(n.seat)"), warn: true)
                return
            }
            // "=name:" is an exact session match; a bare "pong-team-90-c1.b" is read as window.pane
            GraphCLI.openInTerminal("tmux attach-session -t '=" + GJ.str(obj["view"]) + ":'")
        }
    }

    // MARK: Inspector

    /// The right pane names what is selected (a graph, a step, a chat), then puts first what a person is
    /// here for: a question waiting for their answer, then what they can do (every button says what it
    /// does), then the facts. The technical ones (team, lead seat, budget, ids, the terminal command)
    /// fold under Details.
    private func renderInspector() {
        guard hasInspector else { return }
        if mode == .chats, let a = currentChat {
            renderChatInspector(a)
            return
        }
        let g = current
        var sig = "\(tab.rawValue)|\(selectedNode ?? "")|\(detailsOpen)|\(stepsOpen)|\(Int(inspExpandedW))|"
        if let g {
            sig += g.visualSignature + g.plainStatus + g.budgetLine + "\(g.refusals.count)\(g.manualPause)" + g.gates.map { $0.summary }.joined()
            sig += g.gates.map { "\($0.advice?.pending ?? false)\($0.advice?.pick ?? "")\($0.advice?.blind ?? false)" }.joined()
            // a question's words and details, so a late rewrite or its details show up
            sig += g.gates.map { QuestionModel(graph: g, gate: $0).redrawKey + "\($0.askPending)" }.joined()
            sig += g.files.prefix(8).map { "\($0.path)\($0.at)" }.joined()
            sig += architects.map { $0.key }.joined()
            if let nid = selectedNode, let n = g.node(nid) { sig += "\(n.liveState)\(n.liveDoing)" }
        }
        guard sig != lastInspectorSig else { return }
        lastInspectorSig = sig
        inspStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = inspExpandedW - 40

        guard let g else {
            finishInspector()
            return
        }
        if let nid = selectedNode, let n = g.node(nid) {
            renderNode(n, in: g, width: width)
        } else {
            renderGraphSummary(g, width: width)
        }
        finishInspector()
    }

    /// The inspector's width when open (its content is laid out for that, even while it is folded).
    private var inspExpandedW: CGFloat { inspW }

    private func finishInspector() {
        inspDoc.frame.size.height = max(inspScroll.bounds.height, inspStack.fittingSize.height + 20)
    }

    /// A file a question names, as a full path on this Mac: a path the engine resolved, a file of the gate,
    /// or a name under the project folder. nil when there is no such file.
    private func resolveFile(_ name: String, in g: GGraph, gate: GGate) -> String? {
        let fm = FileManager.default
        let t = (name as NSString).expandingTildeInPath
        if t.hasPrefix("/") { return fm.fileExists(atPath: t) ? t : nil }
        let base = (t as NSString).lastPathComponent
        for f in (gate.ask?.files ?? []) + gate.artifacts {
            let full = (f as NSString).expandingTildeInPath
            if full.hasPrefix("/"), (full.hasSuffix("/" + t) || (full as NSString).lastPathComponent == base), fm.fileExists(atPath: full) {
                return full
            }
        }
        let arch = architects.first { $0.id == g.architectId && $0.session == g.session }?.cwd ?? ""
        for root in [gate.ask?.root ?? "", g.filesRoot, arch] where !root.isEmpty {
            let p = ((root as NSString).expandingTildeInPath as NSString).appendingPathComponent(t)
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private static let fileMention = try! NSRegularExpression(
        pattern: #"(?<![\w.~/-])[~/]?(?:[\w.@+-]+/)*[\w@+-][\w.@+-]*\.(?:md|markdown|txt|json|csv|tsv|pdf|png|jpe?g|gif|svg|webp|html?|ya?ml|log|py|swift|tsx?|jsx?|sh)(?![\w])"#,
        options: [.caseInsensitive])

    /// A line of a question card whose file names are links (only names that are a file on this Mac).
    private func linkedText(_ s: String, in g: GGraph, gate: GGate, width: CGFloat, color: NSColor, size: CGFloat,
                            weight: NSFont.Weight = .regular) -> NSView {
        let text = NSMutableAttributedString(string: s, attributes: [.font: PongTheme.font(size, weight: weight), .foregroundColor: color])
        var paths: [String] = []
        for m in Self.fileMention.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), let path = resolveFile(String(s[r]), in: g, gate: gate) else { continue }
            text.addAttribute(.link, value: "pongfile:\(paths.count)", range: m.range)
            text.addAttribute(.toolTip, value: "Open " + path, range: m.range)
            paths.append(path)
        }
        guard !paths.isEmpty else { return para(s, width: width, color: color, size: size, weight: weight) }
        let v = LinkTextView(text, width: width)
        v.onLink = { [weak self] i in if i < paths.count { self?.openSafely(paths[i]) } }
        return v
    }

    private func renderGraphSummary(_ g: GGraph, width: CGFloat) {
        setInspKind("Graph")
        if !g.goalText.isEmpty {
            let goal = para(String(g.goalText.prefix(400)), width: width, color: PongColor.textSecondary, size: 13)
            goal.maximumNumberOfLines = 4
            goal.lineBreakMode = .byTruncatingTail
            goal.cell?.truncatesLastVisibleLine = true
            goal.toolTip = String(g.goalText.prefix(1200))
            add(section("What it is for"))
            add(goal)
        }

        // the first question is on top of the page; any others wait here
        if g.gates.count > 1 {
            add(section("Also waiting for you", color: PongColor.you))
            for gate in g.gates.dropFirst() {
                add(dotRow(Words.name(gate.node), status: "needs your answer", extra: "", color: PongColor.you, width: width,
                           tip: "Open this question") { [weak self] in self?.selectNode(gate.node) })
            }
        }

        if !g.lastError.isEmpty || !g.refusals.isEmpty {
            add(section("Problems", color: PongColor.fail))
            if !g.lastError.isEmpty { add(para(g.lastError, width: width, color: PongColor.fail, size: 12)) }
            for r in g.refusals.suffix(5).reversed() {
                add(para("\(Words.name(r.node)) was refused: \(r.reason)", width: width, color: PongColor.textSecondary, size: 12))
            }
        }

        if !g.files.isEmpty {
            add(section("Result files · \(g.files.count)"))
            for f in g.files.prefix(6) {
                add(fileLink((f.path as NSString).lastPathComponent, detail: GraphTime.ago(f.at)) { [weak self] in self?.openChangedFile(f, in: g) })
            }
            add(hint("A document opens in its app. A script opens in Finder, never runs.", width: width))
        }

        let hasChat = architects.contains { $0.id == g.architectId && $0.session == g.session }
        add(section("Its chat"))
        add(tipped(ActionButton(hasChat ? "Open its chat" : "Start a chat") { [weak self] in self?.openChat(for: g) },
                   hasChat ? "Talk with the chat that looks after this graph."
                           : "A new chat reads this graph first, then you can talk with it."))

        add(detailsToggle("the team, budget, goal and ids"))
        if detailsOpen {
            add(kv([("team", g.teamName), ("lead", g.owner), ("budget", g.budgetLine),
                    ("started", GraphTime.ago(g.createdAt)), ("finished", g.finishedAt.map { GraphTime.ago($0) } ?? "—"),
                    ("graph id", g.id)], width: width))
            if !g.goalText.isEmpty {
                add(eyebrow("Goal"))
                add(para(String(g.goalText.prefix(1200)) + (g.goalText.count > 1200 ? "…" : ""), width: width, color: PongColor.textSecondary, size: 12))
            }
            if !g.files.isEmpty {
                add(eyebrow("Every file it changed"))
                for f in g.files.prefix(20) {
                    let owner = f.node.isEmpty ? "" : " · \(Words.name(f.node))"
                    add(fileLink(f.path, detail: kbWords(f.kb) + owner) { [weak self] in self?.openChangedFile(f, in: g) })
                }
            }
            add(eyebrow("For engineers"))
            add(mono("pong -s \(g.session) graph show --id \(g.id)", width: width))
            if let gate = g.gates.first {
                add(mono("pong -s \(g.session) goal resume --id \(g.id) --node \(gate.node) --outcome \(g.gateOutcomes(gate.node).first ?? "approved")", width: width))
            }
        }
    }

    /// A graph's steps at work: held still (a pause for Claude's limits, or its team is stopped, paused
    /// or not), or finishing (the person's pause lets steps at work finish; nothing new starts after them).
    /// `teamDown`: held because the team's terminals are gone, which the steps say.
    private func pauseState(_ g: GGraph) -> (still: Bool, finishing: Bool, teamDown: Bool) {
        let up = g.teamUp
        let still = g.stepsHoldStill(teamUp: up)
        return (still, g.isPausedNow && !still, still && !up)
    }

    /// Whose report a question carries, by what that step does: "What the reviewer reported" on the
    /// person's step after a review, "What Draft reported" after a step named Draft.
    private func reportTitle(_ g: GGraph, _ gate: GGate) -> String {
        guard let src = g.node(gate.from) else { return "What the step before reported" }
        switch src.role {
        case "critic": return "What the reviewer reported"
        case "check": return "What the automatic test reported"
        case "jev": return "What Jev's check reported"
        case "human": return "Your earlier answer"
        default: return "What \(Words.name(src.id)) reported"
        }
    }

    /// A step's state in words. In a graph that has stopped, a step that never ran was not reached.
    private func stepStatus(_ n: GNode, running: Bool = true, paused: Bool = false, finishing: Bool = false,
                            teamDown: Bool = false) -> String {
        if !running && ["pending", "ready", "waiting", ""].contains(n.status) { return "not reached" }
        if teamDown && n.status == "running" { return "waits for its team to start" }
        if paused && n.status == "running" { return "paused with the graph" }
        if finishing && n.status == "running" { return "finishing, then the graph waits" }
        switch n.status {
        case "pending", "": return "not started"
        case "ready": return "about to start"
        case "waiting": return "waiting for the steps before it"
        case "waiting_human": return "waiting for your answer"
        case "held": return "held by the pause"
        case "bounded": return "stopped: its rounds are spent"
        case "awaiting_critic": return "waiting for the reviewer"
        case "done":
            switch n.lastOutcome {
            case "", "done", "ok": return "finished"
            case "win", "pass", "passed": return "finished · passed"
            case "fail", "failed": return "finished · didn't pass"
            case "approved": return "approved"
            case "rejected": return "sent back"
            default: return "finished · " + Words.outcome(n.lastOutcome).lowercased()  // "hit an error", "chose fix"
            }
        default: return n.status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func renderNode(_ n: GNode, in g: GGraph, width: CGFloat) {
        setInspKind("Step")
        add(tipped(linkButton("← The whole graph") { [weak self] in self?.selectNode(nil) }, "Back to the graph's summary"))
        add(para(Words.name(n.id), width: width, color: PongColor.textPrimary, size: 17, weight: .semibold))
        let ps = pauseState(g)
        let st = n.pongStatus(graphRunning: g.isRunning, graphPaused: ps.still)
        let said = stepStatus(n, running: g.isRunning, paused: ps.still, finishing: ps.finishing, teamDown: ps.teamDown)
        add(para(said.prefix(1).uppercased() + said.dropFirst(),
                 width: width, color: st == .done ? PongColor.textSecondary : st.color, size: 12))
        if !n.isSeatless && !n.runtime.isEmpty {
            add(para("Runs on: " + Words.ai(n.runtime, n.model) + (n.pin.isEmpty ? "" : " (fixed for this step)"),
                     width: width, color: PongColor.textSecondary, size: 12))
        }
        if !n.attention.isEmpty { add(para("Needs you: " + n.attention, width: width, color: PongColor.you, size: 12)) }
        // a question that isn't the one on top of the page shows here as the same card
        if let gate = g.gates.first(where: { $0.node == n.id }), g.isRunning, gate.node != g.gates.first?.node {
            let card = QuestionCardView(QuestionModel(graph: g, gate: gate), compact: false)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: width).isActive = true
            let tall = card.heightAnchor.constraint(equalToConstant: card.height(for: width))
            tall.isActive = true
            // details folded or opened, a note: the card grows in place and the pane scrolls further
            card.onHeightChange = { [weak self, weak card, weak tall] in
                guard let card, let tall else { return }
                tall.constant = card.height(for: width)
                self?.inspStack.layoutSubtreeIfNeeded()
                self?.finishInspector()
            }
            add(card)
        }
        if let gate = g.gates.first(where: { $0.node == n.id }) {
            let jv = jevGateViews(gate, width: width)
            if !jv.isEmpty {
                add(section("Jev's second opinion"))
                for v in jv { add(v) }
            }
            if !gate.summary.isEmpty {
                // the report of the step that asked (a reviewer, mostly), without the verdict word its AI
                // put first ("win: …"): the state shows above
                add(section(reportTitle(g, gate)))
                add(linkedText(String(Words.report(gate.summary).prefix(700)), in: g, gate: gate, width: width,
                               color: PongColor.textSecondary, size: 12))
            }
        }

        if n.status == "running" && !n.isSeatless {
            add(section("Right now", color: liveColor(n)))
            // three lines at most, so the sections under it do not jump as the line changes
            let doing = para(n.liveDoing.isEmpty ? "No screen reading yet. The engine looks every 30 seconds." : n.liveDoing,
                             width: width, color: PongColor.textPrimary, size: 13)
            doing.maximumNumberOfLines = 3
            doing.lineBreakMode = .byWordWrapping
            doing.cell?.truncatesLastVisibleLine = true
            doing.toolTip = n.liveDoing
            add(doing)
            var bits: [String] = []
            switch n.liveState {
            case "working": bits.append("Working")
            case "quiet": bits.append("Quiet: nothing new on its screen for a while. Open its screen if this lasts.")
            case "no_model": bits.append("The AI has stopped.")
            default: break
            }
            if let c = n.liveChangedAt { bits.append("updated \(GraphTime.ago(c))") }
            if !bits.isEmpty {
                let stl = para(bits.joined(separator: " · "), width: width, color: liveColor(n), size: 12)
                stl.maximumNumberOfLines = 2
                stl.lineBreakMode = .byWordWrapping
                stl.cell?.truncatesLastVisibleLine = true
                add(stl)
            }
        }

        let row = buttonRow()
        if !n.isSeatless {
            if tab != .screen {
                row.addArrangedSubview(tipped(ActionButton("Show its screen") { [weak self] in self?.setTab(.screen) },
                                              "This step's terminal, live, on the Screen tab."))
            }
            row.addArrangedSubview(tipped(ActionButton("Open in Terminal") { [weak self] in self?.openSeatTerminal() },
                                          "The same terminal in the Terminal app, where you can type into it."))
        }
        if n.status == "failed" || (n.lastOutcome == "error") || n.liveState == "no_model" {
            row.addArrangedSubview(tipped(ActionButton("Run again") {
                GraphActions.retry(g, node: n.id) { ok, err in
                    Toast.show(ok ? "\(Words.name(n.id)) started again."
                                  : GraphActions.failure(err, "\(Words.name(n.id)) didn't start again. Try again in a moment.",
                                                         log: "retry \(g.key) \(n.id)"), warn: !ok)
                }
            }, "Start this step again from the beginning."))
        }
        if !row.arrangedSubviews.isEmpty { add(row) }

        if n.role == "jev" || n.jev != nil || !n.claimRead.isEmpty {
            for v in jevNodeViews(n, width: width) { add(v) }
        }
        if n.role == "human" && !n.adviceLog.isEmpty {
            add(section("Jev at this question"))
            for a in n.adviceLog.suffix(4).reversed() {
                let same = a.pick == a.answer
                add(para("Jev suggested \(a.pick.replacingOccurrences(of: "route:", with: "")) (\(ProbText.pct(a.p)) sure) · you said \(a.answer.replacingOccurrences(of: "route:", with: ""))",
                         width: width, color: same ? PongColor.textSecondary : PongColor.textPrimary, size: 12))
            }
        }
        let mine = g.recent.filter { $0.node == n.id && ["claim", "check", "gate_answer", "jev"].contains($0.event) }
        if let last = mine.last {
            add(section("Its last message"))
            let said = Words.outcome(last.outcome)
            let text = Words.report(last.summary)
            add(para([said, text].filter { !$0.isEmpty }.joined(separator: " — "), width: width, color: PongColor.textSecondary, size: 12))
        }
        let written = g.files.filter { $0.node == n.id }
        if !written.isEmpty {
            add(section("Result files"))
            for f in written.prefix(6) {
                add(fileLink((f.path as NSString).lastPathComponent, detail: GraphTime.ago(f.at)) { [weak self] in
                    self?.openChangedFile(f, in: g)
                })
            }
        }

        add(detailsToggle("who runs it and why, its task and what comes next"))
        guard detailsOpen else { return }
        if !n.isSeatless || n.role == "check" || n.role == "jev" {
            add(eyebrow("Who runs it"))
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 6
            box.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            box.wantsLayer = true
            box.layer?.backgroundColor = PongColor.raised.cgColor
            box.layer?.borderWidth = 0
            box.layer?.cornerRadius = PongRadius.card
            let head = n.runtime.isEmpty ? "not chosen yet" : (n.model.isEmpty ? n.runtime : "\(n.runtime) · \(n.model)")
            box.addArrangedSubview(para(head + (n.pin.isEmpty ? "" : "  (fixed)"), width: width - 20, color: GraphPalette.platform(n.platformGlyph), size: 13, weight: .semibold))
            if !n.rule.isEmpty { box.addArrangedSubview(mono("rule: " + n.rule, width: width - 20)) }
            if !n.why.isEmpty { box.addArrangedSubview(para(n.why, width: width - 20, color: PongTheme.textSecondary, size: 11.5)) }
            for (p, why) in n.rejected.prefix(6) {
                box.addArrangedSubview(para("not \(p): \(why)", width: width - 20, color: PongTheme.textTertiary, size: 11))
            }
            add(box)
        }
        if !n.taskPreview.isEmpty {
            add(eyebrow(n.role == "check" ? "Its commands" : "Its task"))
            add(n.role == "check" ? mono(n.taskPreview, width: width) : para(n.taskPreview, width: width, color: PongTheme.textSecondary, size: 11.5))
        }
        let edgesOut = g.edges.filter { $0.from == n.id }
        if !edgesOut.isEmpty {
            add(eyebrow("What comes next"))
            for e in edgesOut { add(mono("on \(e.on) → \(e.to)", width: width)) }
        }
        var rows: [(String, String)] = [("seat", n.isSeatless ? (n.role == "check" ? "the engine" : (n.role == "jev" ? "the engine, asking Jev" : "a person / the graph")) : n.seat),
                                        ("visits", "\(n.visits)")]
        if !n.loopId.isEmpty { rows.append(("loop", "\(n.loopId) · round \(n.loopRound) of \(n.loopMax)")) }
        if n.retryCount > 0 { rows.append(("retries", "\(n.retryCount)")) }
        if !n.wait.isEmpty { rows.append(("waits for", n.wait)) }
        if !n.waitingFor.isEmpty { rows.append(("waiting on", n.waitingFor.joined(separator: ", "))) }
        if n.arrivals > 0 { rows.append(("arrived", "\(n.arrivals)")) }
        if let s = n.startedAt { rows.append(("started", GraphTime.ago(s))) }
        if let f = n.finishedAt { rows.append(("finished", GraphTime.ago(f))) }
        if !n.copyOf.isEmpty { rows.append(("copy of", n.copyOf)) }
        if n.fresh { rows.append(("context", "fresh pane each visit")) }
        add(kv(rows, width: width))
        if !n.isSeatless {
            add(eyebrow("For engineers"))
            add(mono("pong -s \(g.session) graph trace --id \(g.id) --node \(n.id)", width: width))
        }
    }

    // MARK: Jev

    /// One option and how likely Jev thinks it is (numbers are for people; builders never see them).
    private func probRow(_ name: String, _ p: Double, width: CGFloat, note: String = "", color: NSColor = PongTheme.textSecondary,
                         chosen: Bool = false, tip: String = "") -> NSView {
        ProbBarView(name: name, p: p, width: width, color: color, chosen: chosen, note: note, tip: tip)
    }

    private func pct(_ p: Double) -> String { ProbBarView.pct(p) }

    private func lineColor(_ verdict: String) -> NSColor {
        switch verdict {
        case "pass": return PongColor.textSecondary
        case "under", "not_assessable": return PongColor.fail
        case "uncertain": return PongColor.textPrimary
        default: return PongColor.textTertiary
        }
    }

    /// The question Jev was asked, quoted: it reads as Jev's question, not as the app's own words.
    private func askedViews(_ title: String, question: String, width: CGFloat) -> [NSView] {
        var out: [NSView] = [eyebrow(title)]
        if !question.isEmpty {
            out.append(para("\u{201C}" + question + "\u{201D}", width: width, color: PongColor.textPrimary, size: 12))
        }
        return out
    }

    /// Every option with its probability, most likely first; the one taken in bold and lime. What an option
    /// means is on hover, and under it when `describe` (a route's own description says where it goes).
    private func optionViews(_ probs: [(String, Double)], chosen: String, optionText: [String: String], width: CGFloat,
                             describe: Bool) -> [NSView] {
        probs.map { k, p in
            let name = k.hasPrefix("route:") ? String(k.dropFirst(6)) : (k == "none" ? "none of these" : k)
            let text = optionText[k] ?? optionText[name] ?? ""
            return probRow(name, p, width: width, note: describe ? text : "",
                           color: k == chosen ? PongColor.textPrimary : PongColor.textTertiary, chosen: k == chosen, tip: text)
        }
    }

    /// A rubric's lines, each a question Jev answered: how likely the work meets the line's bar, the question
    /// itself, and how Jev spread its answer (over the levels, or yes / no).
    private func lineViews(_ lines: [GJevLine], width: CGFloat) -> [NSView] {
        var out: [NSView] = []
        for l in lines {
            var note: String
            switch l.verdict {
            case "not_assessable": note = "not in the document"
            case "under": note = "below the bar"
            case "uncertain": note = "unsure"
            case "pass": note = "meets the bar"
            case "info": note = "for information, does not decide"
            case "unanswered": note = "not answered"
            default: note = l.verdict
            }
            if l.advisory { note += " · advises only (\(l.status.replacingOccurrences(of: "_", with: " ")))" }
            let color = l.advisory ? PongTheme.textTertiary : lineColor(l.verdict)
            out.append(probRow(l.id, l.pMeets ?? 0, width: width, note: note, color: color,
                               tip: "How likely the work meets this line's bar" + (l.floorName.isEmpty ? "" : " (\(l.floorName) or better)")))
            if !l.text.isEmpty { out.append(hint("\u{201C}" + l.text + "\u{201D}", width: width)) }
            switch l.type {
            case "score" where !l.probabilities.isEmpty:
                out.append(levelStrip(l, width: width, color: color))
            case "noul":
                if let pm = l.pMeets { out.append(hint("yes \(pct(pm)) · no \(pct(1 - pm))", width: width)) }
            case "choice" where !l.probabilities.isEmpty:
                out.append(hint(l.probabilities.map { "\($0.0) \(pct($0.1))" }.joined(separator: " · "), width: width))
            default:
                break
            }
        }
        return out
    }

    /// A score line's answer over its levels, as a small chart; the levels and their P are on hover.
    private func levelStrip(_ l: GJevLine, width: CGFloat, color: NSColor) -> NSView {
        let ps = l.probabilities.map { $0.1 }
        let names = l.levelNames
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let strip = LevelStripView(probs: ps, floor: l.floor, color: color)
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.widthAnchor.constraint(equalToConstant: CGFloat(max(3, ps.count)) * 13).isActive = true
        strip.heightAnchor.constraint(equalToConstant: 18).isActive = true
        var tip: [String] = []
        for (i, p) in ps.enumerated() {
            let name = i < names.count ? names[i] : "level \(i)"
            tip.append("\(l.floor == i ? "▸ " : "   ")\(name): \(pct(p))")
        }
        if let f = l.floor, f < names.count { tip.append("The bar: \(names[f]) or better (▸).") }
        strip.toolTip = tip.joined(separator: "\n")
        row.addArrangedSubview(strip)
        if let top = ps.indices.max(by: { ps[$0] < ps[$1] }) {
            let name = top < names.count ? names[top] : "level \(top)"
            row.addArrangedSubview(hint("most likely: \(name) (\(pct(ps[top])))", width: width - CGFloat(max(3, ps.count)) * 13 - 8))
        }
        return row
    }

    /// What a person needs at a gate from Jev: the question it was asked there and every answer's odds
    /// (unless this gate is blind), then the rubric's lines, weakest first.
    private func jevGateViews(_ gate: GGate, width: CGFloat) -> [NSView] {
        var out: [NSView] = []
        if let a = gate.advice {
            if a.blind {
                out += askedViews("Jev was asked", question: a.question, width: width)
                out.append(hint("Its answer is hidden here until you answer: one question in five, so your answers also measure how good Jev is.", width: width))
            } else if a.pending {
                out += askedViews("Jev is being asked", question: a.question, width: width)
                out.append(hint("Jev is reading the work…", width: width))
            } else if !a.pick.isEmpty {
                out += askedViews("Jev was asked", question: a.question, width: width)
                out += optionViews(a.probabilities, chosen: a.pick, optionText: a.optionText, width: width, describe: false)
            } else if !a.error.isEmpty {
                // not always "not asked": a refused key or an unreachable Jev was asked and gave nothing
                out.append(hint("No advice from Jev here. " + Words.jevNotAsked(a.error), width: width))
            }
        }
        if let j = gate.jev, !j.gatingLines.isEmpty {
            let weak = j.gatingLines.filter { $0.verdict != "pass" }
            out.append(eyebrow(weak.isEmpty ? "Checklist · all met" : "Checklist · weakest first"))
            if j.attached && !j.critic.isEmpty {
                out.append(para(verdictsLine(j.critic, j.jevVerdict.isEmpty ? j.outcome : j.jevVerdict, j.combined.isEmpty ? j.outcome : j.combined),
                                width: width, color: PongColor.textSecondary, size: 12))
            }
            out.append(contentsOf: lineViews(j.gatingLines, width: width))
        }
        return out
    }

    /// "Reviewer: passed · Jev: not asked → passed": each verdict in words, never "win" or "fail".
    private func verdictsLine(_ critic: String, _ jev: String, _ combined: String) -> String {
        func said(_ v: String) -> String { Words.outcome(v).lowercased() }
        return "Reviewer: \(said(critic)) · Jev: \(said(jev)) → \(said(combined))"
    }

    /// A Jev step (or a critic with Jev beside it): each question it was asked and every answer's odds.
    private func jevNodeViews(_ n: GNode, width: CGFloat) -> [NSView] {
        var out: [NSView] = []
        if !n.claimRead.isEmpty {
            out += askedViews("Jev read its closing message",
                              question: n.claimQuestion.isEmpty ? "Which verdict does this step's closing message give about the work?" : n.claimQuestion,
                              width: width)
            if n.claimProbs.isEmpty {
                out.append(para(n.claimRead, width: width, color: PongColor.textSecondary, size: 12))
            } else {
                out += optionViews(n.claimProbs, chosen: n.claimTaken ? n.claimPick : "", optionText: [:], width: width, describe: false)
                out.append(hint(n.claimTaken ? "Taken: the step's verdict became \(n.claimPick)."
                                             : "Not taken: Jev was under 90% sure, so the usual rule decided.", width: width))
            }
        }
        guard let j = n.jev else {
            if n.role == "jev" { out.append(para("Jev hasn't been asked yet.", width: width, color: PongColor.textTertiary, size: 12)) }
            return out
        }
        let modeWord = ["grade": "grade", "decide": "which way next", "rank": "ranking"][j.mode] ?? j.mode
        let what = j.attached ? "Jev's second opinion" : "Jev · \(modeWord)"
        out.append(section(what))
        if !j.ok {
            // why it has no opinion here ("No Jev key on this Mac, …"): not a failure, the reviewers decided
            // alone, so quiet, never the red of a failed step
            out.append(para(Words.jevNotAsked(j.error), width: width, color: PongColor.textTertiary, size: 12))
        }
        if j.attached {
            out.append(para(verdictsLine(j.critic, j.jevVerdict, j.combined), width: width, color: PongColor.textPrimary, size: 13))
        } else if !j.summary.isEmpty {
            out.append(para(String(j.summary.split(separator: "\n").first ?? ""), width: width, color: PongColor.textPrimary, size: 13))
        }
        switch j.mode {
        case "decide", "rank":
            let chosen = j.outcome == "abstain" ? "" : (j.mode == "rank" ? j.winner : j.pick)
            let q = !j.question.isEmpty ? j.question
                : (j.mode == "rank" ? "Which candidate best achieves the goal, judged on its documents?"
                                    : "Which way should the graph go next, given the goal, the work and the checks?")
            out += askedViews("The question", question: q, width: width)
            out += optionViews(j.probabilities, chosen: chosen, optionText: j.optionText, width: width, describe: j.mode == "decide")
            var facts: [String] = []
            if let t = j.take, j.mode == "decide" { facts.append("it takes a route at \(pct(t)) or more") }
            if let agree = j.ordersAgree { facts.append(agree ? "both option orders agreed" : "the option orders disagreed") }
            if !facts.isEmpty { out.append(hint(facts.joined(separator: " · "), width: width)) }
        default:
            if !j.lines.isEmpty {
                out.append(hint("Each checklist line is a question Jev answered about the work, weakest first.", width: width))
                out.append(contentsOf: lineViews(j.lines, width: width))
            }
        }
        var foot: [String] = []
        if !j.model.isEmpty { foot.append(j.model) }
        if j.ms > 0 { foot.append("\(j.ms) ms") }
        if j.truncated { foot.append("document cut to fit") }
        for (k, c) in j.redactions { foot.append("\(c) \(k)\(c == 1 ? "" : "s") hidden") }
        if !foot.isEmpty { out.append(hint(foot.joined(separator: " · "), width: width)) }
        for (f, why) in j.withheld.prefix(4) {
            out.append(hint("not sent: \((f as NSString).lastPathComponent) — \(why)", width: width))
        }
        return out
    }

    // MARK: Timeline

    private func renderTimeline() {
        guard let g = current else {
            timelineDoc.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let events = Array(g.recent.filter { $0.event != "route" || $0.outcome == "bounded" }.reversed())
        let chevron = activityOpen ? "chevron.down" : "chevron.right"
        timelineChevron.image = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        timelineChevron.contentTintColor = PongColor.textTertiary
        let head = NSMutableAttributedString(attributedString: PongType.eyebrowString("Activity"))
        var bits = [" · " + Words.plural(events.count, "event")]
        if let last = events.first { bits.append("last " + PongUI.ago(last.at)) }
        head.append(NSAttributedString(string: bits.joined(separator: " · "), attributes: [.font: PongType.meta, .foregroundColor: PongColor.textTertiary]))
        timelineTitle.attributedStringValue = head
        guard activityOpen else { return }

        // a running step gets a "now" line on top: what its screen shows (the engine reads it every 30 s);
        // one held still by a pause (Claude's limits, or its team is stopped) has no "now"
        let still = pauseState(g).still
        let running = g.isRunning && !still ? g.nodes.filter { $0.status == "running" && !$0.isSeatless } : []
        let order = ["no_model": 0, "quiet": 1]
        let rank: (GNode) -> Int = { order[$0.liveState] ?? 2 }
        let live = Array(running.sorted { rank($0) < rank($1) }.prefix(2))
        var sig = g.key + "|\(g.recent.count)|\(g.recent.last?.at ?? 0)|\(Int(Date().timeIntervalSince1970 / 15))|\(still)"
        sig += running.map { "\($0.id):\($0.liveState):\($0.liveDoing):\($0.liveChangedAt ?? 0)" }.joined()
        guard sig != lastTimelineSig else { return }
        lastTimelineSig = sig
        timelineDoc.subviews.forEach { $0.removeFromSuperview() }
        func row(_ time: String, _ timeColor: NSColor, _ status: PongStatus, _ step: String, _ event: String, _ eventColor: NSColor,
                 _ summary: String, click: @escaping () -> Void) {
            let r = ClickRow()
            r.divider = false
            r.inset = 8
            r.onClick = click
            let t = label(time, size: 11, color: timeColor, mono: true)
            t.frame = NSRect(x: 24, y: 6, width: 84, height: 16)
            let m = StatusMarkerView(status, size: 12)
            m.frame = NSRect(x: 112, y: 8, width: 12, height: 12)
            let who = label(step, size: 12, weight: .medium, color: PongColor.textPrimary)
            who.frame = NSRect(x: 132, y: 5, width: 150, height: 17)
            let what = label(event, size: 12, color: eventColor)
            what.frame = NSRect(x: 288, y: 5, width: 130, height: 17)
            let sm = label(summary, size: 12, color: PongColor.textSecondary)
            sm.frame = NSRect(x: 424, y: 5, width: 400, height: 17)
            sm.identifier = NSUserInterfaceItemIdentifier("summary")
            sm.lineBreakMode = .byTruncatingTail
            for v in [t, m, who, what, sm] as [NSView] { r.addSubview(v) }
            timelineDoc.addSubview(r)
        }
        for n in live {
            var line = n.liveDoing.isEmpty ? "waiting for its first screen reading" : n.liveDoing
            if let c = n.liveChangedAt { line += " · updated \(GraphTime.ago(c))" }
            row("now", PongColor.live, n.pongStatus(graphRunning: true), Words.name(n.id),
                n.liveWord.isEmpty ? "started" : n.liveWord, liveColor(n), line) { [weak self] in self?.selectNode(n.id) }
        }
        // repeats of the same step and event merge into one line ("×3")
        var i = 0
        while i < events.count {
            let e = events[i]
            var j = i + 1
            while j < events.count, events[j].node == e.node, events[j].event == e.event, events[j].outcome == e.outcome { j += 1 }
            let times = j - i
            let word = eventWord(e) + (times > 1 ? " ×\(times)" : "")
            let st: PongStatus = {
                switch e.event {
                case "gate_open", "seat": return .needsYou
                case "dispatch": return .working
                case "cancel": return .stopped
                default:
                    if ["fail", "error", "lost", "timeout"].contains(e.outcome) || e.outcome.hasPrefix("failed") { return .failed }
                    return .done
                }
            }()
            let when = Calendar.current.isDateInToday(Date(timeIntervalSince1970: e.at)) ? PongUI.clock(e.at) : PongUI.ago(e.at)
            // the summary without the verdict word in front ("win: …"): the event column already says it
            row(when, PongColor.textTertiary, st, e.node.isEmpty ? "—" : Words.name(e.node), word, eventColor(e),
                Words.report(e.summary.replacingOccurrences(of: "\n", with: " "))) { [weak self] in
                if g.node(e.node) != nil { self?.selectNode(e.node) }
            }
            i = j
        }
        layoutTimelineDoc()
    }

    private func layoutTimelineDoc() {
        let w = timelineScroll.bounds.width
        var y: CGFloat = 0
        for v in timelineDoc.subviews {
            v.frame = NSRect(x: 0, y: y, width: w, height: 28)
            for s in v.subviews where s.identifier?.rawValue == "summary" { s.frame.size.width = max(80, w - 424 - 24) }
            y += 28
        }
        timelineDoc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 8, timelineScroll.bounds.height))
    }

    private func eventWord(_ e: GEvent) -> String {
        // an outcome in words ("win" → "passed", "fail" → "didn't pass"), a route as an arrow
        let said = e.outcome.hasPrefix("route:") ? e.outcome.replacingOccurrences(of: "route:", with: "→ ")
                                                 : Words.outcome(e.outcome).lowercased()
        switch e.event {
        case "dispatch": return "started"
        case "gate_open": return "asks you"
        case "gate_answer": return "you: " + said
        case "retry": return "retry"
        case "join": return "joined · " + said
        case "check": return "check · " + said
        case "jev": return "Jev · " + said
        case "stop": return "graph · " + said
        case "held": return "held"
        case "cancel": return "cancelled"
        case "merged": return "merged"
        case "takeover": return "taken over"
        case "progress": return "file " + e.outcome
        case "seat": return e.outcome == "attention" ? "needs you" : e.outcome
        default: return said
        }
    }

    private func liveColor(_ n: GNode) -> NSColor {
        switch n.liveState {
        case "working": return PongColor.live
        case "quiet": return PongColor.textSecondary
        case "no_model": return PongColor.fail
        default: return PongColor.textSecondary
        }
    }

    private func eventColor(_ e: GEvent) -> NSColor {
        switch e.event {
        case "gate_open", "seat": return PongColor.you
        case "dispatch": return PongColor.live
        default:
            if ["fail", "error", "lost", "timeout"].contains(e.outcome) || e.outcome.hasPrefix("failed") || e.outcome.hasPrefix("no_edge") { return PongColor.fail }
            return PongColor.textSecondary
        }
    }

    // MARK: Actions

    private func confirmCancel(_ g: GGraph) {
        PongAlert.confirmStopGraph(g, on: window) {
            GraphActions.stop(g) { ok, err in
                Toast.show(ok ? "Stopped: \(g.displayTitle)."
                              : GraphActions.failure(err, "Couldn't stop \(g.displayTitle). Try again in a moment.", log: "stop \(g.key)"),
                           warn: !ok)
            }
        }
    }

    /// Attach one of the research templates (build-verify, fan-out, best-of-N,
    /// scout panel, tournament, planner sprints) under a team's lead.
    func startFromTemplate() { fromTemplate() }

    private func fromTemplate() {
        GraphCLI.run(["graph", "examples", "--json"], timeout: 15) { [weak self] r in
            guard let self else { return }
            guard let data = r.out.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else {
                Toast.show(GraphActions.failure(r.err, "Couldn't list the templates. Try again in a moment.", log: "graph examples"),
                           warn: true)
                return
            }
            let teams = PairState.listPairs()
            let a = NSAlert()
            a.messageText = "Start from a template"
            a.informativeText = "Pick a graph, a team, and what done looks like."
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 196))
            func cap(_ t: String, _ y: CGFloat) {
                let l = NSTextField(labelWithString: t)
                l.font = PongType.eyebrow
                l.textColor = PongTheme.textSecondary
                l.frame = NSRect(x: 0, y: y, width: 420, height: 14)
                box.addSubview(l)
            }
            cap("TEMPLATE", 180)
            let tpl = NSPopUpButton(frame: NSRect(x: 0, y: 152, width: 420, height: 26), pullsDown: false)
            for row in rows {
                tpl.addItem(withTitle: "\(Words.name(GJ.str(row["name"]))) · \(GJ.int(row["nodes"])) steps")
                tpl.lastItem?.toolTip = GJ.str(row["notes"])
                tpl.lastItem?.representedObject = GJ.str(row["path"])
            }
            if let i = rows.firstIndex(where: { GJ.str($0["name"]) == "build-verify" }) { tpl.selectItem(at: i) }
            box.addSubview(tpl)
            cap("TEAM", 132)
            let team = NSPopUpButton(frame: NSRect(x: 0, y: 104, width: 420, height: 26), pullsDown: false)
            team.addItems(withTitles: teams.isEmpty ? ["No team yet: start one with New graph"] : teams)
            if let cur = self.current?.session, let i = teams.firstIndex(of: cur) { team.selectItem(at: i) }
            box.addSubview(team)
            let owner = NSTextField(frame: NSRect(x: 310, y: 104, width: 110, height: 24))
            owner.stringValue = self.current?.owner ?? "c1"
            owner.placeholderString = "c1"
            owner.isHidden = true  // the lead seat is for engineers: c1 unless changed in Terminal
            box.addSubview(owner)
            cap("WHAT DOES DONE LOOK LIKE?", 84)
            let goal = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
            goal.placeholderString = "e.g. The intake form works and all tests pass."
            goal.lineBreakMode = .byWordWrapping
            goal.usesSingleLineMode = false
            goal.cell?.wraps = true
            goal.cell?.isScrollable = false
            box.addSubview(goal)
            a.accessoryView = box
            a.addButton(withTitle: "Start")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = goal
            guard a.runModal() == .alertFirstButtonReturn, !teams.isEmpty else { return }
            let path = (tpl.selectedItem?.representedObject as? String) ?? ""
            let text = goal.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let lead = owner.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !text.isEmpty else {
                Toast.show("Say what done looks like: every step reads it first.", warn: true)
                return
            }
            let session = team.titleOfSelectedItem ?? ""
            Toast.show("Starting \(Words.name(((path as NSString).lastPathComponent as NSString).deletingPathExtension))…")
            GraphCLI.run(["-s", session, "graph", "attach", "--owner", lead.isEmpty ? "c1" : lead, "--file", path, "--task", text],
                         timeout: 120) { [weak self] r in
                guard let self else { return }
                if r.code == 0 {
                    let first = r.out.split(separator: "\n").first.map(String.init) ?? "started"
                    Toast.show("Started.")
                    if let gid = first.split(separator: " ").dropFirst().first {
                        self.openGraph(session + "/" + gid, tab: .steps)
                    }
                } else {
                    Toast.show(GraphActions.failure(r.err.isEmpty ? r.out : r.err,
                                                    "The graph didn't start on \(TeamNames.name(session)). Try again in a moment.",
                                                    log: "graph attach on \(session)"), warn: true)
                }
                self.refresh()
            }
        }
    }

    /// A graph's chat: its architect's, or a new architect started for it (it reads the graph first).
    func openChat(for g: GGraph) {
        if let a = architects.first(where: { $0.id == g.architectId && $0.session == g.session }) {
            selectedChat = a.key
            lastInspectorSig = ""
            onNavigate?(.chats)
            return
        }
        Toast.show("Opening a chat for \(g.displayTitle)…")
        GraphCLI.run(["-s", g.session, "architect", "start", "--graph", g.id, "--title", g.displayTitle, "--json"],
                     timeout: 60) { [weak self] r in
            guard let self else { return }
            switch ArchitectStart.read(out: r.out, err: r.err) {
            case .failed(let why):
                // the toast wraps to three lines, so the fix at the end of the sentence is read too
                Toast.show(why, warn: true)
                Pong.log("architect start failed: \(r.err.isEmpty ? r.out : r.err)")
            case .opened(let key, let warning):
                if let warning {
                    Pong.log("architect start for \(g.key): \(warning)")
                    Toast.show(warning, warn: true)
                }
                self.selectedChat = key
                self.onNavigate?(.chats)
                self.refresh()
            }
        }
    }

    private func renderChatInspector(_ a: GArchitect) {
        let teamUp = SchedulesPageView.runningTeams.contains(a.session)
        var sig = "chat|" + a.key + "\(a.alive)\(a.queued)\(teamUp)|" + a.graphs.joined(separator: ",") + "|\(detailsOpen)|\(Int(inspExpandedW))"
        for gid in a.graphs { sig += graphs.first { $0.id == gid && $0.session == a.session }?.plainStatus ?? "" }
        guard sig != lastInspectorSig else { return }
        lastInspectorSig = sig
        inspStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = inspExpandedW - 40
        setInspKind("Chat")
        // a stopped chat says how it comes back: the same choice as the button at the top
        let gone: String
        if teamUp {
            gone = "Its terminal is gone. Start a new chat (the button at the top): it reads its graph first."
        } else if isLeadChat(a) {
            gone = "Its terminal is gone because its team is stopped. Start its team (the button at the top): its AI comes back on this chat."
        } else {
            gone = "Its terminal is gone and its team is stopped. Start its team (the button at the top), then start a new chat: it reads its graph first."
        }
        add(para(a.alive ? "Type in its terminal and press Enter. Its graphs' news arrives there too, as lines starting [CyberPong]." : gone,
                 width: width, color: PongColor.textSecondary, size: 12))

        add(section("Its graphs"))
        if a.graphs.isEmpty {
            add(hint("None yet. Ask it to design one: the graph shows up here when it starts it.", width: width))
        }
        for gid in a.graphs.reversed() {
            let g = graphs.first { $0.id == gid && $0.session == a.session }
            add(dotRow(g?.displayTitle ?? gid, status: g?.plainStatus ?? "not in the recent list", extra: "",
                       color: g?.pongStatus.color ?? PongColor.textTertiary, width: width,
                       tip: "Open this graph") { [weak self] in
                guard let self else { return }
                self.selectedKey = a.session + "/" + gid
                self.selectedNode = nil
                self.onNavigate?(.graphs)
            })
        }

        if !a.cwd.isEmpty {
            add(section("Folder"))
            add(fileLink(a.cwd, detail: "") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.cwd)]) })
        }

        add(detailsToggle("the AI, its team and how the chat works"))
        if detailsOpen {
            add(kv([("ai", Words.ai(a.runtime, a.model)), ("team", a.session), ("seat", a.seat),
                    ("started", GraphTime.ago(a.createdAt)), ("updates waiting", a.queued == 0 ? "none" : "\(a.queued), sent when it is idle")], width: width))
            add(eyebrow("How it works"))
            add(hint("It is a real terminal: the keys answer its menus. Its graphs' news (a question opened, a step needs a look, "
                     + "a step went quiet, the graph finished) arrives as one line, sent when it is idle. ⌃Tab leaves the terminal. "
                     + "History shows everything that went into this chat.", width: width))
            add(eyebrow("For engineers"))
            add(mono("pong -s \(a.session) architect log --id \(a.id)", width: width))
        }
        finishInspector()
    }

    private func openPath(_ path: String, session: String) {
        let expanded = (path as NSString).expandingTildeInPath
        var candidates = [expanded]
        if !expanded.hasPrefix("/") {
            candidates.append(NSHomeDirectory() + "/" + expanded)
        }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            NSWorkspace.shared.open(URL(fileURLWithPath: c))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Toast.show("Not on this Mac. The path is copied.", warn: true)
    }

    // MARK: Small views

    private func add(_ v: NSView) { inspStack.addArrangedSubview(v) }

    private func hint(_ s: String, width: CGFloat) -> NSTextField {
        para(s, width: width, color: PongColor.textTertiary, size: 11)
    }

    /// A section of the inspector: an eyebrow with 12 pt more room above it.
    private func section(_ s: String, color: NSColor = PongColor.textTertiary) -> NSView {
        let f = eyebrow(s, color: color)
        let holder = NSStackView(views: [f])
        holder.orientation = .vertical
        holder.alignment = .leading
        holder.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        return holder
    }

    private func setInspKind(_ s: String) {
        inspKind.attributedStringValue = PongType.eyebrowString(s)
    }

    /// A file as a link: a document glyph and its name in the data face, cyan.
    private func fileLink(_ name: String, detail: String, onPress: @escaping () -> Void) -> NSView {
        let b = linkButton(name + (detail.isEmpty ? "" : "  ·  " + detail), onPress: onPress)
        b.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        b.imagePosition = .imageLeading
        b.contentTintColor = PongColor.live
        return b
    }

    private func buttonRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @discardableResult
    private func tipped<B: NSButton>(_ b: B, _ tip: String) -> B {
        b.toolTip = tip
        return b
    }

    /// A clickable line in the details: a status dot, a name, its status and a quiet extra (the AI).
    private func dotRow(_ name: String, status: String, extra: String, color: NSColor, width: CGFloat,
                        tip: String, onClick: @escaping () -> Void) -> NSView {
        let row = ClickRow()
        row.inset = 1
        row.divider = false
        row.toolTip = tip
        row.onClick = onClick
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let dot = NSView(frame: NSRect(x: 7, y: 9, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = color.cgColor
        row.addSubview(dot)
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: PongType.sf(12, .medium), .foregroundColor: PongColor.textPrimary])
        text.append(NSAttributedString(string: "  " + status, attributes: [.font: PongType.sf(12), .foregroundColor: color]))
        if !extra.isEmpty {
            text.append(NSAttributedString(string: " · " + extra, attributes: [.font: PongType.sf(12), .foregroundColor: PongColor.textTertiary]))
        }
        let l = NSTextField(labelWithAttributedString: text)
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: 20, y: 4, width: width - 24, height: 16)
        row.addSubview(l)
        return row
    }

    /// The fold for the technical facts. It stays open or closed from one selection to the next.
    private func detailsToggle(_ what: String) -> NSView {
        let holder = NSStackView()
        holder.orientation = .vertical
        holder.alignment = .leading
        holder.spacing = 6
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = PongColor.hairline.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: inspExpandedW - 40).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        holder.addArrangedSubview(rule)
        let b = ActionButton("Details") { [weak self] in
            guard let self else { return }
            self.detailsOpen.toggle()
            UserDefaults.standard.set(self.detailsOpen, forKey: "graphs.detailsOpen")
            self.lastInspectorSig = ""
            self.renderInspector()
        }
        b.layer?.borderWidth = 0
        b.image = NSImage(systemSymbolName: detailsOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        b.imagePosition = .imageLeading
        b.contentTintColor = PongColor.textTertiary
        b.attributedTitle = PongType.eyebrowString(" Details")
        b.toolTip = detailsOpen ? "Fold the details away" : "Show \(what)"
        holder.addArrangedSubview(b)
        return holder
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                       mono: Bool = false, wrap: Bool = false) -> NSTextField {
        let f = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
        f.font = mono ? PongTheme.mono(size, weight: .regular) : PongTheme.font(size, weight: weight)
        f.textColor = color
        f.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        f.drawsBackground = false
        f.isBezeled = false
        return f
    }

    private func eyebrow(_ s: String, color: NSColor? = nil) -> NSTextField {
        let f = label("", size: 11, color: color ?? PongColor.textTertiary)
        f.attributedStringValue = PongType.eyebrowString(s, color: color ?? PongColor.textTertiary)
        return f
    }

    private func para(_ s: String, width: CGFloat, color: NSColor = PongTheme.textSecondary, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular) -> NSTextField {
        let f = label(s, size: size, weight: weight, color: color, wrap: true)
        f.preferredMaxLayoutWidth = width
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        f.isSelectable = true
        return f
    }

    private func mono(_ s: String, width: CGFloat) -> NSTextField {
        let f = label(s, size: 11, color: PongColor.textSecondary, mono: true, wrap: true)
        f.preferredMaxLayoutWidth = width
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        f.isSelectable = true
        return f
    }

    private func kv(_ rows: [(String, String)], width: CGFloat) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        for (k, v) in rows {
            let kf = label(k.prefix(1).uppercased() + k.dropFirst(), size: 11, color: PongColor.textTertiary)
            let vf = label(v, size: 12, color: PongColor.textPrimary)
            vf.lineBreakMode = .byTruncatingMiddle
            vf.translatesAutoresizingMaskIntoConstraints = false
            vf.widthAnchor.constraint(lessThanOrEqualToConstant: width - 90).isActive = true
            grid.addRow(with: [kf, vf])
        }
        grid.column(at: 0).width = 96
        return grid
    }

    private func linkButton(_ title: String, onPress: @escaping () -> Void) -> NSButton {
        let b = ActionButton(title) { onPress() }
        b.layer?.borderWidth = 0
        b.alignment = .left
        // a long path is cut in the middle to fit the column: the button's own "as wide as
        // its title" floor is required, so it goes, and the column decides the width
        for c in b.constraints where c.firstAttribute == .width && c.relation == .greaterThanOrEqual { c.isActive = false }
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.toolTip = title
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingMiddle
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongColor.live, .font: PongType.sf(12), .paragraphStyle: para,
        ])
        b.layer?.backgroundColor = NSColor.clear.cgColor
        return b
    }
}

private extension NSStackView {
    /// Keep the inspector stack as wide as its column.
    func widthAnchorConstraint(_ w: CGFloat) {
        if let c = constraints.first(where: { $0.identifier == "studio-width" }) {
            c.constant = w
        } else {
            let c = widthAnchor.constraint(equalToConstant: w)
            c.identifier = "studio-width"
            c.isActive = true
        }
    }
}

// MARK: - New chat form

/// Name, AI and model for a new graph's architect. The AIs are the ones installed on this Mac and the models
/// each offers (`pong model list`), so a pick here is one the seat can run.
private final class NewChatForm: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 90))
    let name = NSTextField(frame: NSRect(x: 0, y: 62, width: 400, height: 24))
    private let provider = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 196, height: 26), pullsDown: false)
    private let modelPop = NSPopUpButton(frame: NSRect(x: 204, y: 30, width: 196, height: 26), pullsDown: false)
    private let hint = NSTextField(labelWithString: "")
    private var models: [String: [String]] = [:]
    private var defaults: [String: String] = [:]
    private var labels: [String: String] = [:]

    override init() {
        super.init()
        name.placeholderString = "Name, e.g. Intake app"
        hint.frame = NSRect(x: 0, y: 4, width: 400, height: 18)
        hint.font = PongTheme.font(10.5)
        hint.textColor = PongTheme.textTertiary
        hint.stringValue = "The AI and model it starts on. Claude's model can be switched later from the chat."
        for v in [name, provider, modelPop, hint] as [NSView] { view.addSubview(v) }
        let r = GraphCLI.runSync(["model", "list", "--json"], timeout: 20)
        var available: [String] = []
        if let data = r.out.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            available = GJ.strings(obj["available"])
            for (rt, info) in GJ.dict(obj["runtimes"]) {
                let d = GJ.dict(info)
                models[rt] = Array(GJ.dict(d["models"]).keys).sorted()
                defaults[rt] = GJ.str(d["default_model"])
                labels[rt] = GJ.str(d["label"]).isEmpty ? rt : GJ.str(d["label"])
            }
        }
        if available.isEmpty { available = ["claude"] }
        for rt in available {
            provider.addItem(withTitle: labels[rt] ?? rt)
            provider.lastItem?.representedObject = rt
        }
        provider.target = self
        provider.action = #selector(providerChanged)
        providerChanged()
    }

    @objc private func providerChanged() {
        modelPop.removeAllItems()
        let rt = runtime ?? "claude"
        let list = models[rt] ?? []
        if list.isEmpty { modelPop.addItem(withTitle: "its default") }
        for m in list {
            modelPop.addItem(withTitle: m == defaults[rt] ? "\(m) (default)" : m)
            modelPop.lastItem?.representedObject = m
        }
        if let d = defaults[rt], let i = list.firstIndex(of: d) { modelPop.selectItem(at: i) }
    }

    var runtime: String? { provider.selectedItem?.representedObject as? String }
    var model: String? { modelPop.selectedItem?.representedObject as? String }
}

// MARK: - Architect chat: a terminal inside CyberPong

/// tmux, called directly: a keystroke cannot wait for a `pong` process to start.
private enum TmuxIO {
    @discardableResult
    static func run(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pong.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// tmux already is the terminal emulator: it keeps the pane's screen drawn, colours included.
/// `capture-pane -e` hands that screen over with its SGR colour codes; this turns them into text.
private enum ANSI {
    /// The terminal's 16 colours (design-language.md §3, Terminal frame): all ≥5.4:1 on the void.
    private static let base: [(CGFloat, CGFloat, CGFloat)] = [
        (42, 51, 66), (255, 122, 110), (143, 214, 160), (245, 196, 81), (122, 167, 255), (255, 110, 199), (76, 214, 224), (170, 178, 190),
        (122, 134, 153), (255, 138, 127), (163, 226, 178), (248, 210, 118), (150, 186, 255), (255, 140, 211), (120, 226, 234), (236, 231, 220),
    ]

    static func color256(_ n: Int) -> NSColor {
        if n < 16 { let c = base[max(0, n)]; return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1) }
        if n < 232 {
            let i = n - 16
            func v(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(srgbRed: v(i / 36), green: v((i / 6) % 6), blue: v(i % 6), alpha: 1)
        }
        let g = CGFloat(8 + (min(n, 255) - 232) * 10) / 255
        return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
    }

    struct Style {
        var fg: NSColor?
        var bg: NSColor?
        var bold = false, dim = false, italic = false, underline = false, inverse = false
    }

    static func apply(_ params: String, _ st: inout Style) {
        let n = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < n.count {
            let c = n[i]
            switch c {
            case 0: st = Style()
            case 1: st.bold = true
            case 2: st.dim = true
            case 3: st.italic = true
            case 4: st.underline = true
            case 7: st.inverse = true
            case 22: st.bold = false; st.dim = false
            case 23: st.italic = false
            case 24: st.underline = false
            case 27: st.inverse = false
            case 30...37: st.fg = color256(c - 30)
            case 39: st.fg = nil
            case 40...47: st.bg = color256(c - 40)
            case 49: st.bg = nil
            case 90...97: st.fg = color256(c - 90 + 8)
            case 100...107: st.bg = color256(c - 100 + 8)
            case 38, 48:
                var col: NSColor?
                if i + 2 < n.count, n[i + 1] == 5 { col = color256(n[i + 2]); i += 2 }
                else if i + 4 < n.count, n[i + 1] == 2 {
                    col = NSColor(srgbRed: CGFloat(n[i + 2]) / 255, green: CGFloat(n[i + 3]) / 255, blue: CGFloat(n[i + 4]) / 255, alpha: 1)
                    i += 4
                }
                if c == 38 { st.fg = col } else { st.bg = col }
            default: break
            }
            i += 1
        }
    }

    static func attrs(_ st: Style, font: NSFont, bold: NSFont, fg: NSColor, bg: NSColor, cursor: Bool = false) -> [NSAttributedString.Key: Any] {
        var f = st.fg ?? fg
        var b = st.bg
        if cursor {
            // the cursor: a cyan block at 60%, its character on the void
            b = PongColor.live.withAlphaComponent(0.6)
            f = PongColor.void
        } else if st.inverse { let fb = b ?? bg; b = f; f = fb }
        if st.dim { f = f.withAlphaComponent(0.6) }
        var a: [NSAttributedString.Key: Any] = [.font: st.bold ? bold : font, .foregroundColor: f]
        if let b { a[.backgroundColor] = b }
        if st.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if st.italic { a[.obliqueness] = 0.15 }
        return a
    }

    /// The captured screen as text, the cursor's cell drawn inverted (line and column in the capture).
    static func render(_ text: String, font: NSFont, bold: NSFont, fg: NSColor, bg: NSColor, cursor: (line: Int, col: Int)?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var st = Style()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (li, line) in lines.enumerated() {
            var col = 0
            var cursorDrawn = false
            var runText = ""
            func flush() {
                if !runText.isEmpty { out.append(NSAttributedString(string: runText, attributes: attrs(st, font: font, bold: bold, fg: fg, bg: bg))); runText = "" }
            }
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if ch == "\u{1B}" {
                    if i + 1 < chars.count, chars[i + 1] == "[" {
                        var j = i + 2
                        var params = ""
                        while j < chars.count, !(chars[j].isLetter) { params.append(chars[j]); j += 1 }
                        flush()
                        if j < chars.count, chars[j] == "m" { apply(params, &st) }
                        i = j + 1
                        continue
                    }
                    i += 1
                    continue
                }
                if let c = cursor, c.line == li, c.col == col, !cursorDrawn {
                    flush()
                    out.append(NSAttributedString(string: String(ch), attributes: attrs(st, font: font, bold: bold, fg: fg, bg: bg, cursor: true)))
                    cursorDrawn = true
                } else {
                    runText.append(ch)
                }
                col += 1
                i += 1
            }
            flush()
            if let c = cursor, c.line == li, !cursorDrawn, c.col >= col {
                out.append(NSAttributedString(string: String(repeating: " ", count: c.col - col), attributes: attrs(Style(), font: font, bold: bold, fg: fg, bg: bg)))
                out.append(NSAttributedString(string: " ", attributes: attrs(Style(), font: font, bold: bold, fg: fg, bg: bg, cursor: true)))
            }
            if li < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        return out
    }
}

/// The terminal's text: read-only to the text system, every key goes to the pane instead.
private final class TerminalTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?
    var onPaste: ((String) -> Void)?
    var onFocus: ((Bool) -> Void)?
    /// A wheel turn or a trackpad swipe: true when the pane took it (ArchitectChatView.wheel).
    var onWheel: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        if onWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }
    override func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty { onPaste?(s) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v", window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A graph architect's chat inside CyberPong: a terminal on its tmux pane.
///
/// The architect is an AI command line (Claude Code, Grok Build, Codex) in the team's tmux. tmux keeps its
/// screen drawn; this view shows that screen, colours and cursor included, a few times a second, and sends
/// every key pressed in it straight to the pane: letters, Enter, arrows, Tab, Esc, Ctrl-keys, and a paste as
/// one bracketed paste (a multi-line paste must not press Enter at each line). So everything the AI's own
/// command line offers works here: its /model and /login menus, its questions, its history. The window is
/// sized to this view, so the AI lays itself out at the width you see. The graph's news arrives in the same
/// terminal as lines starting "[CyberPong]", so the person's chat and the graphs' events are one conversation.
private final class ArchitectChatView: NSView {
    var onToast: ((String, Bool) -> Void)?
    /// Hide the chat and bring the graph back to the middle. The chat keeps running in its terminal.
    var onClose: (() -> Void)?
    private(set) var architect: GArchitect?
    private var poll: Timer?
    private var inFlight = false
    private var lastRaw = ""
    private var pending = ""        // characters typed, sent as one literal a moment later
    private var typedLine = ""      // the line typed since the last Enter, for the chat log
    private var flushWork: DispatchWorkItem?
    private var lastSize = (cols: 0, rows: 0)
    /// Claude Code's full-screen mode draws on tmux's alternate screen, where tmux keeps no history: the
    /// capture is only what is on screen now, so there is nothing above it to scroll to. The AI scrolls its
    /// own transcript instead; while the pane is on that screen and takes mouse events, a scroll here goes
    /// to it the way a mouse wheel over the terminal would.
    private var appScrolls = false
    private var wheelAccum: CGFloat = 0
    /// The words shown in the terminal's place while there is no terminal ("" = none shown).
    private var placeholder = ""

    /// A stopped chat, in the terminal's place: what the window bar's one button is and what it does
    /// (GraphStudioView.restartChatButton). A chat that is its team's lead comes back with its team.
    static func goneWords(_ a: GArchitect, teamUp: Bool) -> String {
        if !teamUp {
            let lead = !a.seat.isEmpty && !a.seat.contains(".")
            return "This chat's terminal is gone: its team is stopped. Start its team, at the top, "
                + (lead ? "and this chat comes back." : "then Start a new chat there.")
        }
        return "This chat's terminal is gone. Start a new chat, at the top: "
            + (a.graphs.isEmpty ? "it opens on the same team." : "it reads this chat's graph first.")
    }

    private let scroll = NSScrollView()
    private let term = TerminalTextView()
    private let footerHint = NSTextField(labelWithString: "")
    private let historyBtn = PongButton(title: "History", style: .quiet, size: .small)
    private let frameMarks = MarksView()
    private var termFont = PongType.terminal
    private var termBold = PongTheme.mono(13, weight: .semibold)
    /// The models each AI offers (`pong model list`), for the ⋯ menu.
    private(set) var models: [String: [String]] = [:]

    /// Registration marks around the terminal: cyan while it has the keyboard.
    private final class MarksView: NSView {
        var focused = false { didSet { needsDisplay = true } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            PongTheme.drawCornerBrackets(in: bounds.insetBy(dx: 6, dy: 6), color: focused ? PongColor.live : PongColor.mark, arm: 8, line: 1)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        term.isEditable = false
        term.isSelectable = true
        term.isRichText = true
        term.font = termFont
        term.textContainerInset = NSSize(width: 4, height: 4)
        term.isHorizontallyResizable = true
        term.textContainer?.widthTracksTextView = false
        term.textContainer?.containerSize = NSSize(width: 6000, height: CGFloat.greatestFiniteMagnitude)
        term.maxSize = NSSize(width: 6000, height: CGFloat.greatestFiniteMagnitude)
        term.autoresizingMask = [.height]
        term.selectedTextAttributes = [.backgroundColor: PongColor.live.withAlphaComponent(0.25)]
        term.onKey = { [weak self] e in self?.key(e) ?? false }
        term.onPaste = { [weak self] s in self?.pasteText(s) }
        term.onFocus = { [weak self] on in self?.frameMarks.focused = on }
        term.onWheel = { [weak self] e in self?.wheel(e) ?? false }
        scroll.documentView = term
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.scrollerStyle = .overlay
        footerHint.stringValue = "Scroll to read back · ⌃O the whole transcript · ⌃Tab leaves the terminal"
        footerHint.font = PongType.meta
        footerHint.textColor = PongColor.textTertiary
        historyBtn.toolTip = "Everything that went into this chat, and where the AI's own transcript is"
        historyBtn.onPress = { [weak self] in self?.showLog() }
        for v in [scroll, frameMarks, footerHint, historyBtn] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        retheme()
        loadModels()
    }

    func retheme() {
        layer?.backgroundColor = PongColor.void.cgColor
        term.backgroundColor = PongColor.void
        scroll.backgroundColor = PongColor.void
        lastRaw = ""
    }

    /// The models each AI offers, from `pong model list` (the same list the teams use).
    private func loadModels() {
        GraphCLI.run(["model", "list", "--json"], timeout: 20) { [weak self] r in
            guard let self, let data = r.out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            for (rt, info) in GJ.dict(obj["runtimes"]) {
                self.models[rt] = Array(GJ.dict(GJ.dict(info)["models"]).keys).sorted()
            }
        }
    }

    func show(_ a: GArchitect) {
        let changed = architect?.key != a.key
        architect = a
        // the terminal's keys mean nothing without a terminal
        footerHint.isHidden = !a.alive
        if changed {
            lastRaw = ""
            lastSize = (0, 0)
            term.string = ""
            needsLayout = true
            refreshScreen()
            window?.makeFirstResponder(term)
        }
        if poll == nil { startPoll() }
    }

    func startPoll() {
        stopPoll()
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.refreshScreen() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func stopPoll() {
        poll?.invalidate()
        poll = nil
    }

    private func refreshScreen() {
        guard !inFlight, let a = architect, !isHidden, !a.paneId.isEmpty else {
            // what stands in for the terminal; it follows the window bar's one button as that changes
            // (the team starts: "Start its team" becomes "Start a new chat")
            if let a = architect, a.paneId.isEmpty, term.string.isEmpty || term.string == placeholder {
                let said = a.alive ? "Waiting for the terminal…" : Self.goneWords(a, teamUp: SchedulesPageView.runningTeams.contains(a.session))
                if said != term.string {
                    placeholder = said
                    term.textStorage?.setAttributedString(NSAttributedString(string: said,
                                                                            attributes: [.font: termFont, .foregroundColor: PongColor.textSecondary]))
                }
            }
            return
        }
        inFlight = true
        let pane = a.paneId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cap = TmuxIO.run(["capture-pane", "-p", "-e", "-t", pane, "-S", "-1500"])
            let cur = TmuxIO.run(["display-message", "-p", "-t", pane,
                                  "#{cursor_x} #{cursor_y} #{pane_height} #{alternate_on} #{mouse_sgr_flag}"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard cap.code == 0 else { return }
                let raw = cap.out + "|" + cur.out
                guard raw != self.lastRaw else { return }
                self.lastRaw = raw
                let parts = cur.out.split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                var cursor: (line: Int, col: Int)? = nil
                self.appScrolls = parts.count >= 5 && parts[3] == 1 && parts[4] == 1
                if parts.count >= 3 {
                    var total = cap.out.components(separatedBy: "\n").count
                    if cap.out.hasSuffix("\n") { total -= 1 }
                    cursor = (line: max(0, total - parts[2]) + parts[1], col: parts[0])
                }
                self.setScreen(ANSI.render(cap.out, font: self.termFont, bold: self.termBold, fg: PongColor.terminalText, bg: PongColor.void, cursor: cursor))
            }
        }
    }

    private func setScreen(_ s: NSAttributedString) {
        let atBottom = scroll.documentVisibleRect.maxY >= (term.frame.height - 40)
        let keepX = scroll.contentView.bounds.origin.x
        term.textStorage?.setAttributedString(s)
        if atBottom {
            term.scrollToEndOfDocument(nil)
            let clip = scroll.contentView
            let x = min(keepX, max(0, term.frame.width - clip.bounds.width))
            if clip.bounds.origin.x != x {
                clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    // MARK: keys

    /// One key to the pane. Characters wait a moment and go as one literal (a word typed fast is one
    /// send-keys, not ten); a named key flushes them first so the order holds.
    private func key(_ e: NSEvent) -> Bool {
        guard let a = architect, !a.paneId.isEmpty else { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }  // copy, select all, the app's own shortcuts
        if e.keyCode == 48 && flags.contains(.control) {  // ⌃Tab leaves the terminal
            window?.selectKeyView(following: term)
            return true
        }
        var named: String?
        switch e.keyCode {
        case 36, 76: named = "Enter"
        case 51: named = "BSpace"
        case 117: named = "DC"
        case 53: named = "Escape"
        case 48: named = flags.contains(.shift) ? "BTab" : "Tab"
        case 123: named = "Left"
        case 124: named = "Right"
        case 125: named = "Down"
        case 126: named = "Up"
        case 115: named = "Home"
        case 119: named = "End"
        case 116: named = "PPage"
        case 121: named = "NPage"
        default: break
        }
        if named == nil, flags.contains(.control), let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1, c.first!.isLetter {
            named = "C-" + c
        }
        if let named {
            flushPending()
            send(["send-keys", "-t", a.paneId, named])
            if named == "Enter" { logTypedLine() }
            else if named == "BSpace" { if !typedLine.isEmpty { typedLine.removeLast() } }
            else if named == "C-c" || named == "C-u" { typedLine = "" }
            soon()
            return true
        }
        guard let chars = e.characters, !chars.isEmpty else { return false }
        pending += chars
        typedLine += chars
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushPending() }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
        return true
    }

    /// A scroll over the terminal. On Claude Code's full screen it goes to the pane as xterm mouse-wheel
    /// events (SGR: button 64 up, 65 down, at the cell under the pointer), so the AI scrolls its transcript
    /// and the next capture shows it. A trackpad's fine deltas add up to whole wheel steps. Anywhere else the
    /// scroll view scrolls the captured history as before.
    private func wheel(_ e: NSEvent) -> Bool {
        guard appScrolls, let a = architect, !a.paneId.isEmpty else { return false }
        let dy = e.scrollingDeltaY
        guard dy != 0 else { return true }
        if wheelAccum != 0, (dy > 0) != (wheelAccum > 0) { wheelAccum = 0 }  // the direction changed
        wheelAccum += e.hasPreciseScrollingDeltas ? dy / 14 : dy
        let steps = Int(wheelAccum.rounded(.towardZero))
        guard steps != 0 else { return true }
        wheelAccum -= CGFloat(steps)
        let cell = cellAt(e)
        let one = "\u{1B}[<\(steps > 0 ? 64 : 65);\(cell.col);\(cell.row)M"
        send(["send-keys", "-t", a.paneId, "-l", String(repeating: one, count: min(abs(steps), 8))])
        soon()
        return true
    }

    /// The terminal cell under the pointer, 1-based, as a mouse event names it.
    private func cellAt(_ e: NSEvent) -> (col: Int, row: Int) {
        let p = term.convert(e.locationInWindow, from: nil)
        let cw = ("M" as NSString).size(withAttributes: [.font: termFont]).width
        let lh = NSLayoutManager().defaultLineHeight(for: termFont)
        guard cw > 0, lh > 0 else { return (1, 1) }
        let inset = term.textContainerInset
        let col = Int((p.x - inset.width) / cw) + 1
        let row = Int((p.y - inset.height) / lh) + 1
        let maxCol = lastSize.cols > 0 ? lastSize.cols : 300, maxRow = lastSize.rows > 0 ? lastSize.rows : 200
        return (max(1, min(col, maxCol)), max(1, min(row, maxRow)))
    }

    private func flushPending() {
        flushWork?.cancel()
        guard !pending.isEmpty, let a = architect else { return }
        let text = pending
        pending = ""
        send(["send-keys", "-t", a.paneId, "-l", text])
        soon()
    }

    /// A paste goes in as a paste: set-buffer, then paste-buffer -p, which the AI reads as one bracketed
    /// paste. Typed as keys, each newline would press Enter and send half the text.
    private func pasteText(_ s: String) {
        guard let a = architect, !a.paneId.isEmpty else { return }
        flushPending()
        let pane = a.paneId
        typedLine += s.replacingOccurrences(of: "\n", with: " ")
        DispatchQueue.global(qos: .userInitiated).async {
            TmuxIO.run(["set-buffer", "-b", "cyberpong-paste", "--", s])
            TmuxIO.run(["paste-buffer", "-p", "-d", "-b", "cyberpong-paste", "-t", pane])
        }
        soon()
    }

    private func send(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async { TmuxIO.run(args) }
    }

    /// The screen, soon after a key: typing must feel like typing.
    private func soon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.refreshScreen() }
    }

    /// The line the person typed goes to the chat log (the AI's own transcript has it too).
    private func logTypedLine() {
        let line = typedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        typedLine = ""
        guard !line.isEmpty, let a = architect else { return }
        GraphCLI.run(["architect", "note", "--id", a.id, "--text", line], timeout: 15) { _ in }
    }

    // MARK: header

    /// Claude Code switches its model in place (/model).
    func pickModel(_ m: String) {
        guard let a = architect, !a.paneId.isEmpty else { return }
        flushPending()
        send(["send-keys", "-t", a.paneId, "-l", "/model \(m)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.send(["send-keys", "-t", a.paneId, "Enter"])
            self?.onToast?("Asked \(Words.ai(a.runtime, "")) to switch to \(m).", false)
            self?.soon()
        }
    }

    /// Claude Code signs in from inside, so its /login runs here; the others sign in with their own login
    /// command in Terminal, the way a new team's seats do.
    func signIn() {
        guard let a = architect else { return }
        if a.runtime == "claude", !a.paneId.isEmpty {
            flushPending()
            send(["send-keys", "-t", a.paneId, "-l", "/login"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.send(["send-keys", "-t", a.paneId, "Enter"])
                self?.soon()
            }
            window?.makeFirstResponder(term)
            return
        }
        ProviderAuth.switchAccount(typeId: a.runtime) { [weak self] result in
            if case .failed(let msg) = result { self?.onToast?("Sign-in did not finish: \(msg)", true) }
            if case .missingCLI(let msg) = result { self?.onToast?(msg, true) }
        }
    }

    func openTerminal() {
        guard let a = architect else { return }
        if !a.paneId.isEmpty {  // hand the window's size back to tmux, so Terminal fits it to its own window
            TmuxIO.run(["set-option", "-w", "-t", a.paneId, "window-size", "latest"])
        }
        GraphCLI.run(["-s", a.session, "graph", "seat-view", "--seat", a.seat, "--json"], timeout: 15) { [weak self] r in
            let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
            guard let obj, GJ.bool(obj["ok"]) else {
                // the engine's reply goes to the log; the toast is its note when that is a sentence, else plain
                Pong.log("chat seat-view \(a.session)/\(a.seat) failed: \((r.out.isEmpty ? r.err : r.out).prefix(300))")
                let note = Words.engineSentence(GJ.str(obj?["note"]))
                self?.onToast?(a.alive ? (note ?? "Couldn't open the chat in Terminal. Try again in a moment.")
                                       : "This chat's terminal is gone, so there is nothing to open.", true)
                return
            }
            GraphCLI.openInTerminal("tmux attach-session -t '=" + GJ.str(obj["view"]) + ":'")
        }
    }

    /// What went into the chat from outside (the person's lines, CyberPong's news) and where the AI's own
    /// transcript is: the first place to look when a graph went wrong.
    func showLog() {
        guard let a = architect else { return }
        GraphCLI.run(["architect", "log", "--id", a.id], timeout: 30) { r in
            let alert = NSAlert()
            alert.messageText = "History · \(a.displayTitle)"
            alert.informativeText = "What went into this chat from outside, then where the AI's own transcript is on this Mac."
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 660, height: 360))
            let tv = NSTextView(frame: sv.bounds)
            tv.isEditable = false
            tv.font = PongType.data
            tv.string = r.out.isEmpty ? (r.err.isEmpty ? "(nothing logged yet)" : r.err) : r.out
            tv.autoresizingMask = [.width]
            sv.documentView = tv
            sv.hasVerticalScroller = true
            alert.accessoryView = sv
            alert.addButton(withTitle: "Close")
            alert.runModal()
        }
    }

    // MARK: layout

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        // the terminal in its frame, 16 pt in; a 24 pt footer under it
        let footer: CGFloat = 24
        frameMarks.frame = NSRect(x: 8, y: footer + 4, width: W - 16, height: H - footer - 12)
        scroll.frame = NSRect(x: 16, y: footer + 12, width: W - 32, height: max(60, H - footer - 28))
        historyBtn.frame = NSRect(x: W - 16 - historyBtn.intrinsicContentSize.width, y: 0, width: historyBtn.intrinsicContentSize.width, height: 24)
        footerHint.frame = NSRect(x: 20, y: 4, width: max(220, historyBtn.frame.minX - 32), height: 16)
        resizePane()
    }

    /// The pane takes this view's size, so the AI lays itself out at the width the person sees.
    private func resizePane() {
        guard let a = architect, !a.paneId.isEmpty else { return }
        let cell = ("M" as NSString).size(withAttributes: [.font: termFont])
        let lineH = NSLayoutManager().defaultLineHeight(for: termFont)
        guard cell.width > 0, lineH > 0 else { return }
        let cols = max(60, Int((scroll.contentSize.width - 12) / cell.width))
        let rows = max(15, Int((scroll.contentSize.height - 12) / lineH))
        guard cols != lastSize.cols || rows != lastSize.rows else { return }
        lastSize = (cols, rows)
        let pane = a.paneId
        DispatchQueue.global(qos: .utility).async {
            TmuxIO.run(["resize-window", "-t", pane, "-x", String(cols), "-y", String(rows)])
        }
    }
}
