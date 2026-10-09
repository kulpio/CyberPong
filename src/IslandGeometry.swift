import AppKit

// Where the notch panel sits and what it takes up (2.1, spec §4.1, §5.1, §8.1, §14.3): the notch's
// measured size, the black shapes for closed, the nudge and open, the areas that open it and keep it
// open, hit testing, and the path the shape layer draws. Pure values in and out, in screen points
// (y up, as AppKit counts); the one AppKit call is reading a screen's size (`NotchMetrics.of`).
// The notch numbers come from island/PongIsland.swift (`Notch`), where they were measured.

/// One screen's notch, as macOS publishes it: its size and nothing else.
struct NotchMetrics: Equatable {
    /// The screen's frame in global coordinates.
    var screen: CGRect
    /// The top of the Dock (the visible frame's bottom edge): the open panel stops 24 pt above it.
    var dockTop: CGFloat
    /// The camera housing's width; 0 on a screen without one.
    var notchWidth: CGFloat
    /// The safe-area inset at the top (the notch's height); 0 on a screen without one.
    var safeTop: CGFloat

    /// The width that stands in for a notch on a screen without one (the top-centre area that still
    /// opens the panel there).
    static let standInWidth: CGFloat = 190
    /// The tab's height on a screen without a notch.
    static let tabHeight: CGFloat = 28

    var hasNotch: Bool { notchWidth > 0 && safeTop > 0 }

    /// The closed panel's height: two points past the safe-area inset (flush with it, a rounding
    /// difference let a sliver of desktop show under the shape), or 28 pt with no notch.
    var chin: CGFloat { safeTop > 0 ? safeTop + 2 : NotchMetrics.tabHeight }

    /// The notch's bottom corner radius. macOS publishes no radius, so it is derived from the height
    /// that is measurable (the ratio was measured against the real cutout).
    var cornerRadius: CGFloat { max(6, min(14, (safeTop > 0 ? safeTop : 33) * 0.30)) }

    /// How far the closed shape flares outward into the bezel at the top (concave shoulders).
    var shoulder: CGFloat { cornerRadius }

    var top: CGFloat { screen.maxY }
    var midX: CGFloat { screen.midX }

    /// The camera housing (or the stand-in area on a screen without one), hard against the top.
    var notchRect: CGRect {
        let w = hasNotch ? notchWidth : NotchMetrics.standInWidth
        return CGRect(x: midX - w / 2, y: top - chin, width: w, height: chin)
    }

    /// The tallest the open panel may be: from the top of the screen to the top of the Dock less 24 pt,
    /// never under 320 pt.
    var openMaxHeight: CGFloat { max(320, floor(top - dockTop - 24)) }

    /// A screen's notch. macOS gives the width as the gap between the two areas beside it.
    static func of(_ s: NSScreen) -> NotchMetrics {
        var w: CGFloat = 0
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let gap = s.frame.width - l.width - r.width
            if gap > 60, gap < 400 { w = gap }
        }
        return NotchMetrics(screen: s.frame, dockTop: s.visibleFrame.minY, notchWidth: w,
                            safeTop: w > 0 ? s.safeAreaInsets.top : 0)
    }

    /// The preview's stand-in screens (spec §13.2): a 14-inch MacBook Pro (1512 × 982 pt with a
    /// 185 × 32 pt notch), or a 1920 × 1080 display without one. `origin` places it anywhere, so a
    /// preview never sits at the real notch.
    static func fake(notch: Bool = true, origin: CGPoint = .zero) -> NotchMetrics {
        notch
            ? NotchMetrics(screen: CGRect(origin: origin, size: CGSize(width: 1512, height: 982)),
                           dockTop: origin.y + 70, notchWidth: 185, safeTop: 32)
            : NotchMetrics(screen: CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)),
                           dockTop: origin.y + 70, notchWidth: 0, safeTop: 0)
    }
}

/// The black shape at one moment: its body (where the content and the clicks are) and the concave
/// shoulders that flare out from its top corners into the bezel.
struct IslandSilhouette: Equatable {
    /// The body in screen coordinates; its top edge is the top of the screen.
    var body: CGRect
    /// The outward flare at each top corner (0: none).
    var shoulder: CGFloat
    /// The bottom corners' radius.
    var radius: CGFloat

    /// The window at rest: the body plus room for the shoulders on each side.
    var frame: CGRect { body.insetBy(dx: -shoulder, dy: 0) }

    static let zero = IslandSilhouette(body: .zero, shoulder: 0, radius: 0)
}

/// The closed panel's two sides, as laid out: where the marker and count go, and where the line goes.
struct IslandClosedLayout: Equatable {
    var silhouette: IslandSilhouette
    /// Left of the notch: the marker and count (on a screen without a notch, the tab's first part).
    var left: CGRect
    /// Right of the notch: the line.
    var right: CGRect
}

enum IslandGeometry {
    // §4.1: the two sides hug their content
    /// The left side at most (marker and count, padding included).
    static let leftMax: CGFloat = 64
    /// The right side at most (the line and its 6 pt padding each side): the text gets 138 pt.
    static let rightMax: CGFloat = 150
    static let sidePad: CGFloat = 6
    /// The widest the line's text may be.
    static var lineTextMax: CGFloat { rightMax - 2 * sidePad }

    // §5.1: open
    static let openBody: CGFloat = 440
    static let openShoulder: CGFloat = 17
    static let openRadius: CGFloat = 20
    static let openContentWidth: CGFloat = 416

    // §14.3: the nudge of a new question
    static let nudgeMaxDrop: CGFloat = 64
    static let nudgeMaxWidth: CGFloat = 360
    static let nudgeRadius: CGFloat = 16

    // MARK: Shapes

    /// The closed shape (§4.1). `leftContent` and `rightContent` are what the sides hold, measured at
    /// the size they are drawn, without padding; 0 = that side is empty. Both sides together empty is
    /// the bare notch (nothing to draw: the shape is the camera housing itself). On a screen without a
    /// notch it is one black tab, 28 pt tall, centred at the top, holding both parts side by side.
    static func closed(_ m: NotchMetrics, leftContent: CGFloat, rightContent: CGFloat) -> IslandClosedLayout {
        let lw = leftContent > 0 ? min(leftMax, ceil(leftContent) + 2 * sidePad) : 0
        let rw = rightContent > 0 ? min(rightMax, ceil(rightContent) + 2 * sidePad) : 0
        let h = m.chin
        let y = m.top - h
        if !m.hasNotch {
            // one tab: the marker and count, then the line (the two pads between them meet as one)
            let w = lw + rw - (lw > 0 && rw > 0 ? sidePad : 0)
            let body = CGRect(x: m.midX - w / 2, y: y, width: w, height: h)
            let left = CGRect(x: body.minX, y: y, width: lw, height: h)
            let right = CGRect(x: body.maxX - rw, y: y, width: rw, height: h)
            return IslandClosedLayout(silhouette: IslandSilhouette(body: body, shoulder: w > 0 ? m.shoulder : 0,
                                                                   radius: min(m.cornerRadius, h / 2)),
                                      left: left, right: right)
        }
        let n = m.notchRect
        let body = CGRect(x: n.minX - lw, y: y, width: n.width + lw + rw, height: h)
        return IslandClosedLayout(silhouette: IslandSilhouette(body: body, shoulder: m.shoulder, radius: m.cornerRadius),
                                  left: CGRect(x: n.minX - lw, y: y, width: lw, height: h),
                                  right: CGRect(x: n.maxX, y: y, width: rw, height: h))
    }

    /// The nudge (§14.3): the closed shape dropped a little below the notch, at most 64 pt below the
    /// chin, as wide as the closed shape or up to 360 pt when the question needs it (grown evenly
    /// about the notch, never narrower than the closed shape).
    static func nudge(_ m: NotchMetrics, closed: IslandSilhouette, contentWidth: CGFloat, drop: CGFloat) -> IslandSilhouette {
        let want = min(nudgeMaxWidth, ceil(contentWidth) + 2 * 12)
        var minX = closed.body.width > 0 ? closed.body.minX : m.notchRect.minX
        var maxX = closed.body.width > 0 ? closed.body.maxX : m.notchRect.maxX
        if maxX - minX < want {
            let extra = want - (maxX - minX)
            minX -= extra / 2
            maxX += extra / 2
        }
        let h = m.chin + min(nudgeMaxDrop, max(0, ceil(drop)))
        return IslandSilhouette(body: CGRect(x: minX, y: m.top - h, width: maxX - minX, height: h),
                                shoulder: m.shoulder, radius: nudgeRadius)
    }

    /// The open panel (§5.1): 440 pt wide about the notch, as tall as its content up to the cap.
    static func open(_ m: NotchMetrics, contentHeight: CGFloat) -> IslandSilhouette {
        let h = min(m.openMaxHeight, max(m.chin, ceil(contentHeight)))
        return IslandSilhouette(body: CGRect(x: m.midX - openBody / 2, y: m.top - h, width: openBody, height: h),
                                shoulder: openShoulder, radius: openRadius)
    }

    /// The window while the shape changes: the union of where it was and where it is going (it shrinks
    /// only after the spring ends, so nothing is clipped on the way).
    static func transitionFrame(_ a: IslandSilhouette, _ b: IslandSilhouette) -> CGRect {
        if a.frame.isEmpty { return b.frame }
        if b.frame.isEmpty { return a.frame }
        return a.frame.union(b.frame)
    }

    // MARK: Areas (§8.1, §8.2)

    /// Where the pointer opens the panel. Just the notch: the camera housing (on a screen without one,
    /// the 190 × 28 pt top-centre area, even while the tab is hidden). The notch and the words beside it:
    /// the closed shape. A bigger area: the closed shape plus `extraW` each side and `extraH` below.
    /// Every choice includes the notch itself.
    static func openingArea(_ m: NotchMetrics, closed: IslandSilhouette, area: IslandSettings.OpenArea,
                            extraW: CGFloat = 40, extraH: CGFloat = 12) -> CGRect {
        let notch = m.notchRect
        let shape = closed.body.isEmpty ? notch : closed.body.union(notch)
        switch area {
        case .notch: return notch
        case .notchWords: return shape
        case .bigger:
            return CGRect(x: shape.minX - extraW, y: shape.minY - extraH,
                          width: shape.width + 2 * extraW, height: shape.height + extraH)
        }
    }

    /// Where the pointer keeps an open panel open: its shape plus the room to wander on every side
    /// but the top (the top is the screen's edge).
    static func stayArea(_ open: IslandSilhouette, pad: CGFloat) -> CGRect {
        let b = open.frame
        return CGRect(x: b.minX - pad, y: b.minY - pad, width: b.width + 2 * pad, height: b.height + pad)
    }

    // MARK: Full screen (§8.5)

    /// Whether a window covers the panel's screen as a full-screen app's does. Both rectangles are in
    /// window-server coordinates (y down, the top of the screen is `screen.minY`). A window over the
    /// whole screen counts. On a screen with a notch macOS puts a full-screen window under the strip
    /// beside the camera (the menu bar's height, `strip`) and fills that strip with black, so a window
    /// as wide as the screen, down to its bottom, whose top is in that strip counts too, as long as the
    /// menu bar isn't showing on that screen (a zoomed window on the desktop has the same frame).
    static func fillsScreen(_ r: CGRect, screen: CGRect, notch: Bool, strip: CGFloat, menuBarShown: Bool) -> Bool {
        let wide = abs(r.minX - screen.minX) < 1 && abs(r.width - screen.width) < 1 && abs(r.maxY - screen.maxY) < 1
        guard wide else { return false }
        if abs(r.minY - screen.minY) < 1 { return true }
        // a few points of slack: the menu bar can be taller than the notch
        return notch && !menuBarShown && r.minY > screen.minY + 1 && r.minY <= screen.minY + strip + 4
    }

    // MARK: Hit testing

    /// Whether a point is in a rectangle, edges included. `NSRect.contains` leaves out the top edge, and
    /// a pointer thrown hard against the top of the screen sits exactly there (§8.1).
    static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        guard !r.isNull, r.width > 0, r.height > 0 else { return false }
        return p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
    }

    /// Whether a click lands on the shape: its body, edges and the screen's top row included. Clicks
    /// beside it pass through to whatever is underneath.
    static func hits(_ s: IslandSilhouette, _ p: CGPoint) -> Bool {
        guard contains(s.body, p) else { return false }
        // the bottom corners are round: a point in a corner's square but outside its circle misses
        let r = s.radius
        guard r > 0, p.y < s.body.minY + r else { return true }
        let cx: CGFloat
        if p.x < s.body.minX + r { cx = s.body.minX + r } else if p.x > s.body.maxX - r { cx = s.body.maxX - r } else { return true }
        let cy = s.body.minY + r
        return (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) <= r * r
    }

    // MARK: The shape's path

    /// The outline the shape layer fills and masks with, in the coordinates of a view whose frame on
    /// screen is `window` (y up: the top edge is the view's maxY). The shoulders curve outward from the
    /// screen edge into the walls; the bottom corners are round. Every shape is built from the same
    /// nine elements in the same order, so a spring animation on `path` morphs one into another.
    static func path(_ s: IslandSilhouette, in window: CGRect) -> CGPath {
        let p = CGMutablePath()
        guard s.body.width > 0, s.body.height > 0 else { return p }
        let b = s.body.offsetBy(dx: -window.minX, dy: -window.minY)
        let sh = max(0, min(s.shoulder, b.height / 2))
        let r = max(0, min(s.radius, b.width / 2, b.height - sh))
        let top = b.maxY
        p.move(to: CGPoint(x: b.minX - sh, y: top))
        p.addQuadCurve(to: CGPoint(x: b.minX, y: top - sh), control: CGPoint(x: b.minX, y: top))
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addQuadCurve(to: CGPoint(x: b.minX + r, y: b.minY), control: CGPoint(x: b.minX, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addQuadCurve(to: CGPoint(x: b.maxX, y: b.minY + r), control: CGPoint(x: b.maxX, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX, y: top - sh))
        p.addQuadCurve(to: CGPoint(x: b.maxX + sh, y: top), control: CGPoint(x: b.maxX, y: top))
        p.closeSubpath()
        return p
    }

    /// A path drawn for a window at `from`, moved into the coordinates of a window at `to` (the same
    /// place on screen). A spring that takes over from one still running starts from where the shape
    /// is drawn now, while the window around it has changed.
    static func path(_ p: CGPath, from: CGRect, to: CGRect) -> CGPath {
        var t = CGAffineTransform(translationX: from.minX - to.minX, y: from.minY - to.minY)
        return p.copy(using: &t) ?? p
    }
}

/// The opening area came to the pointer, not the pointer to the area (spec rule 5, §14.3): a nudge
/// dropped or widened under a pointer that hasn't moved, the closed shape grew under it, or the panel
/// came up around it (just started, or back after a full-screen app that hid it). That is not the person
/// pointing, so until the pointer has left the area it can't open the panel (a click on the nudge still
/// does). The controller asks it, every tick of the pointer watch, for the opening area IslandHover goes
/// by: the area itself, or none while it is shut. While the panel is hidden it is told the area is
/// `.null`.
struct IslandAreaGate {
    /// The pointer and the area at the last tick (nil: no tick yet since the panel was built).
    private var last: (p: CGPoint, area: CGRect)?
    /// The area came to a resting pointer: shut until the pointer leaves it.
    private(set) var shut = false

    /// The opening area for this tick: `area`, or `.null` (nothing opens it) while shut.
    mutating func area(_ area: CGRect, pointer p: CGPoint, panelOpen: Bool) -> CGRect {
        defer { last = (p, area) }
        guard !panelOpen, IslandGeometry.contains(area, p) else {
            shut = false
            return area
        }
        if let l = last {
            if !IslandGeometry.contains(l.area, p), hypot(p.x - l.p.x, p.y - l.p.y) < 1 { shut = true }
        } else {
            // the first look since the panel came up, and the pointer is already in its area
            shut = true
        }
        return shut ? .null : area
    }

    /// Nothing remembered (the panel was built again, or turned off).
    mutating func reset() {
        last = nil
        shut = false
    }
}
