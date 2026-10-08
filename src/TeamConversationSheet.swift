import AppKit

/// The whole conversation with a team's lead (1.9), in the new look: what you wrote and what it
/// said, oldest at the top; a question the lead is waiting on, with its three answers; and a
/// field to write to it. Replaces the Team focus window (its pills, pipeline and digest) wherever
/// "Conversation with the lead" or "The whole conversation" opens.
final class TeamConversationSheet: PongSheet, NSTextFieldDelegate {
    private let session: String
    private let scroll = NSScrollView()
    private let doc = Doc()
    private let askBox = NSView()
    private let field = NSTextField()
    private let fieldBox = NSView()
    private let sendBtn = PongButton(title: "Send", style: .primary, size: .large)
    private let closeBtn = PongButton(title: "Close", style: .secondary, size: .large)
    private var timer: Timer?
    private var lastSig = ""
    private static let W: CGFloat = 600, H: CGFloat = 620

    private final class Doc: NSView { override var isFlipped: Bool { true } }

    static func present(session: String, on parent: NSWindow?) {
        let s = TeamConversationSheet(session: session)
        s.build()
        s.present(on: parent) { [weak s] in s?.timer?.invalidate() }
        s.window.makeFirstResponder(s.field)
    }

    private init(session: String) {
        self.session = session
        super.init(width: Self.W, height: Self.H)
    }

    /// Its terminals are there: the test Teams, Schedules and the sidebar use, so they all say one thing.
    private var running: Bool { SchedulesPageView.runningTeams.contains(session) }

    private func build() {
        let W = Self.W, H = Self.H, pad: CGFloat = 24
        let name = SchedulesPageView.teamName(session)
        let title = PongUI.label("Conversation with the lead", PongType.question, PongColor.textPrimary)
        title.frame = NSRect(x: pad, y: 24, width: W - pad * 2, height: 24)
        content.addSubview(title)
        let sub = PongUI.label("\(name) · \(running ? "running" : "stopped") · what you wrote and what the lead said, oldest first",
                               PongType.secondary, PongColor.textSecondary)
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: pad, y: 52, width: W - pad * 2, height: 16)
        content.addSubview(sub)

        askBox.wantsLayer = true
        askBox.layer?.backgroundColor = PongColor.tintYou.cgColor
        askBox.layer?.cornerRadius = PongRadius.card
        askBox.isHidden = true
        content.addSubview(askBox)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = doc
        content.addSubview(scroll)

        // the field, then the footer
        fieldBox.wantsLayer = true
        fieldBox.layer?.backgroundColor = PongColor.field.cgColor
        fieldBox.layer?.cornerRadius = PongRadius.control
        fieldBox.layer?.borderWidth = 1
        fieldBox.layer?.borderColor = PongColor.control.cgColor
        content.addSubview(fieldBox)
        field.font = PongType.body
        field.textColor = PongColor.textPrimary
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.target = self
        field.action = #selector(send)
        field.isEnabled = running
        field.placeholderAttributedString = NSAttributedString(
            string: running ? "Write to the lead…" : "Start the team to write to its lead",
            attributes: [.font: PongType.body, .foregroundColor: PongColor.textTertiary])
        field.setAccessibilityLabel("Message to the lead")
        content.addSubview(field)

        content.addSubview(footerRule(y: H - 57))
        let fy = H - 44
        let sw = sendBtn.intrinsicContentSize.width, cw = closeBtn.intrinsicContentSize.width
        sendBtn.frame = NSRect(x: W - pad - sw, y: fy, width: sw, height: 32)
        closeBtn.frame = NSRect(x: W - pad - sw - 8 - cw, y: fy, width: cw, height: 32)
        fieldBox.frame = NSRect(x: pad, y: H - 57 - 12 - 32, width: W - pad * 2, height: 32)
        field.frame = fieldBox.frame.insetBy(dx: 8, dy: 7)
        sendBtn.isEnabled = false
        sendBtn.onPress = { [weak self] in self?.send() }
        closeBtn.onPress = { [weak self] in self?.close() }
        content.addSubview(sendBtn)
        content.addSubview(closeBtn)

        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reload(force: false) }
    }

    func controlTextDidChange(_ obj: Notification) {
        sendBtn.isEnabled = running && !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, running else { return }
        field.stringValue = ""
        sendBtn.isEnabled = false
        let s = session
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HumanConsoleController.deliver(session: s, text: text)
            DispatchQueue.main.async { [weak self] in
                if !ok { Toast.show("Not sent: the team isn't running.", warn: true) }
                self?.reload(force: true)
            }
        }
    }

    @objc func cancelOperation(_ sender: Any?) { close() }

    private func reload(force: Bool) {
        let cards = HumanConsoleController.loadCards(session: session, limit: 200)
            .filter { $0.kind != .status && !TeamMessagesView.isChrome($0.text) && !$0.text.isEmpty }
        let ask = HumanConsoleController.loadPendingAsk(session: session)
        let sig = cards.map { $0.id }.joined() + "|" + (ask?.id ?? "")
        guard force || sig != lastSig else { return }
        lastSig = sig
        let W = Self.W, pad: CGFloat = 24
        var top: CGFloat = 84

        // a question the lead is waiting on
        askBox.subviews.forEach { $0.removeFromSuperview() }
        if let ask {
            askBox.isHidden = false
            let q = PongUI.label(HumanConsoleController.questionOnly(ask.question), PongType.bodyStrong, PongColor.textPrimary, lines: 3)
            let eyebrow = PongUI.eyebrow("The lead asks")
            eyebrow.frame = NSRect(x: 16, y: 12, width: 200, height: 16)
            q.frame = NSRect(x: 16, y: 32, width: W - pad * 2 - 32, height: 54)
            askBox.addSubview(eyebrow)
            askBox.addSubview(q)
            var x: CGFloat = 16
            for (d, style) in [(HumanAskDecision.acceptOnce, PongButton.Style.primary), (.alwaysAccept, .secondary), (.deny, .secondary)] {
                let b = PongButton(title: d == .acceptOnce ? "Allow once" : (d == .alwaysAccept ? "Always allow" : "Deny"), style: style, size: .small)
                b.toolTip = d.replyText
                b.onPress = { [weak self] in
                    guard let self else { return }
                    let ok = HumanConsoleController.respondToAsk(session: self.session, decision: d)
                    Toast.show(ok ? "Answered: \(b.title)." : "The answer didn't reach the lead.", warn: !ok)
                    self.reload(force: true)
                }
                let bw = b.intrinsicContentSize.width
                b.frame = NSRect(x: x, y: 94, width: bw, height: 24)
                askBox.addSubview(b)
                x += bw + 8
            }
            askBox.frame = NSRect(x: pad, y: top, width: W - pad * 2, height: 130)
            top += 142
        } else {
            askBox.isHidden = true
        }

        // the conversation
        let fieldTop = Self.H - 57 - 12 - 32 - 12
        scroll.frame = NSRect(x: pad - 8, y: top, width: W - pad * 2 + 16, height: max(80, fieldTop - top))
        doc.subviews.forEach { $0.removeFromSuperview() }
        let cw = scroll.frame.width - 16
        var y: CGFloat = 4
        if cards.isEmpty {
            let e = PongUI.label("Nothing yet. Write to the lead below; its replies show here.", PongType.secondary, PongColor.textTertiary)
            e.frame = NSRect(x: 8, y: y, width: cw, height: 18)
            doc.addSubview(e)
            y += 24
        }
        for c in cards {
            let you = c.kind == .fromYou
            let who = PongUI.label(you ? "You" : (c.kind == .ask ? "The lead asked" : "Lead"), PongType.metaStrong,
                                   you ? PongColor.textSecondary : PongColor.textPrimary)
            let when = PongUI.label(TeamMessagesView.when(c.ts), PongType.meta, PongColor.textTertiary)
            when.alignment = .right
            let text = PongUI.label(c.text, PongType.body, you ? PongColor.textSecondary : PongColor.textPrimary, lines: 0)
            text.isSelectable = true
            let size = (c.text as NSString).boundingRect(with: NSSize(width: cw - 16, height: 2000), options: [.usesLineFragmentOrigin],
                                                          attributes: [.font: PongType.body]).size
            let th = min(400, ceil(size.height) + 4)
            who.frame = NSRect(x: 8, y: y, width: 160, height: 16)
            when.frame = NSRect(x: cw - 90, y: y, width: 90, height: 16)
            text.frame = NSRect(x: 8, y: y + 18, width: cw - 16, height: th)
            for v in [who, when, text] { doc.addSubview(v) }
            y += 18 + th + 14
        }
        doc.frame = NSRect(x: 0, y: 0, width: cw + 8, height: max(y, scroll.contentSize.height))
        // newest in view
        doc.scroll(NSPoint(x: 0, y: max(0, doc.frame.height - scroll.contentSize.height)))
    }
}
