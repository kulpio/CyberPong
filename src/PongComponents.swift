import AppKit

// Shared controls for the 1.9 look (design-language.md §3): buttons, labels,
// status markers. Every page builds from these so a state looks the same everywhere.

/// A button in one of the five styles. One primary per view.
final class PongButton: NSButton {
    enum Style { case primary, secondary, quiet, destructive, confirm }
    enum Size { case small, regular, large }

    var style: Style { didSet { restyle() } }
    var size: Size { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// "⌘1": shown in meta after the label.
    var keycap: String? { didSet { restyle(); invalidateIntrinsicContentSize() } }
    /// SF Symbol shown before the label.
    var symbol: String? { didSet { restyle(); invalidateIntrinsicContentSize() } }

    private var plainTitle: String
    private var hovering = false
    private var pressing = false
    private var focused = false
    private var tracking: NSTrackingArea?

    init(title: String, style: Style = .secondary, size: Size = .regular,
         target: AnyObject? = nil, action: Selector? = nil) {
        self.plainTitle = title
        self.style = style
        self.size = size
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = PongRadius.control
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var title: String {
        get { plainTitle }
        set { plainTitle = newValue; restyle(); invalidateIntrinsicContentSize() }
    }

    override var isEnabled: Bool {
        didSet { restyle() }
    }

    var height: CGFloat {
        switch size {
        case .small: return PongSpace.controlSmall
        case .regular: return PongSpace.control
        case .large: return PongSpace.controlLarge
        }
    }

    private var padding: CGFloat { size == .large ? 16 : 12 }
    private var minWidth: CGFloat { size == .large ? 88 : (size == .small ? 48 : 64) }
    private var labelFont: NSFont {
        let pt: CGFloat = size == .small ? 12 : 13
        return .systemFont(ofSize: pt, weight: style == .primary || style == .confirm ? .semibold : .medium)
    }

    override var intrinsicContentSize: NSSize {
        var w = (plainTitle as NSString).size(withAttributes: [.font: labelFont]).width
        if let k = keycap, !k.isEmpty {
            w += 8 + (k as NSString).size(withAttributes: [.font: PongType.meta]).width
        }
        if symbol != nil { w += 14 + (plainTitle.isEmpty ? 0 : 6) }
        return NSSize(width: max(plainTitle.isEmpty ? height : minWidth, ceil(w) + padding * 2), height: height)
    }

    /// Size to content at the current origin; returns self for chaining.
    @discardableResult
    func fit() -> PongButton {
        setFrameSize(intrinsicContentSize)
        return self
    }

    private var textColor: NSColor {
        guard isEnabled else { return PongColor.textDisabled }
        switch style {
        case .primary, .confirm: return PongColor.onInk
        case .secondary: return PongColor.textPrimary
        case .quiet: return hovering ? PongColor.textPrimary : PongColor.textSecondary
        case .destructive: return PongColor.fail
        }
    }

    private var fill: NSColor {
        switch style {
        case .primary:
            if !isEnabled { return PongColor.overlay }
            return pressing ? PongColor.inkPressed : (hovering ? PongColor.inkHover : PongColor.ink)
        case .secondary:
            if !isEnabled { return PongColor.secondaryFill }
            return pressing ? PongColor.secondaryPressed : (hovering ? PongColor.secondaryHover : PongColor.secondaryFill)
        case .quiet:
            if !isEnabled { return .clear }
            return pressing ? PongColor.pressed : (hovering ? PongColor.hover : .clear)
        case .destructive:
            if !isEnabled { return .clear }
            return pressing ? PongColor.pressed : (hovering ? PongColor.tintFail : .clear)
        case .confirm:
            if !isEnabled { return PongColor.overlay }
            return pressing ? PongColor.failPressed : (hovering ? PongColor.failHover : PongColor.fail)
        }
    }

    func restyle() {
        layer?.backgroundColor = fill.cgColor
        if focused {
            layer?.borderWidth = 2
            layer?.borderColor = PongColor.live.cgColor
        } else if style == .secondary {
            layer?.borderWidth = 1
            layer?.borderColor = (isEnabled ? PongColor.control : PongColor.controlDisabled).cgColor
        } else {
            layer?.borderWidth = 0
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString(string: plainTitle, attributes: [
            .font: labelFont, .foregroundColor: textColor, .paragraphStyle: para,
        ])
        if let k = keycap, !k.isEmpty {
            let kc: NSColor = (style == .primary || style == .confirm)
                ? PongColor.onInk.withAlphaComponent(0.62) : PongColor.textTertiary
            out.append(NSAttributedString(string: "  " + k, attributes: [
                .font: PongType.meta, .foregroundColor: kc, .paragraphStyle: para,
            ]))
        }
        super.attributedTitle = out
        if let s = symbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: plainTitle.isEmpty ? s : nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            image = img.withSymbolConfiguration(cfg)
            imagePosition = plainTitle.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
            contentTintColor = textColor
        } else {
            image = nil
            imagePosition = .noImage
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        restyle()
        super.mouseDown(with: event)   // runs the tracking loop until mouse-up
        pressing = false
        restyle()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focused = true; restyle() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focused = false; restyle() }
        return ok
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Labels, eyebrows and dividers in the type scale.
enum PongUI {
    static func label(_ text: String, _ font: NSFont = PongType.body,
                      _ color: NSColor = PongColor.textPrimary, lines: Int = 1) -> NSTextField {
        let f = lines == 1 ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        f.font = font
        f.textColor = color
        f.isSelectable = false
        f.drawsBackground = false
        f.isBordered = false
        f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        f.maximumNumberOfLines = lines
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    /// Capitals, at most three plain words.
    static func eyebrow(_ text: String, color: NSColor = PongColor.textTertiary) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = PongType.eyebrowString(text, color: color)
        f.isSelectable = false
        f.drawsBackground = false
        f.isBordered = false
        f.maximumNumberOfLines = 1
        f.lineBreakMode = .byClipping
        f.usesSingleLineMode = true
        return f
    }

    /// A 1 pt hairline divider.
    static func divider(width: CGFloat = 100) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.hairline.cgColor
        return v
    }

    /// A raised, borderless card.
    static func card(_ frame: NSRect = .zero, fill: NSColor = PongColor.raised) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = fill.cgColor
        v.layer?.cornerRadius = PongRadius.card
        return v
    }

    /// "5 min ago", "2 h 5 min ago", then "Mon 28 Sep".
    static func ago(_ t: Double, now: Double = Date().timeIntervalSince1970) -> String {
        guard t > 0 else { return "" }
        let s = max(0, Int(now - t))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60)) min ago" }
        if s < 86_400 {
            let h = s / 3600, m = (s % 3600) / 60
            return m == 0 || h >= 6 ? "\(h) h ago" : "\(h) h \(m) min ago"
        }
        return dayStamp(t)
    }

    /// "26 min", "2 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Clock time in the Mac's own 12- or 24-hour setting.
    static func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// "Mon 28 Sep" in the Mac's locale.
    static func dayStamp(_ t: Double) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

/// A state's shape in a 16 pt cell. Working is a turning 270° ring.
final class StatusMarkerView: NSView {
    var status: PongStatus { didSet { rebuild() } }
    private let ring = CAShapeLayer()
    private let glyph = NSImageView()

    init(_ status: PongStatus, size: CGFloat = 16) {
        self.status = status
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        glyph.frame = bounds
        glyph.imageScaling = .scaleProportionallyDown
        addSubview(glyph)
        layer?.addSublayer(ring)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        ring.frame = bounds
        rebuild()
    }

    private func rebuild() {
        setAccessibilityLabel(status.word)
        setAccessibilityRole(.image)
        if status == .working {
            glyph.isHidden = true
            ring.isHidden = false
            let inset: CGFloat = bounds.width * 0.19
            let r = bounds.insetBy(dx: inset, dy: inset)
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                        startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
            ring.path = path
            ring.fillColor = nil
            ring.strokeColor = PongColor.live.cgColor
            ring.lineWidth = 1.5
            ring.lineCap = .round
            ring.bounds = bounds
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            if ring.animation(forKey: "spin") == nil && !PongMotion.reduced {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * Double.pi
                a.duration = PongMotion.spin
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                ring.add(a, forKey: "spin")
            }
        } else {
            ring.removeAllAnimations()
            ring.isHidden = true
            glyph.isHidden = false
            let pt: CGFloat = status == .needsYou ? 10 : 11
            let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .bold)
            glyph.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.word)?
                .withSymbolConfiguration(cfg)
            glyph.contentTintColor = status.color
        }
    }
}

/// A 52 pt list row (36 pt with one line): marker, title, status line, and a trailing
/// state word and time. Hover and selection are fills; rows are divided by a hairline.
final class ListRowView: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var showsDivider = true { didSet { needsDisplay = true } }

    let marker: StatusMarkerView
    let title = PongUI.label("", PongType.bodyStrong, PongColor.textPrimary)
    let subtitle = PongUI.label("", PongType.secondary, PongColor.textSecondary)
    let word = PongUI.label("", NSFont.systemFont(ofSize: 12, weight: .medium), PongColor.textSecondary)
    let time = PongUI.label("", PongType.meta, PongColor.textTertiary)
    /// A custom leading view (a chat's glyph) in place of the marker.
    var leading: NSView? { didSet { oldValue?.removeFromSuperview(); if let l = leading { addSubview(l) }; marker.isHidden = leading != nil; needsLayout = true } }
    /// A trailing button (Watch, Start) shown on hover or always.
    var accessory: NSView? { didSet { oldValue?.removeFromSuperview(); if let a = accessory { addSubview(a) }; needsLayout = true } }
    var accessoryOnHover = false

    private var hovering = false { didSet { needsDisplay = true; if accessoryOnHover { accessory?.isHidden = !hovering } } }
    private var tracking: NSTrackingArea?

    init(status: PongStatus) {
        marker = StatusMarkerView(status)
        super.init(frame: .zero)
        addSubview(marker)
        addSubview(title)
        addSubview(subtitle)
        word.alignment = .right
        time.alignment = .right
        addSubview(word)
        addSubview(time)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(title t: String, subtitle s: String, status: PongStatus, word w: String? = nil, time tm: String = "") {
        title.stringValue = t
        title.toolTip = t
        subtitle.stringValue = s
        subtitle.toolTip = s
        marker.status = status
        word.stringValue = w ?? status.word
        word.textColor = status == .done ? PongColor.textSecondary : status.color
        time.stringValue = tm
        title.textColor = (status == .stopped || status == .stale) ? PongColor.textSecondary : PongColor.textPrimary
        setAccessibilityLabel("\(t), \(w ?? status.word). \(s)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        let two = !subtitle.stringValue.isEmpty
        marker.frame = NSRect(x: 12, y: two ? 10 : (H - 16) / 2, width: 16, height: 16)
        leading?.frame = NSRect(x: 10, y: two ? 8 : (H - 20) / 2, width: 20, height: 20)
        var right = W - 12
        if let a = accessory {
            let w = (a as? PongButton)?.intrinsicContentSize.width ?? a.fittingSize.width
            a.frame = NSRect(x: right - w, y: (H - 24) / 2, width: w, height: 24)
            if !accessoryOnHover || hovering { right -= w + 8 }
        }
        let colW: CGFloat = 88
        let hasTrail = !word.stringValue.isEmpty || !time.stringValue.isEmpty
        if hasTrail {
            word.frame = NSRect(x: right - colW, y: two ? 9 : (H - 16) / 2 - (time.stringValue.isEmpty ? 0 : 7), width: colW, height: 16)
            time.frame = NSRect(x: right - colW, y: two ? 28 : (H - 14) / 2 + 8, width: colW, height: 14)
            right -= colW + 8
        }
        title.frame = NSRect(x: 40, y: two ? 8 : (H - 18) / 2, width: max(40, right - 40), height: 18)
        subtitle.frame = NSRect(x: 40, y: 28, width: max(40, right - 40), height: 16)
        subtitle.isHidden = !two
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovering {
            (selected ? PongColor.overlay : PongColor.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: PongRadius.control, yRadius: PongRadius.control).fill()
        }
        if showsDivider && !selected && !hovering {
            PongColor.hairline.setFill()
            NSRect(x: 40, y: bounds.height - 1, width: bounds.width - 40, height: 1).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsLayout = true }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A chat's glyph: a magenta bubble in a 20 pt circle, a cyan dot while it is live.
final class ChatGlyphView: NSView {
    init(live: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        wantsLayer = true
        layer?.backgroundColor = PongColor.tintArchitect.cgColor
        layer?.cornerRadius = 10
        let img = NSImageView(frame: NSRect(x: 4, y: 4, width: 12, height: 12))
        img.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "chat")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        img.contentTintColor = live ? PongColor.architect : PongColor.textTertiary
        addSubview(img)
        if live {
            let dot = NSView(frame: NSRect(x: 14, y: 14, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = PongColor.live.cgColor
            dot.layer?.cornerRadius = 3
            addSubview(dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An empty state: registration marks around a headline, a line or two, one button.
final class EmptyStateView: NSView {
    let headline = PongUI.label("", PongType.question, PongColor.textPrimary)
    let body = PongUI.label("", PongType.body, PongColor.textSecondary, lines: 3)
    let button = PongButton(title: "", style: .primary, size: .large)
    private var chips: [PongButton] = []

    init(headline h: String, body b: String, button t: String?, action: (() -> Void)?) {
        super.init(frame: .zero)
        headline.stringValue = h
        headline.alignment = .center
        body.stringValue = b
        body.alignment = .center
        addSubview(headline)
        addSubview(body)
        if let t, let action {
            button.title = t
            button.onPress = action
            addSubview(button)
        } else {
            button.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Up to three example requests under the button.
    func setChips(_ items: [(String, () -> Void)]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = items.prefix(3).map { t, a in
            let c = PongButton(title: t, style: .secondary, size: .small)
            c.onPress = a
            addSubview(c)
            return c
        }
        needsLayout = true
    }

    static let preferredHeight: CGFloat = 200

    override func layout() {
        super.layout()
        let W = bounds.width
        let cw = min(360, W - 32)
        let x = (W - cw) / 2
        headline.frame = NSRect(x: x, y: 40, width: cw, height: 24)
        let bh = body.attributedStringValue.boundingRect(with: NSSize(width: cw, height: 200), options: [.usesLineFragmentOrigin]).height
        body.frame = NSRect(x: x, y: 72, width: cw, height: ceil(bh) + 2)
        var y = 72 + ceil(bh) + 16
        if !button.isHidden {
            let w = button.intrinsicContentSize.width
            button.frame = NSRect(x: (W - w) / 2, y: y, width: w, height: 32)
            y += 44
        }
        if !chips.isEmpty {
            let total = chips.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width } + CGFloat(chips.count - 1) * 8
            var cx = max(8, (W - total) / 2)
            for c in chips {
                let w = c.intrinsicContentSize.width
                c.frame = NSRect(x: cx, y: y, width: w, height: 24)
                cx += w + 8
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // registration marks 40 pt around the text block, 12 pt arms
        let cw = min(360, bounds.width - 32)
        let r = NSRect(x: (bounds.width - cw) / 2 - 24, y: 16, width: cw + 48, height: bounds.height - 32)
        PongTheme.drawCornerBrackets(in: r, color: PongColor.mark, arm: 12, line: 1)
    }
}
