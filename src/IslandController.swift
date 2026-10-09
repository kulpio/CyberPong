import AppKit
import Carbon.HIToolbox

// The notch panel inside CyberPong (2.1, spec §8, §11): one non-activating panel at the top of the
// screen, driven by IslandModel (what it says), IslandHover (when it opens and closes) and IslandGeometry
// (where it sits). It reads the app's own feeds (GraphStore, IslandTeamFeed), runs every command off the
// main thread, and never takes CyberPong's windows forward unless the person asks for them.
//
// The old helper app (`com.owi.pongisland`, 2.0) is asked to quit once per launch, so two panels never
// fight over the notch; a preview never does it, and a preview's panel never sits at the real notch:
// it is drawn on a stand-in screen far off every display and photographed from its layers.

extension NSApplication {
    /// The key window, unless it is the notch panel: a toast, a sheet or an overlay goes to one of the
    /// app's own windows instead (2.1).
    var appKeyWindow: NSWindow? { keyWindow is IslandPanel ? nil : keyWindow }
    /// A visible window of the app's own that a toast can sit in: a titled one, so never the notch panel,
    /// the menu bar item's window, the Show me outline or a popover panel.
    var visibleAppWindow: NSWindow? {
        windows.first { $0.isVisible && !($0 is IslandPanel) && $0.styleMask.contains(.titled) }
    }
}

/// The panel (§11.3): borderless and non-activating, above the menu bar, on every Space, kept through
/// ⌘H and app-modal alerts. It takes the keyboard only when it needs it: a click on it, or typing.
final class IslandPanel: NSPanel {
    /// ⌘1–3, ⌘D, ⌘[ ⌘] before the main menu.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Esc, Tab, arrows, Return.
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // a click on the shape takes the keyboard (⌘1 then answers), and is delivered as a click, not a
        // first click; one in the shadow's room beside it is not the panel's
        if (event.type == .leftMouseDown || event.type == .rightMouseDown) && !isKeyWindow,
           contentView?.hitTest(event.locationInWindow) != nil {
            makeKey()
        }
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

final class IslandController: NSObject, IslandActions {
    static let shared = IslandController()
    /// The 2.0 helper app that drew the panel in a process of its own.
    static let oldHelperID = "com.owi.pongisland"

    private(set) var panel: IslandPanel?
    private var root: IslandRootView?
    private var model = IslandModel()
    private var hover = IslandHover(rules: .init(IslandSettings.current))
    private(set) var settings = IslandSettings.current
    private(set) var metrics = NotchMetrics.fake()
    private var screenID: CGDirectDisplayID?
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pointerTimer: Timer?
    private var clockTimer: Timer?
    private var monitors: [Any] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// The clock's ticks (1 s): they pace its slower work.
    private var clockTicks = 0
    /// The pointer watch's pace now (0: stopped): 0.1 s near the top centre, 0.25 s elsewhere.
    private var pointerInterval: TimeInterval = 0
    /// Keeps a nudge that dropped under a resting pointer from opening the panel by itself.
    private var areaGate = IslandAreaGate()
    /// The closing spring is running: what changes meanwhile waits for its end (`finish`), so nothing
    /// takes the spring over and skips giving the keyboard back.
    private var closing = false
    /// Counts the closes: only the last one's end may finish closing.
    private var closeCount = 0
    /// Counts the shape's moves: only the last one shrinks the window when it ends.
    private var shapeMoves = 0

    private var lastInput = IslandInput()
    private var closedLayout = IslandClosedLayout(silhouette: .zero, left: .zero, right: .zero)
    private var pointerOverClosed = false
    private var fullScreenActive = false
    /// A pick in the panel's switch while Settings says Automatic (kept until Settings changes).
    private var viewOverride: IslandSettings.View?
    private var menuShowing = false
    private var closeWork: DispatchWorkItem?
    /// The panel shows (false: hidden for a full-screen app, or a screen without a notch with nothing to say).
    private var visible = false

    // the preview's stand-in screen
    private(set) var preview = false
    private var previewNotch = true
    /// A stand-in screen far off every display: a preview's panel never covers the live one.
    static let previewOrigin = CGPoint(x: -26_000, y: -26_000)
    var previewInput: IslandInput?

    /// The open panel's room for its shadow (it sits beside and under the shape, never over the menu bar).
    private static let shadowSide: CGFloat = 12
    private static let shadowBelow: CGFloat = 20

    private enum Spring {
        static let open = (response: 0.42, damping: 0.80)
        static let close = (response: 0.36, damping: 0.90)
        static let nudge = (response: 0.22, damping: 1.0)
    }

    // MARK: Start and stop

    /// From applicationDidFinishLaunching: the old helper goes, then the panel comes up when it is on.
    func start() {
        guard !started else { return }
        started = true
        retireOldHelper()
        observe()
        settings = IslandSettings.current
        hover.rules = .init(settings)
        wireShowMe()
        if settings.enabled { build() }
    }

    /// Settings' [Show me] draws the area of this panel as it is now: its screen's notch and its closed shape.
    private func wireShowMe() {
        IslandShowMe.panelPlace = { [weak self] in
            guard let self, self.panel != nil || self.preview else { return nil }
            return (self.metrics, self.closedSilhouette)
        }
    }

    /// The preview's panel on its stand-in screen (`PONG_PREVIEW_ISLAND=1`): level normal, behind every
    /// window, far off every display; no pointer watch, no click monitors, no shortcut, no commands.
    func startPreview(notch: Bool = true) {
        guard !started else { return }
        started = true
        preview = true
        previewNotch = notch
        observe()
        settings = IslandSettings.current
        settings.enabled = true
        hover.rules = .init(settings)
        wireShowMe()
        build()
    }

    /// Settings › Notch panel's first switch (and General's): on or off, everywhere.
    func setEnabled(_ on: Bool) {
        IslandSettings.set(.hide, !on)
    }

    /// Settings were changed elsewhere: read them again.
    func reloadSettings() {
        IslandSettings.reload()
        settingsChanged()
    }

    /// The map's Island button: open now, held until the pointer has been on it once (or 10 s). Only
    /// once the panel was started: a preview without its stand-in screen (`PONG_PREVIEW_ISLAND`) never
    /// builds a live panel at the real notch.
    func forceExpand() {
        guard settings.enabled, started, !UIPreview.isOn || preview else { return }
        if panel == nil { build() }
        if hover.forceOpen(at: CACurrentMediaTime()) == .open { openPanel(focus: nil, byPerson: true) }
    }

    /// Where the pointer opens the panel now, on the screen it shows on (for Settings' [Show me]). With
    /// `s`, as those settings would have it. In a preview, on the stand-in screen.
    func openingArea(_ s: IslandSettings? = nil) -> CGRect {
        let st = s ?? settings
        return IslandGeometry.openingArea(metrics, closed: closedSilhouette, area: st.openArea,
                                          extraW: st.openExtraW, extraH: st.openExtraH)
    }

    private var showMeWindow: NSWindow?

    /// Settings' [Show me] (§8.1): the opening area drawn on the screen for 3 s, a cyan 1 pt outline over
    /// a 60% tint, "Opens here" under it. Clicks pass through it. In a preview it is drawn on the stand-in
    /// screen, never at the real notch.
    func showOpeningArea(_ s: IslandSettings? = nil) {
        if panel == nil && !preview { pickScreenForShowMe() }
        let area = openingArea(s)
        showMeWindow?.orderOut(nil)
        let frame = CGRect(x: area.minX, y: area.minY - 20, width: max(area.width, 80), height: area.height + 20).integral
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = preview ? .normal : .popUpMenu
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        let box = NSView(frame: NSRect(x: area.minX - frame.minX, y: 20, width: area.width, height: area.height))
        box.wantsLayer = true
        box.layer?.backgroundColor = PongColor.tintLive.withAlphaComponent(0.6).cgColor
        box.layer?.borderColor = PongColor.live.cgColor
        box.layer?.borderWidth = 1
        v.addSubview(box)
        let label = IslandLabel("Opens here", font: PongType.meta, color: PongColor.live)
        label.frame = NSRect(x: box.frame.minX + 4, y: 2, width: 90, height: 14)
        v.addSubview(label)
        w.contentView = v
        if preview { w.orderBack(nil) } else { w.orderFrontRegardless() }
        showMeWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak w] in
            w?.orderOut(nil)
            if self?.showMeWindow === w { self?.showMeWindow = nil }
        }
    }

    /// With the panel off, [Show me] still shows where it would open.
    private func pickScreenForShowMe() {
        let screens = NSScreen.screens
        if let s = screens.first(where: { NotchMetrics.of($0).hasNotch }) ?? screens.first { metrics = NotchMetrics.of(s) }
    }

    /// The 2.0 helper, from an update or a crash, would draw a second panel: it is asked to quit, once.
    private func retireOldHelper() {
        guard !UIPreview.isOn, !preview else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: IslandController.oldHelperID)
        guard !apps.isEmpty else { return }
        for a in apps { a.terminate() }
        Pong.log("notch panel: asked the old helper app to quit (\(apps.count))")
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: IslandSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsChanged()
        })
        observers.append(nc.addObserver(forName: GraphStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(nc.addObserver(forName: IslandTeamFeed.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.relayoutScreen()
        })
        guard !preview else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // the Space's own animation first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.checkFullScreen() }
            })
        }
        // the pointer watch rests while the screens sleep or the Mac is locked (§13.5)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pausePointer()
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.settings.enabled else { return }
                self.schedulePointer(0.1)
            })
        }
    }

    private func build() {
        guard panel == nil else { return }
        let p = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = preview ? .normal : .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.canHide = false
        p.worksWhenModal = true
        p.isExcludedFromWindowsMenu = true
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = settings.hideFromCapture ? .none : .readOnly
        p.title = "Notch panel"
        let r = IslandRootView(actions: self)
        r.onClickClosed = { [weak self] in self?.clickClosed() }
        r.nudge.onClick = { [weak self] in self?.nudgeClicked() }
        p.contentView = r
        p.onKeyEquivalent = { [weak self] e in self?.keyEquivalent(e) ?? false }
        p.onKeyDown = { [weak self] e in self?.keyDown(e) ?? false }
        panel = p
        root = r
        model = IslandModel()
        hover = IslandHover(rules: .init(settings))
        areaGate.reset()
        pickScreen()
        refresh()
        startTimers()
        registerShortcut()
        checkFullScreen()
    }

    private func teardown() {
        if hover.isOpen { GraphStore.shared.wantFast("island", false) }
        pausePointer()
        clockTimer?.invalidate()
        clockTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        unregisterShortcut()
        panel?.orderOut(nil)
        panel = nil
        root = nil
        hover.reset()
        areaGate.reset()
        closing = false
        visible = false
        IslandTeamFeed.shared.wanted = false
    }

    private func startTimers() {
        let c = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.clockTick() }
        c.tolerance = 0.2
        RunLoop.main.add(c, forMode: .common)
        clockTimer = c
        guard !preview else { return }
        // the pointer, every 0.1 s near the top centre and 0.25 s elsewhere (§13.5); no file or text work in it
        schedulePointer(0.1)
        // a click elsewhere lets a pin go, or closes with "Until I click elsewhere" (mouse monitors need
        // no Accessibility permission)
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.clickedElsewhere()
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            if e.window !== self.panel {
                self.clickedElsewhere()
            } else if let r = self.root, !IslandGeometry.hits(r.silhouette, NSEvent.mouseLocation) {
                // the shadow's room beside the shape is not the panel
                self.clickedElsewhere()
            }
            return e
        }) { monitors.append(l) }
    }

    /// The pointer watch at `every` seconds (kept as it is when it already runs at that pace).
    private func schedulePointer(_ every: TimeInterval) {
        guard !preview, panel != nil else { return }
        if pointerTimer != nil && pointerInterval == every { return }
        pointerTimer?.invalidate()
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.pointerTick() }
        t.tolerance = every * 0.2
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
        pointerInterval = every
    }

    /// The screens are awake and this session is the one on the screen: the pointer watch has work to do.
    private var pointerMayRun: Bool {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?[kCGSessionOnConsoleKey as String] as? Bool) ?? true
    }

    /// No pointer watch (the panel is off, the screens sleep, the Mac is locked).
    private func pausePointer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerInterval = 0
    }

    // MARK: Settings, screens, full screen

    private func settingsChanged() {
        let s = IslandSettings.current
        let old = settings
        settings = s
        if preview { settings.enabled = true }
        hover.rules = .init(settings)
        // "a pick in the panel keeps that pick until Settings is changed"
        if old.view != s.view { viewOverride = nil }
        guard settings.enabled else {
            teardown()
            return
        }
        guard let panel else {
            build()
            return
        }
        panel.sharingType = s.hideFromCapture ? .none : .readOnly
        if old.shortcut != s.shortcut { registerShortcut() }
        if old.screen != s.screen || old.noNotch != s.noNotch { pickScreen() }
        refresh()
    }

    /// The screen it shows on (§8.5): the one with the notch (with the lid closed, the main one), the
    /// main one, or the one with the pointer.
    private func pickScreen() {
        if preview {
            metrics = NotchMetrics.fake(notch: previewNotch, origin: IslandController.previewOrigin)
            screenID = nil
            relayout()
            return
        }
        let screens = NSScreen.screens
        let chosen: NSScreen?
        switch settings.screen {
        case .notch: chosen = screens.first { NotchMetrics.of($0).hasNotch } ?? screens.first
        case .main: chosen = screens.first
        case .pointer: chosen = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? screens.first
        }
        guard let s = chosen else { return }
        metrics = NotchMetrics.of(s)
        screenID = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        // a full-screen app is a matter of each screen: look again on this one (laid out on it first,
        // so nothing springs across screens)
        let fullChanged = readFullScreen()
        relayout()
        if fullChanged { refresh() }
    }

    private func relayoutScreen() {
        // a panel kept open moves with its screen too; a resize mid-question keeps the question
        pickScreen()
    }

    private func relayout() {
        guard root != nil else { return }
        applyClosed(animated: false)
        if hover.isOpen { layoutOpen(animated: false) } else { setRest(animated: false) }
    }

    /// A full-screen app on the panel's screen (§8.5): read again, and the panel follows when it changed.
    private func checkFullScreen() {
        if readFullScreen() { refresh() }
    }

    /// Whether the front app has a full-screen window on the panel's screen: its window covers the whole
    /// screen, or (with a notch) everything under the strip beside the camera while the menu bar is
    /// away. Returns true when that changed.
    private func readFullScreen() -> Bool {
        guard !preview, panel != nil else { return false }
        var full = false
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let f = metrics.screen
            let cg = CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height)
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            func bounds(_ w: [String: Any]) -> CGRect? {
                (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            }
            // the strip a full-screen window leaves above it: the menu bar's height, at least the notch's
            let visibleTop = NSScreen.screens.first { $0.frame == f }?.visibleFrame.maxY ?? f.maxY
            let strip = max(metrics.safeTop, f.maxY - visibleTop)
            // the menu bar on this screen: a zoomed window on the desktop has a full-screen window's frame
            let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
            let topEdge = CGRect(x: cg.minX, y: cg.minY, width: cg.width, height: 2)
            let menuBarShown = info.contains { w in
                (w[kCGWindowLayer as String] as? Int) == menuLevel && (bounds(w)?.intersects(topEdge) ?? false)
            }
            full = info.contains { w in
                guard (w[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                      (w[kCGWindowLayer as String] as? Int) == 0, let r = bounds(w) else { return false }
                return IslandGeometry.fillsScreen(r, screen: cg, notch: metrics.hasNotch, strip: strip, menuBarShown: menuBarShown)
            }
        }
        guard full != fullScreenActive else { return false }
        fullScreenActive = full
        return true
    }

    // MARK: Reading the feeds

    private var flags: IslandModel.Flags {
        IslandModel.Flags(pointerOverClosed: pointerOverClosed, panelOpen: hover.isOpen,
                          nudgeAllowed: !(fullScreenActive && settings.fullScreen == .hide))
    }

    /// The settings the model reads: the panel's own pick of the list wins over Automatic.
    private var modelSettings: IslandSettings {
        var s = settings
        if let v = viewOverride { s.view = v }
        return s
    }

    /// One read of the feeds (a graph, a question, the limits or a team changed).
    func refresh() {
        guard root != nil else { return }
        let input = previewInput ?? IslandInput.fromApp()
        lastInput = input
        model.update(input, settings: modelSettings, flags: flags)
        if let a = model.announcement, let r = root {
            NSAccessibility.post(element: r, notification: .announcementRequested,
                                 userInfo: [.announcement: a, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        // "Open the whole panel" for a new question (never at night: the model leaves `arrived` empty)
        if settings.onQuestion == .open, let first = model.arrived.first, !hover.isOpen, flags.nudgeAllowed {
            if hover.forceOpen(at: CACurrentMediaTime()) == .open { openPanel(focus: first.key, byPerson: false) }
        }
        updateTeamFeed()
        applyClosed(animated: true)
        if hover.isOpen { renderOpen(force: false) }
    }

    private func updateTeamFeed() {
        guard !preview else { return }
        let teams = model.state.view == .teams
        IslandTeamFeed.shared.wanted = teams && (hover.isOpen || settings.beside == .words)
    }

    private func clockTick() {
        guard root != nil else { return }
        // a change written elsewhere (or by hand): IslandSettings looks at the file's date and says so
        _ = IslandSettings.current
        if model.tick(now: Date().timeIntervalSince1970, flags: flags) { applyClosed(animated: true) }
        clockTicks &+= 1
        // the pointer watch rests while the screens sleep or the session is away; should the news of their
        // waking go unheard, it comes back here (never a panel the pointer can't open)
        if !preview, pointerTimer == nil, panel != nil, pointerMayRun { schedulePointer(0.1) }
        // the screen with the pointer follows the pointer (closed only: an open panel stays put)
        if !preview, settings.screen == .pointer, !hover.isOpen, clockTicks % 2 == 0,
           let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
           (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != screenID {
            pickScreen()
        }
        // "waiting 12 min" moves on while the card shows
        if hover.isOpen, clockTicks % 10 == 0 { root?.open.focusedCard?.refreshWaited() }
    }

    // MARK: The closed panel and the nudge

    /// Beside the notch: the marks, the line, the nudge; whether the panel shows at all. `shape`: move the
    /// closed shape too (closing moves it itself, with its own spring, and the shape waits for its end).
    private func applyClosed(animated: Bool, shape: Bool = true) {
        guard let root else { return }
        let c = model.closed
        root.closedLabel = c.accessibilityLabel
        root.marks.set(c.marks)
        var lw = IslandMarksView.width(c.marks)
        let rw = IslandLineView.width(c.line)
        // "Always" on a screen without a notch: a small tab even with nothing to say
        if !metrics.hasNotch && settings.noNotch == .always && lw == 0 && rw == 0 { lw = 16 }
        closedLayout = IslandGeometry.closed(metrics, leftContent: lw, rightContent: rw)
        root.line.set(c.line, animated: animated && !preview)
        root.nudge.set(c.nudge)
        updateVisibility()
        if !hover.isOpen && shape && !closing { setRest(animated: animated) } else { place() }
    }

    /// Whether the panel is on screen now.
    private func updateVisibility() {
        guard let panel else { return }
        let c = model.closed
        var show = true
        if fullScreenActive {
            switch settings.fullScreen {
            case .hide: show = false
            case .questions: show = model.state.needsCount > 0 || hover.isOpen
            case .show: show = true
            }
        }
        if !metrics.hasNotch && !hover.isOpen {
            switch settings.noNotch {
            case .never: show = false
            case .happening: show = show && !c.isEmpty
            case .always: break
            }
        }
        if hover.isOpen { show = true }
        guard show != visible || panel.isVisible != show else { return }
        visible = show
        if show {
            if preview { panel.orderBack(nil) } else { panel.orderFrontRegardless() }
        } else {
            panel.orderOut(nil)
        }
    }

    /// The shape at rest when closed: the nudge while one shows, else the closed panel; with nothing to
    /// say, the camera housing itself (no shoulders), so the shape grows out of the notch when it opens.
    private var restSilhouette: IslandSilhouette {
        if let n = model.closed.nudge {
            return IslandGeometry.nudge(metrics, closed: closedSilhouette, contentWidth: IslandNudgeView.contentWidth(n),
                                        drop: IslandNudgeView.drop)
        }
        return closedSilhouette
    }

    private var closedSilhouette: IslandSilhouette {
        let s = closedLayout.silhouette
        if model.closed.isEmpty && !(metrics.hasNotch == false && settings.noNotch == .always) {
            return metrics.hasNotch ? IslandSilhouette(body: metrics.notchRect, shoulder: 0, radius: metrics.cornerRadius) : .zero
        }
        return s
    }

    private func setRest(animated: Bool) {
        guard let root else { return }
        let s = restSilhouette
        let nudgeNow = model.closed.nudge != nil
        let wasNudge = root.silhouette.body.height > metrics.chin + 1 && !root.isOpen
        let spring = nudgeNow || wasNudge ? Spring.nudge : Spring.close
        transition(to: s, spring: animated ? spring : nil, fade: nudgeNow ? 0.15 : 0.1)
        // the nudge's words come in after the shape (in 200 ms, out at once)
        root.nudge.isHidden = !nudgeNow
        if nudgeNow && root.nudge.alphaValue < 1 {
            if animated && !preview {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    root.nudge.animator().alphaValue = 1
                }
            } else {
                root.nudge.alphaValue = 1
            }
        } else if !nudgeNow {
            root.nudge.alphaValue = 0
        }
    }

    /// Move the shape to `s`: the window grows to hold both shapes while the spring runs, and shrinks
    /// to the new one only after it ends (nothing is clipped on the way). A move that takes over from one
    /// still running starts where the shape is drawn now and keeps the window that one had. `completion`
    /// runs when this move ends, or when a later one takes it over.
    private func transition(to s: IslandSilhouette, spring: (response: Double, damping: Double)?, fade: Double = 0.15,
                            completion: (() -> Void)? = nil) {
        guard let panel, let root else { return }
        let old = root.silhouette
        let target = frame(for: s)
        let animate = spring != nil && !preview && old != .zero && s != .zero && old != s
        guard animate else {
            // already there, or on its way there: a spring still running keeps its window until it ends
            if old == s && (panel.frame == target || root.isMovingShape) { place(); completion?(); return }
            shapeMoves &+= 1
            root.setShape(s, frame: setWindow(target))
            place()
            completion?()
            return
        }
        let base = root.isMovingShape ? panel.frame.union(frame(for: old)) : frame(for: old)
        let union = setWindow(base.union(target))
        shapeMoves &+= 1
        let move = shapeMoves
        root.setShape(s, frame: union, from: old, spring: PongMotion.reduced ? nil : spring, fade: fade) { [weak self] in
            guard let self, let root = self.root else { return }
            // only the last move shrinks the window; one taken over by a later move has just ended
            if move == self.shapeMoves {
                root.setShape(s, frame: self.setWindow(self.frame(for: s)))
                self.place()
            }
            completion?()
        }
        place()
    }

    /// The window for a shape: its frame (in whole points: AppKit rounds a window's frame, and the shape
    /// is drawn for the frame the window really has), with room for the shadow under the open panel.
    private func frame(for s: IslandSilhouette) -> CGRect {
        guard s != .zero else { return CGRect(x: floor(metrics.midX) - 1, y: metrics.top - 1, width: 2, height: 1) }
        let f = s.frame
        guard isOpenShape(s) else { return f.integral }
        return CGRect(x: f.minX - IslandController.shadowSide, y: f.minY - IslandController.shadowBelow,
                      width: f.width + 2 * IslandController.shadowSide, height: f.height + IslandController.shadowBelow).integral
    }

    /// Put the window at `r` and say where it really is.
    private func setWindow(_ r: CGRect) -> CGRect {
        guard let panel else { return r }
        if panel.frame != r { panel.setFrame(r, display: true, animate: false) }
        return panel.frame
    }

    private func isOpenShape(_ s: IslandSilhouette) -> Bool {
        abs(s.body.width - IslandGeometry.openBody) < 0.5 && s.radius == IslandGeometry.openRadius
    }

    /// Everything in its place for the window as it is now.
    private func place() {
        guard let root else { return }
        let chin = metrics.chin
        let left = closedLayout.left, right = closedLayout.right
        let pad = IslandGeometry.sidePad
        root.marks.frame = root.local(CGRect(x: left.minX + pad, y: metrics.top - chin, width: max(0, left.width - 2 * pad + 4), height: chin))
        root.line.frame = root.local(CGRect(x: right.minX + pad, y: metrics.top - chin, width: max(0, right.width - 2 * pad), height: chin))
        root.marks.isHidden = root.isOpen && !metrics.hasNotch
        root.line.isHidden = root.isOpen
        if let n = model.closed.nudge {
            let body = IslandGeometry.nudge(metrics, closed: closedSilhouette, contentWidth: IslandNudgeView.contentWidth(n),
                                            drop: IslandNudgeView.drop).body
            root.nudge.frame = root.local(CGRect(x: body.minX + 12, y: metrics.top - chin - (IslandNudgeView.drop - 4),
                                                 width: max(40, body.width - 24), height: IslandNudgeView.drop - 4))
        }
        if root.isOpen {
            root.open.frame = root.local(root.silhouette.body)
        }
        root.needsDisplay = true
    }

    // MARK: Opening and closing

    private func openPanel(focus: String?, byPerson: Bool) {
        guard let panel, let root else { return }
        closeWork?.cancel()
        // reopened while it was closing: the opening spring takes over from where the shape is now
        closing = false
        // an open panel watches for the pointer leaving at full pace, wherever it was opened from (opened by a
        // question while the screens sleep, it waits for them to wake)
        if !preview && (pointerTimer != nil || pointerMayRun) { schedulePointer(0.1) }
        if !panel.isVisible || !visible {
            visible = true
            if preview { panel.orderBack(nil) } else { panel.orderFrontRegardless() }
        }
        // the nudge opens the panel at its question
        if let n = model.closed.nudge {
            root.open.focusKey = n.key
            model.nudgeLooked()
        } else if let f = focus {
            root.open.focusKey = f
        } else {
            root.open.focusKey = nil
        }
        root.isOpen = true
        root.open.clearAllDone()
        GraphStore.shared.wantFast("island", true)
        updateTeamFeed()
        renderOpen(force: true)
        root.nudge.isHidden = true
        root.open.isHidden = false
        root.setShadow(true)
        if preview || PongMotion.reduced {
            root.open.alphaValue = 1
        } else {
            root.open.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak root] in
                guard root?.isOpen == true else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    root?.open.animator().alphaValue = 1
                }
            }
        }
        layoutOpen(animated: true)
        if byPerson && settings.haptic && !preview {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        NSAccessibility.post(element: root, notification: .layoutChanged)
    }

    private func closePanel() {
        guard let root else { return }
        closeWork?.cancel()
        root.isOpen = false
        GraphStore.shared.wantFast("island", false)
        updateTeamFeed()
        let open = root.open
        closeCount &+= 1
        let this = closeCount
        var finished = false
        // runs once, when the closing spring has ended or something took it over (a redraw can't skip
        // it: the keyboard always goes back)
        let finish = { [weak self] (animated: Bool) in
            // a later close finishes itself
            guard let self, !finished, this == self.closeCount else { return }
            finished = true
            self.closing = false
            // reopened on the way: the open panel stays
            guard !self.hover.isOpen else { return }
            open.isHidden = true
            open.clearAllDone()
            self.root?.setShadow(false)
            // what changed while it closed (a new line, a nudge) moves the settled shape on
            self.applyClosed(animated: animated)
            self.releaseKeyboard()
        }
        if preview || PongMotion.reduced {
            open.alphaValue = 0
            finish(false)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            open.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.hover.isOpen == false { open.isHidden = true }
        })
        applyClosed(animated: false, shape: false)
        closing = true
        transition(to: restSilhouette, spring: Spring.close) { finish(true) }
        // the spring settles within 1.2 s; should its end never be reported, closing still finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(true) }
    }

    /// The keyboard goes back to the app that had it (the panel only borrowed it for typing or a click).
    private func releaseKeyboard() {
        guard let panel, panel.isKeyWindow, !preview else { return }
        panel.makeFirstResponder(nil)
        if NSApp.isActive, let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is IslandPanel) }) {
            w.makeKey()
        } else {
            // a non-activating panel gives the keyboard back to the frontmost app when it leaves the screen
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// Draw the open panel from the last read.
    private func renderOpen(force: Bool) {
        guard let root else { return }
        var d = IslandOpenData()
        d.state = model.state
        d.input = lastInput
        d.settings = settings
        d.view = model.state.view
        d.hasNotch = metrics.hasNotch
        d.chin = metrics.chin
        let bodyLeft = metrics.midX - IslandGeometry.openBody / 2
        d.notchLeft = metrics.notchRect.minX - bodyLeft
        d.notchRight = metrics.notchRect.maxX - bodyLeft
        d.pinned = hover.pinned
        d.marks = model.closed.marks
        root.open.render(d, force: force)
        if !force { layoutOpen(animated: true) }
    }

    /// The open shape for its content, up to the screen's cap.
    private func layoutOpen(animated: Bool) {
        guard let root, root.isOpen else { return }
        let h = root.open.preferredHeight()
        let s = IslandGeometry.open(metrics, contentHeight: h)
        if s != root.silhouette {
            let fromClosed = !isOpenShape(root.silhouette)
            transition(to: s, spring: animated ? (fromClosed ? Spring.open : Spring.close) : nil)
        } else {
            place()
        }
        root.open.needsLayout = true
    }

    // MARK: The pointer, clicks, keys

    private var holds: IslandHover.Holds {
        var h: IslandHover.Holds = []
        guard let root else { return h }
        // typing in the panel (it has the keyboard): a field left behind in another app's turn doesn't hold it
        if root.open.isTyping && (panel?.isKeyWindow ?? false) { h.insert(.typing) }
        if let c = root.open.focusedCard {
            if c.isStopArmed { h.insert(.stopArmed) }
            if c.isSending { h.insert(.sending) }
        }
        if menuShowing { h.insert(.menu) }
        if root.open.holdsReceipt { h.insert(.receipt) }
        return h
    }

    private func pointerTick() {
        guard let root, settings.enabled else { return }
        let p = NSEvent.mouseLocation
        // far from the top centre (and nothing open or nudging), a slower pace
        let near = abs(p.x - metrics.midX) < 420 && metrics.top - p.y < 520
        schedulePointer(near || hover.isOpen || model.closed.nudge != nil ? 0.1 : 0.25)
        // hidden for a full-screen app ("Always hide it"): nothing opens it (and when it comes back under a
        // pointer resting there, that pointer didn't come to it)
        if fullScreenActive && settings.fullScreen == .hide && !hover.isOpen {
            _ = areaGate.area(.null, pointer: p, panelOpen: false)
            return
        }
        let t = CACurrentMediaTime()
        var openArea = IslandGeometry.openingArea(metrics, closed: closedSilhouette, area: settings.openArea,
                                                  extraW: settings.openExtraW, extraH: settings.openExtraH)
        if model.closed.nudge != nil { openArea = openArea.union(restSilhouette.body) }
        // the area came to a pointer that hasn't moved (a nudge dropped under it): that isn't pointing
        openArea = areaGate.area(openArea, pointer: p, panelOpen: hover.isOpen)
        let openShape = root.isOpen ? root.silhouette : IslandGeometry.open(metrics, contentHeight: 320)
        let stay = IslandGeometry.stayArea(openShape, pad: settings.stayPad)
        let over = !hover.isOpen && IslandGeometry.contains(closedSilhouette.body.union(metrics.notchRect), p)
        if over != pointerOverClosed {
            pointerOverClosed = over
            if model.tick(now: Date().timeIntervalSince1970, flags: flags) { applyClosed(animated: true) }
        }
        // rows held still while the pointer was over the list come in once it leaves
        if root.isOpen { root.open.flushIfPointerLeft() }
        switch hover.pointer(p, at: t, openArea: openArea, stayArea: stay, holds: holds,
                             questionShowing: root.open.showsQuestion) {
        case .open: openPanel(focus: nil, byPerson: true)
        case .close: closePanel()
        case .hold: break
        }
    }

    private func clickClosed() {
        guard !preview else { return }
        let d = hover.clickNotch(at: CACurrentMediaTime())
        if d == .open { openPanel(focus: nil, byPerson: true) } else { root?.open.render(openData(), force: false) }
    }

    private func nudgeClicked() {
        guard !preview else { return }
        if hover.openNow(at: CACurrentMediaTime()) == .open { openPanel(focus: nil, byPerson: true) }
    }

    private func clickedElsewhere() {
        guard hover.isOpen else { return }
        let d = hover.clickElsewhere(at: CACurrentMediaTime(), holds: holds)
        if d == .close { closePanel() } else { updatePin() }
    }

    private func updatePin() {
        guard let root, root.isOpen else { return }
        root.open.render(openData(), force: false)
    }

    private func openData() -> IslandOpenData {
        var d = root?.open.data ?? IslandOpenData()
        d.pinned = hover.pinned
        return d
    }

    private func keyEquivalent(_ e: NSEvent) -> Bool {
        guard hover.isOpen, let root else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let ch = e.charactersIgnoringModifiers else { return false }
        switch ch {
        case "1", "2", "3":
            guard let c = root.open.focusedCard, !c.answered, let i = Int(ch), i - 1 < c.model.answers.count else { return false }
            c.press(i - 1)
            return true
        case "d", "D":
            root.open.focusedCard?.toggleDetails()
            return true
        case "[":
            islandSetView(.graphs)
            return true
        case "]":
            islandSetView(.teams)
            return true
        default:
            return false
        }
    }

    private func keyDown(_ e: NSEvent) -> Bool {
        guard hover.isOpen, let root, let panel else { return false }
        let typing = panel.firstResponder is NSTextView
        let shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case kVK_Escape:
            escape()
            return true
        case kVK_Tab where !typing:
            root.open.moveQuestion(shift ? -1 : 1)
            return true
        case kVK_DownArrow where !typing:
            root.open.moveSelection(1)
            return true
        case kVK_UpArrow where !typing:
            root.open.moveSelection(-1)
            return true
        case kVK_Return where !typing:
            return root.open.openSelection()
        default:
            return false
        }
    }

    /// Esc: an armed Stop first, then typing, then the pin, then the panel (§8.4).
    private func escape() {
        guard let root, let panel else { return }
        if root.open.focusedCard?.cancelArmedStop() == true { return }
        if panel.firstResponder is NSTextView {
            panel.makeFirstResponder(nil)
            return
        }
        if hover.escape(at: CACurrentMediaTime()) == .close { closePanel() } else { updatePin() }
    }

    // MARK: The keyboard shortcut (Carbon's hot keys need no permission)

    private func registerShortcut() {
        unregisterShortcut()
        guard !preview, let s = settings.shortcut else { return }
        var mods: UInt32 = 0
        if s.modifiers & IslandSettings.Shortcut.commandMask != 0 { mods |= UInt32(cmdKey) }
        if s.modifiers & IslandSettings.Shortcut.optionMask != 0 { mods |= UInt32(optionKey) }
        if s.modifiers & IslandSettings.Shortcut.controlMask != 0 { mods |= UInt32(controlKey) }
        if s.modifiers & IslandSettings.Shortcut.shiftMask != 0 { mods |= UInt32(shiftKey) }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let handler: EventHandlerUPP = { _, _, _ in
                DispatchQueue.main.async { IslandController.shared.shortcutPressed() }
                return noErr
            }
            InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: OSType(0x434E_504C), id: 1)   // "CNPL"
        let status = RegisterEventHotKey(UInt32(s.keyCode), mods, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            hotKey = nil
            Pong.log("notch panel: the shortcut \(s.display) is taken by another app (\(status))")
        }
    }

    private func unregisterShortcut() {
        if let k = hotKey { UnregisterEventHotKey(k) }
        hotKey = nil
    }

    /// The shortcut: open at the oldest question, ready for ⌘1 (pinned: the pointer is elsewhere);
    /// pressed again, close.
    private func shortcutPressed() {
        guard settings.enabled, panel != nil else { return }
        switch hover.shortcut(at: CACurrentMediaTime()) {
        case .open:
            openPanel(focus: nil, byPerson: true)
            panel?.makeKey()
        case .close:
            closePanel()
        case .hold:
            break
        }
    }

    // MARK: IslandActions

    /// Whatever opens CyberPong's window from the panel brings it forward and closes the panel.
    private func toApp(_ go: () -> Void) {
        guard !preview else { return }
        if hover.closeNow() == .close { closePanel() }
        NSApp.activate(ignoringOtherApps: true)
        go()
    }

    private func graph(_ key: String) -> GGraph? { lastInput.graphs.first { $0.key == key } }

    func islandOpenGraph(_ key: String, tab: GraphStudioView.Tab?) {
        toApp { PanelController.shared.openGraph(key, tab: tab) }
    }

    func islandOpenChat(_ key: String) {
        toApp { PanelController.shared.openChat(key) }
    }

    func islandPause(_ graphKey: String) {
        guard !preview, let g = graph(graphKey) else { return }
        GraphActions.pause(g) { [weak self] ok, err in
            self?.root?.open.showNotice(ok ? "\(g.displayTitle) is paused."
                : GraphActions.failure(err, "\(g.displayTitle) didn't pause. Try again in a moment.", log: "pause \(g.key)"), warn: !ok)
        }
    }

    func islandResume(_ graphKey: String) {
        guard !preview, let g = graph(graphKey) else { return }
        GraphActions.resume(g) { [weak self] ok, err in
            self?.root?.open.showNotice(ok ? "\(g.displayTitle) goes on."
                : GraphActions.failure(err, "\(g.displayTitle) didn't resume. Try again in a moment.", log: "resume \(g.key)"), warn: !ok)
        }
    }

    func islandStartTeam(_ session: String) {
        guard !preview else { return }
        let name = lastInput.teams.first { $0.session == session }?.name ?? lastInput.teamNames[session] ?? TeamNames.name(session)
        root?.open.showNotice("Starting \(name)…")
        TeamStart.start(session, name: name) { [weak self] in
            // its toast goes to CyberPong's window, which may be out of sight: the panel says it too
            let up = SchedulesPageView.runningTeams.contains(session)
            self?.root?.open.showNotice(up ? "\(name) is running again." : "\(name) didn't start. Try again in a moment.", warn: !up)
            self?.refresh()
        }
    }

    func islandOpenScreen(_ graphKey: String, node: String) {
        guard !preview, let g = graph(graphKey), let n = g.node(node), !n.seat.isEmpty else { return }
        SeatScreen.front(session: g.session, seat: n.seat)
    }

    func islandRetry(_ graphKey: String, node: String) {
        guard !preview, let g = graph(graphKey) else { return }
        GraphActions.retry(g, node: node) { [weak self] ok, err in
            let name = g.node(node)?.displayName ?? Words.name(node)
            self?.root?.open.showNotice(ok ? "\(name) started again."
                : GraphActions.failure(err, "\(name) didn't start again. Try again in a moment.", log: "retry \(g.key) \(node)"), warn: !ok)
        }
    }

    func islandBanner(_ kind: IslandBanner.Kind) {
        guard !preview else { return }
        switch kind {
        case .runnerOff:
            root?.open.showNotice("Turning the graph runner on…")
            GraphStore.shared.installRunner { [weak self] ok, words in self?.root?.open.showNotice(words, warn: !ok) }
        case .limitWeek:
            GraphStore.shared.resumeLimits { [weak self] ok, words in
                self?.root?.open.showNotice(ok && words.isEmpty ? "The paused graphs are running again." : words, warn: !ok)
            }
        case .engineOff:
            toApp { SettingsWindow.shared.show(.mac) }
        case .limit5h:
            break
        }
    }

    func islandNewGraph() {
        toApp { PanelController.shared.newGraph() }
    }

    func islandOpenApp() {
        toApp { PanelController.shared.show() }
    }

    func islandOpenSettings() {
        // Settings › Notch panel (its pane is the ninth; until it is there, the pane Settings shows last)
        toApp { SettingsWindow.shared.show(SettingsWindow.Pane(rawValue: 8)) }
    }

    func islandHide() {
        guard !preview else { return }
        let words = "Notch panel hidden. Settings › Notch panel brings it back."
        if (NSApp.appKeyWindow ?? NSApp.mainWindow ?? NSApp.visibleAppWindow) != nil {
            if hover.closeNow() == .close { closePanel() }
            IslandSettings.set(.hide, true)
            Toast.show(words)
            return
        }
        // no window of CyberPong's to carry the toast (the usual case): the panel says it, kept open a
        // moment to be read, then goes
        root?.open.showNotice(words)
        if hover.isOpen && !hover.pinned { hover.togglePin() }
        updatePin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.settings.enabled else { return }
            if self.hover.closeNow() == .close { self.closePanel() }
            IslandSettings.set(.hide, true)
        }
    }

    func islandTogglePin() {
        hover.togglePin()
        updatePin()
    }

    func islandClickNotch() {
        _ = hover.clickNotch(at: CACurrentMediaTime())
        updatePin()
    }

    func islandSetView(_ v: IslandSettings.View) {
        if settings.view == .automatic || preview {
            viewOverride = v
            refresh()
        } else if settings.view != v {
            IslandSettings.set(.view, v.rawValue)   // the same key as Settings › Notch panel › Shows
        } else {
            refresh()
        }
    }

    func islandSend(_ text: String, to session: String, done: @escaping (Bool) -> Void) {
        guard !preview else {
            root?.open.showNotice("A preview doesn't send messages.")
            done(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HumanConsoleController.deliver(session: session, text: text)
            DispatchQueue.main.async { [weak self] in
                self?.root?.open.showNotice(ok ? "Sent to the lead." : "Message not sent: the team isn't running.", warn: !ok)
                done(ok)
            }
        }
    }

    func islandContentChanged() {
        layoutOpen(animated: true)
    }

    func islandAnswered(_ key: String) {
        // the receipt shows for 1.5 s; then the next question moves up, or "That's everything."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let root = self.root, root.isOpen else { return }
            root.open.afterReceipt()
            self.layoutOpen(animated: true)
            guard root.open.allDone, self.settings.afterLast == .close else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self, let root = self.root, root.open.allDone, self.holds.isEmpty else { return }
                if self.hover.closeNow() == .close { self.closePanel() }
            }
            self.closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
    }

    func islandMenu(_ showing: Bool) {
        menuShowing = showing
    }
}

// MARK: - The preview's stand-in (spec §13.2)

extension IslandController {
    /// Load a scene: `before` first (a question that arrives, a graph that finishes), then `scene`.
    func previewScene(_ scene: IslandInput, before: IslandInput? = nil) {
        guard preview else { return }
        // each scene starts from a fresh read: what it shows is there already, unless `before` says
        // otherwise (a question that arrives, a graph that finishes)
        model = IslandModel()
        if let b = before {
            previewInput = b
            refresh()
        }
        previewInput = scene
        refresh()
    }

    /// The stand-in screen: a 14-inch notch, or a display without one.
    func previewSetNotch(_ notch: Bool) {
        guard preview else { return }
        previewNotch = notch
        pickScreen()
    }

    func previewOpen(_ view: IslandSettings.View) {
        guard preview else { return }
        viewOverride = view
        model.update(lastInput, settings: modelSettings, flags: flags)
        if hover.isOpen {
            renderOpen(force: true)
            layoutOpen(animated: false)
        } else if hover.forceOpen(at: CACurrentMediaTime()) == .open {
            openPanel(focus: nil, byPerson: false)
        }
    }

    func previewClose() {
        guard preview else { return }
        if hover.closeNow() == .close { closePanel() }
    }

    /// Make the n-th question (from 1) the card.
    func previewFocus(_ n: Int) {
        guard preview, let root, hover.isOpen else { return }
        let cards = model.state.needs.filter { $0.kind != .step }
        guard n >= 1, n <= cards.count else { return }
        root.open.focusKey = cards[n - 1].key
        renderOpen(force: true)
        layoutOpen(animated: false)
    }

    /// Open a graph row's step list, by the graph's name.
    func previewSteps(_ name: String) {
        guard preview, let root, hover.isOpen,
              let r = model.state.graphRows.first(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        root.open.openSteps(r.key)
        layoutOpen(animated: false)
    }

    /// The panel's layers drawn into a PNG at 2×, over a drawn slice of menu bar with its notch.
    func previewShot(_ path: String) {
        guard let panel, let root else { return }
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let m = metrics
        let wf = panel.frame
        // the slice: the window and some menu bar around it
        let region = CGRect(x: min(wf.minX, m.midX - 340) - 40, y: wf.minY - 30,
                            width: max(wf.width, 680) + 80, height: m.top - wf.minY + 30).integral
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale), pixelsHigh: Int(region.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        // a dark desktop, the menu bar band, the camera housing
        let wall = NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.15, blue: 0.20, alpha: 1),
                                       NSColor(srgbRed: 0.15, green: 0.14, blue: 0.19, alpha: 1)])
        wall?.draw(in: NSRect(origin: .zero, size: region.size), angle: -80)
        let barH = m.hasNotch ? m.chin - 2 : 24
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.55).setFill()
        NSRect(x: 0, y: region.height - (region.maxY - m.top) - barH, width: region.width, height: barH).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let barY = region.height - (region.maxY - m.top) - barH + (barH - 16) / 2
        ("File    Edit    View    Window" as NSString).draw(at: NSPoint(x: 14, y: barY), withAttributes: attrs)
        ("Thu 2:58 pm" as NSString).draw(at: NSPoint(x: region.width - 86, y: barY), withAttributes: attrs)
        if m.hasNotch {
            let n = m.notchRect.offsetBy(dx: -region.minX, dy: -region.minY)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: n.minX, y: n.minY + 2, width: n.width, height: n.height + 8),
                         xRadius: m.cornerRadius, yRadius: m.cornerRadius).fill()
        }
        cg.saveGState()
        cg.translateBy(x: wf.minX - region.minX, y: wf.minY - region.minY)
        root.layer?.render(in: cg)
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Pong.log("preview: island shot \(path)")
        }
    }

    /// What the harness checks (§13.3): every view's frame on the stand-in screen, every visible string
    /// with its size, every button inside its card, the window against the shape.
    func previewCheck(_ path: String) {
        guard let panel, let root else { return }
        root.layoutSubtreeIfNeeded()
        let wf = panel.frame
        func rect(_ r: CGRect) -> [String: Double] {
            ["x": Double(r.minX - metrics.screen.minX), "y": Double(metrics.screen.maxY - r.maxY), "w": Double(r.width), "h": Double(r.height)]
        }
        var texts: [[String: Any]] = []
        var buttons: [[String: Any]] = []
        var cards: [[String: Any]] = []
        func onScreen(_ v: NSView) -> CGRect {
            let inWin = v.convert(v.bounds, to: nil)
            return inWin.offsetBy(dx: wf.minX, dy: wf.minY)
        }
        func visibleRect(_ v: NSView) -> Bool {
            var cur: NSView? = v
            while let c = cur { if c.isHidden || c.alphaValue < 0.01 { return false }; cur = c.superview }
            return true
        }
        func walk(_ v: NSView, card: CGRect?) {
            guard visibleRect(v) else { return }
            var inCard = card
            if v is QuestionCardView {
                let r = onScreen(v)
                inCard = r
                cards.append(["frame": rect(r)])
            }
            if let b = v as? PongButton {
                let r = onScreen(b)
                var d: [String: Any] = ["title": b.title, "frame": rect(r), "height": Double(b.frame.height)]
                if let c = inCard { d["insideCard"] = c.insetBy(dx: -0.5, dy: -0.5).contains(r) }
                buttons.append(d)
            } else if let f = v as? NSTextField, !f.stringValue.isEmpty {
                var size = Double(f.font?.pointSize ?? 0)
                f.attributedStringValue.enumerateAttribute(.font, in: NSRange(location: 0, length: f.attributedStringValue.length)) { a, _, _ in
                    if let font = a as? NSFont { size = min(size == 0 ? 99 : size, Double(font.pointSize)) }
                }
                texts.append(["text": f.stringValue, "size": size, "frame": rect(onScreen(f))])
            } else if let l = v as? IslandLineView, let line = l.line {
                texts.append(["text": line.text, "size": Double(IslandStyle.lineFont.pointSize), "frame": rect(onScreen(l)),
                              "tail": line.tail, "fits": IslandStyle.width(line.text, IslandStyle.lineFont) <= l.bounds.width + 0.5])
            }
            for s in v.subviews { walk(s, card: inCard) }
        }
        walk(root, card: nil)
        let s = root.silhouette
        let out: [String: Any] = [
            "screen": ["w": Double(metrics.screen.width), "h": Double(metrics.screen.height), "notch": metrics.hasNotch,
                       "openMaxHeight": Double(metrics.openMaxHeight)],
            "notch": rect(metrics.notchRect),
            "open": root.isOpen,
            "window": rect(wf),
            "silhouette": ["body": rect(s.body), "frame": rect(s.frame), "shoulder": Double(s.shoulder)],
            // at rest the window is the shape (in whole points; the open panel adds its shadow's room)
            "windowAtRest": s == .zero || wf == frame(for: s),
            "closed": ["left": rect(closedLayout.left), "right": rect(closedLayout.right),
                       "leftWidth": Double(closedLayout.left.width), "rightWidth": Double(closedLayout.right.width)],
            "texts": texts, "buttons": buttons, "cards": cards,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
