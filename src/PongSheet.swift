import AppKit

// Sheets and alerts in our own colours (design-language.md §3: Sheet, Alert). A sheet
// is `bg.raised`, a question-style title, at most two sentences, a 56 pt footer with at
// most three buttons. In an alert the safe choice is the loud one and takes Return.

/// A window-modal sheet whose content a caller lays out.
class PongSheet: NSObject, NSWindowDelegate {
    let window: NSWindow
    let content: NSView
    private(set) weak var parent: NSWindow?
    private var onEnd: (() -> Void)?

    init(width: CGFloat, height: CGFloat) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = PongColor.raised
        w.isMovableByWindowBackground = false
        window = w
        content = FlippedContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = PongColor.raised.cgColor
        w.contentView = content
        super.init()
        w.delegate = self
    }

    private final class FlippedContent: NSView {
        override var isFlipped: Bool { true }
    }

    func present(on parentWindow: NSWindow?, onEnd: (() -> Void)? = nil) {
        self.onEnd = onEnd
        PongSheet.retained.append(self)
        if let p = parentWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
            parent = p
            dim(p)
            p.beginSheet(window) { _ in }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        undim()
        if let p = parent { p.endSheet(window) } else { window.orderOut(nil) }
        PongSheet.retained.removeAll { $0 === self }
        onEnd?()
    }

    // MARK: The scrim (§2.7: a sheet sits on a void scrim at 55%)

    private weak var scrim: ScrimView?
    private static let scrimId = NSUserInterfaceItemIdentifier("pong.sheetScrim")

    /// Dim the window the sheet hangs from, so the sheet reads as a step the person is in.
    /// A sheet on a window that is already dimmed adds nothing. One opened while the last sheet's
    /// backdrop is still fading out (setup's "New graph…", an alert's answer opening a sheet) takes
    /// that backdrop back: it would otherwise find it, add none, and lose it a moment later.
    private func dim(_ p: NSWindow) {
        guard let host = p.contentView else { return }
        let backdrops = host.subviews.compactMap { $0 as? ScrimView }
        guard !backdrops.contains(where: { !$0.leaving }) else { return }
        let v: ScrimView
        if let fading = backdrops.last {
            v = fading
            v.leaving = false               // the end of its fade no longer removes it
        } else {
            v = ScrimView(frame: host.bounds)
            v.identifier = Self.scrimId
            v.autoresizingMask = [.width, .height]
            host.addSubview(v)
            v.alphaValue = 0
        }
        scrim = v
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PongMotion.reduced ? 0 : PongMotion.base
            v.animator().alphaValue = 1
        }
    }

    private func undim() {
        guard let v = scrim else { return }
        scrim = nil
        v.leaving = true
        v.fades += 1
        let fade = v.fades
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PongMotion.reduced ? 0 : PongMotion.exit
            v.animator().alphaValue = 0
        }, completionHandler: {
            // only this fade's end, and only if no sheet took the backdrop back in the meantime
            if v.leaving && v.fades == fade { v.removeFromSuperview() }
        })
    }

    /// Void at 55%; takes no clicks (the sheet is modal anyway) and says nothing to VoiceOver.
    private final class ScrimView: NSView {
        /// Fading out: its sheet closed. A sheet opened now may take it back.
        var leaving = false
        /// Counts fade-outs, so an earlier fade that ends late doesn't remove it.
        var fades = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = PongColor.void.withAlphaComponent(0.55).cgColor
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Sheets are kept alive while they show.
    private static var retained: [PongSheet] = []

    /// A 1 pt hairline over the footer.
    func footerRule(y: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: y, width: content.bounds.width, height: 1))
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.hairline.cgColor
        return v
    }
}

/// A two- or three-button alert: "Stop “site-review-r3”?", one line of consequence, the
/// verb on the button. `safe` is the default (Return); Esc picks `cancelIndex`.
final class PongAlert: PongSheet {
    struct Button {
        let title: String
        let style: PongButton.Style
        init(_ title: String, _ style: PongButton.Style = .secondary) { self.title = title; self.style = style }
    }

    private var done: ((Int) -> Void)?
    private var buttons: [PongButton] = []
    private var cancelIndex = 0

    /// - Parameters:
    ///   - buttons: left to right as shown; the last is the default (Return).
    ///   - cancelIndex: the one Esc presses.
    static func show(on parent: NSWindow?, title: String, message: String, buttons: [Button],
                     cancelIndex: Int = 0, done: @escaping (Int) -> Void) {
        let a = PongAlert(width: 400, height: 10)
        a.cancelIndex = cancelIndex
        a.build(title: title, message: message, buttons: buttons)
        a.done = done
        a.present(on: parent)
    }

    private func build(title: String, message: String, buttons specs: [Button]) {
        let W: CGFloat = 400, pad: CGFloat = 24
        let t = PongUI.label(title, PongType.question, PongColor.textPrimary, lines: 3)
        let th = ceil(t.attributedStringValue.boundingRect(with: NSSize(width: W - pad * 2, height: 200), options: [.usesLineFragmentOrigin]).height) + 2
        t.frame = NSRect(x: pad, y: pad, width: W - pad * 2, height: th)
        content.addSubview(t)
        var y = pad + th + 8
        if !message.isEmpty {
            let m = PongUI.label(message, PongType.body, PongColor.textSecondary, lines: 4)
            let mh = ceil(m.attributedStringValue.boundingRect(with: NSSize(width: W - pad * 2, height: 200), options: [.usesLineFragmentOrigin]).height) + 2
            m.frame = NSRect(x: pad, y: y, width: W - pad * 2, height: mh)
            content.addSubview(m)
            y += mh
        }
        y += 20
        let footerY = y
        content.addSubview(footerRule(y: footerY))
        var x = W - pad
        for (i, s) in specs.enumerated().reversed() {
            let b = PongButton(title: s.title, style: s.style, size: .large)
            let w = b.intrinsicContentSize.width
            x -= w
            b.frame = NSRect(x: x, y: footerY + 12, width: w, height: 32)
            b.onPress = { [weak self] in self?.finish(i) }
            if i == specs.count - 1 {
                b.keyEquivalent = "\r"
            }
            content.addSubview(b)
            buttons.insert(b, at: 0)
            x -= 8
        }
        let H = footerY + 56
        window.setContentSize(NSSize(width: W, height: H))
        content.frame = NSRect(x: 0, y: 0, width: W, height: H)
        window.initialFirstResponder = buttons.last
    }

    private func finish(_ i: Int) {
        close()
        done?(i)
        done = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(cancelIndex); return false }

    @objc func cancelOperation(_ sender: Any?) { finish(cancelIndex) }
}

extension PongAlert {
    /// "Stop “X”?" with Keep running as the safe default.
    static func confirmStopGraph(_ g: GGraph, on parent: NSWindow?, stop: @escaping () -> Void) {
        show(on: parent, title: "Stop “\(g.displayTitle)”?",
             message: "Steps at work stop now and nothing new starts. It stays in the list.",
             buttons: [Button("Stop graph", .destructive), Button("Keep running", .primary)],
             cancelIndex: 1) { i in if i == 0 { stop() } }
    }
}
