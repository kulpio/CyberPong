import AppKit
import CoreText

/// CyberPong's look (1.9, "Sodium & Neon"). The values live in `PongTokens.swift`;
/// these older names stay so every screen keeps compiling while it moves over.
/// Night only: there is no light mode.
enum PongTheme {
    // MARK: - Product identity (public name)
    /// Product name — always CyberPong in UI / About / menus.
    static let productName = "CyberPong"
    /// Short tagline for About / tooltips
    static let productTagline = "Local agent mission control"

    /// Old accent name. It meant "running" on the Graphs page, so it is the live cyan now.
    static var lime: NSColor { PongColor.live }
    static var limeSoft: NSColor { PongColor.tintLive }
    enum Appearance: String { case dark, light }

    static let appearanceDidChange = Notification.Name("PongThemeAppearanceDidChange")

    /// Always Night (decided 29 Sep 2026: dark only).
    static var appearance: Appearance {
        get { .dark }
        set { }
    }

    static func toggleAppearance() { }

    // MARK: - Launch / wizard chrome

    /// Wizards and sheets used their own always-dark palette; it is the Night palette now.
    enum Launch {
        static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }
        static let bg = PongColor.base
        static let bgElevated = PongColor.raised
        static let bgHover = PongColor.overlay
        static let bgInput = PongColor.field
        static let textPrimary = PongColor.textPrimary
        static let textSecondary = PongColor.textSecondary
        static let textTertiary = PongColor.textTertiary
        static let line = PongColor.control
        static let lineSoft = PongColor.hairline
        static let ink = PongColor.ink
        /// Was the lime primary; the primary button is ink now.
        static let lime = PongColor.ink
        static let blue = PongColor.live
        static let magenta = PongColor.architect

        static func styleWindow(_ win: NSWindow) {
            win.appearance = appearance
            win.backgroundColor = bg
        }
    }

    // MARK: - Surfaces

    static var bg: NSColor { PongColor.base }
    static var bgElevated: NSColor { PongColor.raised }
    static var bgHover: NSColor { PongColor.overlay }
    static var bgInput: NSColor { PongColor.field }
    static var bgFooter: NSColor { PongColor.base }
    static var bgMetric: NSColor { PongColor.raised }
    static var bgRail: NSColor { PongColor.frame }
    static var bgChrome: NSColor { PongColor.frame }

    static var spaceGlow: NSColor { PongColor.hover }
    static var ink: NSColor { PongColor.textPrimary }
    static var gridDot: NSColor { PongColor.mark.withAlphaComponent(0.55) }
    static var gridDotMajor: NSColor { PongColor.mark }

    // MARK: - Type colours

    static var textPrimary: NSColor { PongColor.textPrimary }
    static var textSecondary: NSColor { PongColor.textSecondary }
    static var textTertiary: NSColor { PongColor.textTertiary }
    static var textMono: NSColor { PongColor.textSecondary }

    // MARK: - Lines

    /// Control edges and graph edges (≥3:1).
    static var line: NSColor { PongColor.control }
    /// Dividers.
    static var lineSoft: NSColor { PongColor.hairline }
    static var lineStrong: NSColor { PongColor.textSecondary }

    static var border: NSColor { PongColor.hairline }
    static var borderStrong: NSColor { PongColor.control }
    static var borderAccent: NSColor { PongColor.textSecondary }

    // MARK: - Signals (old role names → one colour, one job)

    /// Was the orchestrator's blue: machines at work.
    static var blue: NSColor { PongColor.live }
    static var blueSoft: NSColor { PongColor.tintLive }
    static var blueGlow: NSColor { PongColor.live.withAlphaComponent(0.35) }
    static var cyanBright: NSColor { PongColor.live }

    /// Magenta belongs to the architect.
    static var magenta: NSColor { PongColor.architect }
    static var magentaSoft: NSColor { PongColor.tintArchitect }

    /// Violet is retired: sub-agents are neutral.
    static var violet: NSColor { PongColor.textSecondary }
    static var violetSoft: NSColor { PongColor.raised }

    /// Needs you, only.
    static var amber: NSColor { PongColor.you }
    static var amberSoft: NSColor { PongColor.tintYou }
    static var amberInk: NSColor { PongColor.onInk }
    static var orange: NSColor { amber }
    static var orangeSoft: NSColor { amberSoft }

    /// Was the lime primary action: the primary is ink ("Wallace white") now.
    static var limeAction: NSColor { PongColor.ink }

    static var mapGrid: NSColor { PongColor.mark }
    static var mapNodeBody: NSColor { PongColor.base }

    static var accent: NSColor { PongColor.textSecondary }
    static var accentSoft: NSColor { PongColor.hairline }
    static var accentGlow: NSColor { PongColor.live.withAlphaComponent(0.35) }
    static let accentInk = PongColor.onInk
    static var live: NSColor { PongColor.live }
    static var liveSoft: NSColor { PongColor.tintLive }
    static var warn: NSColor { PongColor.you }
    static var warnSoft: NSColor { PongColor.tintYou }
    static var danger: NSColor { PongColor.fail }
    static var idle: NSColor { PongColor.textTertiary }
    static var idleSoft: NSColor { PongColor.raised }

    static let tabSelected = PongColor.overlay
    static let tabIdle = NSColor.clear

    static let radiusCard: CGFloat = PongRadius.card
    static let radiusPill: CGFloat = PongRadius.control
    static let radiusBtn: CGFloat = PongRadius.control
    static let radiusRail: CGFloat = PongRadius.control
    static let hairline: CGFloat = 1

    /// A pop-up button in our colours (never the Mac's accent).
    static func stylePopUp(_ pop: NSPopUpButton) {
        pop.bezelStyle = .rounded
        pop.isBordered = true
        pop.wantsLayer = true
        pop.layer?.cornerRadius = PongRadius.control
        pop.layer?.backgroundColor = PongColor.secondaryFill.cgColor
        pop.layer?.borderWidth = hairline
        pop.layer?.borderColor = PongColor.control.cgColor
        pop.font = PongType.control
        pop.contentTintColor = textPrimary
        pop.appearance = NSAppearance(named: .darkAqua)
        if let cell = pop.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .arrowAtBottom
            cell.backgroundStyle = .emphasized
        }
        stylePopUpItemTitles(pop)
    }

    static func stylePopUpItemTitles(_ pop: NSPopUpButton) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: textPrimary,
            .font: PongType.control,
        ]
        for item in pop.itemArray {
            let t = item.title
            guard !t.isEmpty else { continue }
            item.attributedTitle = NSAttributedString(string: t, attributes: attrs)
        }
        if let sel = pop.selectedItem {
            let t = sel.title
            if !t.isEmpty {
                pop.attributedTitle = NSAttributedString(string: t, attributes: attrs)
            }
        }
    }

    /// A segment of a segmented control: `bg.overlay` and Semibold when selected.
    static func styleTopTab(_ b: NSButton, selected: Bool) {
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = PongRadius.control
        b.layer?.backgroundColor = (selected ? PongColor.overlay : NSColor.clear).cgColor
        b.layer?.borderWidth = 0
        let title = b.attributedTitle.string.isEmpty ? b.title : b.attributedTitle.string
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: selected ? textPrimary : textSecondary,
            .font: font(13, weight: selected ? .semibold : .medium),
        ])
    }

    enum SystemSignal {
        case idle
        case orchestratorWorking
        case humanNeeded
    }

    // MARK: - Fonts (SF for the UI, IBM Plex Mono for data and terminals)

    private static var fontsRegistered = false

    /// Register bundled TTFs once at launch (resources/fonts/).
    static func registerBundledFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let names = ["IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold", "IBMPlexMono-Bold"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "fonts")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func weightName(_ w: NSFont.Weight) -> String {
        if w >= .bold { return "Bold" }
        if w >= .semibold { return "SemiBold" }
        if w >= .medium { return "Medium" }
        return "Regular"
    }

    /// UI text: the system font, never under 11 pt.
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        PongType.sf(size, weight)
    }

    /// Data, paths and terminals: IBM Plex Mono, never under 11 pt.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
        registerBundledFonts()
        let size = max(PongType.floor, size)
        let w = weightName(weight)
        for name in ["IBMPlexMono-\(w)", "IBM Plex Mono \(w)", "IBMPlexMono-Regular", "IBM Plex Mono"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        if let f = NSFont(name: "SF Mono", size: size) { return f }
        if let f = NSFont(name: "Menlo", size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Nav / section labels
    static func labelFont(_ size: CGFloat = 11) -> NSFont {
        font(size, weight: .medium)
    }

    // MARK: - Assets

    static func texture(named: String) -> NSImage? {
        if let img = NSImage(named: named) { return img }
        if let path = Bundle.main.path(forResource: named, ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
    static var texConductor: NSImage? { texture(named: "tex-conductor") }
    static var texWorker: NSImage? { texture(named: "tex-worker") }
    static var texCanvas: NSImage? { texture(named: "tex-canvas") }

    // MARK: - Apply

    /// Cards are borderless raised fills (radius 10); `accentBorder` keeps a control edge.
    static func applyCard(_ v: NSView, elevated: Bool = true, accentBorder: Bool = false) {
        v.wantsLayer = true
        v.layer?.backgroundColor = (elevated ? PongColor.raised : PongColor.field).cgColor
        v.layer?.cornerRadius = PongRadius.card
        v.layer?.borderWidth = accentBorder ? hairline : 0
        v.layer?.borderColor = accentBorder ? PongColor.control.cgColor : nil
        v.layer?.masksToBounds = true
    }

    static func applyMetricCard(_ v: NSView) {
        applyCard(v, elevated: true)
    }

    /// Level 2: popovers, toasts, overlays. Overlay fill, soft shadow, a 1 pt top edge.
    static func applyFloating(_ v: NSView) {
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.overlay.cgColor
        v.layer?.cornerRadius = PongRadius.card
        v.layer?.borderWidth = hairline
        v.layer?.borderColor = PongColor.hairline.cgColor
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.5
        v.layer?.shadowRadius = 12
        v.layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    static func drawCornerBrackets(in rect: NSRect, color: NSColor, arm: CGFloat = 12, line: CGFloat = 1) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = line
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + arm))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + arm, y: rect.minY))
        path.move(to: NSPoint(x: rect.maxX - arm, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + arm))
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY - arm))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + arm, y: rect.maxY))
        path.move(to: NSPoint(x: rect.maxX - arm, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - arm))
        path.stroke()
    }

    /// Concentric selection rings (Lattice map marker language)
    static func drawRings(center: NSPoint, radii: [CGFloat], color: NSColor) {
        for (i, r) in radii.enumerated() {
            let a = 0.35 - CGFloat(i) * 0.1
            color.withAlphaComponent(max(0.08, a)).setStroke()
            let p = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            p.lineWidth = 1
            p.stroke()
        }
    }

    static func statusKind(_ raw: String) -> (label: String, color: NSColor, soft: NSColor) {
        let t = raw.lowercased()
        if t.contains("human") || t.contains("takeover") || t.contains("ask") || t.contains("wait") {
            return ("HUMAN", amber, amberSoft)
        }
        if t.contains("busy") || t.contains("running") || t.contains("live") || t.contains("notified") || t.contains("active") {
            return ("LIVE", textPrimary, blueSoft)
        }
        if t.contains("hide") || t.contains("hidden") {
            return ("STOW", textSecondary, idleSoft)
        }
        if t.contains("fail") || t.contains("error") {
            return ("FAIL", danger, danger.withAlphaComponent(0.15))
        }
        if t.contains("job") {
            return ("JOB", blue, blueSoft)
        }
        return ("IDLE", idle, idleSoft)
    }

    /// Soft radial glow under a colored menu-bar dot (body stays monochrome).
    private static func fillDotGlow(at c: NSPoint, coreR: CGFloat, color: NSColor, intensity: CGFloat) {
        guard intensity > 0.01 else { return }
        // Outer halo → mid bloom → near core (only the dots glow)
        let rings: [(scale: CGFloat, alpha: CGFloat)] = [
            (3.4, 0.10 * intensity),
            (2.4, 0.22 * intensity),
            (1.7, 0.40 * intensity),
        ]
        for ring in rings {
            let gr = coreR * ring.scale
            color.withAlphaComponent(min(0.95, ring.alpha)).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)).fill()
        }
    }

    /// App mark for menu bar. Prefers brand package state assets
    /// (`resources/brand/pong/macos-menubar/state/`), then drawn flash fallback.
    static func menuIcon(signal: SystemSignal, size: CGFloat = 18, phase: CGFloat = 1) -> NSImage {
        // Brand state icons — active / idle / empty (see brand/README.md)
        if signal == .idle, PairState.listPairs().isEmpty {
            if let empty = loadBundledImage(named: "pong-empty-36")
                ?? loadBundledImage(named: "pong-empty-18") {
                let out = scaledLogo(empty, size: size)
                out.isTemplate = false
                return out
            }
        }
        let brandBase: String = {
            switch signal {
            case .idle: return "pong-idle"
            case .orchestratorWorking, .humanNeeded: return "pong-active"
            }
        }()
        for suffix in ["-36", "-44", "-18", "-64"] {
            if let raw = loadBundledImage(named: brandBase + suffix) {
                var out = scaledLogo(raw, size: size)
                out.isTemplate = false
                if signal == .orchestratorWorking || signal == .humanNeeded {
                    let a = 0.82 + 0.18 * phase
                    if let pulsed = out.withAlpha(a) { out = pulsed }
                }
                return out
            }
        }

        // Fallback: drawn flash (legacy geometry)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = min(rect.width, rect.height)
            let body = NSColor(calibratedWhite: 0.86, alpha: 1)
            let bottomDot: NSColor
            let topDot: NSColor
            let glowI: CGFloat
            switch signal {
            case .idle:
                bottomDot = blue.withAlphaComponent(0.85)
                topDot = magenta.withAlphaComponent(0.85)
                glowI = 0.35
            case .orchestratorWorking:
                bottomDot = blue
                topDot = magenta
                glowI = 0.55 + 0.45 * phase
            case .humanNeeded:
                bottomDot = blue
                topDot = amber
                glowI = 0.6 + 0.4 * phase
            }
            let r = s * 0.105
            let inset = s * 0.14
            let pBottom = NSPoint(x: rect.minX + inset + r, y: rect.minY + inset + r * 0.85)
            let pTop = NSPoint(x: rect.maxX - inset - r, y: rect.maxY - inset - r * 0.85)
            fillDotGlow(at: pBottom, coreR: r, color: bottomDot, intensity: glowI)
            fillDotGlow(at: pTop, coreR: r, color: topDot, intensity: glowI)
            let cx = rect.midX, cy = rect.midY, u = s * 0.48
            let logo = NSBezierPath()
            logo.move(to: NSPoint(x: cx + u * 0.28, y: cy + u * 0.46))
            logo.line(to: NSPoint(x: cx - u * 0.18, y: cy + u * 0.10))
            logo.line(to: NSPoint(x: cx - u * 0.02, y: cy + u * 0.00))
            logo.line(to: NSPoint(x: cx - u * 0.28, y: cy - u * 0.46))
            logo.line(to: NSPoint(x: cx + u * 0.18, y: cy - u * 0.10))
            logo.line(to: NSPoint(x: cx + u * 0.02, y: cy - u * 0.00))
            logo.close()
            body.setFill()
            logo.fill()
            bottomDot.setFill()
            NSBezierPath(ovalIn: NSRect(x: pBottom.x - r, y: pBottom.y - r, width: r * 2, height: r * 2)).fill()
            topDot.setFill()
            NSBezierPath(ovalIn: NSRect(x: pTop.x - r, y: pTop.y - r, width: r * 2, height: r * 2)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func loadBundledImage(named name: String) -> NSImage? {
        if let img = NSImage(named: name) { return img }
        let roots = [
            Bundle.main.resourcePath,
            Bundle.main.resourcePath.map { $0 + "/brand/pong/macos-menubar/state" },
        ].compactMap { $0 }
        for root in roots {
            let p = "\(root)/\(name).png"
            if let img = NSImage(contentsOfFile: p) { return img }
        }
        return nil
    }

    /// Flash mark (square) — menubar / fallback when wordmark missing.
    static func logoImage(size: CGFloat = 22) -> NSImage {
        let names = [
            "logo-accent-256", "logo-accent", "logo-accent-128",
            "pong-idle-64", "pong-active-64", "pong-idle-44",
            "logo", "pong-mark-color",
        ]
        for n in names {
            if let img = loadLogoCandidate(named: n), !isSolidWhiteTile(img) {
                return scaledLogo(img, size: size)
            }
        }
        return menuIcon(signal: .idle, size: size, phase: 0.35)
    }

    /// CyberPong wordmark for panel title bar.
    /// Loads the glow **PNG only** (never SVG). Does **not** re-draw/re-export the asset —
    /// only sets the layout size; NSImageView scales the original 3048×720 bitmap.
    static func wordmarkImage(height: CGFloat = 38) -> NSImage {
        let name = "cyberpong-wordmark-dark"
        if let img = loadWordmarkPNG(named: name) {
            // Keep original bitmap representations (glow intact). Point size is for layout only.
            let aspect = img.size.width / max(img.size.height, 1)
            let w = height * max(aspect, 4.23)
            let out = img.copy() as? NSImage ?? img
            out.size = NSSize(width: w, height: height)
            out.isTemplate = false
            return out
        }
        // Fallback text only if PNG missing
        let w = height * 5.2
        let out = NSImage(size: NSSize(width: w, height: height))
        out.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: height)).fill()
        let s = productName as NSString
        let attr: [NSAttributedString.Key: Any] = [
            .font: font(height * 0.72, weight: .bold),
            .foregroundColor: textPrimary,
        ]
        let sz = s.size(withAttributes: attr)
        s.draw(at: NSPoint(x: 0, y: (height - sz.height) / 2), withAttributes: attr)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    /// Glow wordmarks: **PNG only** — never SVG (flat, no neon glow).
    private static func loadWordmarkPNG(named n: String) -> NSImage? {
        // Prefer explicit .png path so we never pick the companion .svg
        if let path = Bundle.main.path(forResource: n, ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            return img
        }
        let roots = [
            Bundle.main.resourcePath,
            Bundle.main.resourcePath.map { $0 + "/brand/cyberpong/wordmark" },
        ].compactMap { $0 }
        for root in roots {
            let p = "\(root)/\(n).png"
            if FileManager.default.fileExists(atPath: p),
               let img = NSImage(contentsOfFile: p) {
                return img
            }
        }
        return nil
    }

    private static func loadLogoCandidate(named n: String) -> NSImage? {
        if let img = NSImage(named: n) { return img }
        if let path = Bundle.main.path(forResource: n, ofType: "png"),
           let img = NSImage(contentsOfFile: path) { return img }
        let roots = [
            Bundle.main.resourcePath,
            Bundle.main.resourcePath.map { $0 + "/brand/cyberpong/wordmark" },
            Bundle.main.resourcePath.map { $0 + "/brand/pong/logo" },
            Bundle.main.resourcePath.map { $0 + "/brand/pong/macos-menubar/state" },
        ].compactMap { $0 }
        for root in roots {
            for ext in ["png", "svg"] {
                let p = "\(root)/\(n).\(ext)"
                if let img = NSImage(contentsOfFile: p) { return img }
            }
        }
        return nil
    }

    /// True when the bitmap is basically a filled white rectangle (broken export).
    private static func isSolidWhiteTile(_ img: NSImage) -> Bool {
        guard let rep = img.bestRepresentation(for: NSRect(x: 0, y: 0, width: 16, height: 16),
                                               context: nil, hints: nil) as? NSBitmapImageRep
                ?? {
                    guard let tiff = img.tiffRepresentation,
                          let r = NSBitmapImageRep(data: tiff) else { return nil }
                    return r
                }()
        else { return false }
        let w = min(rep.pixelsWide, 32)
        let h = min(rep.pixelsHigh, 32)
        guard w > 2, h > 2 else { return false }
        var opaque = 0
        var whiteish = 0
        let stepX = max(1, w / 8)
        let stepY = max(1, h / 8)
        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.usingColorSpace(.genericRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                if a < 0.08 { continue }
                opaque += 1
                if r > 0.92 && g > 0.92 && b > 0.92 { whiteish += 1 }
            }
        }
        // Nearly every sampled opaque pixel is white → solid white tile
        return opaque >= 8 && whiteish * 10 >= opaque * 9
    }

    private static func scaledLogo(_ img: NSImage, size: CGFloat, width: CGFloat? = nil) -> NSImage {
        let w = width ?? size
        let h = size
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }

    /// Menu-bar signal from real work only — not “a team exists”.
    /// active = notified/running jobs or busy workers · human = takeover · idle otherwise.
    static func signalFromState() -> SystemSignal {
        let pairs = PairState.listPairs()
        if pairs.isEmpty { return .idle }
        let snap = Pong.loadJSON(Pong.stateDir + "/snapshot.json")
        guard let teams = snap["teams"] as? [[String: Any]], !teams.isEmpty else {
            return .idle
        }
        var anyLiveWork = false
        for t in teams {
            for w in (t["workers"] as? [[String: Any]]) ?? [] {
                let h = ((w["status_hint"] as? String) ?? "").lowercased()
                if h.contains("human") || h.contains("takeover") { return .humanNeeded }
                if h.contains("busy") || h.contains("running") { anyLiveWork = true }
            }
            for j in ((t["jobs"] as? [String: Any])?["open"] as? [[String: Any]]) ?? [] {
                let st = ((j["status"] as? String) ?? "").lowercased()
                if st.contains("human") || st == "human_takeover" { return .humanNeeded }
                // queued alone is not “working” — only once dispatched or running
                if st == "notified" || st == "running" { anyLiveWork = true }
            }
        }
        return anyLiveWork ? .orchestratorWorking : .idle
    }
}

// MARK: - Neon seat accent catalog (rename / primitive / Terminal)

/// Fixed neon swatches only — no free color well. Each swatch is a full
/// `TerminalTheme.Colors` triple (dark-terminal friendly). Highlight = map glow.
enum PongNeonCatalog {
    struct Swatch {
        let id: String
        let name: String
        let colors: TerminalTheme.Colors
        var highlightNS: NSColor {
            let h = colors.highlight
            return NSColor(calibratedRed: h.0, green: h.1, blue: h.2, alpha: 1)
        }
    }

    /// ~10 product neon accents
    static let all: [Swatch] = [
        Swatch(id: "cyan", name: "Electric cyan", colors: TerminalTheme.Colors(
            bg: (0.04, 0.08, 0.12), text: (0.85, 0.96, 1.0), highlight: (0.05, 0.92, 1.0))),
        Swatch(id: "magenta", name: "Hot magenta", colors: TerminalTheme.Colors(
            bg: (0.10, 0.04, 0.09), text: (1.0, 0.88, 0.96), highlight: (1.0, 0.25, 0.78))),
        Swatch(id: "lime", name: "Acid lime", colors: TerminalTheme.Colors(
            bg: (0.06, 0.09, 0.04), text: (0.92, 0.98, 0.80), highlight: (0.78, 0.95, 0.20))),
        Swatch(id: "violet", name: "Neon violet", colors: TerminalTheme.Colors(
            bg: (0.07, 0.05, 0.12), text: (0.92, 0.88, 1.0), highlight: (0.72, 0.42, 1.0))),
        Swatch(id: "plasma", name: "Plasma blue", colors: TerminalTheme.Colors(
            bg: (0.04, 0.06, 0.14), text: (0.82, 0.90, 1.0), highlight: (0.25, 0.55, 1.0))),
        Swatch(id: "amber", name: "Amber gold", colors: TerminalTheme.Colors(
            bg: (0.10, 0.08, 0.04), text: (1.0, 0.95, 0.82), highlight: (1.0, 0.72, 0.15))),
        Swatch(id: "coral", name: "Coral pink", colors: TerminalTheme.Colors(
            bg: (0.11, 0.05, 0.06), text: (1.0, 0.90, 0.90), highlight: (1.0, 0.40, 0.48))),
        Swatch(id: "mint", name: "Mint", colors: TerminalTheme.Colors(
            bg: (0.04, 0.10, 0.08), text: (0.85, 1.0, 0.94), highlight: (0.20, 0.95, 0.72))),
        Swatch(id: "whitehot", name: "White-hot", colors: TerminalTheme.Colors(
            bg: (0.08, 0.08, 0.10), text: (0.98, 0.98, 1.0), highlight: (0.95, 0.97, 1.0))),
        Swatch(id: "ruby", name: "Ruby", colors: TerminalTheme.Colors(
            bg: (0.11, 0.04, 0.05), text: (1.0, 0.88, 0.90), highlight: (1.0, 0.18, 0.32))),
    ]

    static func swatch(id: String) -> Swatch? {
        all.first { $0.id == id }
    }

    /// Best match by highlight RGB distance (for reselecting chips).
    static func matching(_ colors: TerminalTheme.Colors?) -> Swatch? {
        guard let colors else { return nil }
        let h = colors.highlight
        var best: Swatch?
        var bestD = CGFloat.greatestFiniteMagnitude
        for s in all {
            let sh = s.colors.highlight
            let d = abs(sh.0 - h.0) + abs(sh.1 - h.1) + abs(sh.2 - h.2)
            if d < bestD { bestD = d; best = s }
        }
        return bestD < 0.35 ? best : nil
    }

    static func nsColor(from any: Any?) -> NSColor? {
        TerminalTheme.Colors.from(any)?.asNSColors.hi
    }
}

private extension NSImage {
    /// Soft opacity pulse without recoloring brand assets.
    func withAlpha(_ alpha: CGFloat) -> NSImage? {
        let out = NSImage(size: size)
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .sourceOver, fraction: max(0, min(1, alpha)))
        out.unlockFocus()
        out.isTemplate = false
        return out
    }
}
