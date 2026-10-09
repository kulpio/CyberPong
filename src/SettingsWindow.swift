import AppKit
import ApplicationServices
import UserNotifications

/// Settings (⌘,): its own window, a list on the left, changes apply at once (no Save).
/// Replaces the Setup page and Mission's advanced content (ux-review.md §3, §4).
final class SettingsWindow: NSObject, NSWindowDelegate, SetupHost, IslandSettingsHost {
    static let shared = SettingsWindow()

    /// Saved by index (`settings.pane`): new panes go at the end. The list shows them in
    /// `listed` order: This Mac next to General, as the setup asks about this Mac first, then the
    /// notch panel (2.1).
    enum Pane: Int, CaseIterable {
        case general = 0, accounts, permissions, bars, notifications, advanced, limits, mac, island
        static let listed: [Pane] = [.general, .mac, .island, .accounts, .permissions, .bars, .notifications, .advanced, .limits]
        var title: String {
            switch self {
            case .general: return "General"
            case .accounts: return "AI accounts"
            case .permissions: return "Permissions"
            case .bars: return "Quality bars"
            case .notifications: return "Notifications"
            case .advanced: return "Advanced"
            case .limits: return "Limits & keys"
            case .mac: return "This Mac"
            case .island: return "Notch panel"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .accounts: return "person.crop.circle"
            case .permissions: return "lock.shield"
            case .bars: return "checkmark.seal"
            case .notifications: return "bell"
            case .advanced: return "wrench.and.screwdriver"
            case .limits: return "gauge"
            case .mac: return "laptopcomputer"
            case .island: return "menubar.rectangle"
            }
        }
        /// The panes that show the setup's rows and follow its checks.
        var showsSetup: Bool { self == .accounts || self == .limits || self == .mac }
    }

    private var window: NSWindow?
    private let list = FlippedView()
    private let paneScroll = NSScrollView()
    private let paneDoc = FlippedView()
    private var pane: Pane = Pane(rawValue: UserDefaults.standard.integer(forKey: "settings.pane")) ?? .general
    private var rows: [Pane: NSButton] = [:]
    private var boxes: [ClosureBox] = []
    /// What the current pane's switches and pop-ups call; replaced on every redraw.
    private var renderBoxes: [ClosureBox] = []
    /// The planning chat's AI and model (shared with the first-run setup's step).
    private let picker = ArchitectPicker(style: .settings)
    private var setupObserver: NSObjectProtocol?
    private lazy var fade = MoreBelowFade(on: paneScroll, color: PongColor.base)
    /// The pane whose scroller was last shown for a moment (once per pane, not per redraw).
    private var flashedPane: Pane?
    /// The pane drawn last: a redraw of the same pane keeps its scroll place.
    private var renderedPane: Pane?

    // Settings › Notch panel
    /// The notch-panel settings the pane shows: a change from elsewhere (the panel's own switch, Hide
    /// the notch panel, a hand edit) redraws it.
    private var islandShown: IslandSettings?
    private var islandObserver: NSObjectProtocol?
    /// "Try it here" is open the first time the pane is shown, then as the person leaves it.
    private var islandTryOpen: Bool?
    private weak var islandTry: IslandTryItCard?
    /// "Back to the usual settings." after a reset, until the next change.
    private var islandResetNote = false
    private weak var islandNote: NSTextField?
    /// True while the pane writes a setting itself. IslandSettings tells its observers at once, on this
    /// thread, before the write returns: the pane's own change is already on screen, so that news must
    /// not redraw it (a redraw there took the focus from the field Tab moved to, cut the switch's slide
    /// short, and inside a redraw it drew the page twice).
    private var islandWriting = false

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// The window; only a preview shooting a whole page lets it be taller than the screen.
    private final class PageWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            UIPreview.isOn && UIPreview.env["PONG_PREVIEW_SETTINGS_TALL"] == "1"
                ? frameRect : super.constrainFrameRect(frameRect, to: screen)
        }
    }

    /// Back from an edit (the bar sheet, System Settings, a sign-in in Terminal): read what may have changed.
    func windowDidBecomeKey(_ notification: Notification) {
        if pane.showsSetup { SetupModel.shared.refreshDoctor() }
        // the notch panel's settings, edited by hand meanwhile: read again (a difference redraws the page)
        if pane == .island { IslandSettings.reload() }
        setupPolling()
        guard pane == .bars || pane == .permissions else { return }
        if pane == .bars, window?.attachedSheet == nil { barsRead = nil }
        render()
    }

    func windowWillClose(_ notification: Notification) {
        endEditing()
        SetupModel.shared.stopPolling(self)
        SetupModel.shared.keyDrafts = [:]
    }

    private func endEditing() {
        if let w = window, w.firstResponder is NSText { w.makeFirstResponder(nil) }
    }

    /// Checking every few seconds is for while someone is looking; coming back checks at once.
    func windowDidResignKey(_ notification: Notification) {
        SetupModel.shared.stopPolling(self)
    }

    func show(_ p: Pane? = nil) {
        if window == nil { build() }
        if let p { pane = p }
        barsRead = nil
        render()
        if UIPreview.isOn {
            // a preview never takes the keyboard: what someone types elsewhere must not land here
            window?.orderFront(nil)
            previewFitPage()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        setupPolling()
    }

    /// A preview can ask for a whole page in one shot (`PONG_PREVIEW_SETTINGS_TALL=1`): the window grows
    /// to the page's height, however tall (it sits behind every other window).
    private func previewFitPage() {
        guard UIPreview.env["PONG_PREVIEW_SETTINGS_TALL"] == "1", let w = window else { return }
        let want = ceil(paneDoc.frame.height)
        guard abs(paneScroll.contentSize.height - want) > 1 else { return }
        w.maxSize = NSSize(width: w.maxSize.width, height: 10_000)
        var f = w.frame
        let chrome = f.height - paneScroll.contentSize.height
        f.origin.y = f.maxY - (want + chrome)
        f.size.height = want + chrome
        w.setFrame(f, display: true)
    }

    // MARK: SetupHost

    var setupWindow: NSWindow? { window }

    func setupNeedsRender() {
        guard pane.showsSetup || pane == .permissions else { return }
        render()
    }

    /// The accounts pane follows sign-ins as they happen, and This Mac and Permissions the permissions
    /// (every 3 s, as the setup's step 1 does); every setup pane follows key changes.
    private func setupPolling() {
        if window?.isKeyWindow == true && (pane == .accounts || pane == .mac || pane == .permissions) {
            SetupModel.shared.startPolling(self, every: pane == .accounts ? 4 : 3)
        } else {
            SetupModel.shared.stopPolling(self)
        }
        if setupObserver == nil {
            setupObserver = NotificationCenter.default.addObserver(forName: SetupModel.didChange, object: nil, queue: .main) { [weak self] _ in
                // only when what this pane shows changed: a redraw rebuilds its pop-ups and fields
                guard let self, self.window?.isVisible == true, self.setupSignature() != self.lastSetupSignature else { return }
                self.setupNeedsRender()
            }
        }
    }

    private var lastSetupSignature = ""

    /// What the setup panes show from the shared setup model.
    private func setupSignature() -> String {
        let m = SetupModel.shared
        switch pane {
        case .accounts:
            return "\(String(describing: m.doctor?.ais))|\(m.signingIn.sorted())|\(String(describing: m.catalog))|\(m.guideAwaitingLogin)"
        case .limits:
            return "\(m.keys)|\(m.credits ?? "")"
        case .mac:
            return "\(String(describing: m.doctor?.forDisplay))|\(m.mac)"
        case .permissions:
            return "\(m.mac)"
        default:
            return ""
        }
    }

    /// Tall enough for the longest panes (AI accounts, Limits & keys) where the screen allows;
    /// what still doesn't fit scrolls, with a fade at the foot saying there is more.
    private static var openingSize: NSSize {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        return NSSize(width: 780, height: max(540, min(880, screenH - 60)))
    }

    private func build() {
        let size = Self.openingSize
        let w = PageWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        w.title = "Settings"
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = PongColor.base
        w.minSize = NSSize(width: 640, height: 420)
        w.maxSize = NSSize(width: 1100, height: 1000)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        // a new name: a frame saved at 2.0's first size (720 × 540, keys and credits out of
        // sight) would otherwise keep opening that small
        w.setFrameAutosaveName("CyberPongSettings.2")
        let root = NSView(frame: w.contentRect(forFrameRect: w.frame))
        root.wantsLayer = true
        root.layer?.backgroundColor = PongColor.base.cgColor
        list.wantsLayer = true
        list.layer?.backgroundColor = PongColor.frame.cgColor
        root.addSubview(list)
        paneScroll.drawsBackground = false
        paneScroll.hasVerticalScroller = true
        paneScroll.autohidesScrollers = true
        paneScroll.borderType = .noBorder
        paneScroll.documentView = paneDoc
        root.addSubview(paneScroll)
        root.addSubview(fade)
        root.autoresizesSubviews = true
        w.contentView = root
        window = w
        for p in Pane.listed {
            let b = NSButton(title: p.title, target: nil, action: nil)
            b.isBordered = false
            b.bezelStyle = .inline
            b.wantsLayer = true
            b.layer?.cornerRadius = PongRadius.control
            b.alignment = .left
            b.imagePosition = .noImage
            let icon = NSImageView(frame: NSRect(x: 10, y: 8, width: 16, height: 16))
            icon.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            icon.imageScaling = .scaleProportionallyDown
            icon.identifier = NSUserInterfaceItemIdentifier("icon")
            b.addSubview(icon)
            let box = ClosureBox { [weak self] in self?.go(p) }
            boxes.append(box)
            b.target = box
            b.action = #selector(ClosureBox.fire)
            rows[p] = b
            list.addSubview(b)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
            self?.layout()
            self?.render()
        }
        islandObserver = NotificationCenter.default.addObserver(forName: IslandSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            // a change made elsewhere shows at once; the pane's own changes are already on screen
            guard let self, !self.islandWriting, self.pane == .island, self.window?.isVisible == true,
                  IslandSettings.current != self.islandShown else { return }
            self.render()
        }
        layout()
    }

    /// Another pane, from the list or a link on a pane.
    private func go(_ p: Pane) {
        // a name or number still being typed is saved before its pane goes
        endEditing()
        pane = p
        UserDefaults.standard.set(p.rawValue, forKey: "settings.pane")
        render()
    }

    private func layout() {
        guard let root = window?.contentView else { return }
        let H = root.bounds.height, W = root.bounds.width
        list.frame = NSRect(x: 0, y: 0, width: 180, height: H)
        var y: CGFloat = 52
        for p in Pane.listed {
            rows[p]?.frame = NSRect(x: 8, y: y, width: 164, height: 32)
            y += 34
        }
        paneScroll.frame = NSRect(x: 180, y: 0, width: W - 180, height: H)
        fade.place()
    }

    private func styleRows() {
        for (p, b) in rows {
            let on = p == pane
            b.layer?.backgroundColor = (on ? PongColor.overlay : NSColor.clear).cgColor
            (b.subviews.first { $0.identifier?.rawValue == "icon" } as? NSImageView)?.contentTintColor = on ? PongColor.textPrimary : PongColor.textSecondary
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = 30
            b.attributedTitle = NSAttributedString(string: p.title, attributes: [
                .paragraphStyle: para,
                .font: NSFont.systemFont(ofSize: 13, weight: on ? .semibold : .medium),
                .foregroundColor: on ? PongColor.textPrimary : PongColor.textSecondary,
            ])
        }
    }

    // MARK: Panes

    private var y: CGFloat = 0
    private var paneW: CGFloat { max(360, paneScroll.contentSize.width - 64) }

    private func render() {
        styleRows()
        lastSetupSignature = setupSignature()
        setupPolling()
        let keepScroll = paneScroll.contentView.bounds.origin
        paneDoc.subviews.forEach { $0.removeFromSuperview() }
        renderBoxes = []
        y = 44
        let title = PongUI.label(pane.title, PongType.title, PongColor.textPrimary)
        title.frame = NSRect(x: 32, y: y, width: paneW, height: 28)
        paneDoc.addSubview(title)
        y += 44
        switch pane {
        case .general: general()
        case .accounts: accounts()
        case .permissions: permissions()
        case .bars: bars()
        case .notifications: notifications()
        case .advanced: advanced()
        case .limits: limits()
        case .mac: mac()
        case .island: island()
        }
        paneDoc.frame = NSRect(x: 0, y: 0, width: paneScroll.contentSize.width, height: max(y + 32, paneScroll.contentSize.height))
        // a redraw from a sign-in, a fix or a saved key keeps the person where they were (and one
        // from a notch-panel choice that adds or folds rows)
        let samePane = renderedPane == pane
        renderedPane = pane
        if pane.showsSetup || (pane == .island && samePane) {
            let maxY = max(0, paneDoc.frame.height - paneScroll.contentSize.height)
            paneScroll.contentView.scroll(to: NSPoint(x: 0, y: min(keepScroll.y, maxY)))
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        } else if pane == .island {
            // the notch panel's page is long: it opens at its top, not where another page was scrolled to
            paneScroll.contentView.scroll(to: .zero)
            paneScroll.reflectScrolledClipView(paneScroll.contentView)
        }
        fade.update()
        // a pane longer than the window shows its scroller for a moment when it opens
        if flashedPane != pane, paneDoc.frame.height > paneScroll.contentSize.height + 1 {
            flashedPane = pane
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.paneScroll.flashScrollers() }
        }
    }

    /// Setup's rows (SetupParts.swift) on a raised card, with an optional note under it.
    private func setupCard(_ rowsIn: [SetupRowView], note: String = "") {
        let c = SetupCardView(rows: rowsIn, fill: PongColor.raised)
        let h = c.fit(width: paneW)
        c.frame = NSRect(x: 32, y: y, width: paneW, height: h)
        paneDoc.addSubview(c)
        y += h + 8
        if !note.isEmpty {
            // up to five lines: This Mac's note can add why its check was the app's own
            let n = PongUI.label(note, PongType.secondary, PongColor.textTertiary, lines: 5)
            let nh = ceil(n.attributedStringValue.boundingRect(with: NSSize(width: paneW - 12, height: 200), options: [.usesLineFragmentOrigin]).height) + 2
            n.frame = NSRect(x: 36, y: y, width: paneW - 8, height: nh)
            paneDoc.addSubview(n)
            y += nh + 8
        }
        y += 24
    }

    /// A card of 40 pt rows. Each row: a title, an optional line, and a control at the end.
    private func card(_ rowsIn: [(String, String, NSView?)], note: String = "") {
        let rowH: CGFloat = 40
        func controlW(_ c: NSView?) -> CGFloat {
            guard let c else { return 0 }
            let s = (c as? PongButton)?.intrinsicContentSize ?? c.fittingSize
            return min(260, max(s.width, 40))
        }
        func textW(_ c: NSView?) -> CGFloat { paneW - 32 - (c == nil ? 0 : controlW(c) + 16) }
        func subH(_ sub: String, _ c: NSView?) -> CGFloat {
            guard !sub.isEmpty else { return 0 }
            // 4 pt narrower than the label (its cell keeps 2 pt each side), and up to four lines:
            // a line measured as fitting that then wraps would be cut off with "…"
            let r = (sub as NSString).boundingRect(with: NSSize(width: textW(c) - 4, height: 200), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: PongType.secondary])
            return min(66, ceil(r.height) + 2)
        }
        var heights: [CGFloat] = []
        for (_, sub, c) in rowsIn { heights.append(sub.isEmpty ? rowH : 36 + subH(sub, c)) }
        let h = heights.reduce(0, +)
        let c = PongUI.card(NSRect(x: 32, y: y, width: paneW, height: h))
        let flipped = FlippedView(frame: c.bounds)
        c.addSubview(flipped)
        var ry: CGFloat = 0
        for (i, (t, sub, control)) in rowsIn.enumerated() {
            let rh = heights[i]
            let tl = PongUI.label(t, PongType.body, PongColor.textPrimary)
            tl.frame = NSRect(x: 16, y: ry + (sub.isEmpty ? 11 : 10), width: textW(control), height: 18)
            flipped.addSubview(tl)
            if !sub.isEmpty {
                let sl = PongUI.label(sub, PongType.secondary, PongColor.textSecondary, lines: 4)
                sl.frame = NSRect(x: 16, y: ry + 29, width: textW(control), height: subH(sub, control))
                sl.toolTip = sub
                flipped.addSubview(sl)
            }
            if let control {
                let s = (control as? PongButton)?.intrinsicContentSize ?? control.fittingSize
                let w = min(260, max(s.width, 40))
                control.frame = NSRect(x: paneW - 16 - w, y: ry + (rh - min(28, max(s.height, 20))) / 2, width: w, height: min(28, max(s.height, 20)))
                flipped.addSubview(control)
            }
            if i < rowsIn.count - 1 {
                let d = PongUI.divider(width: paneW - 16)
                d.frame = NSRect(x: 16, y: ry + rh - 1, width: paneW - 16, height: 1)
                flipped.addSubview(d)
            }
            ry += rh
        }
        paneDoc.addSubview(c)
        y += h + 8
        if !note.isEmpty {
            let n = PongUI.label(note, PongType.secondary, PongColor.textTertiary, lines: 3)
            let nh = ceil(n.attributedStringValue.boundingRect(with: NSSize(width: paneW - 8, height: 100), options: [.usesLineFragmentOrigin]).height) + 2
            n.frame = NSRect(x: 36, y: y, width: paneW - 8, height: nh)
            paneDoc.addSubview(n)
            y += nh + 8
        }
        y += 24
    }

    private func sectionTitle(_ s: String) {
        let e = PongUI.eyebrow(s)
        e.frame = NSRect(x: 36, y: y, width: paneW, height: 16)
        paneDoc.addSubview(e)
        y += 24
    }

    private func button(_ title: String, _ style: PongButton.Style = .secondary, _ fn: @escaping () -> Void) -> PongButton {
        let b = PongButton(title: title, style: style)
        b.onPress = fn
        return b
    }

    private func toggle(_ on: Bool, _ fn: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        let box = ClosureBox { [weak s] in fn(s?.state == .on) }
        renderBoxes.append(box)
        s.target = box
        s.action = #selector(ClosureBox.fire)
        return s
    }

    /// Under the settings lock, merged with what's there (unknown keys kept), 0600.
    private func setSetting(_ key: String, _ value: Any) {
        AppSettings.set(key, value)
    }

    private func general() {
        let d = NSApp.delegate as? AppDelegate
        let name = SetupField(placeholder: "Your first name", value: AppSettings.ownerName, width: 200)
        name.onCommit = { s in
            if AppSettings.cleanName(s) != AppSettings.ownerName { AppSettings.setOwnerName(s) }
        }
        card([("Your name", "What your AIs call you in their messages. Empty: “the person”.", name)])
        card([
            ("Menu bar icon", "The CyberPong mark in the menu bar, with the count of questions",
             toggle(!Pong.boolSetting("hide_menu_bar_item")) { [weak self] on in
                 self?.setSetting("hide_menu_bar_item", !on)
                 d?.applyMenuBarVisibility()
             }),
            // its switch and the rest live on its own pane (2.1)
            (IslandSettingsWords.generalTitle, IslandSettingsWords.generalLine,
             button("Open", .quiet) { [weak self] in self?.go(.island) }),
            ("Dock count", "The number of questions on the Dock icon",
             toggle(!UserDefaults.standard.bool(forKey: "attention.noDockBadge")) { on in
                 UserDefaults.standard.set(!on, forKey: "attention.noDockBadge")
                 Attention.shared.update()
             }),
        ])
        sectionTitle("Look")
        card([("Night", "CyberPong is dark only: dark blue rooms, warm white text, one colour per job.", nil)])
    }

    // MARK: Notch panel (2.1, spec §9)

    /// The notch panel's page: card 1 (the owner's asks) with "Try it here" under it, card 2 (what it
    /// shows), More settings (folded), and Reset. Every change is written at once (IslandSettings).
    private func island() {
        let s = IslandSettings.current
        islandShown = s
        // the page's line, under its title
        y -= 12
        let intro = PongUI.label(IslandSettingsWords.paneLine, PongType.secondary, PongColor.textSecondary, lines: 2)
        let ih = ceil(intro.attributedStringValue.boundingRect(with: NSSize(width: paneW - 4, height: 100), options: [.usesLineFragmentOrigin]).height) + 2
        intro.frame = NSRect(x: 32, y: y, width: paneW, height: ih)
        paneDoc.addSubview(intro)
        y += ih + 20

        sectionTitle(IslandSettingsWords.card1)
        islandCard(IslandSettingsRows.card1(s, host: self), gap: 10)

        // Try it here: open the first time the page is shown, then as the person leaves it
        if islandTryOpen == nil {
            let seen = UserDefaults.standard.bool(forKey: "settings.island.trySeen")
            islandTryOpen = !seen
            UserDefaults.standard.set(true, forKey: "settings.island.trySeen")
        }
        let t = IslandTryItCard(open: islandTryOpen ?? false, showAreas: UserDefaults.standard.bool(forKey: "settings.island.areas"))
        t.onFold = { [weak self] open in
            self?.islandTryOpen = open
            self?.render()
        }
        t.onAreas = { on in UserDefaults.standard.set(on, forKey: "settings.island.areas") }
        let th = t.fit(width: paneW)
        t.frame = NSRect(x: 32, y: y, width: paneW, height: th)
        paneDoc.addSubview(t)
        islandTry = t
        y += th + 32

        sectionTitle(IslandSettingsWords.card2)
        islandCard(IslandSettingsRows.card2(s, host: self), gap: 20)

        let moreOpen = UserDefaults.standard.bool(forKey: "settings.island.more")
        let moreRows = IslandSettingsRows.more(s, host: self)
        let fold = IslandSettingsRows.fold(IslandSettingsWords.moreTitle(moreRows.count), open: moreOpen) { [weak self] in
            UserDefaults.standard.set(!moreOpen, forKey: "settings.island.more")
            self?.render()
        }
        fold.frame.origin = NSPoint(x: 28, y: y)
        paneDoc.addSubview(fold)
        y += 32
        if moreOpen { islandCard(moreRows, gap: 20) } else { y += 4 }

        let note = PongUI.label(islandResetNote ? IslandSettingsWords.resetNote : IslandSettingsWords.applyNote,
                                PongType.secondary, PongColor.textTertiary)
        let reset = button(IslandSettingsWords.resetTitle, .quiet) { [weak self] in
            guard let self else { return }
            self.endEditing()
            self.islandWriting = true
            IslandSettings.reset()
            self.islandWriting = false
            self.islandResetNote = true
            self.render()
        }
        reset.toolTip = "Every setting on this page back to how CyberPong comes, except whether the panel shows"
        let rw = reset.intrinsicContentSize.width
        reset.frame = NSRect(x: 32 + paneW - rw, y: y, width: rw, height: reset.height)
        note.frame = NSRect(x: 36, y: y + 6, width: max(40, paneW - rw - 16), height: 16)
        paneDoc.addSubview(note)
        paneDoc.addSubview(reset)
        islandNote = note
        y += reset.height + 8
    }

    /// Rows on a card, `gap` under it.
    private func islandCard(_ rowsIn: [SetupRowView], gap: CGFloat) {
        let c = SetupCardView(rows: rowsIn, fill: PongColor.raised)
        let h = c.fit(width: paneW)
        c.frame = NSRect(x: 32, y: y, width: paneW, height: h)
        paneDoc.addSubview(c)
        y += h + gap
    }

    // MARK: IslandSettingsHost

    var islandWindow: NSWindow? { window }

    func islandWrite(_ key: IslandSettings.Key, _ value: Any?, redraw: Bool) {
        let was = IslandSettings.current.value(key)
        let same: Bool
        switch (was, value) {
        case (nil, nil): same = true
        case (let a as NSObject, let b as NSObject): same = a.isEqual(b)
        default: same = false
        }
        guard !same else { return }
        islandWriting = true
        IslandSettings.set(key, value)
        islandWriting = false
        islandShown = IslandSettings.current
        if islandResetNote {
            islandResetNote = false
            islandNote?.stringValue = IslandSettingsWords.applyNote
        }
        if redraw { render() }
    }

    func islandShowMe() {
        // a number still being typed in "A bigger area" counts: it is saved before the area is drawn
        endEditing()
        IslandShowMe.show()
        islandTry?.stage.flashAreas()
    }

    /// The same rows as the setup's "Which AIs do you use?" and "Which AI plans your graphs?".
    private func accounts() {
        let m = SetupModel.shared
        if m.doctor == nil { m.refreshDoctor() }
        if m.catalog == nil { m.refreshCatalog() }
        setupCard(SetupRows.aiRows(host: self),
                  note: "Each AI signs in inside its own command line, with its own account. A team's AIs use the account signed in here.")
        sectionTitle("Plans your graphs")
        let auto = AppSettings.seatPermissions == "auto"
        setupCard(SetupRows.architectRows(picker: picker, permissionsOn: auto, host: self) { v in
            AppSettings.setSeatPermissions(auto: v)
        }, note: "New graph › More options picks another AI for one graph.")
        sectionTitle("The Guide")
        setupCard([guideRow()])
        sectionTitle("Setup")
        setupCard([SetupRowView(mark: .none, title: "Set up CyberPong again",
                                line: "The same steps as the first time: this Mac, your AIs, limits and keys.",
                                controls: [button("Run setup again…") { FirstRunSetup.present(force: true) }])])
    }

    /// The Guide (⌘K's assistant): which AI answers it, and connecting it. This was the old
    /// floating onboarding's one job.
    private func guideRow() -> SetupRowView {
        let m = SetupModel.shared
        let current = AppAISettings.provider ?? Self.guideDefault(m.doctor)
        let ready = AppAIRuntime.isHeadlessReady && AppAISettings.providerId != nil
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 28), pullsDown: false)
        for p in AppAISettings.Provider.all {
            pop.addItem(withTitle: p.label)
            pop.lastItem?.representedObject = p.id
            pop.lastItem?.toolTip = p.blurb
        }
        pop.selectItem(at: AppAISettings.Provider.all.firstIndex(of: current) ?? 0)
        pop.setAccessibilityLabel("The Guide's AI")
        PongTheme.stylePopUp(pop)
        let pick = ClosureBox { [weak self, weak pop] in
            guard let id = pop?.selectedItem?.representedObject as? String else { return }
            let p = AppAISettings.Provider.named(id)
            if p.id != AppAISettings.providerId {
                AppAISettings.setProvider(p)
                AppAIRuntime.markHeadlessReady(false)
                m.guideAwaitingLogin = false
            }
            self?.render()
        }
        renderBoxes.append(pick)
        pop.target = pick
        pop.action = #selector(ClosureBox.fire)
        // the doctor's id for the Guide's AI ("openai" signs in through Codex)
        let docId = current.id == "openai" ? "codex" : current.id
        let signedIn = m.doctor?.ai(docId)?.signedIn == true
        let connect: () -> Void = { [weak self] in
            AppAIRuntime.completeLogin { ok, msg in
                m.guideAwaitingLogin = false
                Toast.show(msg, warn: !ok)
                self?.render()
            }
        }
        var controls: [NSView] = [pop]
        let line: String
        if m.guideAwaitingLogin {
            line = "Sign in to \(current.label) in Terminal, then press I'm signed in."
            controls.append(button("I'm signed in", .secondary, connect))
        } else if ready {
            line = "Connected: it answers questions about your teams, using \(current.label)."
            controls.append(button("Reconnect…", .quiet) { [weak self] in self?.openGuideLogin(current) })
        } else {
            line = "Not connected. Connect signs it in with the AI picked here."
            controls.append(button("Connect…") { [weak self] in
                // the AI shown may be the one picked for the person (none saved yet): connect that one
                if AppAISettings.providerId == nil { AppAISettings.setProvider(current) }
                if signedIn { connect() } else { self?.openGuideLogin(current) }
            })
        }
        // under the section's own "The Guide": the row says what it does, not its name again
        return SetupRowView(mark: ready ? .ok : .off, title: "Answers ⌘K questions", line: line, controls: controls)
    }

    /// The Guide's AI before one is chosen: one that is on and signed in, Claude first (as New
    /// team's lead); Grok, the Guide's own default, while none is known to be.
    static func guideDefault(_ d: DoctorReport?) -> AppAISettings.Provider {
        // the doctor's id for each ("openai" signs in through Codex)
        let ready = { (id: String) -> Bool in
            let doc = id == "openai" ? "codex" : id
            return AppSettings.aiEnabled(doc) && d?.ai(doc)?.signedIn == true
        }
        return ["claude", "grok", "openai"].first(where: ready).map { AppAISettings.Provider.named($0) } ?? .named("grok")
    }

    private func openGuideLogin(_ p: AppAISettings.Provider) {
        AppAISettings.setProvider(p)
        SetupModel.shared.guideAwaitingLogin = true
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AppAIRuntime.openLoginTerminal(provider: p)
        }
    }

    /// The setup's "Is this Mac ready?" step: Python, tmux, the pong command, the graph runner and
    /// the two permissions, each with its fix, and what doesn't work until they're fixed.
    private func mac() {
        let m = SetupModel.shared
        if m.doctor == nil { m.refreshDoctor() }
        var note = ""
        if let d = m.doctor {
            let effects = SetupRows.macConsequences(d, m.mac)
            if SetupRows.macGaps(d, m.mac).isEmpty {
                note = "Everything CyberPong needs is on this Mac."
            } else if effects.isEmpty {
                note = "macOS asks for what's left the first time CyberPong needs it."
            } else {
                note = MacReadiness.untilFixedNote(effects)
            }
            if !d.fromEngine { note += " " + d.problem }
        }
        setupCard(SetupRows.macRows(host: self), note: note)
    }

    /// The setup's "Limits and spending" and "Keys" steps.
    private func limits() {
        let m = SetupModel.shared
        if m.doctor == nil { m.refreshDoctor() }
        if m.keysRead == nil { m.refreshKeys() }
        setupCard(SetupRows.limitsRows(host: self),
                  note: "These apply to graphs running on this Mac. When a limit pauses graphs, Needs you says so.")
        sectionTitle("Keys")
        setupCard(SetupRows.keyRows(host: self),
                  note: "Keys stay on this Mac, in a file only you can read. CyberPong never shows a key again after you save it.")
    }

    /// Automation (Terminal) the way This Mac says it: macOS's last real answer (SetupModel reads it).
    static func automationLine(_ a: MacChecks.Automation) -> String {
        switch a {
        case .allowed: return "✓ Allowed: CyberPong can open and front your teams' Terminal windows."
        case .denied: return "✕ Not allowed: CyberPong can't open your teams' Terminal windows. Switch CyberPong on under Terminal in System Settings."
        case .notAsked: return "Not asked yet: macOS asks the first time CyberPong opens Terminal."
        case .unknown: return "Not known yet: macOS only answers while Terminal is open."
        }
    }

    private func permissions() {
        let ax = AXIsProcessTrusted()
        card([
            ("Accessibility", ax ? "✓ Allowed: CyberPong can arrange and front terminal windows." : "✕ Not allowed: terminal windows can't be arranged.",
             button("Open System Settings") {
                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
             }),
            ("Automation (Terminal)", Self.automationLine(SetupModel.shared.mac.automation),
             button("Open System Settings") {
                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
             }),
            ("Notifications", "Lets CyberPong tell you when a graph has a question.",
             button("Open System Settings") {
                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
             }),
        ], note: "Each is changed in System Settings; macOS asks the first time one is needed.")
        sectionTitle("What each AI may do")
        card([("Tools and folders", "Tools are outside apps an AI can use, like a browser or email. Open a team and click an AI › Permissions to change what it may do.",
               button("Open Teams") { PanelController.shared.goArea(.teams) })])
    }

    // Quality bars are read from the engine (a Python call), so off the main thread,
    // once per showing; coming back to the window reads them again (an edit may have landed).
    private var barsRead: GauntletRead?
    private var barsTeam = ""
    private var barsLoading = false

    /// The team a bar is read for: the active one, else the first running one.
    private var barTeam: String {
        let active = Pong.loadJSON(PairState.activePath)
        return (active["session"] as? String) ?? PairState.listPairs().first ?? ""
    }

    private func loadBars(_ team: String) {
        guard !barsLoading else { return }
        barsLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let read = Gauntlet.bars(session: team)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.barsRead = read
                self.barsTeam = team
                self.barsLoading = false
                if self.pane == .bars { self.render() }
            }
        }
    }

    /// "5 checks and 3 examples · passes at 3 on each, 4 on average · held by each lane's own reviewer"
    private func barLine(_ b: GauntletBar) -> String {
        var parts: [String] = []
        let checks = Words.plural(b.dimensions.count, "check")
        // a placeholder anchor is not an example, but it doesn't cancel the real ones
        parts.append(b.references.isEmpty ? "\(checks), no example yet" : "\(checks) and \(Words.plural(b.references.count, "example"))")
        let mean = b.minMean == b.minMean.rounded() ? String(Int(b.minMean)) : String(format: "%.1f", b.minMean)
        parts.append("passes at \(b.minEach) on each, \(mean) on average")
        parts.append(b.held == "nobody yet" ? "no reviewer yet" : "held by \(b.held)")
        if b.shipped { parts.append("came with CyberPong") }
        return parts.joined(separator: " · ")
    }

    private func bars() {
        let team = barTeam
        guard !team.isEmpty else {
            card([("No team yet", "A quality bar covers a team's AIs. Start a team first.", nil)])
            return
        }
        if (barsRead == nil || barsTeam != team) && !barsLoading { loadBars(team) }
        var rowsIn: [(String, String, NSView?)] = []
        if let read = barsRead, barsTeam == team {
            if let err = read.error {
                rowsIn.append(("Couldn't read the bars", err, button("Try again") { [weak self] in
                    self?.barsRead = nil
                    self?.render()
                }))
            }
            for b in read.bars {
                rowsIn.append((b.title.isEmpty ? b.id : b.title, barLine(b), button("Edit…") { [weak self] in
                    GauntletSheet.present(session: team, editing: b, on: self?.window)
                }))
            }
            if read.bars.isEmpty && read.error == nil {
                rowsIn.append(("No bars yet", "Reviewers use their own judgement until a bar is set.", nil))
            }
        } else {
            rowsIn.append(("Reading the bars…", "", nil))
        }
        card(rowsIn, note: "For \(SchedulesPageView.teamName(team)). A bar says what “good enough” means for one kind of work, with real examples. Reviewers check work against it, and the AI doing the work sees it first.")
        card([("New bar", "What good enough means for another kind of work",
               button("New bar…", .primary) { [weak self] in
                   GauntletSheet.present(session: team, on: self?.window)
               })])
    }

    private func notifications() {
        let ud = UserDefaults.standard
        card([
            ("When a graph has a question", "A notification that opens the question",
             toggle(!ud.bool(forKey: "attention.noNotify")) { on in ud.set(!on, forKey: "attention.noNotify") }),
            ("When a graph finishes", "Passed, stopped or failed",
             toggle(ud.bool(forKey: "attention.notifyFinished")) { on in ud.set(on, forKey: "attention.notifyFinished") }),
            ("Sound", "A soft sound with each question",
             toggle(!ud.bool(forKey: "attention.noSound")) { on in ud.set(!on, forKey: "attention.noSound") }),
        ], note: "Focus modes on your Mac still apply: a notification during Do Not Disturb waits.")
    }

    private func advanced() {
        let pc = PanelController.shared
        card([
            ("Diagnostics", "Charts, problems and the event log for engineers", button("Open") { pc.goDiagnostics() }),
            ("Use terminals already open", "Turn open AI windows into a team. Nothing restarts.", button("Link…") { pc.linkTerminals() }),
            ("Saved teams", "Teams saved to start again", button("Open") { pc.showSavedTeams() }),
            ("Recaps", "Summaries of past work, so a team can pick up where it left off", button("Open") { pc.showRecaps() }),
            ("Every team's access", "One list of each team's AIs and the tools they may use", button("Open") { pc.goSetup() }),
            ("The old interview", "The eight-question graph interview, in Terminal", button("Open") {
                // the pong command when it's there, else the app's own engine (a new Mac may
                // have no ~/bin/pong yet)
                SetupActions.runInTerminal(title: "graph interview", command: SetupActions.pongInShell("graph new"),
                                           shown: "pong graph new")
            }),
        ])
        sectionTitle("For engineers")
        let mono = PongUI.label("pong snapshot · pong graph list · pong -s <team> graph show --id <graph>", PongType.data, PongColor.textSecondary, lines: 2)
        mono.frame = NSRect(x: 36, y: y, width: paneW, height: 34)
        paneDoc.addSubview(mono)
        y += 40
    }
}
