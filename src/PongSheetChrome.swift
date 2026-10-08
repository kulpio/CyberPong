import AppKit

/// Shared chrome for sheets and small windows (Sodium & Neon).
enum PongSheetChrome {
    /// Was the lime accent of sheets: the primary is ink ("Wallace white") now.
    static var lime: NSColor { PongColor.ink }
    static var limeSoft: NSColor { PongColor.hover }
    /// Section labels: tertiary text.
    static var limeDim: NSColor { PongColor.textTertiary }

    static func styleWindow(_ win: NSWindow, title: String) {
        win.title = title
        win.backgroundColor = PongColor.raised
        win.appearance = NSAppearance(named: .darkAqua)
    }

    static func rootView(width W: CGFloat, height H: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.raised.cgColor
        return v
    }

    static func titleLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = PongType.question
        f.textColor = PongTheme.textPrimary
        f.frame = frame
        return f
    }

    static func sectionLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.attributedStringValue = PongType.eyebrowString(text)
        f.frame = frame
        return f
    }

    static func bodyLabel(_ text: String, frame: NSRect) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = PongType.body
        f.textColor = PongTheme.textSecondary
        f.frame = frame
        f.maximumNumberOfLines = 8
        return f
    }

    static func hairline(x: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: x, y: y, width: width, height: 1))
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.hairline.cgColor
        return v
    }

    /// A raised card. `accent` is kept for old callers; cards carry no coloured edge now.
    static func plate(frame: NSRect, accent: NSColor = lime) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = PongColor.raised.cgColor
        v.layer?.cornerRadius = PongRadius.card
        return v
    }

    static func primaryButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = PongButton(title: title, style: .primary, target: target, action: action)
        return b
    }

    static func outlineButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = PongButton(title: title, style: .secondary, target: target, action: action)
        return b
    }
}
