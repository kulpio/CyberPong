import AppKit
import ApplicationServices

// What the first-run setup and Settings share: the rows (this Mac, the AIs, the planning AI,
// limits, keys), the one model they read from (`pong doctor`, the model catalog), and what
// each button does. Setup shows them one step at a time; Settings › AI accounts and
// Settings › Limits & keys show the same rows, so the two never disagree.

/// A page or sheet that shows setup rows: told when they need drawing again.
protocol SetupHost: AnyObject {
    func setupNeedsRender()
    var setupWindow: NSWindow? { get }
}

// MARK: - Rows and cards

/// A row's marker: ready, needs you, broken, or not in use.
enum SetupMark { case none, ok, needsYou, failed, off }

final class SetupFlipped: NSView {
    override var isFlipped: Bool { true }
}

/// One row: a status marker, a title, a line or two, controls at the end, and optionally a
/// full-width strip under the text (a key's field and its buttons).
final class SetupRowView: NSView {
    let mark: SetupMark
    private let markerView: StatusMarkerView?
    private let titleLabel: NSTextField
    private let lineLabel: NSTextField
    private(set) var controls: [NSView]
    var below: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let b = below { addSubview(b) } }
    }
    var belowHeight: CGFloat = 0
    /// The strip's height at a width, when it depends on it (a note that wraps); else `belowHeight`.
    var belowHeightFor: ((CGFloat) -> CGFloat)?
    /// What the controls call, kept alive with the row.
    var retained: [AnyObject] = []

    init(mark: SetupMark, title: String, line: String, controls: [NSView] = []) {
        self.mark = mark
        let status: PongStatus? = {
            switch mark {
            case .none: return nil
            case .ok: return .done
            case .needsYou: return .needsYou
            case .failed: return .failed
            case .off: return .pending
            }
        }()
        markerView = status.map { StatusMarkerView($0) }
        titleLabel = PongUI.label(title, PongType.body, PongColor.textPrimary)
        lineLabel = PongUI.label(line, PongType.secondary, PongColor.textSecondary, lines: 5)
        self.controls = controls
        super.init(frame: .zero)
        if let m = markerView { addSubview(m) }
        addSubview(titleLabel)
        addSubview(lineLabel)
        lineLabel.toolTip = line.isEmpty ? nil : line
        controls.forEach { addSubview($0) }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func size(of c: NSView) -> NSSize {
        if let b = c as? PongButton { return b.intrinsicContentSize }
        if c is NSSwitch { return c.fittingSize }
        if c is NSPopUpButton { return NSSize(width: c.frame.width > 0 ? c.frame.width : 220, height: 28) }
        if c.frame.width > 0, c.frame.height > 0 { return c.frame.size }
        return c.fittingSize
    }

    /// Lays the row out at `width`; returns its height. When the controls would leave the text
    /// too narrow to read, they move to a line of their own under it.
    @discardableResult
    func fit(width W: CGFloat) -> CGFloat {
        let sizes = controls.map(size(of:))
        let ctrlW = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, controls.count - 1)) * 8
        let textX: CGFloat = markerView == nil ? 16 : 40
        let besideW = W - textX - 16 - (controls.isEmpty ? 0 : ctrlW + 16)
        let stacked = !controls.isEmpty && besideW < 240
        let textW = stacked ? W - textX - 16 : besideW
        let hasLine = !lineLabel.stringValue.isEmpty
        var lineH: CGFloat = 0
        if hasLine {
            // measured 4 pt narrower than the label: its cell keeps 2 pt each side, and a line
            // measured as fitting that then wraps would be cut off at the bottom
            let r = lineLabel.attributedStringValue.boundingRect(with: NSSize(width: textW - 4, height: 400),
                                                                 options: [.usesLineFragmentOrigin])
            lineH = min(82, ceil(r.height) + 2)
        }
        let textH = 18 + (hasLine ? 2 + lineH : 0)
        let ctrlH = sizes.map(\.height).max() ?? 0
        let topH = stacked ? textH : max(textH, ctrlH)
        let ty = 12 + (topH - textH) / 2
        titleLabel.frame = NSRect(x: textX, y: ty, width: textW, height: 18)
        lineLabel.frame = NSRect(x: textX, y: ty + 20, width: textW, height: lineH)
        lineLabel.isHidden = !hasLine
        markerView?.frame = NSRect(x: 16, y: ty + 1, width: 16, height: 16)
        var h = 12 + topH
        let cy = stacked ? h + 10 : 12
        let band = stacked ? ctrlH : topH
        var x = W - 16
        for (c, s) in zip(controls, sizes).reversed() {
            x -= s.width
            c.frame = NSRect(x: x, y: cy + (band - s.height) / 2, width: s.width, height: s.height)
            x -= 8
        }
        if stacked { h += 10 + ctrlH }
        if let b = below {
            let bw = W - textX - 16
            let bh = belowHeightFor?(bw) ?? belowHeight
            b.frame = NSRect(x: textX, y: h + 10, width: bw, height: bh)
            h += 10 + bh
        }
        h += 12
        setFrameSize(NSSize(width: W, height: h))
        return h
    }
}

/// Rows on one borderless card, divided by hairlines.
final class SetupCardView: NSView {
    let rows: [SetupRowView]
    private var dividers: [NSView] = []

    init(rows: [SetupRowView], fill: NSColor) {
        self.rows = rows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = PongRadius.card
        rows.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    @discardableResult
    func fit(width: CGFloat) -> CGFloat {
        dividers.forEach { $0.removeFromSuperview() }
        dividers = []
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            let h = r.fit(width: width)
            r.frame.origin = NSPoint(x: 0, y: y)
            y += h
            if i < rows.count - 1 {
                let d = PongUI.divider(width: width - 16)
                d.frame = NSRect(x: 16, y: y - 1, width: width - 16, height: 1)
                addSubview(d)
                dividers.append(d)
            }
        }
        setFrameSize(NSSize(width: width, height: y))
        return y
    }
}

/// A text field in the 1.9 look: `bg.field`, a control edge, radius 6.
final class SetupField: NSView, NSTextFieldDelegate {
    let field: NSTextField
    var onChange: ((String) -> Void)?
    /// Return, or leaving the field.
    var onCommit: ((String) -> Void)?
    /// Return only.
    var onReturn: ((String) -> Void)?

    private let preferred: NSSize

    init(secure: Bool = false, placeholder: String, value: String = "", width: CGFloat, height: CGFloat = 28) {
        field = secure ? NSSecureTextField() : NSTextField()
        preferred = NSSize(width: width, height: height)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = PongColor.field.cgColor
        layer?.cornerRadius = PongRadius.control
        layer?.borderWidth = 1
        layer?.borderColor = PongColor.control.cgColor
        field.font = PongType.body
        field.textColor = PongColor.textPrimary
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = value
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: PongType.body, .foregroundColor: PongColor.textTertiary,
        ])
        field.setAccessibilityLabel(placeholder)
        field.delegate = self
        addSubview(field)
        setFrameSize(frame.size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { preferred }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let fh: CGFloat = 18
        field.frame = NSRect(x: 8, y: (newSize.height - fh) / 2, width: max(10, newSize.width - 16), height: fh)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)), let r = onReturn {
            r(field.stringValue)
            return true
        }
        return false
    }
}

/// The step dots at the top of the setup sheet: done, this one (wide), still to come.
final class StepDotsView: NSView {
    var count: Int { didSet { needsDisplay = true } }
    var current = 0 {
        didSet {
            needsDisplay = true
            setAccessibilityLabel("Step \(current + 1) of \(count)")
        }
    }

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Step 1 of \(count)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for i in 0..<count {
            let w: CGFloat = i == current ? 16 : 6
            let c = i == current ? PongColor.textPrimary : (i < current ? PongColor.textSecondary : PongColor.mark)
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - 6) / 2, width: w, height: 6), xRadius: 3, yRadius: 3).fill()
            x += w + 6
        }
    }
}

// MARK: - The model both read from

/// The AIs and models `pong model list` knows, which one the lead policy recommends for the
/// planning chat, and which model that policy would pick on each AI.
struct ModelCatalog: Equatable {
    var available: [String] = []
    var labels: [String: String] = [:]
    var models: [String: [String]] = [:]
    var modelLabels: [String: [String: String]] = [:]
    var defaults: [String: String] = [:]
    var recRuntime = ""
    var recModel = ""
    var leadModel: [String: String] = [:]

    func label(_ rt: String) -> String {
        if let l = labels[rt], !l.isEmpty { return l }
        return DoctorReport.knownLabels[rt] ?? Words.name(rt)
    }

    func modelLabel(_ rt: String, _ m: String) -> String {
        if let l = modelLabels[rt]?[m], !l.isEmpty { return l }
        return m
    }

    /// "Claude Code · Fable 5".
    func pair(_ rt: String, _ m: String) -> String {
        m.isEmpty ? label(rt) : "\(label(rt)) · \(modelLabel(rt, m))"
    }

    /// The model the lead policy would put the planning chat on for `rt`.
    func lead(for rt: String) -> String {
        if let m = leadModel[rt], !m.isEmpty { return m }
        if rt == recRuntime, !recModel.isEmpty { return recModel }
        return defaults[rt] ?? ""
    }

    static func parse(list: [String: Any], plan: [String: Any]) -> ModelCatalog {
        var c = ModelCatalog()
        c.available = GJ.strings(list["available"])
        for (rt, info) in GJ.dict(list["runtimes"]) {
            let d = GJ.dict(info)
            var ids: [String] = []
            var names: [String: String] = [:]
            for (mid, m) in GJ.dict(d["models"]) {
                ids.append(mid)
                names[mid] = GJ.str(GJ.dict(m)["label"])
            }
            c.models[rt] = ids.sorted { (names[$0] ?? $0).localizedStandardCompare(names[$1] ?? $1) == .orderedAscending }
            c.modelLabels[rt] = names
            c.defaults[rt] = GJ.str(d["default_model"])
            c.labels[rt] = GJ.str(d["label"])
        }
        c.recRuntime = GJ.str(plan["runtime"])
        c.recModel = GJ.str(plan["model"])
        return c
    }
}

/// This Mac's two permissions, read by the app itself (the engine can't see them). What the
/// answers mean, and the last real answer standing in while Terminal is closed: SetupCore.swift.
extension MacChecks {
    static func read() -> MacChecks {
        var m = MacChecks()
        m.accessibility = AXIsProcessTrusted()
        let terminal = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        let status = AEDeterminePermissionToAutomateTarget(terminal.aeDesc, typeWildCard, typeWildCard, false)
        m.automation = settle(automation(status: Int32(status)))
        return m
    }
}

/// A soft fade at the foot of a scroll view while there is more below. macOS hides scroll bars
/// until something scrolls, so a long setup step or Settings pane would otherwise look finished
/// at its bottom edge. Sits over the scroll view; clicks go through.
final class MoreBelowFade: NSView {
    private weak var scroll: NSScrollView?
    private let gradient = CAGradientLayer()
    private var observer: NSObjectProtocol?

    init(on scroll: NSScrollView, color: NSColor) {
        self.scroll = scroll
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)    // bottom: the page's own colour
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(gradient)
        isHidden = true
        setAccessibilityElement(false)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.update()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    /// Put it over the scroll view's last `height` points; call after the scroll view moves.
    func place(height: CGFloat = 36) {
        guard let s = scroll else { return }
        let f = s.frame
        let y = superview?.isFlipped == true ? f.maxY - height : f.minY
        frame = NSRect(x: f.minX, y: y, width: max(0, f.width - 14), height: height)
        needsLayout = true
        update()
    }

    /// Shown only while something is still out of sight below.
    func update() {
        guard let s = scroll, let doc = s.documentView else { isHidden = true; return }
        let visible = s.contentView.bounds
        let below = doc.isFlipped ? doc.frame.height - visible.maxY : visible.minY
        isHidden = below < 4
    }
}

/// One place that reads `pong doctor`, the model catalog and the limits state, polls while a
/// setup page is open, and says when anything changed.
final class SetupModel {
    static let shared = SetupModel()
    static let didChange = Notification.Name("CyberPongSetupModelDidChange")

    private(set) var doctor: DoctorReport?
    private(set) var catalog: ModelCatalog?
    private(set) var mac = MacChecks()
    /// The key status (`pong keys status`, also in the doctor's answer), whichever came last.
    private(set) var keysRead: KeysStatus?
    /// What the key rows show: the engine's answer, else the app's own check of the files.
    var keys: KeysStatus { keysRead ?? KeysStatus.fromFiles() }
    /// Claude's own usage credits as the runner last read them: "on", "off", or nil.
    private(set) var credits: String?

    /// AIs whose sign-in Terminal is open (their row says so until they're signed in).
    var signingIn: Set<String> = []
    /// The Guide's sign-in Terminal is open.
    var guideAwaitingLogin = false
    /// Last result under each key row ("Saved.", "Works · 412 ms").
    var keyNotes: [SetupKeys.Name: String] = [:]
    /// What the person has typed into a key field but not saved: kept across a redraw so a
    /// status change elsewhere doesn't wipe it. Never written anywhere.
    var keyDrafts: [SetupKeys.Name: String] = [:]
    var keyTestRunning = false

    private var doctorBusy = false
    private var catalogBusy = false
    private var schedule = PollSchedule()
    private var timer: Timer?

    func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    // MARK: Polling while a setup page is visible

    /// Pages call this on every redraw: only a page that wasn't polling yet gets a check at once,
    /// so a redraw caused by a check never asks for the next one straight away.
    func startPolling(_ owner: AnyObject, every seconds: TimeInterval = 3) {
        let r = schedule.add(ObjectIdentifier(owner), every: seconds)
        if r.changed || timer == nil { restartTimer() }
        if r.isNew { refreshDoctor() }
    }

    func stopPolling(_ owner: AnyObject) {
        if schedule.remove(ObjectIdentifier(owner)) { restartTimer() }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard let every = schedule.interval else { return }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.refreshDoctor() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Reading

    /// `pong doctor --json` (or the preview's doctor.json), the permissions and the credits.
    func refreshDoctor(completion: (() -> Void)? = nil) {
        guard !doctorBusy else { completion?(); return }
        doctorBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Self.readDoctor()
            let mac = MacChecks.read()
            let credits = Self.readCredits()
            DispatchQueue.main.async {
                self.doctorBusy = false
                // the runner's last beat moves on every check: alone it is not a change to redraw for
                let changed = !report.sameForDisplay(self.doctor) || mac != self.mac || credits != self.credits
                    || report.keys != self.keysRead
                self.doctor = report
                self.mac = mac
                self.credits = credits
                self.keysRead = report.keys
                self.syncSignIns(report)
                if changed { self.notify() }
                completion?()
            }
        }
    }

    /// `pong keys status --json` alone: quicker than the whole check, after a key is saved.
    /// `completion` runs on the main thread once `keys` holds the answer.
    func refreshKeys(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            var k: KeysStatus?
            if let p = Self.previewDoctorPath {
                k = DoctorReport.parse(Pong.loadJSON(p)).keys
            } else if LocalChecks.pythonPath() != nil,
                      let obj = Self.json(GraphCLI.runSync(["keys", "status", "--json"], timeout: 15)) {
                k = KeysStatus.parse(obj)
            }
            let read = (k?.known == true ? k : nil) ?? KeysStatus.fromFiles()
            DispatchQueue.main.async {
                if read != self.keysRead {
                    self.keysRead = read
                    self.notify()
                }
                completion?()
            }
        }
    }

    func refreshCatalog() {
        guard !catalogBusy else { return }
        catalogBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            // no usable python3: `pong` would run Apple's stub, which pops an install dialog
            guard LocalChecks.pythonPath() != nil else {
                DispatchQueue.main.async { self.catalogBusy = false }
                return
            }
            let list = Self.json(GraphCLI.runSync(["model", "list", "--json"], timeout: 20))
            let plan = Self.json(GraphCLI.runSync(["model", "plan", "--role", "orchestrator", "--json"], timeout: 20))
            var c: ModelCatalog?
            if let list {
                var cat = ModelCatalog.parse(list: list, plan: plan ?? [:])
                cat.leadModel = Self.leadModels()
                c = cat
            }
            DispatchQueue.main.async {
                self.catalogBusy = false
                guard let c, c != self.catalog else { return }
                self.catalog = c
                self.notify()
            }
        }
    }

    /// The JSON object a command printed, whatever its exit code: a check that found problems
    /// may well exit non-zero and still say what it found.
    private static func json(_ r: GraphCLI.Result) -> [String: Any]? {
        guard let d = r.out.data(using: .utf8), !d.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static var previewDoctorPath: String? {
        guard UIPreview.isOn, let d = UIPreview.env["PONG_PREVIEW_STATE"], !d.isEmpty else { return nil }
        let p = d + "/doctor.json"
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Blocking: the engine's own check, or the app's own check of the same things when it can't run.
    static func readDoctor() -> DoctorReport {
        if let p = previewDoctorPath, case let obj = Pong.loadJSON(p), !obj.isEmpty {
            var r = DoctorReport.parse(obj)
            if !r.keys.known { r.keys = KeysStatus.fromFiles() }
            return r
        }
        guard LocalChecks.pythonPath() != nil else {
            return LocalChecks.report(problem: "Python isn't installed yet, so CyberPong's engine can't run its own check.")
        }
        let r = GraphCLI.runSync(["doctor", "--json"], timeout: 20)
        if let obj = json(r) {
            var d = DoctorReport.parse(obj)
            if !d.keys.known { d.keys = KeysStatus.fromFiles() }
            return d
        }
        let why = r.code == 127 || r.code == -1
            ? "The pong command isn't set up yet, so CyberPong checked this Mac by itself and some rows may be unsure. Fix the pong command above for the full check."
            : "CyberPong's engine couldn't run its check, so CyberPong checked this Mac by itself and some rows may be unsure."
        return LocalChecks.report(problem: why)
    }

    /// limits-state.json's `credits` (C6), written by the runner.
    private static func readCredits() -> String? {
        let v = (Pong.loadJSON(Pong.stateDir + "/limits-state.json")["credits"] as? String) ?? ""
        return v == "on" || v == "off" ? v : nil
    }

    /// For each AI, the model the lead policy would pick when the planning chat runs on it.
    /// The engine decides (its catalog, rules and overrides), asked once per catalog read.
    private static func leadModels() -> [String: String] {
        guard let py = LocalChecks.pythonPath() else { return [:] }
        var roots: [String] = [Pong.stateDir + "/lib", NSHomeDirectory() + "/.pong/lib"]
        if let res = Bundle.main.resourcePath { roots.append(res + "/python") }
        let path = roots.filter { FileManager.default.fileExists(atPath: $0 + "/pong/__init__.py") }
        guard !path.isEmpty else { return [:] }
        let script = """
        import json
        from pong import models as M
        out = {}
        for rt in sorted(M.runtimes(None)):
            try:
                p = M.plan("", "orchestrator", prefer_runtime=rt).as_dict()
            except Exception:
                continue
            if p.get("runtime") == rt and p.get("model"):
                out[rt] = p["model"]
        print(json.dumps(out))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Pong.extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONPATH"] = path.joined(separator: ":")
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }

    /// A sign-in the engine can see marks that AI ready for the team gate too, and ends the
    /// "waiting for you in Terminal" line. A sign-out never clears a flag the person set.
    private func syncSignIns(_ r: DoctorReport) {
        for ai in r.ais where ai.signedIn == true {
            signingIn.remove(ai.id)
            if !UIPreview.isOn, ai.installed, !ProviderAuth.isMarkedReady(typeId: ai.id) {
                ProviderAuth.markReady(typeId: ai.id, ready: true)
            }
        }
    }
}

// MARK: - The app's own check, when the engine can't answer

enum LocalChecks {
    /// The python3 the `pong` command will find, or nil. /usr/bin/python3 counts only when
    /// Apple's command line tools are there: without them it's a stub that pops a dialog.
    static func pythonPath() -> String? {
        let fm = FileManager.default
        for dir in Pong.extraPath.split(separator: ":").map(String.init)
            + ["/Library/Frameworks/Python.framework/Versions/Current/bin"] {
            let p = dir + "/python3"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        if fm.isExecutableFile(atPath: "/usr/bin/python3"), commandLineToolsInstalled() { return "/usr/bin/python3" }
        return nil
    }

    static func commandLineToolsInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let dir = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !dir.isEmpty && FileManager.default.fileExists(atPath: dir)
    }

    static func report(problem: String) -> DoctorReport {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var r = DoctorReport()
        r.fromEngine = false
        r.problem = problem
        let py = pythonPath()
        r.python = .init(ok: py != nil, path: py ?? "", version: "", fix: "xcode-select --install")
        let tmux = AppAIRuntime.resolveBinary("tmux")
        r.tmux = .init(ok: tmux != nil, path: tmux ?? "", version: "", fix: "brew install tmux")
        let brew = AppAIRuntime.resolveBinary("brew")
        r.brew = .init(ok: brew != nil, path: brew ?? "", version: "", fix: "")
        let launcher = EngineInstall.launcherPath(home: home)
        r.launcher = .init(ok: fm.isExecutableFile(atPath: launcher), path: launcher, version: "", fix: "")
        let pkg = Pong.stateDir + "/lib/pong"
        let v = EngineVersion.read(packageDir: pkg)
        r.engine = .init(ok: v != nil, path: pkg, version: v ?? "", fix: "")
        r.runner = .init(ok: false, installed: fm.fileExists(atPath: RunnerInstall.plistPath(home: home)),
                         running: nil, lastBeat: nil)
        r.ais = DoctorReport.aiOrder.map { id in
            let installed = ProviderAuth.isInstalled(typeId: id)
            var signed: Bool?
            switch id {
            case "grok":
                let size = (try? fm.attributesOfItem(atPath: home + "/.grok/auth.json"))?[.size] as? Int ?? 0
                signed = installed ? size > 0 : nil
            case "codex":
                signed = installed ? fm.fileExists(atPath: home + "/.codex/auth.json") : nil
            default:
                signed = nil
            }
            return DoctorReport.AI(id: id, label: DoctorReport.knownLabels[id] ?? id, installed: installed,
                                   path: "", signedIn: signed, plan: "", enabled: AppSettings.aiEnabled(id),
                                   login: DoctorReport.knownLogin[id] ?? "", install: DoctorReport.knownInstall[id] ?? "")
        }
        r.keys = KeysStatus.fromFiles()
        return r
    }
}

// MARK: - What the buttons do

enum SetupActions {
    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// A one-line toast on the window the person is looking at (a sheet's window, not the
    /// sheet: a toast sits at a window's foot). Keep it short: it is one line.
    static func toast(_ message: String, warn: Bool = false) {
        let key = NSApp.appKeyWindow
        Toast.show(message, warn: warn, in: key?.sheetParent ?? key)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast("Copied the install command.")
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Run `command` in a new Terminal window the person can watch. Opening a .command file
    /// needs no Automation permission, which a new Mac may not have granted yet. `shown` is what
    /// the window says it runs, when `command` is longer than the person needs to read.
    static func runInTerminal(title: String, command: String, shown: String? = nil) {
        let dir = NSTemporaryDirectory() + "pong-setup/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "run-\(Int(Date().timeIntervalSince1970))-\(UInt16.random(in: 0...UInt16.max)).command"
        let safeTitle = title.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
        let body = """
        #!/bin/bash
        export PATH="\(Pong.extraPath):$PATH"
        printf '\\033]0;CyberPong · %s\\007' \(shq(safeTitle))
        clear
        echo ""
        printf '  CyberPong · %s\\n  Running: %s\\n\\n' \(shq(safeTitle)) \(shq(shown ?? command))
        \(command)
        echo ""
        echo "  Done. You can close this window and go back to CyberPong."
        """
        guard SecureFile.write(Data(body.utf8), to: path, mode: 0o700) else {
            toast("Couldn't open Terminal.", warn: true)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        Pong.log("setup: opened Terminal for \(title)")
    }

    /// `pong <args>` for a Terminal window: the pong command when there is one (on the shell's
    /// PATH, or in ~/bin, which a new Mac's PATH lacks), else the engine this app put in the state
    /// folder (or carries inside it), run by python3.
    static func pongInShell(_ args: String) -> String {
        var roots = [Pong.stateDir + "/lib"]
        if let res = Bundle.main.resourcePath { roots.append(res + "/python") }
        let path = roots.filter { FileManager.default.fileExists(atPath: $0 + "/pong/cli/main.py") }
        let command = "if command -v pong >/dev/null 2>&1; then pong \(args); "
            + "elif [ -x \"$HOME/bin/pong\" ]; then \"$HOME/bin/pong\" \(args); "
        guard !path.isEmpty else { return command + "else pong \(args); fi" }
        return command + "else PYTHONPATH=\(shq(path.joined(separator: ":"))) python3 -m pong.cli.main \(args); fi"
    }

    /// Opens the AI's own sign-in in Terminal; its row flips to signed in once the engine sees it.
    static func signIn(_ ai: DoctorReport.AI, host: SetupHost?) {
        SetupModel.shared.signingIn.insert(ai.id)
        host?.setupNeedsRender()
        let cmd = ai.login.isEmpty ? nil : ai.login
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ProviderAuth.openLoginTerminal(typeId: ai.id, command: cmd)
        }
    }

    /// For an AI whose sign-in the engine can't see: the person says so.
    static func confirmSignedIn(_ ai: DoctorReport.AI, host: SetupHost?) {
        ProviderAuth.closeLoginTerminal()
        ProviderAuth.markReady(typeId: ai.id, ready: true)
        SetupModel.shared.signingIn.remove(ai.id)
        host?.setupNeedsRender()
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        AppSettings.setAIEnabled(id, on)
        SetupModel.shared.refreshCatalog()
        SetupModel.shared.refreshDoctor()
    }

    static func installTmux(brew: Bool) {
        if brew {
            runInTerminal(title: "install tmux", command: "brew install tmux")
        } else {
            open("https://brew.sh")
            toast("Get Homebrew from brew.sh first.")
        }
    }

    static func installCommandLineTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        toast("macOS will ask to install the tools.")
    }

    /// Writes ~/bin/pong and puts the app's engine in place (C9), then checks again. A preview only
    /// looks; and with no usable Python yet the command couldn't run, so it isn't written.
    static func fixPongCommand() {
        if UIPreview.isOn {
            toast("This is a preview: it never changes this Mac's pong command.")
            return
        }
        guard LocalChecks.pythonPath() != nil else {
            toast("Install Apple's command line tools first: the pong command needs Python.", warn: true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let o = EngineInstall.refresh(home: NSHomeDirectory(), stateDir: EngineInstall.engineStateDir,
                                          bundleResources: EngineInstall.bundleResources,
                                          kickstart: EngineInstall.kickstartRunnerIfLoaded)
            let state = EngineInstall.launcherState(home: NSHomeDirectory())
            DispatchQueue.main.async {
                if o.launcher {
                    toast("The pong command is in place.")
                } else if state == .danglingLink {
                    // the person's own link (to a checkout, say) is left alone, even when its file is gone
                    toast("~/bin/pong is your own link and its file is missing: CyberPong leaves it alone.", warn: true)
                } else if state == .notRunnable {
                    toast("~/bin/pong is there but can't run: CyberPong leaves it alone.", warn: true)
                } else {
                    toast("Couldn't write the pong command.", warn: true)
                }
                SetupModel.shared.refreshDoctor()
            }
        }
    }

    /// `pong runtime install-agent --json` (C5): the graph runner, started by macOS at login.
    /// `place`: beside this Mac's rows, or elsewhere (the words then say where the rows are).
    /// `done` gets whether it is on and plain words; without it they show as a toast. A preview
    /// only says so: there is one runner per Mac, and it is the person's.
    static func installRunner(_ place: RunnerInstall.Place = .rows, done: ((Bool, String) -> Void)? = nil) {
        if UIPreview.isOn {
            if let done { done(false, RunnerInstall.preview) } else { toast(RunnerInstall.preview) }
            return
        }
        let say: (Bool, String) -> Void = { ok, words in
            if let done { done(ok, words) } else { toast(words, warn: !ok) }
        }
        // no usable Python: the engine can't run, and `pong` would reach Apple's stub
        guard LocalChecks.pythonPath() != nil else {
            say(false, RunnerInstall.noPython(place))
            return
        }
        GraphCLI.run(["runtime", "install-agent", "--json"], timeout: 40) { r in
            let reply = RunnerInstall.words(code: r.code, out: r.out, err: r.err, place: place)
            if !reply.ok {
                // the engine's error carries launchctl's own output: the log keeps it, the person reads plain words
                Pong.log("setup: install-agent failed \(r.code) \(r.out.prefix(300)) \(r.err.prefix(300))")
            }
            say(reply.ok, reply.words)
            SetupModel.shared.refreshDoctor()
            GraphStore.shared.refresh()
        }
    }

    static func allowAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    /// Makes macOS ask now (it only asks while Terminal is running), else opens the pane.
    static func askAutomation(_ state: MacChecks.Automation) {
        if state == .denied {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = false
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                   configuration: cfg) { _, _ in }
                Thread.sleep(forTimeInterval: 1.5)
            }
            let terminal = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
            _ = AEDeterminePermissionToAutomateTarget(terminal.aeDesc, typeWildCard, typeWildCard, true)
            DispatchQueue.main.async { SetupModel.shared.refreshDoctor() }
        }
    }

    // MARK: Keys

    static func saveKey(_ n: SetupKeys.Name, _ raw: String, host: SetupHost?) {
        let m = SetupModel.shared
        guard let key = SetupKeys.clean(raw, for: n) else {
            m.keyNotes[n] = SetupKeys.problem(raw, for: n) ?? "That doesn't look like a key. Paste it again."
            host?.setupNeedsRender()
            return
        }
        if SetupKeys.save(n, key: key) {
            m.keyDrafts[n] = nil
            m.keyNotes[n] = n == .jev ? "Saved. Test checks that Jev accepts it." : "Saved."
            Pong.log("setup: \(n.rawValue) key saved in Settings")
        } else {
            m.keyNotes[n] = "Couldn't save the key on this Mac."
        }
        host?.setupNeedsRender()
        m.refreshKeys()
    }

    /// Remove takes only the file Settings saved. Once the engine has looked again, the note says
    /// when a key from somewhere else is still used, and that its switch is what stops it.
    static func removeKey(_ n: SetupKeys.Name, host: SetupHost?) {
        let m = SetupModel.shared
        let removed = SetupKeys.remove(n)
        m.keyNotes[n] = removed ? "Removed from Settings." : "Couldn't remove the key."
        Pong.log(removed ? "setup: \(n.rawValue) key removed from Settings" : "setup: could not remove the \(n.rawValue) key file")
        host?.setupNeedsRender()
        m.refreshKeys { [weak host] in
            let note = KeysStatus.afterRemove(n, removed: removed, now: m.keys[n])
            guard note != m.keyNotes[n] else { return }
            m.keyNotes[n] = note
            host?.setupNeedsRender()
        }
    }

    /// `pong jev key test --json` (C3): one trivial call, not counted against Jev's breaker.
    static func testJev(host: SetupHost?) {
        let m = SetupModel.shared
        guard !m.keyTestRunning else { return }
        m.keyTestRunning = true
        m.keyNotes[.jev] = "Testing…"
        host?.setupNeedsRender()
        GraphCLI.run(["jev", "key", "test", "--json"], timeout: 45) { r in
            m.keyTestRunning = false
            let obj = (r.out.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
            let ms = AppSettings.number(obj["ms"]).map { " · \(Int($0)) ms" } ?? ""
            switch (obj["result"] as? String) ?? "" {
            case "works": m.keyNotes[.jev] = "Works" + ms
            case "key refused": m.keyNotes[.jev] = "Key refused. Check it and save it again."
            case "unreachable": m.keyNotes[.jev] = "Can't reach Jev. Check the internet connection and try again."
            case "no key": m.keyNotes[.jev] = "No key yet."
            default: m.keyNotes[.jev] = "Couldn't test the key on this Mac."
            }
            host?.setupNeedsRender()
        }
    }
}

// MARK: - The planning chat's AI and model

/// The AI and Model pop-ups: in setup and Settings (the saved default) and in New graph (this
/// graph's chat). Picking an AI puts its model on the one the lead policy would choose for it.
final class ArchitectPicker: NSObject {
    enum Style { case settings, newGraph }

    let aiPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
    let modelPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
    /// Runtime and model as picked; nil runtime = the recommendation (or the saved default).
    var onChange: ((String?, String?) -> Void)?
    private let style: Style
    private var catalog = ModelCatalog()
    /// New graph: what the first items stand for, decided once in `fill` so the AI and Model
    /// pop-ups never disagree (the saved default when it can run here, else the recommendation).
    private var newGraphFirst: (ai: String, model: String, isDefault: Bool)?

    init(style: Style) {
        self.style = style
        super.init()
        aiPop.target = self
        aiPop.action = #selector(aiChanged)
        modelPop.target = self
        modelPop.action = #selector(modelChanged)
        aiPop.setAccessibilityLabel("The AI that plans your graphs")
        modelPop.setAccessibilityLabel("Its model")
        fill(catalog: nil, doctor: nil)
    }

    var runtime: String? { aiPop.selectedItem?.representedObject as? String }
    var model: String? { modelPop.selectedItem?.representedObject as? String }

    /// The AIs to offer: able to plan, installed and switched on, signed-in ones first.
    static func runtimes(_ c: ModelCatalog, _ d: DoctorReport?) -> [String] {
        PlanningAI.offer(available: c.available, enabled: AppSettings.aiEnabled,
                         installed: installedSet(d), signedIn: Set((d?.ais ?? []).filter { $0.signedIn == true }.map(\.id)))
    }

    /// The AIs the check found installed; nil while it hasn't answered (or knows none of them).
    private static func installedSet(_ d: DoctorReport?) -> Set<String>? {
        guard let d, !d.ais.isEmpty else { return nil }
        // an AI the check doesn't list can't be judged by it: keep the catalog's word for it
        let unlisted = Set(PlanningAI.runtimes).subtracting(d.ais.map(\.id))
        return Set(d.ais.filter(\.installed).map(\.id)).union(unlisted)
    }

    /// Why the saved planning AI can't run here ("off", "not installed", …), or nil.
    static func savedBlocker(_ c: ModelCatalog, _ d: DoctorReport?, _ rt: String) -> String? {
        PlanningAI.blocker(rt, available: c.available, enabled: AppSettings.aiEnabled(rt),
                           installed: installedSet(d).map { $0.contains(rt) })
    }

    /// Rebuild both pop-ups. In setup and Settings the saved default is selected.
    func fill(catalog c: ModelCatalog?, doctor d: DoctorReport?) {
        catalog = c ?? ModelCatalog()
        let saved = AppSettings.architect
        aiPop.removeAllItems()
        let rec = catalog.recRuntime.isEmpty ? "" : " (\(catalog.pair(catalog.recRuntime, catalog.recModel)))"
        switch style {
        case .settings:
            aiPop.addItem(withTitle: "Recommended" + rec)
        case .newGraph:
            // the engine uses the saved default when nothing is passed, and passes over one that
            // can't run here for its recommendation: the label says which of the two it will be.
            // Only the AI's name goes here (a 270 pt pop-up); the Model pop-up names the model.
            if let s = saved, c != nil, Self.savedBlocker(catalog, d, s.runtime) == nil {
                let m = s.model.isEmpty ? catalog.lead(for: s.runtime) : s.model
                newGraphFirst = (catalog.label(s.runtime), m.isEmpty ? "" : catalog.modelLabel(s.runtime, m), true)
            } else if !catalog.recRuntime.isEmpty {
                newGraphFirst = (catalog.label(catalog.recRuntime),
                                 catalog.recModel.isEmpty ? "" : catalog.modelLabel(catalog.recRuntime, catalog.recModel), false)
            } else {
                newGraphFirst = nil
            }
            aiPop.addItem(withTitle: PlanningAI.newGraphTitles(newGraphFirst).ai)
        }
        aiPop.lastItem?.representedObject = nil
        var rts = Self.runtimes(catalog, d)
        if style == .settings, let s = saved, !rts.contains(s.runtime) { rts.append(s.runtime) }
        for rt in rts {
            let why = Self.savedBlocker(catalog, d, rt)
            aiPop.addItem(withTitle: catalog.label(rt) + (why.map { " (\($0))" } ?? ""))
            aiPop.lastItem?.representedObject = rt
        }
        if style == .settings, let s = saved,
           let i = aiPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == s.runtime }) {
            aiPop.selectItem(at: i)
        } else {
            aiPop.selectItem(at: 0)
        }
        fillModels(prefer: style == .settings ? saved?.model : nil)
        PongTheme.stylePopUp(aiPop)
        showTitlesOnHover()
    }

    /// Put the pop-ups back on a choice made before a refill (nil: leave the first item).
    func select(runtime rt: String?, model m: String?) {
        guard let rt, let i = aiPop.itemArray.firstIndex(where: { ($0.representedObject as? String) == rt }) else { return }
        aiPop.selectItem(at: i)
        fillModels(prefer: m)
        PongTheme.stylePopUp(aiPop)
        showTitlesOnHover()
    }

    /// A title that still doesn't fit its pop-up can be read in full on hover.
    private func showTitlesOnHover() {
        aiPop.toolTip = aiPop.titleOfSelectedItem
        modelPop.toolTip = modelPop.titleOfSelectedItem
    }

    private func fillModels(prefer: String?) {
        modelPop.removeAllItems()
        guard let rt = runtime else {
            let title = style == .newGraph ? PlanningAI.newGraphTitles(newGraphFirst).model : "Model: recommended"
            modelPop.addItem(withTitle: title)
            modelPop.lastItem?.representedObject = nil
            modelPop.isEnabled = false
            PongTheme.stylePopUp(modelPop)
            return
        }
        let list = catalog.models[rt] ?? []
        let lead = catalog.lead(for: rt)
        modelPop.isEnabled = !list.isEmpty
        if list.isEmpty {
            modelPop.addItem(withTitle: "Model: its own setting")
            modelPop.lastItem?.representedObject = nil
        }
        for m in list {
            modelPop.addItem(withTitle: catalog.modelLabel(rt, m) + (m == lead ? " (recommended)" : ""))
            modelPop.lastItem?.representedObject = m
        }
        let want = [prefer ?? "", lead, catalog.defaults[rt] ?? ""].first { !$0.isEmpty && list.contains($0) }
        if let w = want, let i = list.firstIndex(of: w) { modelPop.selectItem(at: i) }
        PongTheme.stylePopUp(modelPop)
    }

    @objc private func aiChanged() {
        fillModels(prefer: nil)
        PongTheme.stylePopUp(aiPop)
        showTitlesOnHover()
        onChange?(runtime, model)
    }

    @objc private func modelChanged() {
        PongTheme.stylePopUpItemTitles(modelPop)
        showTitlesOnHover()
        onChange?(runtime, model)
    }
}

// MARK: - The rows, built from the model

enum SetupRows {
    private static func button(_ title: String, _ style: PongButton.Style = .secondary,
                               _ fn: @escaping () -> Void) -> PongButton {
        let b = PongButton(title: title, style: style)
        b.onPress = fn
        return b
    }

    private static func toggle(_ on: Bool, label: String, enabled: Bool = true, row keep: inout [AnyObject],
                               _ fn: @escaping (Bool) -> Void) -> NSSwitch {
        let s = NSSwitch()
        s.state = on ? .on : .off
        s.isEnabled = enabled
        s.setAccessibilityLabel(label)
        let box = ClosureBox { [weak s] in fn(s?.state == .on) }
        keep.append(box)
        s.target = box
        s.action = #selector(ClosureBox.fire)
        return s
    }

    private static func checking(_ what: String) -> SetupRowView {
        SetupRowView(mark: .none, title: "Checking \(what)…", line: "")
    }

    // MARK: Is this Mac ready?

    /// The app can run its own engine (the copy it carries, or the one it put in the state
    /// folder), so its pages load even before the pong command is there.
    static var appHasEngine: Bool {
        let fm = FileManager.default
        if let res = Bundle.main.resourcePath, fm.fileExists(atPath: res + "/python/pong/cli/main.py") { return true }
        return fm.fileExists(atPath: Pong.stateDir + "/lib/pong/cli/main.py")
    }

    /// What doesn't work yet, for the line under the card: "no AI can start", ….
    static func macConsequences(_ d: DoctorReport?, _ m: MacChecks) -> [String] {
        MacReadiness.consequences(d, m, appHasEngine: appHasEngine)
    }

    /// What still needs fixing, by name: "tmux", "the graph runner".
    static func macGaps(_ d: DoctorReport?, _ m: MacChecks) -> [String] {
        MacReadiness.gaps(d, m)
    }

    static func macRows(host: SetupHost?) -> [SetupRowView] {
        let model = SetupModel.shared
        guard let d = model.doctor else { return [checking("this Mac")] }
        let m = model.mac
        var rows: [SetupRowView] = []

        if d.python.ok {
            let v = d.python.version.isEmpty ? "" : " · Python \(d.python.version)"
            rows.append(SetupRowView(mark: .ok, title: "Python", line: "Ready\(v)."))
        } else {
            rows.append(SetupRowView(mark: .needsYou, title: "Python",
                                     line: "Missing: CyberPong's engine runs on it. Apple's command line tools include it; installing takes a few minutes.",
                                     controls: [button("Install the tools") { SetupActions.installCommandLineTools() }]))
        }

        if d.tmux.ok {
            rows.append(SetupRowView(mark: .ok, title: "tmux", line: "Ready: it runs each AI in its own terminal."))
        } else if d.brew.ok {
            rows.append(SetupRowView(mark: .needsYou, title: "tmux",
                                     line: "Missing: no AI can start without it. Install runs “brew install tmux” in a Terminal window you can watch.",
                                     controls: [button("Install") { SetupActions.installTmux(brew: true) }]))
        } else {
            rows.append(SetupRowView(mark: .needsYou, title: "tmux",
                                     line: "Missing: no AI can start without it. It installs with Homebrew: get Homebrew from brew.sh first (one line to paste into Terminal), then come back here.",
                                     controls: [button("Open brew.sh") { SetupActions.installTmux(brew: false) }]))
        }

        if d.launcher.ok && d.engine.ok {
            let v = d.engine.version.isEmpty ? "" : " · engine \(d.engine.version)"
            rows.append(SetupRowView(mark: .ok, title: "The pong command", line: "Ready\(v)."))
        } else {
            // the person's own link whose file is gone is theirs to mend: Fix leaves it alone
            let ownLink = EngineInstall.launcherState(home: NSHomeDirectory()) == .danglingLink
            let line = ownLink
                ? "Your own ~/bin/pong link points to a file that isn't there, so your AIs can't report back. CyberPong leaves your link alone: reconnect its folder, or remove the link and press Fix."
                : MacReadiness.launcherLine(appHasEngine: appHasEngine)
            rows.append(SetupRowView(mark: .needsYou, title: "The pong command", line: line,
                                     controls: [button("Fix") { SetupActions.fixPongCommand() }]))
        }

        if d.runner.ok {
            rows.append(SetupRowView(mark: .ok, title: "Graph runner",
                                     line: "On: it moves graphs from step to step, even with this window closed."))
        } else {
            let line: String
            if d.runner.installed && d.runner.running == nil {
                line = "Can't tell whether it's running. Without it, graphs stop after their first step. Turn on starts it."
            } else if d.runner.installed {
                line = "Installed but not running: graphs stop after their first step. Turn on starts it."
            } else {
                line = "Off: graphs stop after their first step. Turn on starts it now and whenever you log in."
            }
            rows.append(SetupRowView(mark: .needsYou, title: "Graph runner", line: line,
                                     controls: [button("Turn on") { SetupActions.installRunner() }]))
        }

        if m.accessibility {
            rows.append(SetupRowView(mark: .ok, title: "Accessibility", line: "Allowed: CyberPong can arrange your terminal windows."))
        } else {
            rows.append(SetupRowView(mark: .needsYou, title: "Accessibility",
                                     line: "Not allowed: CyberPong can't arrange your terminal windows. Allow opens System Settings: switch CyberPong on there.",
                                     controls: [button("Allow…") { SetupActions.allowAccessibility() }]))
        }

        switch m.automation {
        case .allowed:
            rows.append(SetupRowView(mark: .ok, title: "Automation (Terminal)", line: "Allowed: CyberPong can open your teams' Terminal windows."))
        case .denied:
            rows.append(SetupRowView(mark: .needsYou, title: "Automation (Terminal)",
                                     line: "Not allowed: CyberPong can't open your teams' Terminal windows. Switch CyberPong on under Terminal in System Settings.",
                                     controls: [button("Open System Settings") { SetupActions.askAutomation(.denied) }]))
        case .notAsked:
            rows.append(SetupRowView(mark: .needsYou, title: "Automation (Terminal)",
                                     line: "Not asked yet: macOS asks the first time CyberPong opens Terminal. Ask now opens Terminal so macOS can ask.",
                                     controls: [button("Ask now") { SetupActions.askAutomation(.notAsked) }]))
        case .unknown:
            // Terminal is closed and macOS has never answered here: nothing is known to be missing
            rows.append(SetupRowView(mark: .off, title: "Automation (Terminal)",
                                     line: "Checked while Terminal is open: macOS only answers then. Check now opens Terminal so macOS can answer, or ask you.",
                                     controls: [button("Check now") { SetupActions.askAutomation(.unknown) }]))
        }
        return rows
    }

    // MARK: Which AIs do you use?

    static func aiLine(_ ai: DoctorReport.AI, on: Bool, marked: Bool, signing: Bool) -> (SetupMark, String) {
        guard ai.installed else {
            let hint = ai.install.trimmingCharacters(in: .whitespaces)
            if DoctorReport.installIsCommand(hint) {
                return (.off, "Not installed. To install it, Copy this and paste it in Terminal: \(hint)")
            }
            // a sentence from the engine ("See Grok Build's install page"), not a command to copy
            let said = hint.isEmpty ? "See its install page" : hint
            return (.off, "Not installed. " + said + (said.hasSuffix(".") ? "" : "."))
        }
        var mark: SetupMark
        var line: String
        switch ai.signedIn {
        case .some(true):
            mark = .ok
            let plan = DoctorReport.planWords(ai.plan)
            line = "Signed in" + (plan.isEmpty ? "." : " · \(plan).")
        case .some(false):
            mark = .needsYou
            line = signing ? "Waiting for you to sign in in Terminal…" : "Installed · not signed in."
        case .none:
            mark = marked ? .ok : .needsYou
            line = signing ? "Sign in in Terminal, then press I'm signed in."
                : (marked ? "Installed · you said it's signed in."
                    : "Installed · CyberPong can't tell whether it's signed in. Sign in, then press I'm signed in.")
        }
        if !on {
            mark = .off
            line += " Off: CyberPong won't use it."
        }
        return (mark, line)
    }

    static func aiRows(host: SetupHost?) -> [SetupRowView] {
        let model = SetupModel.shared
        guard let d = model.doctor else { return [checking("your AIs")] }
        return d.ais.map { ai in
            let on = AppSettings.aiEnabled(ai.id)
            let marked = ProviderAuth.isMarkedReady(typeId: ai.id)
            let signing = model.signingIn.contains(ai.id)
            let (mark, line) = aiLine(ai, on: on, marked: marked, signing: signing)
            var keep: [AnyObject] = []
            var controls: [NSView] = []
            if !ai.installed {
                if DoctorReport.installIsCommand(ai.install) {
                    let cmd = ai.install.trimmingCharacters(in: .whitespaces)
                    controls.append(button("Copy") { SetupActions.copy(cmd) })
                }
            } else if ai.signedIn == true || (ai.signedIn == nil && marked) {
                controls.append(button("Switch account…", .quiet) { SetupActions.signIn(ai, host: host) })
            } else {
                controls.append(button("Sign in…") { SetupActions.signIn(ai, host: host) })
                if ai.signedIn == nil {
                    // the engine can't see this AI's sign-in: the person says so
                    controls.append(button("I'm signed in") { SetupActions.confirmSignedIn(ai, host: host) })
                }
            }
            let use = PongUI.label("Use", PongType.secondary, PongColor.textTertiary)
            use.frame = NSRect(x: 0, y: 0, width: ceil(use.intrinsicContentSize.width) + 4, height: 16)
            controls.append(use)
            controls.append(toggle(on && ai.installed, label: "Use \(ai.label)", enabled: ai.installed, row: &keep) { v in
                SetupActions.setEnabled(ai.id, v)
                host?.setupNeedsRender()
            })
            let row = SetupRowView(mark: mark, title: ai.label, line: line, controls: controls)
            row.retained = keep
            return row
        }
    }

    /// Why Continue waits on the AI step, or nil: at least one AI on and installed.
    static func aiBlocker() -> String? {
        guard let d = SetupModel.shared.doctor else { return "Checking which AIs are on this Mac…" }
        let installed = d.ais.filter(\.installed)
        if installed.isEmpty {
            let engine = d.ai("claude")?.install ?? ""
            let how = DoctorReport.installIsCommand(engine) ? engine : (DoctorReport.knownInstall["claude"] ?? "")
            return "Install an AI first: Claude Code is the one to start with" + (how.isEmpty ? "." : ". In Terminal: \(how)")
        }
        if !installed.contains(where: { AppSettings.aiEnabled($0.id) }) {
            return "Switch on at least one AI that's installed."
        }
        return nil
    }

    // MARK: Which AI plans your graphs?

    /// The engine adds the flag to Claude and Grok only (`groups.AUTO_PERMISSION_RUNTIMES`).
    static let permissionsLine = "Claude and Grok steps run without stopping, in their own “auto” mode, which still blocks risky actions. This doesn't change Codex or Hermes: they may still stop to ask. Off: each AI asks before using a tool, and graphs wait for you."

    static func architectRows(picker: ArchitectPicker, permissionsOn: Bool, host: SetupHost?,
                              onPermissions: @escaping (Bool) -> Void) -> [SetupRowView] {
        let model = SetupModel.shared
        picker.fill(catalog: model.catalog, doctor: model.doctor)
        // weak: the picker belongs to the host, which must be free to go when it closes
        picker.onChange = { [weak host] rt, m in
            AppSettings.setArchitect(runtime: rt, model: m)
            host?.setupNeedsRender()
        }
        let c = model.catalog
        let aiLine: String = {
            guard let c else { return "Reading which AIs and models this Mac has…" }
            if c.recRuntime.isEmpty { return "Signed-in AIs come first." }
            return "Recommended is CyberPong's own pick for planning. Signed-in AIs come first."
        }()
        var keep: [AnyObject] = []
        let rows = [
            SetupRowView(mark: .none, title: "AI", line: aiLine, controls: [picker.aiPop]),
            SetupRowView(mark: .none, title: "Model",
                         line: "Picking an AI picks the model CyberPong recommends for planning on it.",
                         controls: [picker.modelPop]),
            SetupRowView(mark: .none, title: "Let the AIs work without stopping to ask permission",
                         line: permissionsLine,
                         controls: [toggle(permissionsOn, label: "Let the AIs work without stopping to ask permission", row: &keep) { v in
                             onPermissions(v)
                         }]),
        ]
        rows[2].retained = keep
        rows[0].retained = [picker]
        return rows
    }

    /// The AI and model the planning chat will run on: "Claude Code · Fable 5" ("its AI" when
    /// nothing is known yet).
    static func architectPair() -> String {
        let c = SetupModel.shared.catalog ?? ModelCatalog()
        if let a = savedArchitectThatRuns() {
            return c.pair(a.runtime, a.model.isEmpty ? c.lead(for: a.runtime) : a.model)
        }
        return c.recRuntime.isEmpty ? "its AI" : c.pair(c.recRuntime, c.recModel)
    }

    /// The saved planning AI, unless the catalog says it can't run here (then the engine uses its
    /// recommendation, and so do these words).
    static func savedArchitectThatRuns() -> (runtime: String, model: String)? {
        guard let a = AppSettings.architect else { return nil }
        let m = SetupModel.shared
        guard let c = m.catalog else { return a }
        return ArchitectPicker.savedBlocker(c, m.doctor, a.runtime) == nil ? a : nil
    }

    /// "Claude Code · Fable 5" when one is saved, else "Recommended (…)"; says so when the saved
    /// one can't run here.
    static func architectWords() -> String {
        let pair = architectPair()
        if savedArchitectThatRuns() != nil { return pair }
        let rec = pair == "its AI" ? "Recommended" : "Recommended (\(pair))"
        if let a = AppSettings.architect, let c = SetupModel.shared.catalog,
           let why = ArchitectPicker.savedBlocker(c, SetupModel.shared.doctor, a.runtime) {
            return rec + ": your choice, \(c.label(a.runtime)), is \(why == "can't plan graphs" ? "unable to plan graphs" : why)"
        }
        return rec
    }

    // MARK: Limits and spending

    /// A small right-aligned number field (Settings › Notch panel uses it too); `commit` runs on Return
    /// or when the field is left.
    static func numberField(_ value: String, width: CGFloat, label: String, row keep: inout [AnyObject],
                            _ commit: @escaping (String) -> Void) -> SetupField {
        let f = SetupField(placeholder: label, value: value, width: width, height: 24)
        f.field.alignment = .right
        f.field.setAccessibilityLabel(label)
        f.onCommit = commit
        keep.append(f)
        return f
    }

    private static func money(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    static func limitsRows(host: SetupHost?) -> [SetupRowView] {
        let l = AppSettings.limits
        let keys = SetupModel.shared.keys
        var rows: [SetupRowView] = []

        var k1: [AnyObject] = []
        let r1 = SetupRowView(mark: .none, title: "Pause at Claude's 5-hour limit",
                              line: "When Claude says you've hit the 5-hour limit, running graphs pause and pick up again after the reset.",
                              controls: [toggle(l.rideOut5h, label: "Pause at Claude's 5-hour limit", row: &k1) { v in
                                  AppSettings.setLimit("ride_out_5h", v)
                              }])
        r1.retained = k1
        rows.append(r1)

        var k2: [AnyObject] = []
        let remembered = UserDefaults.standard.integer(forKey: "setup.weekStopPct")
        let pct = l.weekStopPct > 0 ? l.weekStopPct : (remembered > 0 ? remembered : 97)
        let pctField = numberField(String(pct), width: 44, label: "Weekly percent", row: &k2) { s in
            let v = Int(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) ?? pct
            let clamped = max(50, min(100, v))
            UserDefaults.standard.set(clamped, forKey: "setup.weekStopPct")
            if AppSettings.limits.weekStopPct > 0 { AppSettings.setLimit("week_stop_pct", clamped) }
            host?.setupNeedsRender()
        }
        let pctSign = PongUI.label("%", PongType.secondary, PongColor.textSecondary)
        pctSign.frame = NSRect(x: 0, y: 0, width: 12, height: 16)
        let r2 = SetupRowView(mark: .none, title: "Stop near the weekly limit",
                              line: "When this week's Claude use passes \(pct)%, running graphs pause until the reset or until you resume them.",
                              controls: [pctField, pctSign, toggle(l.weekStopPct > 0, label: "Stop near the weekly limit", row: &k2) { v in
                                  if v {
                                      let r = UserDefaults.standard.integer(forKey: "setup.weekStopPct")
                                      AppSettings.setLimit("week_stop_pct", r > 0 ? r : pct)
                                  } else {
                                      UserDefaults.standard.set(pct, forKey: "setup.weekStopPct")
                                      AppSettings.setLimit("week_stop_pct", 0)
                                  }
                              }])
        r2.retained = k2
        rows.append(r2)

        // with Claude's two limits, high up: the person asked for it to be easy to see
        rows.append(creditsRow())

        var k3: [AnyObject] = []
        let r3 = SetupRowView(mark: .none, title: "Helper AI for questions and names",
                              line: "Claude Haiku turns questions into plain words, explains them, and names your chats. Uses a little of your Claude allowance.",
                              controls: [toggle(l.helperAI, label: "Helper AI for questions and names", row: &k3) { v in
                                  AppSettings.setLimit("helper_ai", v)
                              }])
        r3.retained = k3
        rows.append(r3)

        var k4: [AnyObject] = []
        let r4 = SetupRowView(mark: .none, title: "Jev second opinions",
                              line: "Jev scores the work beside the reviewers. Needs a Jev key" + (keys.jev.set ? "." : ": none yet, add one under Keys."),
                              controls: [toggle(l.jev, label: "Jev second opinions", row: &k4) { v in
                                  AppSettings.setLimit("jev", v)
                              }])
        r4.retained = k4
        rows.append(r4)

        var k5: [AnyObject] = []
        let usd = l.perplexityDailyUSD
        let usdSign = PongUI.label("$", PongType.secondary, PongColor.textSecondary)
        usdSign.alignment = .right
        usdSign.frame = NSRect(x: 0, y: 0, width: 10, height: 16)
        let usdField = numberField(money(usd), width: 48, label: "Perplexity dollars a day", row: &k5) { s in
            let v = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")) ?? usd
            let clamped = max(0, min(500, v))
            AppSettings.setLimit("perplexity_daily_usd", clamped == clamped.rounded() ? Int(clamped) as Any : clamped as Any)
            host?.setupNeedsRender()
        }
        let r5 = SetupRowView(mark: .none, title: "Perplexity web research",
                              line: "Research steps search the web through Perplexity, up to $\(money(usd)) a day. Needs a Perplexity key"
                                + (keys.perplexity.set ? "." : ": none yet, add one under Keys."),
                              controls: [usdSign, usdField, toggle(l.perplexity, label: "Perplexity web research", row: &k5) { v in
                                  AppSettings.setLimit("perplexity", v)
                              }])
        r5.retained = k5
        rows.append(r5)
        return rows
    }

    /// Claude's own usage credits: shown, never changed.
    static func creditsRow() -> SetupRowView {
        let state: String
        switch SetupModel.shared.credits {
        case "on": state = "on"
        case "off": state = "off"
        default: state = "not known yet"
        }
        return SetupRowView(mark: .none, title: "Claude's usage credits",
                            line: "Claude's own “usage credits” (paid extra use at a limit) are \(state). Change them in your Claude account: CyberPong never turns them on.",
                            controls: [button("Open Claude usage settings") { SetupActions.open("https://claude.ai/settings/usage") }])
    }

    // MARK: Keys

    static func keyRows(host: SetupHost?) -> [SetupRowView] {
        let model = SetupModel.shared
        let keys = model.keys
        return SetupKeys.Name.allCases.map { n in
            let k = keys[n]
            // where a key comes from is the row's one link, "Get a key…" (its site in the tooltip)
            let about = n == .jev
                ? "Jev, from TypeSafe, gives second opinions on the work."
                : "Perplexity lets research steps search the web."
            let url = n == .jev ? "https://typesafe.ai" : "https://www.perplexity.ai/settings/api"
            let getKey = button("Get a key…", .quiet) { SetupActions.open(url) }
            getKey.toolTip = n == .jev ? "Opens typesafe.ai, where Jev keys come from" : "Opens perplexity.ai/settings/api, where Perplexity keys come from"
            let row = SetupRowView(mark: k.set ? .ok : .off, title: n.title,
                                   line: "\(KeysStatus.words(k)). \(about)",
                                   controls: [getKey])
            // the field, its buttons and the last result, under the text
            let strip = KeyStrip()
            let field = SetupField(secure: true, placeholder: "Paste the \(n == .jev ? "Jev" : "Perplexity") key", value: model.keyDrafts[n] ?? "",
                                   width: 200)
            field.onChange = { s in model.keyDrafts[n] = s.isEmpty ? nil : s }
            field.onReturn = { s in SetupActions.saveKey(n, s, host: host) }
            strip.addSubview(field)
            var buttons: [PongButton] = [button("Save") { [weak field] in
                SetupActions.saveKey(n, field?.field.stringValue ?? "", host: host)
            }]
            if n == .jev {
                let t = button("Test") { SetupActions.testJev(host: host) }
                t.isEnabled = k.set && !model.keyTestRunning
                buttons.append(t)
            }
            if SetupKeys.hasSettingsFile(n) {
                buttons.append(button("Remove", .destructive) { SetupActions.removeKey(n, host: host) })
            }
            buttons.forEach { strip.addSubview($0) }
            let note = model.keyNotes[n] ?? ""
            // a note can run to two lines (a key Remove couldn't take away): it wraps, never cut off
            let noteLabel = PongUI.label(note, PongType.secondary, PongColor.textSecondary, lines: 3)
            strip.addSubview(noteLabel)
            strip.field = field
            strip.buttons = buttons
            strip.note = noteLabel
            row.below = strip
            row.belowHeight = note.isEmpty ? 28 : 50
            row.belowHeightFor = { [weak strip] w in strip?.height(width: w) ?? 28 }
            return row
        }
    }
}

/// A key's field, its buttons on the right, and the last result under them.
final class KeyStrip: NSView {
    var field: SetupField?
    var buttons: [PongButton] = []
    var note: NSTextField?

    override var isFlipped: Bool { true }

    /// The note's height at `width`: as many lines as it needs, three at most.
    private func noteHeight(_ width: CGFloat) -> CGFloat {
        guard let n = note, !n.stringValue.isEmpty else { return 0 }
        // measured 4 pt narrower than the label, as the rows' lines are (its cell keeps 2 pt each side)
        let r = n.attributedStringValue.boundingRect(with: NSSize(width: max(40, width - 4), height: 200),
                                                     options: [.usesLineFragmentOrigin])
        return min(50, max(16, ceil(r.height) + 2))
    }

    /// The field and buttons, then the note under them when there is one.
    func height(width: CGFloat) -> CGFloat {
        let nh = noteHeight(width)
        return nh > 0 ? 34 + nh : 28
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        var x = newSize.width
        for b in buttons.reversed() {
            let w = b.intrinsicContentSize.width
            x -= w
            b.frame = NSRect(x: x, y: 0, width: w, height: 28)
            x -= 8
        }
        field?.frame = NSRect(x: 0, y: 0, width: max(120, x), height: 28)
        note?.frame = NSRect(x: 0, y: 34, width: newSize.width, height: noteHeight(newSize.width))
    }
}
