import Cocoa

/// The drawing tools offered in the toolbar.
enum Tool: Int, CaseIterable {
    case freehand, arrow, rectangle, ellipse, text, highlighter, redact

    var symbolName: String {
        switch self {
        case .freehand:    return "scribble"
        case .arrow:       return "arrow.down.left"
        case .rectangle:   return "rectangle"
        case .ellipse:     return "circle"
        case .text:        return "textformat"
        case .highlighter: return "highlighter"
        case .redact:      return "rectangle.fill"
        }
    }

    var label: String {
        switch self {
        case .freehand:    return "Freehand"
        case .arrow:       return "Arrow"
        case .rectangle:   return "Rectangle"
        case .ellipse:     return "Ellipse"
        case .text:        return "Text"
        case .highlighter: return "Highlighter"
        case .redact:      return "Redact"
        }
    }

    /// Key that selects this tool while drawing.
    var shortcut: String {
        switch self {
        case .freehand:    return "P"
        case .arrow:       return "A"
        case .rectangle:   return "R"
        case .ellipse:     return "O"
        case .text:        return "T"
        case .highlighter: return "H"
        case .redact:      return "D"
        }
    }

    /// Tools drawn by sampling the cursor along a drag.
    var isFreehandStyle: Bool { self == .freehand || self == .highlighter }

    /// Tools whose whole point is to stay put. Redactions cover something the
    /// audience mustn't see, so they never join the fade — `C` or `esc` clears
    /// them, deliberately, rather than a timer doing it while you're talking.
    var isPermanent: Bool { self == .redact }
}

/// One finished (or in-progress) mark on screen.
struct Mark {
    /// Stable identity, so undo can name a mark that may have moved or faded.
    let id = UUID()

    var tool: Tool
    var color: NSColor
    var lineWidth: CGFloat
    /// Highlighter stroke width, set independently of `lineWidth` so the two
    /// tools can be sized separately. Unused by every other tool.
    var highlighterWidth: CGFloat = 24
    var cornerRadius: CGFloat

    /// Freehand sample points, in view coordinates.
    var points: [NSPoint] = []
    /// Drag start/end, used by arrow, rectangle and ellipse.
    var start: NSPoint = .zero
    var end: NSPoint = .zero
    /// Typed string, for the text tool.
    var text: String = ""

    /// When the mark was completed. `nil` means it never fades.
    var finishedAt: Date?

    var rect: NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    /// 1 while held, easing to 0 across the fade, then gone.
    func opacity(hold: TimeInterval, fade: TimeInterval) -> CGFloat {
        guard let finishedAt else { return 1 }
        let age = Date().timeIntervalSince(finishedAt)
        if age <= hold { return 1 }
        let t = (age - hold) / fade
        if t >= 1 { return 0 }
        return CGFloat(1 - t * t) // ease-out: lingers, then drops off
    }

    var fontSize: CGFloat { 14 + lineWidth * 4 }

    var textFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

    /// Measured size of the drawn string, so hit-testing matches what's on screen.
    var textSize: NSSize {
        let measured = (text as NSString).size(withAttributes: [.font: textFont])
        return NSSize(width: max(measured.width, fontSize), height: max(measured.height, fontSize))
    }

    /// True when the mark would actually render something. Marks that fail this
    /// are dropped rather than stored invisibly where undo can still find them.
    var isDrawable: Bool {
        switch tool {
        case .text: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        default:    return bezierPath() != nil
        }
    }

    /// Strokes the mark into the current graphics context.
    func draw(opacity: CGFloat) {
        guard opacity > 0 else { return }
        let stroke = color.withAlphaComponent(opacity)
        let halo = NSColor.black.withAlphaComponent(0.35 * opacity)

        switch tool {
        case .text:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6 * opacity)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: stroke,
                .shadow: shadow,
            ]
            text.draw(at: start, withAttributes: attributes)

        case .redact:
            guard let path = bezierPath() else { return }
            // Deliberately opaque, and deliberately not the palette colour: a
            // redaction has to actually hide what's under it, and it should
            // read as a blanked-out box rather than as a filled-in shape.
            path.lineJoinStyle = .round
            NSColor.black.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 1
            path.stroke()

        case .highlighter:
            guard let path = bezierPath() else { return }
            // One translucent pass, no halo: the point is to let whatever is
            // underneath read through, the way a real highlighter does.
            path.lineCapStyle = .square
            path.lineWidth = highlighterWidth
            color.withAlphaComponent(0.32 * opacity).setStroke()
            path.stroke()

        default:
            guard let path = bezierPath() else { return }

            // Dark halo so marks stay visible on light and dark backgrounds alike.
            path.lineWidth = lineWidth + 2
            halo.setStroke()
            path.stroke()

            path.lineWidth = lineWidth
            stroke.setStroke()
            path.stroke()
        }
    }

    private func bezierPath() -> NSBezierPath? {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch tool {
        case .freehand, .highlighter:
            guard points.count > 1 else { return nil }
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }

        case .arrow:
            let dx = end.x - start.x, dy = end.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 4 else { return nil }
            path.move(to: start)
            path.line(to: end)

            // Arrowhead scales with stroke weight but is capped by the shaft length.
            let head = min(max(lineWidth * 4, 12), length * 0.5)
            let angle = atan2(dy, dx)
            let spread = CGFloat.pi / 7
            for side in [angle + .pi - spread, angle + .pi + spread] {
                path.move(to: end)
                path.line(to: NSPoint(x: end.x + cos(side) * head, y: end.y + sin(side) * head))
            }

        case .rectangle, .redact:
            // A redaction covers exactly what was dragged: it takes no stroke
            // inset, and no corner radius either. Both would leave slivers of
            // whatever it's hiding showing at the edges — square is the point.
            let inset = tool == .redact ? 0 : lineWidth / 2
            let box = rect.insetBy(dx: inset, dy: inset)
            guard box.width > 1, box.height > 1 else { return nil }
            let radius = tool == .redact ? 0 : min(cornerRadius, min(box.width, box.height) / 2)
            if radius > 0 {
                path.appendRoundedRect(box, xRadius: radius, yRadius: radius)
            } else {
                path.appendRect(box)
                path.lineJoinStyle = .miter
            }

        case .ellipse:
            let box = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            guard box.width > 1, box.height > 1 else { return nil }
            path.appendOval(in: box)

        case .text:
            return nil
        }

        return path
    }
}
