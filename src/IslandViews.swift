import AppKit

// The notch panel's drawing (2.1, spec §4-§7, §12, §14.3), in AppKit from the app's own components:
// the black shape (a CAShapeLayer whose path springs between closed, nudge and open), the marker and
// count beside the notch, the closed line, the nudge of a new question, and the open panel: the top
// band with [Graphs | Teams], the count line, the banners, the questions first (the app's question
// card at island size), then every graph's step, AI and doing line, or every team and its AIs, and
// the footer. The words all come from IslandModel; nothing here reads a file or runs a command: the
// buttons call IslandController (IslandActions), which runs them off the main thread.

/// What the open panel's buttons ask the controller to do.
protocol IslandActions: AnyObject {
    func islandOpenGraph(_ key: String, tab: GraphStudioView.Tab?)
    func islandOpenChat(_ key: String)
    func islandPause(_ graphKey: String)
    func islandResume(_ graphKey: String)
    func islandStartTeam(_ session: String)
    func islandOpenScreen(_ graphKey: String, node: String)
    func islandRetry(_ graphKey: String, node: String)
    func islandBanner(_ kind: IslandBanner.Kind)
    func islandNewGraph()
    func islandOpenApp()
    func islandOpenSettings()
    func islandHide()
    func islandTogglePin()
    func islandClickNotch()
    func islandSetView(_ v: IslandSettings.View)
    func islandSend(_ text: String, to session: String, done: @escaping (Bool) -> Void)
    /// The open panel's content changed height: the shape follows.
    func islandContentChanged()
    /// An answer went through (its receipt shows for a moment).
    func islandAnswered(_ key: String)
    /// A menu the panel opened is showing (the panel holds open meanwhile).
    func islandMenu(_ showing: Bool)
}

// MARK: - Small pieces

enum IslandStyle {
    /// The closed line: 11 pt Medium with tabular digits, measured at the size it is drawn.
    static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let rowName = PongType.bodyStrong
    static let small = PongType.secondary

    static func width(_ s: String, _ f: NSFont) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// Dividers; under Increase Contrast they take the stronger `mark` (§12).
    static var hairline: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? PongColor.mark : PongColor.hairline
    }

    /// Under Increase Contrast tertiary text reads as secondary (§12).
    static var tertiary: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? PongColor.textSecondary : PongColor.textTertiary
    }

    /// A count's colour beside its marker.
    static func countColor(_ s: PongStatus) -> NSColor {
        switch s {
        case .needsYou: return PongColor.you
        case .working: return PongColor.textPrimary
        case .failed: return PongColor.fail
        case .paused, .done: return PongColor.textSecondary
        default: return tertiary
        }
    }

    /// The health strip's sign for a status, in the count line ("◆ 2 need you").
    static func sign(_ s: PongStatus) -> String {
        switch s {
        case .needsYou: return "◆"
        case .working: return "◠"
        case .paused: return "‖"
        case .failed: return "✕"
        case .done: return "✓"
        case .stopped: return "■"
        default: return "○"
        }
    }

    static func attributed(_ parts: [(String, NSFont, NSColor)], truncate: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = truncate
        let out = NSMutableAttributedString()
        for (s, f, c) in parts where !s.isEmpty {
            out.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .paragraphStyle: para]))
        }
        return out
    }
}

/// A label that can't be selected and passes clicks to what is under it. Always made with a text
/// (`IslandLabel("")`): a bare `IslandLabel()` is NSTextField's own init, editable and bezeled.
final class IslandLabel: NSTextField {
    convenience init(_ text: String = "", font: NSFont = PongType.secondary, color: NSColor = PongColor.textSecondary, lines: Int = 1) {
        self.init(frame: .zero)
        stringValue = text
        self.font = font
        textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        maximumNumberOfLines = lines
        lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        cell?.truncatesLastVisibleLine = true
        cell?.wraps = lines != 1
        setAccessibilityElement(!text.isEmpty)
    }

    func set(_ a: NSAttributedString) {
        attributedStringValue = a
        toolTip = a.string.isEmpty ? nil : a.string
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 24 pt icon button (pin, ⋯, Pause, Open): an SF Symbol, the hover fill of a quiet button, cyan when on.
final class IslandIconButton: NSButton {
    var on = false { didSet { restyle() } }
    var onPress: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let symbol: String
    private let onSymbol: String

    init(_ symbol: String, onSymbol: String? = nil, label: String) {
        self.symbol = symbol
        self.onSymbol = onSymbol ?? symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        isBordered = false
        bezelStyle = .inline
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = PongRadius.control
        focusRingType = .default
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { onPress?() }

    private func restyle() {
        image = NSImage(systemSymbolName: on ? onSymbol : symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        contentTintColor = on ? PongColor.live : (hovering ? PongColor.textPrimary : PongColor.textSecondary)
        layer?.backgroundColor = (hovering ? PongColor.hover : NSColor.clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A view whose origin is its top-left.
class IslandFlipped: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Beside the notch

/// The left side: one marker and its count per group ("◆ 2  ◠ 3"). The working ring holds still while
/// anything needs the person.
final class IslandMarksView: NSView {
    private var markers: [StatusMarkerView] = []
    private var counts: [NSTextField] = []
    private(set) var marks: [IslandMark] = []

    /// Between two groups, and between a marker and its count: "◆ 2  ◠ 3" fits the left side's 64 pt.
    static let gap: CGFloat = 4
    static let countGap: CGFloat = 1

    static func width(_ marks: [IslandMark]) -> CGFloat {
        guard !marks.isEmpty else { return 0 }
        var w: CGFloat = 0
        for (i, m) in marks.enumerated() {
            if i > 0 { w += gap }
            w += 16
            if let c = m.count { w += countGap + IslandStyle.width("\(c)", IslandStyle.countFont) }
        }
        return w
    }

    func set(_ m: [IslandMark]) {
        guard m != marks || markers.count != m.count else { return }
        // a count that changed glows cyan and fades to its own colour (§8.7 afterglow; none under Reduce Motion)
        var was: [PongStatus: Int] = [:]
        for old in marks { if let c = old.count { was[old.status] = c } }
        marks = m
        while markers.count < m.count {
            let v = StatusMarkerView(.working)
            let c = IslandLabel("", font: IslandStyle.countFont, color: PongColor.textPrimary)
            c.setAccessibilityElement(false)
            v.setAccessibilityElement(false)
            markers.append(v)
            counts.append(c)
            addSubview(v)
            addSubview(c)
        }
        while markers.count > m.count {
            markers.removeLast().removeFromSuperview()
            counts.removeLast().removeFromSuperview()
        }
        for (i, mark) in m.enumerated() {
            markers[i].status = mark.status
            markers[i].still = mark.still
            counts[i].stringValue = mark.count.map { "\($0)" } ?? ""
            let color = IslandStyle.countColor(mark.status)
            if let c = mark.count, let before = was[mark.status], before != c, !PongMotion.reduced, window != nil {
                IslandMarksView.afterglow(counts[i], to: color)
            } else {
                counts[i].textColor = color
            }
            counts[i].isHidden = mark.count == nil
        }
        needsLayout = true
    }

    /// The number shows in cyan, then fades to its own colour in 400 ms.
    static func afterglow(_ f: NSTextField, to color: NSColor) {
        f.wantsLayer = true
        f.textColor = PongColor.live
        f.display()
        let t = CATransition()
        t.type = .fade
        t.duration = 0.4
        t.timingFunction = PongMotion.easeOut
        f.layer?.add(t, forKey: "afterglow")
        f.textColor = color
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let H = bounds.height
        for (i, mark) in marks.enumerated() where i < markers.count {
            if i > 0 { x += IslandMarksView.gap }
            markers[i].frame = NSRect(x: x, y: (H - 16) / 2, width: 16, height: 16)
            x += 16
            if let c = mark.count {
                // the label keeps 2 pt inside each edge: drawn from x - 2, the digits start at x
                let w = IslandStyle.width("\(c)", IslandStyle.countFont)
                counts[i].frame = NSRect(x: x + IslandMarksView.countGap - 2, y: (H - 14) / 2, width: w + 4, height: 14)
                x += IslandMarksView.countGap + w
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The closed line: a head and a tail that are never cut, and the graph's name between them, cut in the
/// middle when the line is too long for its 138 pt ("Help center a…cles · 2/4"). Changing subject, it
/// slides up (a cross-fade under Reduce Motion).
final class IslandLineView: NSView {
    private(set) var line: IslandLine?

    /// The widest the text may be.
    static var maxWidth: CGFloat { IslandGeometry.lineTextMax }

    /// The line's natural width, capped at what the right side holds.
    static func width(_ l: IslandLine?) -> CGFloat {
        guard let l else { return 0 }
        let f = IslandStyle.lineFont
        let tail = l.tail.isEmpty ? 0 : IslandStyle.width(" " + l.tail, f)
        return min(maxWidth, IslandStyle.width(l.head, f) + IslandStyle.width(l.name, f) + tail)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ l: IslandLine?, animated: Bool) {
        guard l != line else { return }
        let changed = l?.key != line?.key && line != nil && l != nil
        line = l
        toolTip = l?.text
        if changed && animated {
            let t = CATransition()
            if PongMotion.reduced {
                t.type = .fade
                t.duration = 0.15
            } else {
                t.type = .push
                t.subtype = .fromBottom
                t.duration = 0.28
                t.timingFunction = PongMotion.easeInOut
            }
            layer?.add(t, forKey: "line")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let l = line else { return }
        let f = IslandStyle.lineFont
        let main: NSColor, second: NSColor
        switch l.tone {
        case .you: main = PongColor.you; second = PongColor.you
        case .fail: main = PongColor.fail; second = PongColor.fail
        case .quiet: main = IslandStyle.tertiary; second = IslandStyle.tertiary
        case .normal: main = PongColor.textPrimary; second = PongColor.textSecondary
        }
        let tail = l.tail.isEmpty ? "" : " " + l.tail
        let hw = IslandStyle.width(l.head, f)
        let tw = IslandStyle.width(tail, f)
        let room = max(12, bounds.width - hw - tw)
        let nw = min(room, IslandStyle.width(l.name, f))
        let y = (bounds.height - ceil(f.ascender - f.descender)) / 2
        var x: CGFloat = 0
        func put(_ s: String, _ c: NSColor, _ w: CGFloat, _ mode: NSLineBreakMode) {
            guard !s.isEmpty else { return }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = mode
            (s as NSString).draw(with: NSRect(x: x, y: y, width: w + 1, height: ceil(f.ascender - f.descender) + 1),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: f, .foregroundColor: c, .paragraphStyle: para])
            x += w
        }
        put(l.head, second, hw, .byClipping)
        put(l.name, main, nw, .byTruncatingMiddle)
        put(tail, second, tw, .byClipping)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The nudge of a new question (§14.3): the ◆, the question itself on one line, and where it comes from.
final class IslandNudgeView: NSView {
    private let marker = StatusMarkerView(.needsYou)
    private let title = IslandLabel("", font: PongType.bodyStrong, color: PongColor.textPrimary)
    private let source = IslandLabel("", font: PongType.meta, color: IslandStyle.tertiary)
    var onClick: (() -> Void)?

    static let titleFont = PongType.bodyStrong
    /// Below the chin: a gap, the title, the source and a little room under it.
    static let drop: CGFloat = 4 + 18 + 15 + 9

    static func contentWidth(_ n: IslandNudge) -> CGFloat {
        24 + max(IslandStyle.width(n.title, titleFont), IslandStyle.width(n.source, PongType.meta))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(marker)
        addSubview(title)
        addSubview(source)
        marker.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(_ n: IslandNudge?) {
        title.stringValue = n?.title ?? ""
        title.toolTip = n?.title
        source.stringValue = n?.source ?? ""
        setAccessibilityLabel(n.map { $0.announcement + ". Opens the panel at this question." })
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        marker.frame = NSRect(x: 0, y: 5, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: 4, width: max(20, W - 24), height: 18)
        source.frame = NSRect(x: 24, y: 23, width: max(20, W - 24), height: 15)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - The root: the shape and what is in it

/// The panel's content view. Its black shape is a CAShapeLayer whose path springs between the closed
/// panel, the nudge and the open panel; the content sits in a view masked by the same path, so nothing
/// spills past the shape while it moves. Clicks outside the shape fall through to what is underneath.
final class IslandRootView: NSView {
    let marks = IslandMarksView()
    let line = IslandLineView()
    let nudge = IslandNudgeView()
    let open: IslandOpenView
    private let content = NSView()
    private let shape = CAShapeLayer()
    private let maskShape = CAShapeLayer()

    /// Where the shape is going (or is, at rest), in screen points.
    private(set) var silhouette = IslandSilhouette.zero
    /// The window's frame the paths are drawn for.
    private(set) var windowFrame = CGRect.zero
    /// The closed panel was clicked (or pressed by VoiceOver).
    var onClickClosed: (() -> Void)?
    /// The closed panel's sentence for VoiceOver ("" while open).
    var closedLabel = "" { didSet { updateAccessibility() } }
    var isOpen = false { didSet { updateAccessibility() } }

    init(actions: IslandActions) {
        open = IslandOpenView(actions: actions)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        shape.fillColor = NSColor.black.cgColor
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0
        shape.shadowRadius = 12
        shape.shadowOffset = CGSize(width: 0, height: -8)
        layer?.addSublayer(shape)
        content.wantsLayer = true
        maskShape.fillColor = NSColor.black.cgColor
        content.layer?.mask = maskShape
        addSubview(content)
        content.addSubview(marks)
        content.addSubview(line)
        content.addSubview(nudge)
        content.addSubview(open)
        open.alphaValue = 0
        open.isHidden = true
        nudge.alphaValue = 0
        nudge.isHidden = true
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A rectangle on screen in this view's coordinates (y up, the window's origin at 0,0).
    func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY) }

    /// A spring (or a fade) is moving the shape now.
    var isMovingShape: Bool { shape.animation(forKey: "path") != nil }

    /// While a move runs, the shape as drawn now, in the window frame the paths are drawn for. A move
    /// added in this same turn of the run loop isn't on screen yet (it starts when the turn ends): the
    /// shape is still where that move starts, and the presentation would show it as it was before, for
    /// the window as it was then.
    private var drawnPath: CGPath? {
        guard let a = shape.animation(forKey: "path") else { return nil }
        if a.beginTime == 0, let f = (a as? CABasicAnimation)?.fromValue, CFGetTypeID(f as CFTypeRef) == CGPath.typeID {
            return (f as! CGPath)
        }
        return shape.presentation()?.path
    }

    /// Show `s` in a window at `frame`, springing from `from` (in the same window) when given. A move that
    /// takes over from one still running starts where the shape is drawn now (moved into the new window),
    /// not from `from`, so it never jumps; a shape set without a move ends any move still running, which
    /// was drawn for the window as it was.
    func setShape(_ s: IslandSilhouette, frame: CGRect, from: IslandSilhouette? = nil, spring: (response: Double, damping: Double)? = nil,
                  fade: Double = 0, completion: (() -> Void)? = nil) {
        let oldFrame = windowFrame
        let drawnNow = drawnPath
        windowFrame = frame
        silhouette = s
        let to = IslandGeometry.path(s, in: frame)
        let start = from.map { f in drawnNow.map { IslandGeometry.path($0, from: oldFrame, to: frame) } ?? IslandGeometry.path(f, in: frame) }
        let moves = start != nil && ((spring != nil && !PongMotion.reduced) || fade > 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        shape.frame = bounds
        maskShape.frame = bounds
        if !moves {
            shape.removeAnimation(forKey: "path")
            maskShape.removeAnimation(forKey: "path")
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion?() }
        if let start, let spring, !PongMotion.reduced {
            for l in [shape, maskShape] {
                let a = CASpringAnimation(keyPath: "path")
                // a spring by its response and damping ratio (stiffness and damping for a mass of 1)
                a.mass = 1
                a.stiffness = CGFloat(pow(2 * Double.pi / spring.response, 2))
                a.damping = CGFloat(4 * Double.pi * spring.damping / spring.response)
                a.fromValue = start
                a.toValue = to
                a.duration = min(1.2, a.settlingDuration)
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                l.add(a, forKey: "path")
            }
        } else if let start, fade > 0 {
            for l in [shape, maskShape] {
                let a = CABasicAnimation(keyPath: "path")
                a.fromValue = start
                a.toValue = to
                a.duration = fade
                l.add(a, forKey: "path")
            }
        }
        CATransaction.setDisableActions(true)
        shape.path = to
        maskShape.path = to
        shape.shadowPath = to
        CATransaction.commit()
    }

    /// The soft shadow under the open panel (level 2), none closed.
    func setShadow(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.shadowOpacity = on && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.5 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        shape.frame = bounds
        maskShape.frame = bounds
        CATransaction.commit()
    }

    // Clicks beside the shape pass through (§4.1); the screen's top row counts as inside.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let onScreen = window.convertPoint(toScreen: point)
        guard IslandGeometry.hits(silhouette, onScreen) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isOpen { onClickClosed?() }
    }

    private func updateAccessibility() {
        setAccessibilityElement(!isOpen && !closedLabel.isEmpty)
        setAccessibilityRole(isOpen ? .group : .button)
        setAccessibilityLabel(isOpen ? "Notch panel" : closedLabel)
        setAccessibilityHelp(isOpen ? nil : "Opens the notch panel.")
    }

    override func accessibilityPerformPress() -> Bool {
        guard !isOpen else { return false }
        onClickClosed?()
        return true
    }
}

// MARK: - The open panel

/// Everything one drawing of the open panel needs.
struct IslandOpenData {
    var state = IslandState()
    var input = IslandInput()
    var settings = IslandSettings()
    /// The list it shows (the switch, or Automatic resolved).
    var view = IslandSettings.View.graphs
    var hasNotch = true
    var chin: CGFloat = 34
    /// The notch's left and right edges from the open body's left edge.
    var notchLeft: CGFloat = 127
    var notchRight: CGFloat = 313
    var pinned = false
    /// The closed panel's marks (the band repeats them on a screen without a notch).
    var marks: [IslandMark] = []
}

/// The open panel (§5): a top band, the count line, banners, one scroll area (questions first, then the
/// list), the message box in Teams, and the footer.
final class IslandOpenView: IslandFlipped, NSTextFieldDelegate {
    weak var actions: IslandActions?
    private(set) var data = IslandOpenData()

    // band
    private let pin = IslandIconButton("pin", onSymbol: "pin.fill", label: "Keep open")
    private let more = IslandIconButton("ellipsis", label: "More")
    let segment = PongSegmented(["Graphs", "Teams"], tips: ["Show your graphs step by step, or your teams and their AIs.",
                                                            "Show your graphs step by step, or your teams and their AIs."])
    private let bandMarks = IslandMarksView()
    // count line and banners
    private let countLine = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary)
    private var banners: [IslandBannerView] = []
    // the scrolling part
    let scroll = NSScrollView()
    private let doc = IslandFlipped()
    // pinned answers of a card that doesn't fit, the message box, a passing notice and the footer
    private var pinnedFooter: NSView?
    private let pinnedRule = NSView()
    let messageBox = IslandMessageBox()
    private let notice = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary, lines: 2)
    private var noticeWork: DispatchWorkItem?
    private let footerRule = NSView()
    private let newGraph = PongButton(title: "New graph", style: .quiet, size: .small)
    private let openApp = PongButton(title: "Open CyberPong", style: .quiet, size: .small)
    private let week = IslandLabel("", font: PongType.meta, color: IslandStyle.tertiary)

    // the list's own state
    /// The question the card shows (nil: the oldest that can be a card).
    var focusKey: String?
    /// Graphs whose step list is open.
    private var stepsOpen: Set<String> = []
    private var finishedOpen = false
    /// The row picked with ↑ / ↓ (a graph's or a team's key).
    private(set) var selectedKey: String?
    /// A row to scroll to and mark once (a chip or a team name was clicked).
    private var revealKey: String?
    /// Questions answered here: hidden until the feed stops listing them.
    private var answered: [String: Double] = [:]
    /// The answered card, kept for its receipt.
    private var receiptUntil: Double = 0
    /// "That's everything." after the last answer.
    private(set) var allDone = false

    private(set) var card: QuestionCardView?
    /// Each graph's track and times sent back at the last drawing: work sent back eases its track back.
    private var lastTracks: [String: (track: [IslandTrack], sentBack: Int)] = [:]
    private var rowViews: [String: NSView] = [:]
    private var selectableKeys: [String] = []
    private var focusedNeeds: [IslandNeed] = []

    static let footerH: CGFloat = 44
    static let side: CGFloat = 12
    static var contentW: CGFloat { IslandGeometry.openContentWidth }

    init(actions: IslandActions) {
        self.actions = actions
        super.init(frame: .zero)
        pin.onPress = { [weak self] in self?.actions?.islandTogglePin() }
        more.onPress = { [weak self] in self?.showMore() }
        more.setAccessibilityHelp("New graph, Open CyberPong, Notch panel settings, Hide the notch panel")
        segment.setAccessibilityLabel("Show")
        segment.onChange = { [weak self] i in self?.actions?.islandSetView(i == 0 ? .graphs : .teams) }
        addSubview(pin)
        addSubview(more)
        addSubview(segment)
        addSubview(bandMarks)
        addSubview(countLine)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        pinnedRule.wantsLayer = true
        pinnedRule.layer?.backgroundColor = IslandStyle.hairline.cgColor
        addSubview(pinnedRule)
        messageBox.onSend = { [weak self] text, team, done in self?.actions?.islandSend(text, to: team, done: done) }
        messageBox.onMenu = { [weak self] showing in self?.actions?.islandMenu(showing) }
        addSubview(messageBox)
        notice.isHidden = true
        addSubview(notice)
        footerRule.wantsLayer = true
        footerRule.layer?.backgroundColor = IslandStyle.hairline.cgColor
        addSubview(footerRule)
        newGraph.symbol = "plus"
        newGraph.toolTip = "Start a new graph with a chat"
        newGraph.onPress = { [weak self] in self?.actions?.islandNewGraph() }
        openApp.symbol = "arrow.up.right"
        openApp.toolTip = "Open CyberPong's window"
        openApp.onPress = { [weak self] in self?.actions?.islandOpenApp() }
        addSubview(newGraph)
        addSubview(openApp)
        addSubview(week)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Notch panel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: State for the controller

    /// A note or a message is being typed.
    var isTyping: Bool {
        (card?.isEditingNote ?? false) || messageBox.isEditing
    }

    /// A question card is showing (the panel then waits at least 3 s before it closes).
    var showsQuestion: Bool { card != nil && !(card?.answered ?? true) }

    var holdsReceipt: Bool { Date().timeIntervalSince1970 < receiptUntil }

    /// The question card on show.
    var focusedCard: QuestionCardView? { card }

    // MARK: Drawing

    /// Draw from one read. `force`: rebuild the question card too (the person moved to another one).
    func render(_ d: IslandOpenData, force: Bool = false) {
        data = d
        let now = d.input.now
        answered = answered.filter { now - $0.value < 30 }
        // the band
        pin.on = d.pinned
        pin.setAccessibilityValue(d.pinned ? "on" : "off")
        segment.select(d.view == .teams ? 1 : 0)
        bandMarks.set(d.marks)
        bandMarks.isHidden = d.hasNotch
        // the count line
        countLine.set(countWords(d.state))
        // banners: made again only when they change (or the panel opens), so a button under the pointer
        // keeps its hover and a click on it that is under way lands (a read comes every 2.5 s while open)
        if force || d.state.banners != shownBanners {
            banners.forEach { $0.removeFromSuperview() }
            banners = d.state.banners.map { b in
                let v = IslandBannerView(b)
                v.onAction = { [weak self] in self?.actions?.islandBanner(b.kind) }
                addSubview(v)
                return v
            }
            shownBanners = d.state.banners
        }
        week.stringValue = d.state.footerWeek ?? ""
        let viewChanged = messageBox.isHidden != (d.view != .teams)
        messageBox.isHidden = d.view != .teams
        messageBox.setTeams(d.input.teams.filter { $0.running }.map { ($0.session, $0.name) })
        // rows never move under the pointer or the keyboard: the list waits until they leave it (a pick
        // of its own doesn't)
        if !force && !viewChanged && holdsList {
            listPending = true
        } else {
            listPending = false
            buildList(force: force)
        }
        needsLayout = true
    }

    /// The banners on show, as they were read.
    private var shownBanners: [IslandBanner]?

    /// The list's new read waits while the pointer or the keyboard is on it.
    private var listPending = false

    private var holdsList: Bool { pointerOverList || focusInList }

    private var pointerOverList: Bool {
        guard let w = window, !scroll.isHidden else { return false }
        let p = scroll.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return scroll.bounds.contains(p)
    }

    /// The keyboard is on a button in the list (VoiceOver's cursor takes it along). A note being typed
    /// doesn't hold it: its card is kept anyway, and the rows under it go on.
    private var focusInList: Bool {
        guard let v = window?.firstResponder as? NSView, !(v is NSText) else { return false }
        return v.isDescendant(of: doc)
    }

    /// The pointer (and the keyboard) left the list: the read that waited comes in.
    func flushIfPointerLeft() {
        guard listPending, !holdsList else { return }
        listPending = false
        buildList(force: false)
        needsLayout = true
        actions?.islandContentChanged()
    }

    /// "◆ 2 need you   ◠ 3 working   ‖ 1 paused", or "All quiet."
    private func countWords(_ s: IslandState) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // with the engine off nothing is known: no "All quiet." under its banner
        if s.countLine.isEmpty && s.engineOff { return out }
        if s.countLine.isEmpty {
            out.append(NSAttributedString(string: s.countQuiet.isEmpty ? "All quiet." : s.countQuiet,
                                          attributes: [.font: PongType.secondary, .foregroundColor: PongColor.textSecondary]))
            return out
        }
        for c in s.countLine {
            if out.length > 0 { out.append(NSAttributedString(string: "   ", attributes: [.font: PongType.secondary])) }
            let tone: NSColor = c.dim ? IslandStyle.tertiary : (c.status == .needsYou ? PongColor.you : c.status.color)
            out.append(NSAttributedString(string: IslandStyle.sign(c.status) + " ",
                                          attributes: [.font: PongType.secondary, .foregroundColor: c.dim ? PongColor.textDisabled : tone]))
            out.append(NSAttributedString(string: c.words, attributes: [
                .font: PongType.secondary,
                .foregroundColor: c.dim ? IslandStyle.tertiary : (c.status == .needsYou ? PongColor.you : PongColor.textSecondary)]))
        }
        return out
    }

    /// The needs, without the ones answered here a moment ago.
    private var needs: [IslandNeed] { data.state.needs.filter { answered[$0.key] == nil } }

    private func buildList(force: Bool) {
        let keepCard = card.flatMap { c -> QuestionCardView? in
            // a card being typed in, answering, armed or showing its receipt is left alone
            if c.isEditingNote || c.isSending || c.isStopArmed || (c.answered && holdsReceipt) { return c }
            return nil
        }
        // a read that changes nothing replaces nothing: each view showing the same thing as before is
        // kept (the person moving to another question builds afresh)
        reusable = force ? [:] : shown
        building = []
        built = [:]
        rowViews = [:]
        selectableKeys = []
        let W = IslandOpenView.contentW
        let list = needs
        focusedNeeds = list
        // the focused question: kept while it waits; else the oldest that can be a card
        if let k = focusKey, !list.contains(where: { $0.key == k && $0.kind != .step }) { focusKey = nil }
        if focusKey == nil { focusKey = list.first { $0.kind != .step }?.key }
        if keepCard == nil {
            let model = focusKey.flatMap { questionModel($0) }
            if let c = card, let m = model, !force, c.model.key == m.key, c.model.redrawKey == m.redrawKey,
               c.model.jevLine?.lead == m.jevLine?.lead, !c.answered {
                card = c   // the same words: keep it (and the person's note, details and scroll)
            } else {
                dropCard()
                card = model.map { makeCard($0) }
            }
        } else {
            card = keepCard
        }
        card?.refreshWaited()

        if !list.isEmpty || card != nil {
            let i = (list.firstIndex { $0.key == card?.model.key } ?? 0) + 1
            let words = list.isEmpty ? "Needs you" : "Needs you · \(min(i, list.count)) of \(list.count)"
            // the eyebrow, then the card, then the other questions
            keepOrMake("needs-eyebrow:" + words) { () -> NSView in
                let e = PongUI.eyebrow(words, color: PongColor.you)
                e.identifier = NSUserInterfaceItemIdentifier("needs-eyebrow")
                return e
            }
            if let c = card { building.append(c) }
            for n in list where n.key != card?.model.key {
                let row = keepOrMake("need:" + n.key, keep: { (r: IslandNeedRowView) in r.need == n }) { () -> IslandNeedRowView in
                    let row = IslandNeedRowView(n, now: data.input.now, width: W)
                    row.onFocus = { [weak self] in
                        guard n.kind != .step else { return }
                        self?.focusKey = n.key
                        self?.buildList(force: true)
                        self?.actions?.islandContentChanged()
                    }
                    row.onOpenScreen = { [weak self] in self?.actions?.islandOpenScreen(n.graphKey, node: n.nodeId) }
                    return row
                }
                row.refreshWaited(now: data.input.now)
            }
            allDone = false
        }
        for p in data.state.problems {
            keepOrMake("problem:" + p.key, keep: { (v: IslandProblemView) in v.problem == p }) { () -> IslandProblemView in
                let v = IslandProblemView(p)
                v.onRetry = { [weak self] in self?.actions?.islandRetry(p.graphKey, node: p.nodeId) }
                v.onOpen = { [weak self] in self?.actions?.islandOpenGraph(p.graphKey, tab: nil) }
                return v
            }
        }
        if allDone && list.isEmpty && card == nil {
            let closes = data.settings.afterLast == .close
            keepOrMake("all-done:\(closes)") { IslandAllDoneView(closes: closes) }
        }
        if data.view == .teams { buildTeams(W) } else { buildGraphs(W, compact: !list.isEmpty) }
        // in one step: views kept are only moved, never taken out, so they keep the pointer's hover, the
        // keyboard and VoiceOver's place (and a card being typed in keeps its note)
        doc.subviews = building
        shown = built
        building = []
        built = [:]
        reusable = [:]
    }

    /// The list's views at the last build, by what each shows ("graph:" and a graph's key, "need:" and a
    /// question's key, an eyebrow by its words).
    private var shown: [String: NSView] = [:]
    /// While building: the last build's views that may be kept, and this build's views in order and by key.
    private var reusable: [String: NSView] = [:]
    private var building: [NSView] = []
    private var built: [String: NSView] = [:]

    /// The view for `key` in this build: the last build's when `keep` says it can show the new read (it
    /// may update its words in place), else a new one from `make`.
    @discardableResult
    private func keepOrMake<V: NSView>(_ key: String, keep: (V) -> Bool = { _ in true }, make: () -> V) -> V {
        let v: V
        if built[key] == nil, let old = reusable[key] as? V, keep(old) { v = old } else { v = make() }
        if built[key] == nil { built[key] = v }
        reusable[key] = nil
        building.append(v)
        return v
    }

    private func buildGraphs(_ W: CGFloat, compact: Bool) {
        let s = data.state
        if s.graphGroups.isEmpty {
            // the engine off: its banner says so, and "No graphs running" would be a guess
            if s.engineOff { return }
            if needs.isEmpty && card == nil && !allDone {
                // [+ New graph] is the footer's, right under it
                let title = s.emptyTitle.isEmpty ? "Nothing needs you." : s.emptyTitle
                keepOrMake("empty:" + title + "|" + s.emptyLine) { IslandEmptyView(title: title, line: s.emptyLine, button: nil) }
            } else if !s.emptyLine.isEmpty {
                keepOrMake("empty:|" + s.emptyLine) { IslandEmptyView(title: "", line: s.emptyLine, button: nil) }
            }
            return
        }
        let before = lastTracks
        lastTracks = Dictionary(s.graphRows.map { ($0.key, ($0.track, $0.sentBack)) }, uniquingKeysWith: { a, _ in a })
        for g in s.graphGroups {
            keepOrMake("eyebrow:" + g.title) { eyebrow(g.title) }
            if g.kind == .finished {
                let title = finishedOpen ? "Hide finished" : g.foldTitle
                let label = finishedOpen ? "Hide finished graphs" : g.foldTitle
                keepOrMake("fold:" + title) { () -> PongButton in
                    let fold = PongButton(title: title, style: .quiet, size: .small)
                    fold.identifier = NSUserInterfaceItemIdentifier("fold")
                    fold.onPress = { [weak self] in
                        guard let self else { return }
                        self.finishedOpen.toggle()
                        self.buildList(force: false)
                        self.actions?.islandContentChanged()
                    }
                    fold.setAccessibilityLabel(label)
                    return fold
                }
                if !finishedOpen { continue }
            }
            for r in g.rows {
                let rowCompact = compact && !r.oneLine
                let rowSteps = stepsOpen.contains(r.key)
                // the same graph with new words and times: its row shows them in place
                let keep = { (old: IslandGraphRowView) in old.update(r, compact: rowCompact, stepsOpen: rowSteps) }
                let v = keepOrMake("graph:" + r.key, keep: keep) { () -> IslandGraphRowView in
                    let v = IslandGraphRowView(r, compact: rowCompact, stepsOpen: rowSteps)
                    v.onOpen = { [weak self] in self?.actions?.islandOpenGraph(r.key, tab: nil) }
                    v.onPause = { [weak self] in self?.actions?.islandPause(r.key) }
                    v.onResume = { [weak self] in self?.actions?.islandResume(r.key) }
                    v.onTeam = { [weak self] in self?.showTeam(r.session) }
                    v.onSteps = { [weak self] in
                        guard let self else { return }
                        if self.stepsOpen.contains(r.key) { self.stepsOpen.remove(r.key) } else { self.stepsOpen.insert(r.key) }
                        self.buildList(force: false)
                        self.actions?.islandContentChanged()
                    }
                    v.onAction = { [weak self] a in self?.rowAction(a, r) }
                    // sent back: the track eases back over 400 ms, so progress going backwards never looks
                    // like a glitch (§5.5; at once under Reduce Motion)
                    if let b = before[r.key], b.track != r.track, !PongMotion.reduced,
                       IslandOpenView.wentBack(b.track, r.track) || r.sentBack > b.sentBack {
                        v.easeTrack(from: b.track)
                    }
                    return v
                }
                v.selected = selectedKey == r.key || revealKey == r.key
                rowViews[r.key] = v
                selectableKeys.append(r.key)
            }
        }
    }

    private func buildTeams(_ W: CGFloat) {
        let s = data.state
        if s.teamRows.isEmpty {
            let title = s.teamsEmptyTitle.isEmpty ? "No teams yet." : s.teamsEmptyTitle
            keepOrMake("empty:" + title + "|" + s.teamsEmptyLine) { IslandEmptyView(title: title, line: s.teamsEmptyLine, button: nil) }
        } else {
            keepOrMake("eyebrow:Teams") { eyebrow("Teams") }
            for t in s.teamRows {
                let key = "team:" + t.session
                // the same team with new words (what each AI is doing, the lead's last message) in place
                let v = keepOrMake(key, keep: { (old: IslandTeamRowView) in old.update(t) }) { () -> IslandTeamRowView in
                    let v = IslandTeamRowView(t, width: W)
                    v.onStart = { [weak self] in self?.actions?.islandStartTeam(t.session) }
                    v.onChip = { [weak self] key in self?.showGraph(key) }
                    return v
                }
                v.selected = selectedKey == key || revealKey == key
                rowViews[key] = v
                selectableKeys.append(key)
            }
        }
        if !s.chatRows.isEmpty {
            keepOrMake("eyebrow:Chats") { eyebrow("Chats") }
            for c in s.chatRows {
                keepOrMake("chat:" + c.key, keep: { (v: IslandChatRowView) in v.chat == c }) { () -> IslandChatRowView in
                    let v = IslandChatRowView(c)
                    v.onOpen = { [weak self] in self?.actions?.islandOpenChat(c.key) }
                    return v
                }
            }
        }
    }

    /// The track's first segment not yet done moved left.
    static func wentBack(_ a: [IslandTrack], _ b: [IslandTrack]) -> Bool {
        func at(_ t: [IslandTrack]) -> Int { t.firstIndex { $0 != .done } ?? t.count }
        return !a.isEmpty && !b.isEmpty && at(b) < at(a)
    }

    private func eyebrow(_ s: String) -> NSView {
        let e = PongUI.eyebrow(s)
        e.identifier = NSUserInterfaceItemIdentifier("eyebrow")
        return e
    }

    private func makeCard(_ m: QuestionModel) -> QuestionCardView {
        let c = QuestionCardView(m, size: .island)
        c.focused = true
        c.onOpen = { [weak self] in
            if let k = m.graphKey { self?.actions?.islandOpenGraph(k, tab: nil) } else if let ch = m.chatKey { self?.actions?.islandOpenChat(ch) }
        }
        c.onHeightChange = { [weak self] in
            self?.needsLayout = true
            self?.actions?.islandContentChanged()
        }
        c.onReceipt = { [weak self] _ in
            guard let self else { return }
            self.receiptUntil = Date().timeIntervalSince1970 + 1.5
            self.answered[m.key] = Date().timeIntervalSince1970
            self.actions?.islandAnswered(m.key)
        }
        return c
    }

    /// The card goes, its answers too when they were pinned to the panel's foot.
    private func dropCard() {
        if let c = card, c.footerPinned { c.footer.removeFromSuperview() }
        pinnedFooter = nil
        card?.removeFromSuperview()
        card = nil
    }

    /// A need's card model: a graph's gate, or a chat's question.
    private func questionModel(_ key: String) -> QuestionModel? {
        guard let n = focusedNeeds.first(where: { $0.key == key }) else { return nil }
        switch n.kind {
        case .question:
            let parts = key.components(separatedBy: "#")
            guard let g = data.input.graphs.first(where: { $0.key == n.graphKey }), let node = parts.last,
                  let gate = g.gates.first(where: { $0.node == node }) else { return nil }
            return QuestionModel(graph: g, gate: gate)
        case .chat:
            guard let a = data.input.asks.first(where: { $0.key == key }) else { return nil }
            return QuestionModel(ask: a, architects: data.input.architects)
        case .step:
            return nil
        }
    }

    /// The receipt has had its moment: the next question moves up, or "That's everything."
    func afterReceipt() {
        receiptUntil = 0
        let hadCard = card != nil
        dropCard()
        focusKey = nil
        if hadCard && needs.isEmpty { allDone = true }
        buildList(force: true)
        needsLayout = true
    }

    func clearAllDone() { allDone = false }

    /// Open a graph row's step list (the preview's `islandsteps:`).
    func openSteps(_ key: String) {
        stepsOpen.insert(key)
        buildList(force: false)
        needsLayout = true
    }

    private func rowAction(_ a: IslandRowAction, _ r: IslandGraphRow) {
        switch a {
        case .watch: actions?.islandOpenGraph(r.key, tab: .screen)
        case .resume: actions?.islandResume(r.key)
        case .startTeam: actions?.islandStartTeam(r.session)
        case .openGraph: actions?.islandOpenGraph(r.key, tab: nil)
        case .openScreen:
            let node = data.input.graphs.first { $0.key == r.key }?.nodes.first { !$0.attention.isEmpty && $0.status == "running" }?.id ?? ""
            actions?.islandOpenScreen(r.key, node: node)
        }
    }

    /// A team's name in a graph row: the Teams view, at that team.
    private func showTeam(_ session: String) {
        revealKey = "team:" + session
        actions?.islandSetView(.teams)
    }

    /// A graph chip in a team row: the Graphs view, at that graph.
    private func showGraph(_ key: String) {
        revealKey = key
        actions?.islandSetView(.graphs)
    }

    // MARK: Keyboard (§8.4)

    /// Tab / ⇧Tab: the next or previous question becomes the card.
    func moveQuestion(_ by: Int) {
        let cards = needs.filter { $0.kind != .step }
        guard cards.count > 1, let i = cards.firstIndex(where: { $0.key == card?.model.key }) else { return }
        focusKey = cards[(i + by + cards.count) % cards.count].key
        buildList(force: true)
        actions?.islandContentChanged()
    }

    /// ↑ / ↓ over the rows.
    func moveSelection(_ by: Int) {
        guard !selectableKeys.isEmpty else { return }
        let i = selectedKey.flatMap { selectableKeys.firstIndex(of: $0) }
        let next = i.map { min(max(0, $0 + by), selectableKeys.count - 1) } ?? (by > 0 ? 0 : selectableKeys.count - 1)
        selectedKey = selectableKeys[next]
        for (k, v) in rowViews {
            (v as? IslandGraphRowView)?.selected = k == selectedKey
            (v as? IslandTeamRowView)?.selected = k == selectedKey
        }
        if let v = selectedKey.flatMap({ rowViews[$0] }) { doc.scrollToVisible(v.frame.insetBy(dx: 0, dy: -8)) }
    }

    /// Return: open the picked row in CyberPong.
    func openSelection() -> Bool {
        guard let k = selectedKey else { return false }
        if k.hasPrefix("team:") {
            PanelController.shared.openTeam(String(k.dropFirst(5)))
            actions?.islandOpenApp()
        } else {
            actions?.islandOpenGraph(k, tab: nil)
        }
        return true
    }

    /// A row the person picked elsewhere (a step's graph, a team): scroll to it once.
    private func reveal() {
        guard let k = revealKey, let v = rowViews[k] else { return }
        doc.scrollToVisible(v.frame.insetBy(dx: 0, dy: -8))
        revealKey = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak v] in
            (v as? IslandGraphRowView)?.selected = false
            (v as? IslandTeamRowView)?.selected = false
        }
    }

    func showNotice(_ text: String, warn: Bool = false) {
        notice.stringValue = text
        notice.textColor = warn ? PongColor.fail : PongColor.textSecondary
        notice.isHidden = text.isEmpty
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        noticeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.notice.isHidden = true
            self?.needsLayout = true
            self?.actions?.islandContentChanged()
        }
        noticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (warn ? 6 : 4), execute: w)
        needsLayout = true
        actions?.islandContentChanged()
    }

    // MARK: The ⋯ menu

    private func showMore() {
        let menu = NSMenu()
        let items: [(String, () -> Void)] = [
            ("New graph", { [weak self] in self?.actions?.islandNewGraph() }),
            ("Open CyberPong", { [weak self] in self?.actions?.islandOpenApp() }),
            ("Notch panel settings…", { [weak self] in self?.actions?.islandOpenSettings() }),
            ("Hide the notch panel", { [weak self] in self?.actions?.islandHide() }),
        ]
        var boxes: [ClosureBox] = []
        for (i, (title, fn)) in items.enumerated() {
            if i == 3 { menu.addItem(.separator()) }
            let box = ClosureBox(fn)
            boxes.append(box)
            let item = NSMenuItem(title: title, action: #selector(ClosureBox.fire), keyEquivalent: "")
            item.target = box
            menu.addItem(item)
        }
        actions?.islandMenu(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        withExtendedLifetime(boxes) {}
        actions?.islandMenu(false)
    }

    override func mouseDown(with event: NSEvent) {
        // the notch's own place in the band pins the panel, or lets it go (§8.3)
        let p = convert(event.locationInWindow, from: nil)
        if p.y <= data.chin, p.x >= data.notchLeft, p.x <= data.notchRight { actions?.islandClickNotch() }
    }

    // MARK: Layout

    private var bandH: CGFloat { data.hasNotch ? data.chin : 32 }

    /// How tall the panel wants to be for its content (before the cap).
    func preferredHeight() -> CGFloat {
        layoutAll(height: nil)
    }

    override func layout() {
        super.layout()
        _ = layoutAll(height: bounds.height)
        reveal()
    }

    /// Lays everything out at a height (nil: measures only) and returns the height wanted.
    @discardableResult
    private func layoutAll(height: CGFloat?) -> CGFloat {
        let apply = height != nil
        let W: CGFloat = IslandGeometry.openBody
        let side = IslandOpenView.side
        let inner = IslandOpenView.contentW
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        // band
        let bh = bandH
        if data.hasNotch {
            place(pin, NSRect(x: 8, y: (bh - 24) / 2, width: 24, height: 24))
            place(more, NSRect(x: 34, y: (bh - 24) / 2, width: 24, height: 24))
        } else {
            let mw = IslandMarksView.width(data.marks)
            place(bandMarks, NSRect(x: side, y: (bh - 16) / 2, width: mw + 4, height: 16))
            let x0 = side + (mw > 0 ? mw + 8 : 0)
            place(pin, NSRect(x: x0, y: (bh - 24) / 2, width: 24, height: 24))
            place(more, NSRect(x: x0 + 26, y: (bh - 24) / 2, width: 24, height: 24))
        }
        // the compact switch: 8 pt either side of each label (the app's is 12)
        let sw = segment.fittingSize.width - 16
        place(segment, NSRect(x: W - 8 - sw, y: (bh - 24) / 2, width: sw, height: 24))
        var y = bh + 2
        place(countLine, NSRect(x: side, y: y + 5, width: inner, height: 16))
        // with the engine off the count line says nothing: its banner comes up under the band
        y += countLine.attributedStringValue.length == 0 ? 6 : 26
        for b in banners {
            let h = b.height(for: inner)
            place(b, NSRect(x: side, y: y, width: inner, height: h))
            y += h + 6
        }
        y += 2
        let top = y
        // under the list: the pinned answers, the notice, the message box, the footer
        let footerH = IslandOpenView.footerH
        var bottomStack: CGFloat = footerH
        let boxH: CGFloat = messageBox.isHidden ? 0 : 44
        bottomStack += boxH
        // a notice is one line, or two when it is long ("… didn't resume. Try again in a moment.")
        let noticeH: CGFloat = notice.isHidden ? 0 : (IslandStyle.width(notice.stringValue, PongType.secondary) > inner ? 44 : 28)
        bottomStack += noticeH
        // the list's own height
        let docH = layoutDoc(width: inner, apply: apply)
        // a card that doesn't fit pins its answers to the panel's foot (the app's footerPinned)
        var pinH: CGFloat = 0
        if let h = height, let c = card, !c.answered {
            let avail = h - top - bottomStack
            let fullCard = c.height(for: inner)
            if fullCard + 40 > avail && avail > 120 {
                pinH = c.pinnedFooterHeight(for: inner)
                if !c.footerPinned {
                    c.footerPinned = true
                    addSubview(c.footer)
                    pinnedFooter = c.footer
                }
            } else if c.footerPinned {
                c.footerPinned = false
                pinnedFooter = nil
            }
        } else if let c = card, c.footerPinned, height == nil {
            pinH = c.pinnedFooterHeight(for: inner)
        }
        bottomStack += pinH
        let want = top + docH + bottomStack + 4
        guard let H = height else { return want }
        // the scroll area takes what is left
        let scrollH = max(40, H - top - bottomStack)
        scroll.frame = NSRect(x: side, y: top, width: inner, height: scrollH)
        // re-measure the doc with the pinned footer taken out
        let docH2 = layoutDoc(width: inner, apply: true)
        doc.frame = NSRect(x: 0, y: 0, width: inner, height: max(docH2, scrollH))
        var by = H - footerH
        place(footerRule, NSRect(x: side, y: by, width: inner, height: 1))
        let nw = newGraph.intrinsicContentSize.width
        place(newGraph, NSRect(x: side - 8, y: by + 10, width: nw, height: 24))
        let ow = openApp.intrinsicContentSize.width
        place(openApp, NSRect(x: side - 8 + nw + 4, y: by + 10, width: ow, height: 24))
        let ww = min(160, IslandStyle.width(week.stringValue, PongType.meta) + 4)
        place(week, NSRect(x: W - side - ww, y: by + 15, width: ww, height: 14))
        if boxH > 0 {
            by -= boxH
            place(messageBox, NSRect(x: side, y: by + 6, width: inner, height: 32))
        }
        if noticeH > 0 {
            by -= noticeH
            place(notice, NSRect(x: side, y: by + 6, width: inner, height: noticeH - 10))
        }
        if pinH > 0, let f = pinnedFooter {
            by -= pinH
            place(pinnedRule, NSRect(x: side, y: by, width: inner, height: 1))
            pinnedRule.isHidden = false
            f.frame = NSRect(x: side, y: by, width: inner, height: pinH)
            f.needsLayout = true
        } else {
            pinnedRule.isHidden = true
        }
        return want
    }

    /// The scrolling part, top to bottom; returns its height.
    private func layoutDoc(width W: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 4
        func place(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        for v in doc.subviews {
            switch v {
            case let c as QuestionCardView:
                let h = c.footerPinned ? c.bodyHeight(for: W) : c.height(for: W)
                place(c, NSRect(x: 0, y: y, width: W, height: h))
                y += h + 6
            case let r as IslandNeedRowView:
                place(r, NSRect(x: -6, y: y, width: W + 12, height: 36))
                y += 36
            case let p as IslandProblemView:
                let h = p.height(for: W)
                y += 4
                place(p, NSRect(x: 0, y: y, width: W, height: h))
                y += h + 4
            case let r as IslandGraphRowView:
                let h = r.height
                place(r, NSRect(x: -6, y: y, width: W + 12, height: h))
                y += h
            case let t as IslandTeamRowView:
                let h = t.height
                place(t, NSRect(x: 0, y: y, width: W, height: h))
                y += h
            case let c as IslandChatRowView:
                place(c, NSRect(x: 0, y: y, width: W, height: 44))
                y += 44
            case let e as IslandEmptyView:
                let h = e.height
                place(e, NSRect(x: 0, y: y, width: W, height: h))
                y += h
            case let a as IslandAllDoneView:
                place(a, NSRect(x: 0, y: y, width: W, height: 58))
                y += 58
            case let b as PongButton where b.identifier?.rawValue == "fold":
                place(b, NSRect(x: -8, y: y, width: b.intrinsicContentSize.width, height: 24))
                y += 26
            default:
                let id = v.identifier?.rawValue ?? ""
                if id == "needs-eyebrow" || id == "eyebrow" {
                    y += id == "needs-eyebrow" ? 4 : 12
                    let w = ceil((v as? NSTextField)?.attributedStringValue.size().width ?? 120) + 8
                    place(v, NSRect(x: 0, y: y, width: min(W, w), height: 16))
                    y += 22
                }
            }
        }
        return y + 4
    }
}

// MARK: - Rows

/// The step track: one segment per step place (10 × 4 pt, 2 pt apart; 6 pt wide in a compact row).
final class IslandTrackView: NSView {
    var track: [IslandTrack] = [] { didSet { needsDisplay = true } }
    var mini = false

    static func width(_ t: [IslandTrack], mini: Bool) -> CGFloat {
        guard !t.isEmpty else { return 0 }
        let seg: CGFloat = mini ? 6 : 10
        return CGFloat(t.count) * seg + CGFloat(t.count - 1) * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let seg: CGFloat = mini ? 6 : 10
        let edge = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var x: CGFloat = 0
        let y = (bounds.height - 4) / 2
        for t in track {
            let r = NSRect(x: x, y: y, width: seg, height: 4)
            let c: NSColor
            switch t {
            case .done: c = PongColor.textSecondary.withAlphaComponent(0.6)
            case .now: c = PongColor.live
            case .you: c = PongColor.you
            case .failed: c = PongColor.fail
            case .ahead: c = PongColor.mark
            }
            c.setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1)
            p.fill()
            if edge && t == .ahead {
                PongColor.textTertiary.setStroke()
                p.lineWidth = 1
                p.stroke()
            }
            x += seg + 2
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row with a hover fill and a click.
class IslandRow: IslandFlipped {
    var selected = false { didSet { needsDisplay = true } }
    private(set) var hovering = false
    private var tracking: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; onHover?(false) }

    var fillRect: NSRect { bounds.insetBy(dx: 0, dy: 1) }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering {
            (selected ? PongColor.overlay : PongColor.hover).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        }
        if selected {
            PongColor.live.setStroke()
            let p = NSBezierPath(roundedRect: fillRect.insetBy(dx: 1, dy: 1), xRadius: PongRadius.control, yRadius: PongRadius.control)
            p.lineWidth = 2
            p.stroke()
        }
    }
}

/// One graph (§5.5): full (three lines), compact while anything waits (two: the second is what it is
/// doing), or one line when finished. Hover shows Steps ›, Pause or Resume, and Open; a click anywhere
/// else on the row opens the graph in CyberPong.
final class IslandGraphRowView: IslandRow {
    private(set) var row: IslandGraphRow
    let compact: Bool
    let stepsOpen: Bool
    var onOpen: (() -> Void)?
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?
    var onTeam: (() -> Void)?
    var onSteps: (() -> Void)?
    var onAction: ((IslandRowAction) -> Void)?

    private let marker: StatusMarkerView
    private let name = IslandLabel("", font: PongType.bodyStrong, color: PongColor.textPrimary)
    private let team = NSButton(title: "", target: nil, action: nil)
    private let time = IslandLabel("", font: PongType.meta, color: IslandStyle.tertiary)
    private let track = IslandTrackView()
    private let fraction = IslandLabel("", font: PongType.meta, color: PongColor.textSecondary)
    private let line2 = IslandLabel("")
    private let line3 = IslandLabel("")
    private var action: PongButton?
    private let stepsBtn = PongButton(title: "Steps ›", style: .quiet, size: .small)
    /// ‖ Pause, or ▶ Resume on a graph that is paused.
    private let pauseBtn: IslandIconButton
    private let openBtn = IslandIconButton("arrow.up.right", label: "Open the graph")
    private var steps: IslandStepListView?
    private var teamBox: ClosureBox?

    init(_ r: IslandGraphRow, compact: Bool, stepsOpen: Bool) {
        row = r
        self.compact = compact
        self.stepsOpen = stepsOpen && !r.steps.isEmpty
        marker = StatusMarkerView(r.marker)
        pauseBtn = r.canResume ? IslandIconButton("play.fill", label: "Resume") : IslandIconButton("pause.fill", label: "Pause")
        super.init(frame: .zero)
        marker.setAccessibilityElement(false)
        addSubview(marker)
        name.stringValue = r.name
        name.toolTip = r.name
        name.lineBreakMode = .byTruncatingMiddle
        if r.titleDim { name.textColor = PongColor.textSecondary }
        addSubview(name)
        team.isBordered = false
        team.bezelStyle = .inline
        team.attributedTitle = NSAttributedString(string: r.team, attributes: [.font: PongType.secondary, .foregroundColor: IslandStyle.tertiary])
        team.toolTip = "Show \(r.team) in Teams"
        team.setAccessibilityLabel("Show \(r.team) in Teams")
        let box = ClosureBox { [weak self] in self?.onTeam?() }
        teamBox = box
        team.target = box
        team.action = #selector(ClosureBox.fire)
        team.isHidden = r.team.isEmpty
        addSubview(team)
        time.alignment = .right
        addSubview(time)
        track.track = r.track
        track.mini = compact
        track.setAccessibilityElement(false)
        addSubview(track)
        addSubview(fraction)
        addSubview(line2)
        addSubview(line3)
        showWords()
        if let a = r.action {
            let b = PongButton(title: a.title, style: a == .startTeam ? .secondary : .quiet, size: .small)
            b.onPress = { [weak self] in self?.onAction?(a) }
            if a == .startTeam { b.toolTip = "Start \(r.team) again: its lead and helpers, as it was set up" }
            action = b
            addSubview(b)
        }
        stepsBtn.title = self.stepsOpen ? "Hide steps" : "Steps ›"
        stepsBtn.toolTip = "Show this graph's steps here"
        stepsBtn.onPress = { [weak self] in self?.onSteps?() }
        pauseBtn.onPress = { [weak self] in
            guard let self else { return }
            if self.row.canResume { self.onResume?() } else { self.onPause?() }
        }
        openBtn.onPress = { [weak self] in self?.onOpen?() }
        for b in [stepsBtn, pauseBtn, openBtn] as [NSView] {
            b.isHidden = true
            addSubview(b)
        }
        showSteps()
        onHover = { [weak self] _ in self?.needsLayout = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var acts = [NSAccessibilityCustomAction(name: "Open") { [weak self] in self?.onOpen?(); return true }]
        if r.canPause { acts.append(NSAccessibilityCustomAction(name: "Pause") { [weak self] in self?.onPause?(); return true }) }
        if r.canResume { acts.append(NSAccessibilityCustomAction(name: "Resume") { [weak self] in self?.onResume?(); return true }) }
        if !r.steps.isEmpty {
            acts.append(NSAccessibilityCustomAction(name: self.stepsOpen ? "Hide steps" : "Show steps") { [weak self] in self?.onSteps?(); return true })
        }
        setAccessibilityCustomActions(acts)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row's words and times: what a new read changes without a new row.
    private func showWords() {
        let r = row
        time.stringValue = r.time
        fraction.stringValue = compact ? r.fraction : ""
        let small = PongType.secondary
        let ter = IslandStyle.tertiary
        if r.oneLine {
            line2.set(IslandStyle.attributed([(r.line2, small, r.marker == .failed ? PongColor.fail : PongColor.textSecondary)]))
        } else if compact {
            line2.set(IslandStyle.attributed([(r.compactLine, small, r.state == .quiet ? ter : PongColor.textSecondary),
                                              (r.compactAge.isEmpty ? "" : " · " + r.compactAge, small, ter)]))
        } else {
            line2.set(IslandStyle.attributed([(r.line2, small, PongColor.textSecondary),
                                              (r.line2Meta.isEmpty ? "" : " · " + r.line2Meta, small, ter)]))
            if let l3 = r.line3 {
                line3.set(IslandStyle.attributed([(l3, small, r.state == .quiet ? ter : PongColor.textSecondary),
                                                  (r.line3Age.isEmpty ? "" : " · " + r.line3Age, small, ter)]))
            }
        }
        setAccessibilityLabel(r.accessibilityLabel)
    }

    /// The step list, when it is open (made again only when its steps changed: it holds nothing of the
    /// person's).
    private func showSteps() {
        guard stepsOpen else { return }
        if let s = steps, s.rows == row.steps, s.more == row.moreSteps { return }
        steps?.removeFromSuperview()
        let s = IslandStepListView(row.steps, more: row.moreSteps)
        s.onMore = { [weak self] in self?.onOpen?() }
        steps = s
        addSubview(s)
    }

    /// Show `r` in this row as it is, when the new read changes only its words and times (how long it has
    /// run, what it is doing and since when, the AI and the round, the steps' words): the row stays, with
    /// the pointer's hover, a button being pressed and VoiceOver's place. False: it needs a row of its own.
    func update(_ r: IslandGraphRow, compact: Bool, stepsOpen: Bool) -> Bool {
        guard compact == self.compact, (stepsOpen && !r.steps.isEmpty) == self.stepsOpen else { return false }
        if r == row { return true }
        guard IslandGraphRowView.sameShape(row, r) else { return false }
        row = r
        showWords()
        showSteps()
        needsLayout = true
        return true
    }

    /// Two reads of a graph that draw the same row but for its words: the same buttons, marker, track,
    /// lines and height.
    static func sameShape(_ a: IslandGraphRow, _ b: IslandGraphRow) -> Bool {
        a.key == b.key && a.session == b.session && a.state == b.state && a.marker == b.marker && a.name == b.name
            && a.team == b.team && a.titleDim == b.titleDim && a.action == b.action && a.track == b.track
            && a.sentBack == b.sentBack && a.oneLine == b.oneLine && a.canPause == b.canPause && a.canResume == b.canResume
            && (a.line3 == nil) == (b.line3 == nil) && a.steps.count == b.steps.count && a.moreSteps == b.moreSteps
    }

    /// Show the track as it was, then ease it to where it is now (400 ms).
    func easeTrack(from old: [IslandTrack]) {
        let now = row.track
        track.track = old
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { self?.track.track = now; return }
            self.track.wantsLayer = true
            self.track.display()
            let t = CATransition()
            t.type = .fade
            t.duration = 0.4
            t.timingFunction = PongMotion.easeInOut
            self.track.layer?.add(t, forKey: "easeBack")
            self.track.track = now
        }
    }

    var height: CGFloat {
        if row.oneLine { return 36 }
        var h: CGFloat = compact ? 46 : (row.line3 == nil ? 46 : 64)
        // a 24 pt button beside the last line ([Start team], [Watch]) keeps clear of the divider
        if action != nil { h += 4 }
        if let s = steps { h += s.height + 4 }
        return h
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        let pad: CGFloat = 6
        let showHover = hovering && !row.oneLine
        marker.frame = NSRect(x: pad, y: row.oneLine ? 10 : 9, width: 16, height: 16)
        // the right end of line 1: hover buttons, else the track and time
        var right = W - pad
        let canHover = row.canPause || row.canResume
        stepsBtn.isHidden = !(showHover && !row.steps.isEmpty)
        pauseBtn.isHidden = !(showHover && canHover)
        openBtn.isHidden = !showHover
        let ly: CGFloat = row.oneLine ? 9 : 8
        if showHover {
            openBtn.frame = NSRect(x: right - 24, y: ly - 3, width: 24, height: 24)
            right -= 26
            if canHover {
                pauseBtn.frame = NSRect(x: right - 24, y: ly - 3, width: 24, height: 24)
                right -= 26
            }
            if !stepsBtn.isHidden {
                let sw = stepsBtn.intrinsicContentSize.width
                stepsBtn.frame = NSRect(x: right - sw, y: ly - 3, width: sw, height: 24)
                right -= sw + 4
            }
            time.isHidden = true
        } else {
            time.isHidden = false
            let tw = IslandStyle.width(row.time, PongType.meta) + 4
            time.frame = NSRect(x: right - tw, y: ly + 2, width: tw, height: 14)
            right -= tw + 6
        }
        if compact && !row.track.isEmpty && !showHover {
            let fw = IslandStyle.width(row.fraction, PongType.meta) + 4
            fraction.frame = NSRect(x: right - fw, y: ly + 2, width: fw, height: 14)
            right -= fw + 4
            let tw = IslandTrackView.width(row.track, mini: true)
            track.frame = NSRect(x: right - tw, y: ly + 5, width: tw, height: 8)
            right -= tw + 6
            track.isHidden = false
            fraction.isHidden = false
        } else if compact {
            track.isHidden = true
            fraction.isHidden = true
        }
        // name and team
        let x0: CGFloat = pad + 16 + 8
        let nameW = min(IslandStyle.width(row.name, PongType.bodyStrong) + 4, max(60, right - x0 - (team.isHidden ? 0 : 50)))
        name.frame = NSRect(x: x0, y: ly, width: nameW, height: 18)
        if !team.isHidden {
            let tw = min(IslandStyle.width(row.team, PongType.secondary) + 8, max(0, right - x0 - nameW - 4))
            team.frame = NSRect(x: x0 + nameW + 2, y: ly + 1, width: tw, height: 16)
            team.isHidden = tw < 24
        }
        if row.oneLine {
            // "Faster search  Juniper  Finished · passed ··· 12 min ago"
            let after = team.isHidden ? x0 + nameW : team.frame.maxX
            line2.frame = NSRect(x: after + 6, y: ly + 1, width: max(20, right - after - 6), height: 17)
            track.isHidden = true
            return
        }
        var y: CGFloat = ly + 19
        let lineRight = W - pad
        if !compact {
            var x = x0
            if !row.track.isEmpty {
                let tw = IslandTrackView.width(row.track, mini: false)
                track.frame = NSRect(x: x, y: y + 6, width: tw, height: 6)
                track.isHidden = false
                x += tw + 8
            } else {
                track.isHidden = true
            }
            var l2Right = lineRight
            if let a = action, row.line3 == nil {
                let aw = a.intrinsicContentSize.width
                a.frame = NSRect(x: lineRight - aw, y: y - 3, width: aw, height: 24)
                l2Right -= aw + 6
            }
            line2.frame = NSRect(x: x, y: y, width: max(20, l2Right - x), height: 17)
            y += 18
            if row.line3 != nil {
                var l3Right = lineRight
                if let a = action {
                    let aw = a.intrinsicContentSize.width
                    a.frame = NSRect(x: lineRight - aw, y: y - 3, width: aw, height: 24)
                    l3Right -= aw + 6
                }
                line3.frame = NSRect(x: x0, y: y, width: max(20, l3Right - x0), height: 17)
                y += 18
            }
        } else {
            var l2Right = lineRight
            if let a = action {
                let aw = a.intrinsicContentSize.width
                a.frame = NSRect(x: lineRight - aw, y: y - 3, width: aw, height: 24)
                l2Right -= aw + 6
            }
            line2.frame = NSRect(x: x0, y: y, width: max(20, l2Right - x0), height: 17)
            y += 18
        }
        if let s = steps {
            s.frame = NSRect(x: x0, y: y + 6, width: W - x0 - pad, height: s.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !selected && !hovering {
            IslandStyle.hairline.setFill()
            NSRect(x: 6, y: bounds.height - 1, width: bounds.width - 12, height: 1).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func mouseDown(with event: NSEvent) {}
}

/// A graph's steps inside its row: "03  ◠ Run the tests · running a command · Claude Sonnet ··· 2 min".
final class IslandStepListView: IslandFlipped {
    let rows: [IslandStepRow]
    /// How many steps the list leaves out.
    let more: Int
    private var moreBtn: PongButton?
    var onMore: (() -> Void)?

    init(_ rows: [IslandStepRow], more: Int) {
        self.rows = rows
        self.more = more
        super.init(frame: .zero)
        for r in rows {
            let n = IslandLabel(r.number, font: PongType.data, color: IslandStyle.tertiary)
            let m = StatusMarkerView(r.status, size: 12)
            m.setAccessibilityElement(false)
            let t = IslandLabel("")
            t.set(IslandStyle.attributed([(r.name, NSFont.systemFont(ofSize: 12, weight: .medium), PongColor.textPrimary),
                                          (r.words.isEmpty ? "" : " · " + r.words, PongType.secondary, PongColor.textSecondary)]))
            let tm = IslandLabel(r.time, font: PongType.meta, color: IslandStyle.tertiary)
            tm.alignment = .right
            for v in [n, m, t, tm] as [NSView] { addSubview(v) }
        }
        if more > 0 {
            let b = PongButton(title: "Open the graph for all \(rows.count + more) steps", style: .quiet, size: .small)
            b.onPress = { [weak self] in self?.onMore?() }
            moreBtn = b
            addSubview(b)
        }
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var height: CGFloat { CGFloat(rows.count) * 28 + (moreBtn == nil ? 0 : 28) }

    override func layout() {
        super.layout()
        let W = bounds.width
        var y: CGFloat = 0
        let views = subviews.filter { !($0 is PongButton) }
        for i in 0..<rows.count {
            let base = i * 4
            guard base + 3 < views.count else { break }
            let tw = IslandStyle.width(rows[i].time, PongType.meta) + 4
            views[base].frame = NSRect(x: 10, y: y + 6, width: 24, height: 16)
            views[base + 1].frame = NSRect(x: 36, y: y + 8, width: 12, height: 12)
            views[base + 3].frame = NSRect(x: W - tw, y: y + 7, width: tw, height: 14)
            views[base + 2].frame = NSRect(x: 54, y: y + 6, width: max(20, W - 54 - tw - 6), height: 16)
            y += 28
        }
        moreBtn?.frame = NSRect(x: 2, y: y + 2, width: moreBtn?.intrinsicContentSize.width ?? 0, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        PongColor.mark.setFill()
        NSRect(x: 0, y: 0, width: 1, height: CGFloat(rows.count) * 28).fill()
    }
}

/// A question under the card, one line: "◆ Release notes · Approve the changelog? ··· 4 min"; a click
/// makes it the card. A step asking on its screen offers [Open its screen].
final class IslandNeedRowView: IslandRow {
    var onFocus: (() -> Void)?
    var onOpenScreen: (() -> Void)?
    let need: IslandNeed
    /// "4 min": how long it has waited.
    private let waited: IslandLabel

    init(_ n: IslandNeed, now: Double, width: CGFloat) {
        need = n
        waited = IslandLabel(n.waited(now: now), font: PongType.meta, color: IslandStyle.tertiary)
        super.init(frame: .zero)
        let glyph: NSView = n.kind == .chat ? ChatGlyphView(live: true) : StatusMarkerView(.needsYou)
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        let text = IslandLabel("")
        if n.kind == .chat {
            text.set(IslandStyle.attributed([(n.subject + " chat asks: ", PongType.secondary, PongColor.textPrimary),
                                             (n.text, PongType.secondary, PongColor.textSecondary)]))
        } else {
            text.set(IslandStyle.attributed([(n.subject, NSFont.systemFont(ofSize: 12, weight: .semibold), PongColor.textPrimary),
                                             (" · " + n.text, PongType.secondary, PongColor.textSecondary)]))
        }
        addSubview(text)
        waited.alignment = .right
        addSubview(waited)
        if n.kind == .step {
            let b = PongButton(title: IslandRowAction.openScreen.title, style: .quiet, size: .small)
            b.onPress = { [weak self] in self?.onOpenScreen?() }
            addSubview(b)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Needs you: " + n.rowText + ", " + n.waited(now: now))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// "4 min" moves on in place (the row stays, with the pointer's hover and VoiceOver's place).
    func refreshWaited(now: Double) {
        let w = need.waited(now: now)
        guard w != waited.stringValue else { return }
        waited.stringValue = w
        setAccessibilityLabel("Needs you: " + need.rowText + ", " + w)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let glyph = subviews[0], text = subviews[1]
        if glyph is ChatGlyphView {
            glyph.frame = NSRect(x: 4, y: (H - 20) / 2, width: 20, height: 20)
        } else {
            glyph.frame = NSRect(x: 6, y: (H - 16) / 2, width: 16, height: 16)
        }
        var right = W - 6
        if subviews.count > 3, let b = subviews[3] as? PongButton {
            let bw = b.intrinsicContentSize.width
            b.frame = NSRect(x: right - bw, y: (H - 24) / 2, width: bw, height: 24)
            right -= bw + 6
        }
        let ww = IslandStyle.width(waited.stringValue, PongType.meta) + 4
        waited.frame = NSRect(x: right - ww, y: (H - 14) / 2, width: ww, height: 14)
        right -= ww + 8
        text.frame = NSRect(x: 30, y: (H - 16) / 2, width: max(20, right - 30), height: 16)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onFocus?() }
    }

    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onFocus?(); return true }
}

/// A step that hit an error (not a question): a red card with the fixes Home offers.
final class IslandProblemView: IslandFlipped {
    var onRetry: (() -> Void)?
    var onOpen: (() -> Void)?
    let problem: IslandProblem
    private let marker = StatusMarkerView(.failed)
    private let title = IslandLabel("", font: PongType.bodyStrong, color: PongColor.textPrimary)
    private let line = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary)
    private let retry = PongButton(title: "Run the step again", style: .secondary, size: .small)
    private let open = PongButton(title: "Open the graph", style: .quiet, size: .small)

    init(_ p: IslandProblem) {
        problem = p
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PongColor.tintFail.cgColor
        layer?.cornerRadius = 8
        marker.setAccessibilityElement(false)
        title.stringValue = p.title
        line.stringValue = p.line
        retry.onPress = { [weak self] in self?.onRetry?() }
        open.onPress = { [weak self] in self?.onOpen?() }
        for v in [marker, title, line, retry, open] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Problem: \(p.title). \(p.line)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func height(for width: CGFloat) -> CGFloat { 12 + 18 + 16 + 8 + 24 + 12 }

    override func layout() {
        super.layout()
        let W = bounds.width
        marker.frame = NSRect(x: 12, y: 13, width: 16, height: 16)
        title.frame = NSRect(x: 36, y: 12, width: W - 48, height: 18)
        line.frame = NSRect(x: 36, y: 30, width: W - 48, height: 16)
        let rw = retry.intrinsicContentSize.width
        retry.frame = NSRect(x: 36, y: 54, width: rw, height: 24)
        open.frame = NSRect(x: 36 + rw + 6, y: 54, width: open.intrinsicContentSize.width, height: 24)
    }
}

/// A problem the person can fix, or Claude's limit holding graphs (§5.3): 44 pt, its sign, its words and
/// its one button.
final class IslandBannerView: IslandFlipped {
    var onAction: (() -> Void)?
    private let banner: IslandBanner
    private let marker: StatusMarkerView
    private let text = IslandLabel("", font: PongType.secondary, color: PongColor.textPrimary, lines: 2)
    private let sub = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary)
    private var button: PongButton?

    init(_ b: IslandBanner) {
        banner = b
        marker = StatusMarkerView(b.isProblem ? .failed : .paused)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (b.isProblem ? PongColor.tintFail : PongColor.raised).cgColor
        layer?.cornerRadius = 8
        marker.setAccessibilityElement(false)
        addSubview(marker)
        text.stringValue = b.text
        text.toolTip = b.text
        addSubview(text)
        sub.stringValue = b.sub
        sub.isHidden = b.sub.isEmpty
        addSubview(sub)
        if let a = b.action {
            let btn = PongButton(title: a, style: b.isProblem ? .secondary : .quiet, size: .small)
            btn.onPress = { [weak self] in self?.onAction?() }
            switch b.kind {
            case .runnerOff: btn.toolTip = "Turn the graph runner on: it moves graphs on after each step, even while CyberPong is closed."
            case .limitWeek: btn.toolTip = "Start the paused graphs again now. They may stop at Claude's limit."
            case .engineOff: btn.toolTip = "Open Settings › This Mac"
            case .limit5h: break
            }
            button = btn
            addSubview(btn)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(b.accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func height(for width: CGFloat) -> CGFloat {
        let bw = button.map { $0.intrinsicContentSize.width + 10 } ?? 0
        let tw = width - 36 - 10 - bw
        let lines = IslandStyle.width(banner.text, PongType.secondary) > tw ? 2 : 1
        return max(44, 12 + CGFloat(lines) * 16 + (banner.sub.isEmpty ? 0 : 16) + 12)
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        marker.frame = NSRect(x: 10, y: 13, width: 16, height: 16)
        var right = W - 10
        if let b = button {
            let bw = b.intrinsicContentSize.width
            b.frame = NSRect(x: right - bw, y: (H - 24) / 2, width: bw, height: 24)
            right -= bw + 10
        }
        let subH: CGFloat = banner.sub.isEmpty ? 0 : 16
        let th = H - 24 - subH
        text.frame = NSRect(x: 36, y: 12, width: max(40, right - 36), height: th)
        sub.frame = NSRect(x: 36, y: 12 + th, width: max(40, right - 36), height: 16)
    }
}

/// One team (§5.6): its marker, name and graphs; its plain line; what each AI is doing; the lead's last
/// message; and a chip per graph (a click shows the graph in Graphs).
final class IslandTeamRowView: IslandFlipped {
    var onStart: (() -> Void)?
    var onChip: ((String) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private(set) var row: IslandTeamRow
    private let width: CGFloat
    private var memberViews: [(StatusMarkerView, IslandLabel)] = []
    private let marker: StatusMarkerView
    private let name = IslandLabel("", font: PongType.bodyStrong, color: PongColor.textPrimary)
    private let graphs = IslandLabel("", font: PongType.meta, color: IslandStyle.tertiary)
    private let plain = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary)
    private let message = IslandLabel("", font: PongType.secondary, color: PongColor.textSecondary, lines: 2)
    private var start: PongButton?
    private var chips: [NSButton] = []
    private var chipBoxes: [ClosureBox] = []

    init(_ t: IslandTeamRow, width: CGFloat) {
        row = t
        self.width = width
        marker = StatusMarkerView(t.marker)
        super.init(frame: .zero)
        marker.setAccessibilityElement(false)
        addSubview(marker)
        name.stringValue = t.name
        addSubview(name)
        graphs.alignment = .right
        addSubview(graphs)
        if t.stopped { plain.textColor = IslandStyle.tertiary }
        addSubview(plain)
        if t.stopped {
            let b = PongButton(title: "Start team", style: .secondary, size: .small)
            b.toolTip = "Start \(t.name) again: its lead and helpers, as it was set up"
            b.onPress = { [weak self] in self?.onStart?() }
            start = b
            addSubview(b)
            graphs.isHidden = true
        }
        for m in t.members {
            let mk = StatusMarkerView(m.status, size: 12)
            mk.setAccessibilityElement(false)
            let l = IslandLabel("")
            l.setAccessibilityElement(true)
            addSubview(mk)
            addSubview(l)
            memberViews.append((mk, l))
        }
        if !t.lastMessage.isEmpty {
            message.cell?.truncatesLastVisibleLine = true
            addSubview(message)
        }
        for c in t.chips {
            let b = NSButton(title: "", target: nil, action: nil)
            b.isBordered = false
            b.bezelStyle = .inline
            b.wantsLayer = true
            b.layer?.backgroundColor = PongColor.raised.cgColor
            b.layer?.cornerRadius = 4
            let s = NSMutableAttributedString(string: c.title, attributes: [.font: PongType.meta, .foregroundColor: PongColor.textSecondary])
            if !c.suffix.isEmpty {
                s.append(NSAttributedString(string: c.suffix, attributes: [.font: PongType.meta,
                                                                          .foregroundColor: c.needsYou ? PongColor.you : PongColor.textSecondary]))
            }
            b.attributedTitle = s
            b.toolTip = "Show this graph"
            b.setAccessibilityLabel("Show " + c.title + (c.needsYou ? ", needs you" : ""))
            let box = ClosureBox { [weak self] in self?.onChip?(c.graphKey) }
            chipBoxes.append(box)
            b.target = box
            b.action = #selector(ClosureBox.fire)
            chips.append(b)
            addSubview(b)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        showWords()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row's words: its graphs, its plain line, what each AI is doing, the lead's last message.
    private func showWords() {
        let t = row
        graphs.stringValue = t.graphs
        plain.stringValue = t.plainLine
        plain.toolTip = t.plainLine
        for (m, (_, l)) in zip(t.members, memberViews) {
            l.set(IslandStyle.attributed([(m.who, NSFont.systemFont(ofSize: 12, weight: .medium), PongColor.textPrimary),
                                          (m.ai.isEmpty ? "" : " · " + m.ai, PongType.secondary, IslandStyle.tertiary),
                                          (" — " + m.doing, PongType.secondary, PongColor.textSecondary)]))
            l.setAccessibilityLabel(m.who + (m.ai.isEmpty ? "" : ", " + m.ai) + ": " + m.status.word + ", " + m.doing)
        }
        if !t.lastMessage.isEmpty {
            let parts = t.lastMessage.components(separatedBy: ": ")
            let who = (parts.first ?? "") + ":"
            let rest = parts.dropFirst().joined(separator: ": ")
            message.set(IslandStyle.attributed([(who + " ", PongType.secondary, IslandStyle.tertiary), (rest, PongType.secondary, PongColor.textSecondary)],
                                               truncate: .byWordWrapping))
        }
        setAccessibilityLabel(t.accessibilityLabel)
    }

    /// The lines the lead's last message takes (one or two).
    private func messageLines(_ s: String) -> Int { IslandStyle.width(s, PongType.secondary) > width - 24 ? 2 : 1 }

    /// Show `t` in this row as it is, when the new read changes only its words (what each AI is doing,
    /// the plain line, the lead's last message at the same length): the row stays, with its buttons and
    /// VoiceOver's place. False: it needs a row of its own.
    func update(_ t: IslandTeamRow) -> Bool {
        if t == row { return true }
        guard t.session == row.session, t.name == row.name, t.marker == row.marker, t.stopped == row.stopped,
              t.chips == row.chips, t.members.count == row.members.count,
              zip(t.members, row.members).allSatisfy({ $0.status == $1.status && $0.who == $1.who && $0.ai == $1.ai }),
              t.lastMessage.isEmpty == row.lastMessage.isEmpty,
              messageLines(t.lastMessage) == messageLines(row.lastMessage) else { return false }
        row = t
        showWords()
        needsLayout = true
        return true
    }

    private var chipRows: [[(NSButton, CGFloat)]] {
        var rows: [[(NSButton, CGFloat)]] = [[]]
        var x: CGFloat = 0
        let room = width - 24
        for b in chips {
            let w = ceil(b.attributedTitle.size().width) + 12
            if x + w > room && x > 0 { rows.append([]); x = 0 }
            rows[rows.count - 1].append((b, w))
            x += w + 4
        }
        return rows.filter { !$0.isEmpty }
    }

    var height: CGFloat {
        var h: CGFloat = 10 + 18 + 2 + 17 + 4
        h += CGFloat(memberViews.count) * 20
        if !row.lastMessage.isEmpty {
            let lines = IslandStyle.width(row.lastMessage, PongType.secondary) > width - 24 ? 2 : 1
            h += 6 + CGFloat(lines) * 17
        }
        if !chips.isEmpty { h += 8 + CGFloat(chipRows.count) * 24 }
        return h + 10
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        var y: CGFloat = 10
        marker.frame = NSRect(x: 0, y: y + 1, width: 16, height: 16)
        var right = W
        if let s = start {
            let sw = s.intrinsicContentSize.width
            s.frame = NSRect(x: right - sw, y: y - 3, width: sw, height: 24)
            right -= sw + 6
        } else {
            let gw = IslandStyle.width(row.graphs, PongType.meta) + 4
            graphs.frame = NSRect(x: right - gw, y: y + 2, width: gw, height: 14)
            right -= gw + 6
        }
        name.frame = NSRect(x: 24, y: y, width: max(40, right - 24), height: 18)
        y += 20
        plain.frame = NSRect(x: 24, y: y, width: W - 24, height: 17)
        y += 21
        for (mk, l) in memberViews {
            mk.frame = NSRect(x: 26, y: y + 4, width: 12, height: 12)
            l.frame = NSRect(x: 46, y: y + 2, width: W - 46, height: 16)
            y += 20
        }
        if !row.lastMessage.isEmpty {
            y += 6
            let lines: CGFloat = IslandStyle.width(row.lastMessage, PongType.secondary) > width - 24 ? 2 : 1
            message.frame = NSRect(x: 24, y: y, width: W - 24, height: lines * 17)
            y += lines * 17
        }
        if !chips.isEmpty {
            y += 8
            for r in chipRows {
                var x: CGFloat = 24
                for (b, w) in r {
                    b.frame = NSRect(x: x, y: y, width: w, height: 20)
                    x += w + 4
                }
                y += 24
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            PongColor.overlay.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        }
        IslandStyle.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A chat (a graph architect) after the teams: its glyph, name, AI and graphs, "Live" while it runs.
final class IslandChatRowView: IslandRow {
    var onOpen: (() -> Void)?
    let chat: IslandChatRow

    init(_ c: IslandChatRow) {
        chat = c
        super.init(frame: .zero)
        let glyph = ChatGlyphView(live: c.live)
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        addSubview(IslandLabel(c.title, font: PongType.bodyStrong, color: PongColor.textPrimary))
        addSubview(IslandLabel(c.line, font: PongType.secondary, color: PongColor.textSecondary))
        let live = IslandLabel(c.live ? "Live" : "", font: NSFont.systemFont(ofSize: 12, weight: .medium), color: PongColor.live)
        live.alignment = .right
        addSubview(live)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(c.title + ". " + c.line.replacingOccurrences(of: " · ", with: ", ") + (c.live ? ". Live." : "."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let W = bounds.width
        subviews[0].frame = NSRect(x: 0, y: 12, width: 20, height: 20)
        subviews[3].frame = NSRect(x: W - 40, y: 14, width: 40, height: 16)
        subviews[1].frame = NSRect(x: 28, y: 4, width: W - 76, height: 18)
        subviews[2].frame = NSRect(x: 28, y: 22, width: W - 76, height: 16)
    }

    override var fillRect: NSRect { bounds.insetBy(dx: -6, dy: 1) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// Nothing to list: a title, a line, maybe [+ New graph].
final class IslandEmptyView: IslandFlipped {
    var onButton: (() -> Void)?
    private let title: IslandLabel
    private let line: IslandLabel
    private var button: PongButton?

    init(title t: String, line l: String, button b: String?) {
        title = IslandLabel(t, font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: PongColor.textPrimary)
        line = IslandLabel(l, font: PongType.secondary, color: PongColor.textSecondary, lines: 2)
        super.init(frame: .zero)
        addSubview(title)
        addSubview(line)
        title.isHidden = t.isEmpty
        if let b {
            let btn = PongButton(title: b, style: .quiet, size: .small)
            btn.symbol = "plus"
            btn.onPress = { [weak self] in self?.onButton?() }
            button = btn
            addSubview(btn)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var height: CGFloat { (title.isHidden ? 8 : 34) + (line.stringValue.isEmpty ? 0 : 20) + (button == nil ? 6 : 34) }

    override func layout() {
        super.layout()
        var y: CGFloat = 8
        if !title.isHidden {
            title.frame = NSRect(x: 0, y: 14, width: bounds.width, height: 20)
            y = 36
        }
        line.frame = NSRect(x: 0, y: y, width: bounds.width, height: 17)
        if !line.stringValue.isEmpty { y += 22 }
        if let b = button { b.frame = NSRect(x: -8, y: y + 2, width: b.intrinsicContentSize.width, height: 24) }
    }
}

/// After the last answer (§6.3): "That's everything."
final class IslandAllDoneView: IslandFlipped {
    init(closes: Bool) {
        super.init(frame: .zero)
        addSubview(IslandLabel("That's everything.", font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: PongColor.textPrimary))
        addSubview(IslandLabel(closes ? "The panel closes in a moment." : "Nothing else needs you.", font: PongType.secondary,
                               color: PongColor.textSecondary))
        setAccessibilityElement(true)
        setAccessibilityLabel("That's everything.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        subviews[0].frame = NSRect(x: 0, y: 12, width: bounds.width, height: 20)
        subviews[1].frame = NSRect(x: 0, y: 34, width: bounds.width, height: 16)
    }
}

/// Teams only (§5.6): "Message the lead…" and "To Northwind ▾". Return sends, Shift-Return makes a new
/// line, dropped files go with the message as attachments (the "Attached files:" list the map's message
/// box sends). Sending runs off the main thread.
final class IslandMessageBox: NSView, NSTextFieldDelegate {
    var onSend: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var onMenu: ((Bool) -> Void)?
    private let field = NSTextField()
    private let to = NSPopUpButton(frame: .zero, pullsDown: false)
    /// "2 files", while files dropped on the box wait to go with the message.
    private let attached = IslandLabel("", font: PongType.meta, color: PongColor.live)
    private var teams: [(String, String)] = []
    private var files: [String] = []
    private var sending = false

    /// The box has the keyboard (the panel then holds open; the controller also asks that it is key).
    var isEditing: Bool { field.currentEditor() != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = PongColor.field.cgColor
        layer?.cornerRadius = PongRadius.control
        layer?.borderWidth = 1
        layer?.borderColor = PongColor.control.cgColor
        field.placeholderAttributedString = NSAttributedString(string: "Message the lead…", attributes: [
            .font: PongType.body, .foregroundColor: IslandStyle.tertiary])
        field.font = PongType.body
        field.textColor = PongColor.textPrimary
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Message the lead")
        addSubview(field)
        to.isBordered = false
        to.font = PongType.secondary
        to.contentTintColor = PongColor.textSecondary
        to.setAccessibilityLabel("Send to")
        addSubview(to)
        attached.isHidden = true
        addSubview(attached)
        registerForDraggedTypes([.fileURL])
        // the panel holds open while the team menu shows
        if let menu = to.menu {
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                self?.onMenu?(true)
            }
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
                self?.onMenu?(false)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTeams(_ t: [(String, String)]) {
        let was = to.indexOfSelectedItem >= 0 && to.indexOfSelectedItem < teams.count ? teams[to.indexOfSelectedItem].0 : nil
        guard t.map({ $0.0 + $0.1 }) != teams.map({ $0.0 + $0.1 }) else { return }
        teams = t
        to.removeAllItems()
        for (_, name) in t { to.addItem(withTitle: "To " + name) }
        if let was, let i = t.firstIndex(where: { $0.0 == was }) { to.selectItem(at: i) }
        PongTheme.stylePopUpItemTitles(to)
        field.isEnabled = !t.isEmpty
        field.placeholderAttributedString = NSAttributedString(string: t.isEmpty ? "Start a team to message its lead" : "Message the lead…",
                                                              attributes: [.font: PongType.body, .foregroundColor: IslandStyle.tertiary])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let tw = min(150, ceil(to.attributedTitle.size().width) + 28)
        to.frame = NSRect(x: W - tw - 4, y: (H - 22) / 2, width: tw, height: 22)
        to.isHidden = teams.isEmpty
        var right = W - tw - 12
        if !attached.isHidden {
            let aw = IslandStyle.width(attached.stringValue, PongType.meta) + 4
            attached.frame = NSRect(x: right - aw, y: (H - 14) / 2, width: aw, height: 14)
            right -= aw + 6
        }
        field.frame = NSRect(x: 10, y: (H - 18) / 2, width: max(40, right - 10), height: 18)
    }

    private func showAttached() {
        attached.stringValue = files.isEmpty ? "" : (files.count == 1 ? "1 file" : "\(files.count) files")
        attached.toolTip = files.isEmpty ? nil : files.joined(separator: "\n")
        attached.isHidden = files.isEmpty
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        send()
        return true
    }

    private func send() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = to.indexOfSelectedItem
        guard !typed.isEmpty || !files.isEmpty, !sending, i >= 0, i < teams.count else { return }
        var text = typed
        if !files.isEmpty {
            let block = "Attached files:\n" + files.map { "- " + $0 }.joined(separator: "\n")
            text = text.isEmpty ? block : text + "\n\n" + block
        }
        sending = true
        field.isEnabled = false
        onSend?(text, teams[i].0) { [weak self] ok in
            guard let self else { return }
            self.sending = false
            self.field.isEnabled = true
            if ok {
                self.field.stringValue = ""
                self.files = []
                self.showAttached()
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { teams.isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        for u in urls where !files.contains(u.path) { files.append(u.path) }
        showAttached()
        return true
    }
}
