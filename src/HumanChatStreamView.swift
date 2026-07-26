import AppKit

/// Interactive human-console message stream (cards, not mono dump).
final class HumanChatStreamView: NSView {
    var onDecision: ((HumanAskDecision) -> Void)?
    var onReplyFocus: (() -> Void)?
    var onJobTap: ((String) -> Void)?
    var onSeatTap: ((String) -> Void)?
    var onFileTap: ((String) -> Void)?

    private let scroll = NSScrollView(frame: .zero)
    private let stack = FlippedStack(frame: .zero)
    private var lastSig = ""
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var appearanceObserver: NSObjectProtocol?
    /// Cached last reload args so theme flips can force-rebuild without callers re-supplying.
    private var lastMessages: [HumanChatMessage] = []
    private var lastAsk: HumanAsk?
    private var lastEmptyHint = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scroll.documentView = stack

        emptyLabel.font = PongTheme.font(11)
        emptyLabel.textColor = PongTheme.textTertiary
        emptyLabel.isBordered = false
        emptyLabel.drawsBackground = false
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: PongTheme.appearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload(
                messages: self?.lastMessages ?? [],
                pendingAsk: self?.lastAsk,
                emptyHint: self?.lastEmptyHint ?? "",
                force: true
            )
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    /// Rebuild cards when signature changes (poll-friendly, low flicker).
    func reload(messages: [HumanChatMessage], pendingAsk: HumanAsk?, emptyHint: String, force: Bool = false) {
        lastMessages = messages
        lastAsk = pendingAsk
        lastEmptyHint = emptyHint

        var parts = messages.map { "\($0.id):\($0.kind.rawValue):\($0.text.prefix(40))" }
        if let a = pendingAsk { parts.append("ask:\(a.id):\(a.question.prefix(40))") }
        // Include appearance so light/dark flips always rebuild even when messages unchanged
        parts.append("ap:\(PongTheme.appearance.rawValue)")
        let sig = parts.joined(separator: "|")
        if !force, sig == lastSig { return }
        lastSig = sig

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        emptyLabel.textColor = PongTheme.textTertiary
        let showEmpty = messages.isEmpty && pendingAsk == nil
        emptyLabel.isHidden = !showEmpty
        emptyLabel.stringValue = emptyHint
        scroll.isHidden = showEmpty

        // History first, live ask card last (newest at bottom)
        for msg in messages {
            if msg.kind == .ask, pendingAsk != nil { continue }
            stack.addArrangedSubview(makeBubble(msg))
        }
        if let ask = pendingAsk {
            stack.addArrangedSubview(makeAskCard(ask))
        }

        stack.layoutSubtreeIfNeeded()
        let w = max(120, bounds.width > 1 ? bounds.width - 4 : 200)
        for v in stack.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: w),
            ])
        }
        stack.layoutSubtreeIfNeeded()
        let h = max(40, stack.fittingSize.height)
        stack.frame = NSRect(x: 0, y: 0, width: w, height: h)
        scroll.documentView = stack
        scrollToBottom()
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scroll.documentView else { return }
            let y = max(0, doc.bounds.height - self.scroll.contentView.bounds.height)
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            self.scroll.reflectScrolledClipView(self.scroll.contentView)
        }
    }

    // MARK: - Appearance-aware bubble palette

    private struct BubblePalette {
        let fill: NSColor
        let border: NSColor
        let tag: NSColor
        let body: NSColor
    }

    private var isLight: Bool { PongTheme.appearance == .light }

    /// High-contrast fills for light; keep dark-mode look without white-on-pale.
    private func palette(for kind: HumanChatMessage.Kind) -> BubblePalette {
        if isLight {
            switch kind {
            case .fromYou:
                // Solid light surface + green border — never pale lime + white text
                return BubblePalette(
                    fill: NSColor(calibratedRed: 0.93, green: 0.97, blue: 0.90, alpha: 1),
                    border: NSColor(calibratedRed: 0.25, green: 0.48, blue: 0.18, alpha: 0.55),
                    tag: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.12, alpha: 1),
                    body: NSColor(calibratedWhite: 0.08, alpha: 1)
                )
            case .fromOrch:
                return BubblePalette(
                    fill: NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.99, alpha: 1),
                    border: PongTheme.blue.withAlphaComponent(0.45),
                    tag: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.55, alpha: 1),
                    body: NSColor(calibratedWhite: 0.08, alpha: 1)
                )
            case .status:
                return BubblePalette(
                    fill: NSColor(calibratedWhite: 0.94, alpha: 1),
                    border: NSColor(calibratedWhite: 0, alpha: 0.14),
                    tag: NSColor(calibratedWhite: 0.32, alpha: 1),
                    body: NSColor(calibratedWhite: 0.18, alpha: 1)
                )
            case .ask:
                return BubblePalette(
                    fill: NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.88, alpha: 1),
                    border: PongTheme.amber.withAlphaComponent(0.55),
                    tag: NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.05, alpha: 1),
                    body: NSColor(calibratedWhite: 0.08, alpha: 1)
                )
            }
        }
        // Dark mode
        switch kind {
        case .fromYou:
            return BubblePalette(
                fill: PongSheetChrome.lime.withAlphaComponent(0.14),
                border: PongSheetChrome.lime.withAlphaComponent(0.40),
                tag: PongSheetChrome.lime,
                body: PongTheme.textPrimary
            )
        case .fromOrch:
            return BubblePalette(
                fill: PongTheme.blue.withAlphaComponent(0.14),
                border: PongTheme.blue.withAlphaComponent(0.45),
                tag: PongTheme.blue,
                body: PongTheme.textPrimary
            )
        case .status:
            return BubblePalette(
                fill: PongTheme.bgHover,
                border: PongTheme.lineSoft,
                tag: PongTheme.textTertiary,
                body: PongTheme.textSecondary
            )
        case .ask:
            return BubblePalette(
                fill: NSColor(calibratedRed: 0.16, green: 0.11, blue: 0.04, alpha: 0.95),
                border: PongTheme.amber.withAlphaComponent(0.5),
                tag: PongTheme.amber,
                body: PongTheme.textPrimary
            )
        }
    }

    private func makeAskCard(_ ask: HumanAsk) -> NSView {
        let pal = palette(for: .ask)
        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.backgroundColor = pal.fill.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = pal.border.cgColor

        let tag = label("ASK · \(ask.source)", color: pal.tag, size: 9, bold: true)
        let q = label(HumanConsoleController.questionOnly(ask.question), color: pal.body, size: 11, bold: false)
        q.maximumNumberOfLines = 6

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        // Action chips: solid dark enough for white label, or light-mode dark-on-tinted
        let deny = chipButton("Deny", bg: isLight
            ? NSColor(calibratedRed: 0.75, green: 0.28, blue: 0.28, alpha: 1)
            : NSColor(calibratedRed: 0.35, green: 0.12, blue: 0.12, alpha: 1),
            lightLabel: false)
        deny.target = self
        deny.action = #selector(denyTap)
        let once = chipButton("Accept once", bg: isLight
            ? NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.32, alpha: 1)
            : NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.18, alpha: 1),
            lightLabel: false)
        once.target = self
        once.action = #selector(onceTap)
        let always = chipButton("Always", bg: isLight
            ? NSColor(calibratedRed: 0.25, green: 0.40, blue: 0.58, alpha: 1)
            : NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.32, alpha: 1),
            lightLabel: false)
        always.target = self
        always.action = #selector(alwaysTap)
        always.toolTip = "Always accept elevated actions this session"
        let reply = chipButton(
            "Reply…",
            bg: isLight ? NSColor(calibratedWhite: 0.92, alpha: 1) : PongTheme.bgHover,
            lightLabel: isLight
        )
        reply.target = self
        reply.action = #selector(replyTap)

        row.addArrangedSubview(deny)
        row.addArrangedSubview(once)
        row.addArrangedSubview(always)
        row.addArrangedSubview(reply)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 4
        chips.translatesAutoresizingMaskIntoConstraints = false
        if let jid = ask.jobId, !jid.isEmpty {
            chips.addArrangedSubview(linkChip("job \(jid)", action: #selector(jobChip(_:)), represented: jid))
        }
        if !ask.source.isEmpty, ask.source != "orchestrator" {
            chips.addArrangedSubview(linkChip(ask.source, action: #selector(seatChip(_:)), represented: ask.source))
        }

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(tag)
        col.addArrangedSubview(q)
        if !chips.arrangedSubviews.isEmpty { col.addArrangedSubview(chips) }
        col.addArrangedSubview(row)
        card.addSubview(col)

        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func makeBubble(_ msg: HumanChatMessage) -> NSView {
        let pal = palette(for: msg.kind)
        let card = NSView(frame: .zero)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = max(1, PongTheme.hairline)
        card.layer?.backgroundColor = pal.fill.cgColor
        card.layer?.borderColor = pal.border.cgColor

        let who: String = {
            switch msg.kind {
            case .fromYou: return "YOU"
            case .fromOrch: return "ORCH"
            case .ask: return "ASK"
            case .status: return "STATUS"
            }
        }()
        let tag = label(who, color: pal.tag, size: 9, bold: true)
        let body = label(msg.text, color: pal.body, size: 11, bold: false)
        body.maximumNumberOfLines = 8

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 4
        chips.translatesAutoresizingMaskIntoConstraints = false
        if let jid = msg.jobId, !jid.isEmpty {
            chips.addArrangedSubview(linkChip("job \(jid)", action: #selector(jobChip(_:)), represented: jid))
        }
        if let sid = msg.seatId, !sid.isEmpty {
            chips.addArrangedSubview(linkChip(sid, action: #selector(seatChip(_:)), represented: sid))
        }
        for f in msg.files.prefix(4) {
            let name = (f as NSString).lastPathComponent
            chips.addArrangedSubview(linkChip("📎 \(name)", action: #selector(fileChip(_:)), represented: f))
        }

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        col.addArrangedSubview(tag)
        col.addArrangedSubview(body)
        if !chips.arrangedSubviews.isEmpty { col.addArrangedSubview(chips) }
        card.addSubview(col)

        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    /// Plain NSTextField — avoid wrappingLabelWithString baking system colors that fight light mode.
    private func label(_ t: String, color: NSColor, size: CGFloat, bold: Bool) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = true
        f.isBordered = false
        f.drawsBackground = false
        f.backgroundColor = .clear
        f.font = bold ? PongTheme.font(size, weight: .semibold) : PongTheme.font(size)
        f.textColor = color
        f.stringValue = t
        f.maximumNumberOfLines = 0
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func chipButton(_ title: String, bg: NSColor, lightLabel: Bool) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = bg.cgColor
        b.font = PongTheme.labelFont(9)
        b.contentTintColor = lightLabel ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        // Attributed title forces color (contentTint alone can fail on light system)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: lightLabel ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white,
            .font: PongTheme.labelFont(9),
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func linkChip(_ title: String, action: Selector, represented: String) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = title
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        let chipFill = isLight
            ? PongTheme.blue.withAlphaComponent(0.12)
            : PongTheme.blue.withAlphaComponent(0.2)
        let chipBorder = PongTheme.blue.withAlphaComponent(isLight ? 0.40 : 0.45)
        let chipText = isLight
            ? NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.50, alpha: 1)
            : PongTheme.blue
        b.layer?.backgroundColor = chipFill.cgColor
        b.layer?.borderWidth = 1
        b.layer?.borderColor = chipBorder.cgColor
        b.font = PongTheme.labelFont(9)
        b.contentTintColor = chipText
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: chipText,
            .font: PongTheme.labelFont(9),
        ])
        b.target = self
        b.action = action
        b.identifier = NSUserInterfaceItemIdentifier(represented)
        b.toolTip = represented
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    @objc private func denyTap() { onDecision?(.deny) }
    @objc private func onceTap() { onDecision?(.acceptOnce) }
    @objc private func alwaysTap() { onDecision?(.alwaysAccept) }
    @objc private func replyTap() { onReplyFocus?() }

    @objc private func jobChip(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onJobTap?(id) }
    }
    @objc private func seatChip(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onSeatTap?(id) }
    }
    @objc private func fileChip(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onFileTap?(id) }
    }
}

/// Stack with y-down so messages layout top→bottom in scroll document.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}
