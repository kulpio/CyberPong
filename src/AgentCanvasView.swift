import AppKit

// MARK: - Canvas positions

enum CanvasLayout {
    static func positions(for session: String) -> [String: CGPoint] {
        let entry = PairState.loadPairsDb()[session] as? [String: Any] ?? [:]
        let raw = entry["canvas_positions"] as? [String: [String: Any]] ?? [:]
        var out: [String: CGPoint] = [:]
        for (k, v) in raw {
            let x = (v["x"] as? CGFloat) ?? CGFloat((v["x"] as? Double) ?? 0)
            let y = (v["y"] as? CGFloat) ?? CGFloat((v["y"] as? Double) ?? 0)
            out[k] = CGPoint(x: x, y: y)
        }
        return out
    }

    static func save(session: String, positions: [String: CGPoint]) {
        var db = PairState.loadPairsDb()
        var entry = db[session] as? [String: Any] ?? [:]
        var raw: [String: [String: Any]] = [:]
        for (k, p) in positions {
            raw[k] = ["x": Double(p.x), "y": Double(p.y)]
        }
        entry["canvas_positions"] = raw
        entry["updated"] = Date().timeIntervalSince1970
        db[session] = entry
        Pong.writeJSON(PairState.pairsPath, db)
    }

    static func defaultPosition(role: String, index: Int, canvas: CGSize) -> CGPoint {
        if role == "conductor" {
            return CGPoint(x: max(48, canvas.width * 0.16), y: max(100, canvas.height * 0.42))
        }
        let row = index
        return CGPoint(
            x: min(canvas.width - 280, max(340, canvas.width * 0.52)),
            y: max(60, canvas.height * 0.18) + CGFloat(row) * 160
        )
    }
}

// MARK: - Model

struct AgentNodeModel {
    let id: String
    let role: String
    let title: String
    let subtitle: String
    let detail: String
    let status: String
    let accent: NSColor
    var origin: CGPoint
}

// MARK: - Node card

final class AgentNodeView: NSView {
    let modelId: String
    var onMoved: ((String, CGPoint) -> Void)?
    var onFront: ((String) -> Void)?
    var onKill: ((String) -> Void)?
    var onOptions: ((String) -> Void)?
    var onPerms: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var dragging = false
    private let iconBadge = NSView()
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var primaryBtn: NSButton!
    private var secondaryBtn: NSButton!
    private var isConductor = false

    static let size = NSSize(width: 252, height: 136)

    override var mouseDownCanMoveWindow: Bool { false }

    init(model: AgentNodeModel) {
        self.modelId = model.id
        super.init(frame: NSRect(origin: model.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        isConductor = model.role == "conductor"

        iconBadge.frame = NSRect(x: 14, y: Self.size.height - 50, width: 34, height: 34)
        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 10
        addSubview(iconBadge)
        iconLabel.font = PongTheme.font(15, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 7, width: 34, height: 20)
        styleLabel(iconLabel)
        iconBadge.addSubview(iconLabel)

        statusPill.frame = NSRect(x: Self.size.width - 90, y: Self.size.height - 36, width: 76, height: 22)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 6
        addSubview(statusPill)
        statusLabel.font = PongTheme.font(9, weight: .bold)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 0, y: 3, width: 76, height: 16)
        styleLabel(statusLabel)
        statusPill.addSubview(statusLabel)

        titleField.font = PongTheme.font(13, weight: .semibold)
        titleField.textColor = PongTheme.textPrimary
        titleField.frame = NSRect(x: 56, y: Self.size.height - 46, width: 100, height: 18)
        titleField.lineBreakMode = .byTruncatingTail
        styleLabel(titleField)
        addSubview(titleField)

        subField.font = PongTheme.font(10)
        subField.textColor = PongTheme.textSecondary
        subField.frame = NSRect(x: 56, y: Self.size.height - 62, width: 100, height: 14)
        subField.lineBreakMode = .byTruncatingTail
        styleLabel(subField)
        addSubview(subField)

        detailField.font = PongTheme.font(10)
        detailField.textColor = PongTheme.textTertiary
        detailField.frame = NSRect(x: 14, y: 42, width: Self.size.width - 28, height: 28)
        detailField.maximumNumberOfLines = 2
        detailField.lineBreakMode = .byWordWrapping
        styleLabel(detailField)
        addSubview(detailField)

        primaryBtn = actionBtn("Open", #selector(frontTap), filled: true,
                               frame: NSRect(x: 14, y: 10, width: 72, height: 26))
        addSubview(primaryBtn)
        secondaryBtn = actionBtn(isConductor ? "Options" : "Perms",
                                 isConductor ? #selector(optsTap) : #selector(permsTap),
                                 filled: false,
                                 frame: NSRect(x: 94, y: 10, width: 72, height: 26))
        addSubview(secondaryBtn)

        apply(model)
        toolTip = "Drag card to rearrange · double-click to Open"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func styleLabel(_ f: NSTextField) {
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        f.backgroundColor = .clear
    }

    private func actionBtn(_ title: String, _ sel: Selector, filled: Bool, frame: NSRect) -> NSButton {
        let b = NSButton(frame: frame)
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        if filled {
            b.layer?.backgroundColor = PongTheme.blue.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white,
                .font: PongTheme.font(10, weight: .semibold),
            ])
        } else {
            b.layer?.backgroundColor = PongTheme.bgHover.cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = PongTheme.border.cgColor
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: PongTheme.textSecondary,
                .font: PongTheme.font(10, weight: .medium),
            ])
        }
        b.target = self
        b.action = sel
        return b
    }

    func apply(_ model: AgentNodeModel) {
        // Never jump the node while user is dragging
        if !dragging, frame.origin != model.origin {
            setFrameOrigin(model.origin)
        }
        titleField.stringValue = model.title
        subField.stringValue = model.subtitle
        detailField.stringValue = model.detail
        iconLabel.stringValue = model.role == "conductor" ? "◎" : "◇"
        iconLabel.textColor = model.role == "conductor" ? PongTheme.blue : PongTheme.magenta
        iconBadge.layer?.backgroundColor = (model.role == "conductor" ? PongTheme.blueSoft : PongTheme.magentaSoft).cgColor

        layer?.backgroundColor = PongTheme.bgElevated.cgColor
        if model.role == "conductor" {
            layer?.borderColor = PongTheme.borderAccent.cgColor
            layer?.shadowColor = PongTheme.blue.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 14
            layer?.shadowOffset = .zero
        } else {
            layer?.borderColor = PongTheme.border.cgColor
            layer?.shadowOpacity = 0.15
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowRadius = 8
        }

        let sk = PongTheme.statusKind(model.status)
        statusLabel.stringValue = sk.label
        statusLabel.textColor = sk.color
        statusPill.layer?.backgroundColor = sk.soft.cgColor
    }

    @objc private func frontTap() { onFront?(modelId) }
    @objc private func optsTap() { onOptions?(modelId) }
    @objc private func permsTap() { onPerms?(modelId) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Ensure we receive events over the whole card (not only subviews)
        guard !isHidden, alphaValue > 0.01, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if primaryBtn.frame.contains(local) { return primaryBtn }
        if secondaryBtn.frame.contains(local) { return secondaryBtn }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?(modelId)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if primaryBtn.frame.contains(local) || secondaryBtn.frame.contains(local) {
            return
        }
        dragStart = event.locationInWindow
        originStart = frame.origin
        dragging = true
        onDragBegan?()
        superview?.addSubview(self) // z-order front
        window?.disableCursorRects()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        var nx = originStart.x + (p.x - dragStart.x)
        var ny = originStart.y + (p.y - dragStart.y)
        nx = min(max(12, nx), max(12, superV.bounds.width - bounds.width - 12))
        ny = min(max(12, ny), max(12, superV.bounds.height - bounds.height - 12))
        setFrameOrigin(NSPoint(x: nx, y: ny))
        (superview as? AgentCanvasView)?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onMoved?(modelId, frame.origin)
            onDragEnded?()
        }
        dragging = false
        dragStart = nil
        originStart = nil
        window?.enableCursorRects()
        (superview as? AgentCanvasView)?.needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open terminal", action: #selector(frontTap), keyEquivalent: "")
        if isConductor {
            menu.addItem(withTitle: "Team options", action: #selector(optsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Kill team", action: #selector(killTap), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Permissions", action: #selector(permsTap), keyEquivalent: "")
            menu.addItem(withTitle: "Remove worker", action: #selector(killTap), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func killTap() { onKill?(modelId) }
}

// MARK: - Canvas

final class AgentCanvasView: NSView {
    var session: String = ""
    var nodes: [AgentNodeModel] = []
    private(set) var isDragging = false
    private var nodeViews: [String: AgentNodeView] = [:]
    var onFront: ((String, String) -> Void)?
    var onKill: ((String, String) -> Void)?
    var onOptions: ((String) -> Void)?
    var onPerms: ((String, String) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bg.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        PongTheme.bg.setFill()
        bounds.fill()

        // Dot grid
        let step: CGFloat = 22
        NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            var y: CGFloat = 0
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                y += step
            }
            x += step
        }

        guard let cNode = nodes.first(where: { $0.role == "conductor" }),
              let cView = nodeViews[cNode.id] else { return }
        let from = NSPoint(x: cView.frame.maxX - 2, y: cView.frame.midY)
        for n in nodes where n.role == "worker" {
            guard let wv = nodeViews[n.id] else { continue }
            let to = NSPoint(x: wv.frame.minX + 2, y: wv.frame.midY)
            let human = n.status.lowercased().contains("human")
            drawEdge(from: from, to: to, human: human)
        }
    }

    private func drawEdge(from: NSPoint, to: NSPoint, human: Bool) {
        let path = NSBezierPath()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        path.curve(to: to,
                   controlPoint1: NSPoint(x: midX, y: from.y),
                   controlPoint2: NSPoint(x: midX, y: to.y))
        let color = human ? PongTheme.orange : PongTheme.blue
        path.lineWidth = 5
        color.withAlphaComponent(0.2).setStroke()
        path.stroke()
        path.lineWidth = 1.75
        color.withAlphaComponent(0.75).setStroke()
        path.stroke()
        let r: CGFloat = 3.5
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: from.x - r, y: from.y - r, width: r * 2, height: r * 2)).fill()
        (human ? PongTheme.orange : PongTheme.magenta).setFill()
        NSBezierPath(ovalIn: NSRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2)).fill()
    }

    func reload(session: String, models: [AgentNodeModel]) {
        // Never rebuild nodes mid-drag
        if isDragging { return }
        self.session = session
        self.nodes = models
        let keep = Set(models.map(\.id))
        for (id, v) in nodeViews where !keep.contains(id) {
            v.removeFromSuperview()
            nodeViews[id] = nil
        }
        for m in models {
            if let existing = nodeViews[m.id] {
                existing.apply(m)
            } else {
                let v = AgentNodeView(model: m)
                v.onMoved = { [weak self] id, origin in self?.persist(id: id, origin: origin) }
                v.onFront = { [weak self] id in guard let self else { return }; self.onFront?(self.session, id) }
                v.onKill = { [weak self] id in guard let self else { return }; self.onKill?(self.session, id) }
                v.onOptions = { [weak self] _ in guard let self else { return }; self.onOptions?(self.session) }
                v.onPerms = { [weak self] id in guard let self else { return }; self.onPerms?(self.session, id) }
                v.onDoubleClick = { [weak self] id in guard let self else { return }; self.onFront?(self.session, id) }
                v.onDragBegan = { [weak self] in
                    self?.isDragging = true
                    self?.onDragStateChanged?(true)
                }
                v.onDragEnded = { [weak self] in
                    self?.isDragging = false
                    self?.onDragStateChanged?(false)
                }
                addSubview(v)
                nodeViews[m.id] = v
            }
        }
        needsDisplay = true
    }

    private func persist(id: String, origin: CGPoint) {
        var pos = CanvasLayout.positions(for: session)
        pos[id] = origin
        if let i = nodes.firstIndex(where: { $0.id == id }) {
            nodes[i].origin = origin
        }
        CanvasLayout.save(session: session, positions: pos)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
