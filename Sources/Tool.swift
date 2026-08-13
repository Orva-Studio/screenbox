import Cocoa

/// The drawing tools offered in the toolbar.
enum Tool: Int, CaseIterable {
    case freehand, arrow, rectangle, ellipse, text, eraser

    var symbolName: String {
        switch self {
        case .freehand:  return "scribble"
        case .arrow:     return "arrow.down.left"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .text:      return "textformat"
        case .eraser:    return "eraser"
        }
    }

    var label: String {
        switch self {
        case .freehand:  return "Freehand"
        case .arrow:     return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        case .text:      return "Text"
        case .eraser:    return "Eraser"
        }
    }

    /// Key that selects this tool while drawing.
    var shortcut: String {
        switch self {
        case .freehand:  return "P"
        case .arrow:     return "A"
        case .rectangle: return "R"
        case .ellipse:   return "O"
        case .text:      return "T"
        case .eraser:    return "E"
        }
    }
}

/// One finished (or in-progress) mark on screen.
struct Mark {
    var tool: Tool
    var color: NSColor
    var lineWidth: CGFloat
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

    /// Generous bounds used for eraser hit-testing.
    var hitBounds: NSRect {
        let padding = max(lineWidth * 2, 8)
        switch tool {
        case .freehand:
            guard let first = points.first else { return .zero }
            var box = NSRect(origin: first, size: .zero)
            for point in points { box = NSUnionRect(box, NSRect(origin: point, size: .zero)) }
            return box.insetBy(dx: -padding, dy: -padding)
        case .text:
            return NSRect(origin: start, size: NSSize(width: 400, height: 60))
                .insetBy(dx: -padding, dy: -padding)
        default:
            return rect.insetBy(dx: -padding, dy: -padding)
        }
    }

    var fontSize: CGFloat { 14 + lineWidth * 4 }

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
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: stroke,
                .shadow: shadow,
            ]
            text.draw(at: start, withAttributes: attributes)

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
        case .freehand:
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

        case .rectangle:
            let box = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            guard box.width > 1, box.height > 1 else { return nil }
            let radius = min(cornerRadius, min(box.width, box.height) / 2)
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

        case .text, .eraser:
            return nil
        }

        return path
    }
}
