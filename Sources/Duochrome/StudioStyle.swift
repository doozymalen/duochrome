import AppKit

extension NSButton.BezelStyle {
    /// App-wide push button style. macOS 26's default push button is already a glass pill.
    /// (.glass barely showed a border over glass panels and looked like plain text)
    static var appPush: NSButton.BezelStyle { .rounded }
}

/// Transparent background with a plain arrow cursor (clicks pass through)
final class ArrowCursorView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum StudioStyle {
    static let window = NSColor(white: 0.13, alpha: 1)
    static let canvasBack = NSColor(white: 0.13, alpha: 1)
    static let panel = NSColor(white: 0.19, alpha: 1)
    static let panelBorder = NSColor.white.withAlphaComponent(0.07)
    static let selection = NSColor.white.withAlphaComponent(0.1)
    static let accent = NSColor.controlAccentColor

    /// Floating panel look. From macOS 26, Liquid Glass (NSGlassEffectView) sits behind.
    /// interactive: bars holding clickable buttons (tool strip, per-mode bars, toolbar pills) have glass that reacts to presses (macOS 27).
    static func floating(_ v: NSView, radius: CGFloat = 16, interactive: Bool = false) {
        v.wantsLayer = true
        // Plain arrow over floating panels (so the photo view's edit cursor doesn't show through)
        let arrow = ArrowCursorView(frame: v.bounds)
        arrow.autoresizingMask = [.width, .height]
        v.addSubview(arrow, positioned: .below, relativeTo: nil)
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            // Clear glass (untinted). The whole-bar wobble on press is turned off
            // — the bar swelling when picking a tool looked bad.
            _ = interactive
            glass.frame = v.bounds
            glass.autoresizingMask = [.width, .height]
            // Behind the content (sibling views): the glass is only a background
            v.addSubview(glass, positioned: .below, relativeTo: nil)
            v.layer?.backgroundColor = NSColor.clear.cgColor
            v.layer?.cornerRadius = radius
            return
        }
        v.layer?.backgroundColor = panel.cgColor
        v.layer?.cornerRadius = radius
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = panelBorder.cgColor
        v.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
    }

    static func label(_ s: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject?, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }
}
