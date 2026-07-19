import AppKit

// MARK: - Canvas positions (persisted on pair)

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

    /// Default stacked layout when no positions saved.
    static func defaultPosition(role: String, index: Int, canvas: CGSize) -> CGPoint {
        let cx = max(160, canvas.width * 0.28)
        if role == "conductor" {
            return CGPoint(x: cx - 90, y: max(40, canvas.height * 0.45 - 40))
        }
        let startY = max(40, canvas.height * 0.2)
        return CGPoint(x: min(canvas.width - 220, canvas.width * 0.55),
                       y: startY + CGFloat(index) * 110)
    }
}

// MARK: - Node model

struct AgentNodeModel {
    let id: String
    let role: String // conductor | worker
    let title: String
    let subtitle: String
    let status: String
    let accent: NSColor
    var origin: CGPoint
}

// MARK: - Node view

final class AgentNodeView: NSView {
    let modelId: String
    var onMoved: ((String, CGPoint) -> Void)?
    var onFront: ((String) -> Void)?
    var onKill: ((String) -> Void)?
    var onOptions: ((String) -> Void)?
    var onPerms: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?

    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private let titleField = NSTextField(labelWithString: "")
    private let subField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let badge = NSView()
    private var isConductor = false

    static let size = NSSize(width: 188, height: 96)

    init(model: AgentNodeModel) {
        self.modelId = model.id
        super.init(frame: NSRect(origin: model.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = PongTheme.borderStrong.cgColor
        isConductor = model.role == "conductor"
        layer?.backgroundColor = (isConductor
            ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.16, alpha: 1)
            : PongTheme.bgElevated).cgColor

        // Left accent bar
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: Self.size.height))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = model.accent.cgColor
        bar.layer?.cornerRadius = 2
        addSubview(bar)

        badge.frame = NSRect(x: 14, y: Self.size.height - 22, width: 8, height: 8)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = statusColor(model.status).cgColor
        addSubview(badge)

        titleField.stringValue = model.title
        titleField.font = PongTheme.font(12, weight: .semibold)
        titleField.textColor = PongTheme.textPrimary
        titleField.frame = NSRect(x: 14, y: 52, width: 160, height: 18)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.backgroundColor = .clear
        addSubview(titleField)

        subField.stringValue = model.subtitle
        subField.font = PongTheme.font(10)
        subField.textColor = PongTheme.textSecondary
        subField.frame = NSRect(x: 14, y: 36, width: 160, height: 14)
        subField.lineBreakMode = .byTruncatingTail
        subField.isEditable = false
        subField.isBordered = false
        subField.backgroundColor = .clear
        addSubview(subField)

        statusField.stringValue = model.status
        statusField.font = PongTheme.font(9, weight: .medium)
        statusField.textColor = PongTheme.textTertiary
        statusField.frame = NSRect(x: 14, y: 14, width: 100, height: 12)
        statusField.isEditable = false
        statusField.isBordered = false
        statusField.backgroundColor = .clear
        addSubview(statusField)

        // Mini actions
        addChip("Front", x: 100, sel: #selector(frontTap))
        if isConductor {
            addChip("Opts", x: 140, sel: #selector(optsTap))
        } else {
            addChip("Perms", x: 140, sel: #selector(permsTap))
        }

        toolTip = "Drag to rearrange · double-click to Front · right-click for more"
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addChip(_ title: String, x: CGFloat, sel: Selector) {
        let b = NSButton(frame: NSRect(x: x, y: 8, width: 40, height: 20))
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = PongTheme.bgHover.cgColor
        b.layer?.cornerRadius = 6
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: PongTheme.textSecondary,
            .font: PongTheme.font(9, weight: .medium),
        ])
        b.target = self
        b.action = sel
        addSubview(b)
    }

    private func statusColor(_ s: String) -> NSColor {
        let t = s.lowercased()
        if t.contains("busy") || t.contains("live") || t.contains("running") { return PongTheme.live }
        if t.contains("human") || t.contains("hide") { return PongTheme.warn }
        return PongTheme.idle
    }

    func apply(_ model: AgentNodeModel) {
        titleField.stringValue = model.title
        subField.stringValue = model.subtitle
        statusField.stringValue = model.status
        badge.layer?.backgroundColor = statusColor(model.status).cgColor
        if frame.origin != model.origin {
            setFrameOrigin(model.origin)
        }
    }

    @objc private func frontTap() { onFront?(modelId) }
    @objc private func optsTap() { onOptions?(modelId) }
    @objc private func permsTap() { onPerms?(modelId) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(modelId)
            return
        }
        dragStart = event.locationInWindow
        originStart = frame.origin
        // Bring to front among siblings
        superview?.addSubview(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let originStart, let superV = superview else { return }
        let p = event.locationInWindow
        let dx = p.x - dragStart.x
        let dy = p.y - dragStart.y
        var nx = originStart.x + dx
        var ny = originStart.y + dy
        // Clamp to canvas
        nx = min(max(8, nx), max(8, superV.bounds.width - bounds.width - 8))
        ny = min(max(8, ny), max(8, superV.bounds.height - bounds.height - 8))
        setFrameOrigin(NSPoint(x: nx, y: ny))
        (superview as? AgentCanvasView)?.setNeedsDisplay(superview?.bounds ?? bounds)
    }

    override func mouseUp(with event: NSEvent) {
        onMoved?(modelId, frame.origin)
        dragStart = nil
        originStart = nil
        (superview as? AgentCanvasView)?.setNeedsDisplay(superview?.bounds ?? bounds)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Front terminal", action: #selector(frontTap), keyEquivalent: "")
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
    private var nodeViews: [String: AgentNodeView] = [:]
    var onFront: ((String, String) -> Void)? // session, nodeId
    var onKill: ((String, String) -> Void)?
    var onOptions: ((String) -> Void)? // session
    var onPerms: ((String, String) -> Void)? // session, workerId
    var onLayoutChanged: (() -> Void)?

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PongTheme.bg.cgColor
        // Dot grid via draw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Background
        PongTheme.bg.setFill()
        bounds.fill()

        // Dot grid (n8n-ish)
        let step: CGFloat = 24
        PongTheme.border.setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            var y: CGFloat = 0
            while y < bounds.height {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
                y += step
            }
            x += step
        }

        // Edges: conductor → each worker
        guard let cNode = nodes.first(where: { $0.role == "conductor" }),
              let cView = nodeViews[cNode.id] else { return }
        let c = NSPoint(x: cView.frame.midX, y: cView.frame.midY)
        for n in nodes where n.role == "worker" {
            guard let wv = nodeViews[n.id] else { continue }
            let w = NSPoint(x: wv.frame.midX, y: wv.frame.midY)
            drawEdge(from: c, to: w)
        }
    }

    private func drawEdge(from: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        path.curve(to: to,
                   controlPoint1: NSPoint(x: midX, y: from.y),
                   controlPoint2: NSPoint(x: midX, y: to.y))
        path.lineWidth = 2
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        path.stroke()

        // Arrow head near worker
        let angle = atan2(to.y - from.y, to.x - from.x)
        let ah: CGFloat = 8
        let tip = to
        let left = NSPoint(x: tip.x - ah * cos(angle - .pi / 6), y: tip.y - ah * sin(angle - .pi / 6))
        let right = NSPoint(x: tip.x - ah * cos(angle + .pi / 6), y: tip.y - ah * sin(angle + .pi / 6))
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: left)
        arrow.line(to: right)
        arrow.close()
        NSColor(calibratedWhite: 1, alpha: 0.2).setFill()
        arrow.fill()
    }

    func reload(session: String, models: [AgentNodeModel]) {
        self.session = session
        self.nodes = models
        // Remove old node views
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
                v.onMoved = { [weak self] id, origin in
                    self?.persistPosition(id: id, origin: origin)
                }
                v.onFront = { [weak self] id in
                    guard let self else { return }
                    self.onFront?(self.session, id)
                }
                v.onKill = { [weak self] id in
                    guard let self else { return }
                    self.onKill?(self.session, id)
                }
                v.onOptions = { [weak self] _ in
                    guard let self else { return }
                    self.onOptions?(self.session)
                }
                v.onPerms = { [weak self] id in
                    guard let self else { return }
                    // worker ids are w1 etc; conductor uses c1
                    let wid = id.hasPrefix("w") ? id : id
                    self.onPerms?(self.session, wid)
                }
                v.onDoubleClick = { [weak self] id in
                    guard let self else { return }
                    self.onFront?(self.session, id)
                }
                addSubview(v)
                nodeViews[m.id] = v
            }
        }
        needsDisplay = true
    }

    private func persistPosition(id: String, origin: CGPoint) {
        var pos = CanvasLayout.positions(for: session)
        pos[id] = origin
        // also update in-memory nodes
        if let i = nodes.firstIndex(where: { $0.id == id }) {
            nodes[i].origin = origin
        }
        CanvasLayout.save(session: session, positions: pos)
        needsDisplay = true
        onLayoutChanged?()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
