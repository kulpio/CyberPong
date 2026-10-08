import AppKit

/// ⌘K: jump to any graph, chat, team or page, run a command, or ask the Guide
/// (ux-review.md §3; design-language.md §3, ⌘K). 640 pt wide, a fifth of the way down,
/// groups under eyebrows, 40 pt rows, the last row always "Ask the Guide: …".
final class CommandPalette: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandPalette()

    struct Item {
        let group: String
        let symbol: String
        let title: String
        let subtitle: String
        let keys: String
        let run: () -> Void
    }

    private var panel: NSPanel?
    private let field = NSTextField()
    private let list = PaletteList()
    private var items: [Item] = []
    private var shown: [Item] = []
    private var selected = 0
    private weak var parent: NSWindow?

    func present(in window: NSWindow?) {
        guard let window else { return }
        if panel != nil { close(); return }
        parent = window
        items = buildItems()
        let W: CGFloat = min(640, window.frame.width - 48)
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: 56), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        let root = NSView(frame: p.contentRect(forFrameRect: p.frame))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongColor.overlay.cgColor
        root.layer?.cornerRadius = PongRadius.palette
        root.layer?.borderWidth = 1
        root.layer?.borderColor = PongColor.hairline.cgColor
        root.layer?.masksToBounds = true
        p.contentView = root

        let glass = NSImageView(frame: .zero)
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        glass.contentTintColor = PongColor.textTertiary
        glass.identifier = NSUserInterfaceItemIdentifier("glass")
        root.addSubview(glass)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = PongColor.textPrimary
        field.placeholderAttributedString = NSAttributedString(string: "Search graphs, chats, teams and commands, or ask", attributes: [
            .font: NSFont.systemFont(ofSize: 17), .foregroundColor: PongColor.textTertiary])
        field.stringValue = ""
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        root.addSubview(field)
        list.onPick = { [weak self] i in self?.run(i) }
        list.onHover = { [weak self] i in self?.select(i) }
        list.frame = NSRect(x: 8, y: 8, width: W - 16, height: 0)
        root.addSubview(list)
        panel = p
        filter()
        window.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(field)
        if !PongMotion.reduced {
            p.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PongMotion.fast
                p.animator().alphaValue = 1
            }
        }
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        parent?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Items

    private func buildItems() -> [Item] {
        let pc = PanelController.shared
        var out: [Item] = []
        for a in ShellArea.allCases {
            out.append(Item(group: "Go to", symbol: a.symbol, title: a.title, subtitle: "", keys: "⌘\(a.rawValue + 1)") {
                pc.goArea(a)
            })
        }
        out.append(Item(group: "Go to", symbol: "gearshape", title: "Settings", subtitle: "", keys: "⌘,") { pc.openSettings() })
        out.append(Item(group: "Go to", symbol: "stethoscope", title: "Diagnostics", subtitle: "Charts, problems and the event log", keys: "") {
            pc.goDiagnostics()
        })
        let st = GraphStore.shared
        for g in st.graphs.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            out.append(Item(group: "Graphs", symbol: g.pongStatus.symbol, title: g.displayTitle,
                            subtitle: g.plainStatus + " · " + g.teamName, keys: "") { pc.openGraph(g.key) })
        }
        for a in st.architects.sorted(by: { $0.createdAt > $1.createdAt }) {
            out.append(Item(group: "Chats", symbol: "text.bubble", title: a.displayTitle, subtitle: a.plainLine, keys: "") {
                pc.openChat(a.key)
            })
        }
        let db = PairState.loadPairsDb()
        for t in PairState.listPairs() + PairState.listStoppedPairs() {
            let name = ((db[t] as? [String: Any])?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t
            let running = PairState.listPairs().contains(t)
            out.append(Item(group: "Teams", symbol: "person.2", title: name, subtitle: running ? "Running" : "Stopped", keys: "") {
                pc.openTeam(t)
            })
        }
        out.append(Item(group: "Commands", symbol: "plus", title: "New graph", subtitle: "Describe the work; a chat plans it", keys: "⌘N") { pc.newGraph() })
        out.append(Item(group: "Commands", symbol: "person.2.badge.plus", title: "New team", subtitle: "", keys: "⇧⌘N") { pc.newTeam() })
        out.append(Item(group: "Commands", symbol: "square.stack.3d.up", title: "Start from a template…", subtitle: "A ready-made graph on a team", keys: "") {
            pc.startFromTemplate()
        })
        out.append(Item(group: "Commands", symbol: "diamond", title: "Next question", subtitle: "", keys: "⌘J") { pc.nextQuestion() })
        out.append(Item(group: "Commands", symbol: "arrow.clockwise", title: "Refresh", subtitle: "", keys: "⌘R") { pc.hardRefresh() })
        out.append(Item(group: "Commands", symbol: "sidebar.left", title: "Show or hide the sidebar", subtitle: "", keys: "⌥⌘S") { pc.toggleSidebar() })
        out.append(Item(group: "Commands", symbol: "clock", title: "New schedule", subtitle: "A task that runs by itself", keys: "") { pc.newSchedule() })
        out.append(Item(group: "Commands", symbol: "person.crop.circle", title: "Switch AI account…", subtitle: "", keys: "") {
            (NSApp.delegate as? AppDelegate)?.switchProviderAccount()
        })
        return out
    }

    private func filter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            // nothing typed: where to go and what is live
            shown = items.filter { $0.group == "Go to" }
                + items.filter { $0.group == "Graphs" }.prefix(4)
                + items.filter { $0.group == "Commands" }.prefix(2)
        } else {
            let words = q.split(separator: " ").map(String.init)
            func score(_ it: Item) -> Int? {
                let hay = (it.title + " " + it.subtitle + " " + it.group).lowercased()
                guard words.allSatisfy({ hay.contains($0) }) else { return nil }
                let t = it.title.lowercased()
                if t.hasPrefix(q) { return 0 }
                if t.contains(q) { return 1 }
                return 2
            }
            let hits = items.compactMap { it in score(it).map { (it, $0) } }
            shown = hits.sorted { $0.1 < $1.1 }.prefix(40).map { $0.0 }
            shown.append(Item(group: "Ask", symbol: "sparkles", title: "Ask the Guide: “\(field.stringValue)”",
                              subtitle: "An answer from your teams' live status", keys: "↩") { [weak self] in
                guard let self else { return }
                AppAIChatBubble.shared.beginMissionAsk(self.lastQuery)
            })
        }
        lastQuery = field.stringValue
        selected = 0
        list.set(shown, selected: selected)
        layout()
    }

    private var lastQuery = ""

    private func layout() {
        guard let p = panel, let parent else { return }
        let W = p.frame.width
        let rows = list.heightFor(maxRows: 8)
        let H = 56 + (rows > 0 ? rows + 8 : 0)
        let pf = parent.frame
        let x = pf.midX - W / 2
        let y = pf.maxY - pf.height * 0.2 - H
        p.setFrame(NSRect(x: x, y: y, width: W, height: H), display: true)
        let root = p.contentView!
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        root.subviews.first { $0.identifier?.rawValue == "glass" }?.frame = NSRect(x: 18, y: H - 38, width: 20, height: 20)
        field.frame = NSRect(x: 46, y: H - 42, width: W - 64, height: 26)
        list.frame = NSRect(x: 8, y: 8, width: W - 16, height: max(0, H - 64))
    }

    private func select(_ i: Int) {
        guard !shown.isEmpty else { return }
        selected = max(0, min(shown.count - 1, i))
        list.set(shown, selected: selected)
    }

    private func run(_ i: Int) {
        guard i >= 0, i < shown.count else { return }
        let it = shown[i]
        close()
        DispatchQueue.main.async { it.run() }
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(selected + 1); list.reveal(selected); return true
        case #selector(NSResponder.moveUp(_:)): select(selected - 1); list.reveal(selected); return true
        case #selector(NSResponder.insertNewline(_:)): run(selected); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }
}

/// A borderless panel that can take the keyboard.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The palette's rows under their group eyebrows.
private final class PaletteList: NSView {
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private let scroll = NSScrollView()
    private let doc = Doc()
    private var rowFrames: [NSRect] = []
    private var contentH: CGFloat = 0

    private final class Doc: NSView { override var isFlipped: Bool { true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(contentH, bounds.height))
    }

    func heightFor(maxRows: Int) -> CGFloat {
        guard !rowFrames.isEmpty else { return 0 }
        let cut = rowFrames.count > maxRows ? rowFrames[maxRows - 1].maxY : contentH
        return min(contentH, cut + 4)
    }

    func set(_ items: [CommandPalette.Item], selected: Int) {
        doc.subviews.forEach { $0.removeFromSuperview() }
        rowFrames = []
        var y: CGFloat = 0
        var group = ""
        for (i, it) in items.enumerated() {
            let w = max(200, bounds.width)
            if it.group != group && it.group != "Ask" {
                group = it.group
                let e = PongUI.eyebrow(it.group)
                e.frame = NSRect(x: 12, y: y + 8, width: w - 24, height: 16)
                doc.addSubview(e)
                y += 28
            } else if it.group == "Ask" {
                group = it.group
                let rule = PongUI.divider(width: w)
                rule.frame = NSRect(x: 0, y: y + 4, width: w, height: 1)
                doc.addSubview(rule)
                y += 9
            }
            let row = PaletteRow(it, selected: i == selected, width: w)
            row.frame = NSRect(x: 0, y: y, width: w, height: 40)
            row.onClick = { [weak self] in self?.onPick?(i) }
            row.onHover = { [weak self] in self?.onHover?(i) }
            doc.addSubview(row)
            rowFrames.append(row.frame)
            y += 40
        }
        contentH = y
        needsLayout = true
    }

    func reveal(_ i: Int) {
        guard i < rowFrames.count else { return }
        doc.scrollToVisible(rowFrames[i].insetBy(dx: 0, dy: -8))
    }
}

private final class PaletteRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let isSelected: Bool

    init(_ it: CommandPalette.Item, selected: Bool, width W: CGFloat) {
        isSelected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: 40))
        wantsLayer = true
        layer?.cornerRadius = PongRadius.control
        layer?.backgroundColor = (selected ? PongColor.selectedOnOverlay : NSColor.clear).cgColor
        let icon = NSImageView(frame: NSRect(x: 12, y: 12, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: it.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        icon.contentTintColor = it.group == "Ask" ? PongColor.architect : PongColor.textSecondary
        addSubview(icon)
        let t = PongUI.label(it.title, PongType.control, PongColor.textPrimary)
        t.frame = NSRect(x: 40, y: it.subtitle.isEmpty ? 11 : 4, width: W - 140, height: 18)
        addSubview(t)
        if !it.subtitle.isEmpty {
            let s = PongUI.label(it.subtitle, PongType.secondary, PongColor.textTertiary)
            s.frame = NSRect(x: 40, y: 21, width: W - 140, height: 16)
            addSubview(s)
        }
        if !it.keys.isEmpty {
            let k = PongUI.label(it.keys, PongType.meta, PongColor.textTertiary)
            k.alignment = .right
            k.frame = NSRect(x: W - 92, y: 12, width: 80, height: 16)
            addSubview(k)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(it.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { if !isSelected { onHover?() } }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
