import AppKit

// The app's frame (1.9): a left sidebar with the five areas and the teams, a 52 pt
// window bar with the breadcrumb and ⌘K, and a page header. design-language.md §3–4.

/// The five areas, in sidebar order (⌘1–5).
enum ShellArea: Int, CaseIterable {
    case home = 0, chats, graphs, teams, schedules

    var title: String {
        switch self {
        case .home: return "Needs you"
        case .chats: return "Chats"
        case .graphs: return "Graphs"
        case .teams: return "Teams"
        case .schedules: return "Schedules"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "diamond"
        case .chats: return "text.bubble"
        case .graphs: return "point.3.connected.trianglepath.dotted"
        case .teams: return "person.2"
        case .schedules: return "clock"
        }
    }

    var tip: String {
        switch self {
        case .home: return "Questions only you can answer, and what is working now (⌘1)"
        case .chats: return "Your chats: where an AI plans and runs graphs with you (⌘2)"
        case .graphs: return "Every graph on this Mac: work in steps (⌘3)"
        case .teams: return "Who is on each team and what each AI is doing (⌘4)"
        case .schedules: return "Everything that runs on its own, and when (⌘5)"
        }
    }
}

/// A team as the sidebar shows it.
struct ShellTeam {
    let id: String
    let name: String
    /// Its terminals are there: the test Teams and Schedules use (TeamsUp), so every page agrees.
    let running: Bool
    /// One of its graphs is at work: not waiting on the person, not held by a pause.
    let working: Bool
}

/// One clickable sidebar row: symbol, label, and a count or a word at the end.
private final class SidebarRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { restyle() } }
    var compact = false { didSet { needsLayout = true; restyle() } }
    private var hovering = false { didSet { restyle() } }
    private var tracking: NSTrackingArea?

    let icon = NSImageView()
    let marker: StatusMarkerView?
    let title = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    private var symbolName: String
    private var tintOverride: NSColor?

    init(symbol: String, title t: String, marker: PongStatus? = nil) {
        symbolName = symbol
        self.marker = marker.map { StatusMarkerView($0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = PongRadius.control
        icon.imageScaling = .scaleProportionallyDown
        if let m = self.marker { addSubview(m) } else { addSubview(icon) }
        title.stringValue = t
        title.font = PongType.control
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        trailing.font = PongType.meta
        trailing.textColor = PongColor.textTertiary
        trailing.alignment = .right
        addSubview(trailing)
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = PongColor.onInk
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = PongColor.you
        badge.isBezeled = false
        badge.layer?.cornerRadius = 8
        badge.layer?.masksToBounds = true
        badge.isHidden = true
        addSubview(badge)
        setAccessibilityRole(.button)
        setAccessibilityLabel(t)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setSymbol(_ name: String, tint: NSColor? = nil) {
        symbolName = name
        tintOverride = tint
        restyle()
    }

    /// A filled amber capsule (Needs you only) or a quiet count.
    func setCount(_ n: Int, loud: Bool) {
        if loud {
            badge.stringValue = "\(n)"
            badge.isHidden = n == 0
            trailing.stringValue = ""
        } else {
            badge.isHidden = true
            trailing.stringValue = n > 0 ? "\(n)" : ""
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        if compact {
            let iconFrame = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            icon.frame = iconFrame
            marker?.frame = iconFrame
            title.isHidden = true
            trailing.isHidden = true
            if !badge.isHidden {
                let w = max(16, (badge.stringValue as NSString).size(withAttributes: [.font: badge.font!]).width + 8)
                badge.frame = NSRect(x: iconFrame.maxX - 4, y: iconFrame.minY - 7, width: w, height: 16)
            }
            return
        }
        title.isHidden = false
        trailing.isHidden = false
        icon.frame = NSRect(x: 8, y: (h - 16) / 2, width: 16, height: 16)
        marker?.frame = icon.frame
        var right = bounds.width - 8
        if !badge.isHidden {
            let w = max(20, (badge.stringValue as NSString).size(withAttributes: [.font: badge.font!]).width + 10)
            badge.frame = NSRect(x: right - w, y: (h - 16) / 2, width: w, height: 16)
            right -= w + 6
        }
        let tw = trailing.stringValue.isEmpty ? 0 : min(80, (trailing.stringValue as NSString).size(withAttributes: [.font: trailing.font!]).width + 4)
        trailing.frame = NSRect(x: right - tw, y: (h - 14) / 2, width: tw, height: 14)
        right -= tw + (tw > 0 ? 6 : 0)
        title.frame = NSRect(x: 32, y: (h - 17) / 2, width: max(20, right - 32), height: 17)
    }

    private func restyle() {
        layer?.backgroundColor = (selected ? PongColor.overlay : (hovering ? PongColor.hover : .clear)).cgColor
        title.textColor = selected ? PongColor.textPrimary : PongColor.textSecondary
        title.font = selected ? .systemFont(ofSize: 13, weight: .semibold) : PongType.control
        let tint = tintOverride ?? (selected ? PongColor.textPrimary : PongColor.textSecondary)
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: selected ? .semibold : .regular)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = tint
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The left sidebar: wordmark, New graph, the five areas, the teams, the engine when it is off.
final class SidebarView: NSView {
    var onSelect: ((ShellArea) -> Void)?
    var onSelectTeam: ((String) -> Void)?
    var onNewGraph: (() -> Void)?
    var onFixEngine: (() -> Void)?
    var onShowAllTeams: (() -> Void)?

    private(set) var selectedArea: ShellArea? = .home
    private(set) var selectedTeam: String?
    /// The 56 pt icon rail (windows under 900 pt).
    var compact = false { didSet { if compact != oldValue { rebuildTeams(); needsLayout = true } } }

    private let wordmark = NSImageView()
    private let mark = NSImageView()
    private let newGraph = PongButton(title: "New graph", style: .secondary, size: .large)
    private let newGraphIcon = PongButton(title: "", style: .secondary, size: .large)
    private var areaRows: [ShellArea: SidebarRow] = [:]
    private let teamsEyebrow = PongUI.eyebrow("Teams")
    private var teamRows: [SidebarRow] = []
    private var teams: [ShellTeam] = []
    private let showAll = PongButton(title: "Show all", style: .quiet, size: .small)
    private let engineRow = SidebarRow(symbol: "xmark", title: "Engine off · Fix")
    private let edge = NSView()
    private var engineOff = false
    private let maxTeams = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = PongColor.frame.cgColor
        wordmark.image = PongTheme.wordmarkImage(height: 28)
        wordmark.imageScaling = .scaleProportionallyUpOrDown
        wordmark.imageAlignment = .alignLeft
        wordmark.setAccessibilityLabel(PongTheme.productName)
        addSubview(wordmark)
        mark.image = PongTheme.logoImage(size: 24)
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.setAccessibilityLabel(PongTheme.productName)
        addSubview(mark)

        newGraph.keycap = "⌘N"
        newGraph.symbol = "plus"
        newGraph.target = self
        newGraph.action = #selector(newGraphPressed)
        newGraph.toolTip = "Describe the work; a chat plans it with you, then runs it (⌘N)"
        addSubview(newGraph)
        newGraphIcon.symbol = "plus"
        newGraphIcon.target = self
        newGraphIcon.action = #selector(newGraphPressed)
        newGraphIcon.toolTip = "New graph (⌘N)"
        newGraphIcon.setAccessibilityLabel("New graph")
        addSubview(newGraphIcon)

        for a in ShellArea.allCases {
            let r = SidebarRow(symbol: a.symbol, title: a.title)
            r.toolTip = a.tip
            r.onClick = { [weak self] in self?.onSelect?(a) }
            areaRows[a] = r
            addSubview(r)
        }
        addSubview(teamsEyebrow)
        showAll.target = self
        showAll.action = #selector(showAllPressed)
        addSubview(showAll)
        engineRow.setSymbol("xmark", tint: PongColor.fail)
        engineRow.title.textColor = PongColor.fail
        engineRow.toolTip = "CyberPong can't read your teams. Click to see why."
        engineRow.onClick = { [weak self] in self?.onFixEngine?() }
        engineRow.isHidden = true
        addSubview(engineRow)
        edge.wantsLayer = true
        edge.layer?.backgroundColor = PongColor.hairline.cgColor
        addSubview(edge)
    }

    @objc private func newGraphPressed() { onNewGraph?() }
    @objc private func showAllPressed() { onShowAllTeams?() }

    func select(area: ShellArea?, team: String? = nil) {
        selectedArea = area
        selectedTeam = team
        for (a, r) in areaRows { r.selected = team == nil && a == area }
        for (i, r) in teamRows.enumerated() where i < teams.count { r.selected = teams[i].id == team }
    }

    /// Counts: Needs you as an amber capsule, the rest as quiet numbers.
    func update(needsYou: Int, chats: Int, graphs: Int, teams newTeams: [ShellTeam], engineOff off: Bool) {
        areaRows[.home]?.setCount(needsYou, loud: true)
        areaRows[.home]?.setSymbol(needsYou > 0 ? "diamond.fill" : "diamond", tint: needsYou > 0 ? PongColor.you : nil)
        areaRows[.chats]?.setCount(chats, loud: false)
        areaRows[.graphs]?.setCount(graphs, loud: false)
        areaRows[.teams]?.setCount(0, loud: false)
        let sig = newTeams.map { "\($0.id)|\($0.name)|\($0.running)|\($0.working)" }.joined(separator: ";")
        let old = teams.map { "\($0.id)|\($0.name)|\($0.running)|\($0.working)" }.joined(separator: ";")
        teams = newTeams
        if sig != old { rebuildTeams() }
        if off != engineOff {
            engineOff = off
            engineRow.isHidden = !off
            needsLayout = true
        }
    }

    private func rebuildTeams() {
        teamRows.forEach { $0.removeFromSuperview() }
        teamRows = []
        for t in teams.prefix(maxTeams) {
            let st: PongStatus = t.working ? .working : (t.running ? .done : .stopped)
            let r = SidebarRow(symbol: "circle", title: t.name, marker: st)
            if let m = r.marker, t.running && !t.working {
                // a running team with nothing to do: a quiet filled dot, not a check mark
                m.status = .pending
            }
            r.trailing.stringValue = t.running ? "" : "Stopped"
            r.title.textColor = t.running ? PongColor.textSecondary : PongColor.textTertiary
            r.toolTip = t.running ? (t.working ? "\(t.name): working" : "\(t.name): running, nothing in progress")
                                  : "\(t.name): set up but not running"
            r.selected = t.id == selectedTeam
            r.compact = compact
            r.onClick = { [weak self] in self?.onSelectTeam?(t.id) }
            teamRows.append(r)
            addSubview(r)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        edge.frame = NSRect(x: W - 1, y: 0, width: 1, height: H)
        if compact {
            wordmark.isHidden = true
            mark.isHidden = false
            mark.frame = NSRect(x: (W - 24) / 2, y: 58, width: 24, height: 24)
            newGraph.isHidden = true
            newGraphIcon.isHidden = false
            newGraphIcon.frame = NSRect(x: (W - 32) / 2, y: 98, width: 32, height: 32)
            var y: CGFloat = 146
            for a in ShellArea.allCases {
                guard let r = areaRows[a] else { continue }
                r.compact = true
                r.frame = NSRect(x: (W - 40) / 2, y: y, width: 40, height: 32)
                y += 36
            }
            teamsEyebrow.isHidden = true
            showAll.isHidden = true
            for r in teamRows { r.isHidden = true }
            engineRow.compact = true
            engineRow.frame = NSRect(x: (W - 40) / 2, y: H - 44, width: 40, height: 32)
            return
        }
        wordmark.isHidden = false
        mark.isHidden = true
        // 28 pt tall; the PNG's left 8.1% is empty, so x 6.4 puts the "C" on the 16 pt line.
        wordmark.frame = NSRect(x: 6.4, y: 58, width: 118.5, height: 28)
        newGraph.isHidden = false
        newGraphIcon.isHidden = true
        newGraph.frame = NSRect(x: 12, y: 104, width: W - 24, height: 32)
        var y: CGFloat = 148
        for a in ShellArea.allCases {
            guard let r = areaRows[a] else { continue }
            r.compact = false
            r.frame = NSRect(x: 8, y: y, width: W - 16, height: 32)
            y += 32
        }
        y += 16
        teamsEyebrow.isHidden = teams.isEmpty
        teamsEyebrow.frame = NSRect(x: 16, y: y, width: W - 32, height: 16)
        y += 24
        let bottomLimit = H - (engineOff ? 52 : 12)
        for r in teamRows {
            r.compact = false
            r.isHidden = y + 32 > bottomLimit - 28
            r.frame = NSRect(x: 8, y: y, width: W - 16, height: 32)
            y += 32
        }
        showAll.isHidden = teams.count <= maxTeams || teamRows.isEmpty
        showAll.frame = NSRect(x: 12, y: min(y + 2, bottomLimit - 24), width: 72, height: 24)
        engineRow.compact = false
        engineRow.frame = NSRect(x: 8, y: H - 44, width: W - 16, height: 32)
    }
}

/// The 52 pt bar over the content: parents as a breadcrumb, then the page's actions and ⌘K.
final class WindowBarView: NSView {
    struct Crumb { let title: String; let go: (() -> Void)? }

    var onSearch: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onToggleInspector: (() -> Void)?
    /// Room left for the traffic lights when the sidebar is hidden.
    var leadingInset: CGFloat = 0 { didSet { needsLayout = true } }
    var showsInspectorToggle = false { didSet { inspectorBtn.isHidden = !showsInspectorToggle; needsLayout = true } }

    private let sidebarBtn = PongButton(title: "", style: .quiet)
    private let inspectorBtn = PongButton(title: "", style: .quiet)
    private let searchBtn = PongButton(title: "Search or ask", style: .secondary)
    private var crumbViews: [NSView] = []
    private var actions: [NSView] = []
    private let rule = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.base.cgColor
        sidebarBtn.symbol = "sidebar.left"
        sidebarBtn.toolTip = "Show or hide the sidebar (⌥⌘S)"
        sidebarBtn.setAccessibilityLabel("Toggle sidebar")
        sidebarBtn.target = self
        sidebarBtn.action = #selector(sidebarPressed)
        addSubview(sidebarBtn)
        inspectorBtn.symbol = "sidebar.right"
        inspectorBtn.toolTip = "Show or hide the details (⌥⌘I)"
        inspectorBtn.setAccessibilityLabel("Toggle details")
        inspectorBtn.target = self
        inspectorBtn.action = #selector(inspectorPressed)
        inspectorBtn.isHidden = true
        addSubview(inspectorBtn)
        searchBtn.symbol = "magnifyingglass"
        searchBtn.keycap = "⌘K"
        searchBtn.toolTip = "Jump to any graph, chat, team or setting, or ask a question (⌘K)"
        searchBtn.target = self
        searchBtn.action = #selector(searchPressed)
        addSubview(searchBtn)
        rule.wantsLayer = true
        rule.layer?.backgroundColor = PongColor.hairline.cgColor
        rule.isHidden = true
        addSubview(rule)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func sidebarPressed() { onToggleSidebar?() }
    @objc private func inspectorPressed() { onToggleInspector?() }
    @objc private func searchPressed() { onSearch?() }

    /// A hairline under the bar, only while the page below is scrolled.
    var showsRule = false { didSet { rule.isHidden = !showsRule } }

    func setCrumbs(_ crumbs: [Crumb]) {
        crumbViews.forEach { $0.removeFromSuperview() }
        crumbViews = []
        for (i, c) in crumbs.enumerated() {
            if i > 0 {
                let sep = PongUI.label("›", PongType.control, PongColor.textTertiary)
                crumbViews.append(sep)
                addSubview(sep)
            }
            if let go = c.go {
                let b = PongButton(title: c.title, style: .quiet, size: .regular)
                b.onPress = go
                crumbViews.append(b)
                addSubview(b)
            } else {
                let l = PongUI.label(c.title, PongType.control, PongColor.textSecondary)
                crumbViews.append(l)
                addSubview(l)
            }
        }
        needsLayout = true
    }

    /// At most two page actions, trailing.
    func setActions(_ views: [NSView]) {
        actions.forEach { $0.removeFromSuperview() }
        actions = Array(views.prefix(2))
        actions.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        rule.frame = NSRect(x: 0, y: 0, width: W, height: 1)
        var x = 12 + leadingInset
        sidebarBtn.frame = NSRect(x: x, y: (H - 28) / 2, width: 28, height: 28)
        x += 36
        var right = W - 12
        if !inspectorBtn.isHidden {
            inspectorBtn.frame = NSRect(x: right - 28, y: (H - 28) / 2, width: 28, height: 28)
            right -= 36
        }
        let narrow = W < 900
        searchBtn.title = narrow ? "" : "Search or ask"
        searchBtn.keycap = narrow ? nil : "⌘K"
        let sw: CGFloat = narrow ? 28 : 220
        searchBtn.frame = NSRect(x: right - sw, y: (H - 28) / 2, width: sw, height: 28)
        right -= sw + 12
        for a in actions.reversed() {
            let w = (a as? PongButton)?.intrinsicContentSize.width ?? a.fittingSize.width
            a.frame = NSRect(x: right - w, y: (H - 28) / 2, width: w, height: 28)
            right -= w + 8
        }
        for v in crumbViews {
            if let b = v as? PongButton {
                let w = min(b.intrinsicContentSize.width, max(40, right - x))
                b.frame = NSRect(x: x - 6, y: (H - 28) / 2, width: w, height: 28)
                x += w - 6
            } else if let l = v as? NSTextField {
                let w = min(ceil(l.attributedStringValue.size().width) + 4, max(20, right - x))
                l.frame = NSRect(x: x + 2, y: (H - 17) / 2, width: w, height: 17)
                x += w + 6
            }
            v.isHidden = x > right + 20
        }
    }
}

extension PongButton {
    private static var pressKey = 0
    /// A closure instead of target/action.
    var onPress: (() -> Void)? {
        get { (objc_getAssociatedObject(self, &PongButton.pressKey) as? ClosureBox)?.fn }
        set {
            let box = newValue.map { ClosureBox($0) }
            objc_setAssociatedObject(self, &PongButton.pressKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            target = box
            action = box == nil ? nil : #selector(ClosureBox.fire)
        }
    }
}

final class ClosureBox: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}

/// A page's title (22 pt), its status line, and an optional trailing control (tabs).
final class PageHeaderView: NSView {
    let title = PongUI.label("", PongType.title, PongColor.textPrimary)
    let status = PongUI.label("", PongType.secondary, PongColor.textSecondary)
    let statusMarker = StatusMarkerView(.working)
    private(set) var accessory: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(title)
        addSubview(status)
        statusMarker.isHidden = true
        addSubview(statusMarker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(title t: String, status s: String, marker: PongStatus? = nil, color: NSColor = PongColor.textSecondary) {
        title.stringValue = t
        status.stringValue = s
        status.textColor = color
        if let m = marker {
            statusMarker.status = m
            statusMarker.isHidden = false
        } else {
            statusMarker.isHidden = true
        }
        needsLayout = true
    }

    func setAccessory(_ v: NSView?) {
        accessory?.removeFromSuperview()
        accessory = v
        if let v { addSubview(v) }
        needsLayout = true
    }

    /// 64 pt tall: title at the top, the status line 32 pt below.
    static let height: CGFloat = 52

    override func layout() {
        super.layout()
        let W = bounds.width
        var right = W
        if let a = accessory {
            let s = a.fittingSize
            let w = max(s.width, a.frame.width)
            a.frame = NSRect(x: W - w, y: 2, width: w, height: 28)
            right -= w + 16
        }
        title.frame = NSRect(x: 0, y: 0, width: max(40, right), height: 28)
        var sx: CGFloat = 0
        if !statusMarker.isHidden {
            statusMarker.frame = NSRect(x: 0, y: 33, width: 14, height: 14)
            sx = 20
        }
        status.frame = NSRect(x: sx, y: 32, width: max(40, W - sx), height: 16)
    }
}

/// Segmented tabs: a raised track, the selected segment on `bg.overlay` in Semibold.
final class PongSegmented: NSView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var buttons: [NSButton] = []
    private let labels: [String]

    init(_ labels: [String], tips: [String] = []) {
        self.labels = labels
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PongColor.raised.cgColor
        layer?.cornerRadius = PongRadius.control
        for (i, l) in labels.enumerated() {
            let b = NSButton(title: l, target: self, action: #selector(pressed(_:)))
            b.tag = i
            b.isBordered = false
            b.bezelStyle = .inline
            b.wantsLayer = true
            b.layer?.cornerRadius = PongRadius.control - 1
            b.focusRingType = .none
            if i < tips.count { b.toolTip = tips[i] }
            buttons.append(b)
            addSubview(b)
        }
        setAccessibilityRole(.tabGroup)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ i: Int) {
        selectedIndex = i
        restyle()
    }

    @objc private func pressed(_ b: NSButton) {
        guard b.tag != selectedIndex else { return }
        selectedIndex = b.tag
        restyle()
        onChange?(b.tag)
    }

    private func restyle() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        for (i, b) in buttons.enumerated() {
            let on = i == selectedIndex
            b.layer?.backgroundColor = (on ? PongColor.overlay : NSColor.clear).cgColor
            b.attributedTitle = NSAttributedString(string: labels[i], attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: on ? .semibold : .medium),
                .foregroundColor: on ? PongColor.textPrimary : PongColor.textSecondary,
                .paragraphStyle: para,
            ])
            b.setAccessibilityValue(on ? "selected" : nil)
        }
    }

    override var fittingSize: NSSize {
        let w = labels.reduce(CGFloat(0)) { acc, l in
            acc + (l as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 24
        }
        return NSSize(width: w + 4, height: 28)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        let total = fittingSize.width - 4
        let scale = total > 0 ? (bounds.width - 4) / total : 1
        for (i, b) in buttons.enumerated() {
            let w = ((labels[i] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 24) * scale
            b.frame = NSRect(x: x, y: 2, width: w, height: bounds.height - 4)
            x += w
        }
    }
}
