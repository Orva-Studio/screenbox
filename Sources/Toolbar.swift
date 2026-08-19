import Cocoa

// MARK: - Buttons

/// A circular colour swatch that rings itself when selected.
final class ColorDot: NSView {
    private let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()

        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// An icon button that highlights when its tool is active.
final class ToolButton: NSView {
    private let imageView = NSImageView()
    var isSelected = false { didSet { needsDisplay = true; tint() } }
    var onClick: (() -> Void)?

    init(symbolName: String, tooltip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        toolTip = tooltip

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        imageView.frame = bounds.insetBy(dx: 6, dy: 6)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        tint()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func tint() {
        imageView.contentTintColor = isSelected ? .black : .white
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Toolbar background

/// Rounded black pill that hosts the controls.
final class ToolbarBackground: NSView {
    /// Fades the pill down to near-invisible while click-through is on, so it's
    /// obvious clicks aren't landing on the overlay right now — without making
    /// the bar (which stays clickable) disappear entirely.
    var dimmed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(dimmed ? 0.15 : 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    /// Dragging anywhere on the bar moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The six-dot drag affordance on the left.
final class DragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.5).setFill()
        let radius: CGFloat = 1.6
        let spacingX: CGFloat = 6, spacingY: CGFloat = 6
        let originX = bounds.midX - spacingX / 2
        let originY = bounds.midY - spacingY

        for column in 0..<2 {
            for row in 0..<3 {
                let point = NSPoint(x: originX + CGFloat(column) * spacingX,
                                    y: originY + CGFloat(row) * spacingY)
                NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
    }
}

/// Thin vertical rule separating groups of controls.
final class Divider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSRect(x: bounds.midX - 0.5, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}

// MARK: - Panel

/// Floating, non-activating toolbar. It sits above the overlay and never takes
/// key focus, so the overlay keeps receiving keyboard shortcuts while you click.
final class ToolbarPanel: NSPanel {
    private var dots: [ColorDot] = []
    private var toolButtons: [(Tool, ToolButton)] = []
    private var spotlightButton: ToolButton?
    private var passThroughButton: ToolButton?
    private var background: ToolbarBackground?
    /// Whether the last `build()` laid out the clear button, so `syncSelection`
    /// can spot the auto-fade toggle and relay out.
    private var showsClear = false
    private let prefs = Prefs.shared

    var onClose: (() -> Void)?
    var onClear: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver + 1 // above the drawing overlay
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false

        build()
    }

    // MARK: Layout

    private func build() {
        let height: CGFloat = 44
        let padding: CGFloat = 10
        let gap: CGFloat = 4
        var x = padding
        var controls: [NSView] = []

        func place(_ view: NSView, width: CGFloat, trailing: CGFloat = 0) {
            view.frame = NSRect(x: x, y: (height - view.frame.height) / 2,
                                width: width, height: view.frame.height)
            controls.append(view)
            x += width + gap + trailing
        }

        let handle = DragHandle(frame: NSRect(x: 0, y: 0, width: 14, height: 28))
        place(handle, width: 14, trailing: 4)

        for (index, entry) in Prefs.palette.enumerated() {
            let dot = ColorDot(color: entry.color)
            dot.toolTip = entry.name
            dot.onClick = { [weak self] in self?.prefs.colorIndex = index }
            dots.append(dot)
            place(dot, width: 26)
        }

        place(Divider(frame: NSRect(x: 0, y: 0, width: 9, height: height)), width: 9, trailing: 2)

        for tool in Tool.allCases {
            let button = ToolButton(symbolName: tool.symbolName, tooltip: "\(tool.label)  (\(tool.shortcut))")
            button.onClick = { [weak self] in self?.prefs.tool = tool }
            toolButtons.append((tool, button))
            place(button, width: 30)
        }

        place(Divider(frame: NSRect(x: 0, y: 0, width: 9, height: height)), width: 9, trailing: 2)

        let spotlight = ToolButton(symbolName: "flashlight.on.fill", tooltip: "Spotlight  (S)")
        spotlight.onClick = { [weak self] in self?.prefs.spotlight.toggle() }
        spotlightButton = spotlight
        place(spotlight, width: 30)

        // The toolbar is a separate window, so it keeps taking clicks even while
        // the overlay is passing them through — this is the way back.
        let passThrough = ToolButton(symbolName: "cursorarrow.click.2", tooltip: "Click through  (X or ⌃⌥⌘X)")
        passThrough.onClick = { [weak self] in self?.prefs.passThrough.toggle() }
        passThroughButton = passThrough
        place(passThrough, width: 30)

        // Only worth a slot when marks actually stick around. With auto-fade on
        // — the default — the screen empties itself, so there is never anything
        // to clear and the button is dead weight. `C` still works either way.
        showsClear = !prefs.autoFade
        if showsClear {
            let clear = ToolButton(symbolName: "trash", tooltip: "Clear all  (C)")
            clear.onClick = { [weak self] in self?.onClear?() }
            place(clear, width: 30)
        }

        let close = ToolButton(symbolName: "xmark.circle.fill", tooltip: "Close  (esc)")
        close.onClick = { [weak self] in self?.onClose?() }
        place(close, width: 30)

        let width = x - gap + padding
        setContentSize(NSSize(width: width, height: height))

        let background = ToolbarBackground(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.autoresizingMask = [.width, .height]
        controls.forEach { background.addSubview($0) }
        contentView = background
        self.background = background

        syncSelection()
    }

    /// Reflects the current preferences in the button states.
    func syncSelection() {
        // Toggling auto-fade adds or removes the clear button, which changes the
        // bar's width — that needs a fresh layout, not just new button states.
        if showsClear == prefs.autoFade {
            dots.removeAll()
            toolButtons.removeAll()
            spotlightButton = nil
            passThroughButton = nil
            background = nil
            build() // ends in syncSelection() itself, with showsClear now correct
            return
        }

        for (index, dot) in dots.enumerated() {
            dot.isSelected = (index == prefs.colorIndex)
        }
        for (tool, button) in toolButtons {
            button.isSelected = (tool == prefs.tool)
        }
        spotlightButton?.isSelected = prefs.spotlight
        passThroughButton?.isSelected = prefs.passThrough
        background?.dimmed = prefs.passThrough
    }

    // MARK: Positioning

    /// Restores the saved position, or centres near the top of `screen`.
    ///
    /// The saved spot is only reused if it lands on the screen we're drawing on —
    /// otherwise the bar would strand itself on another display, out of reach of
    /// the overlay it belongs to.
    func position(on screen: NSScreen) {
        let size = frame.size
        let visible = screen.visibleFrame

        if let saved = prefs.toolbarOrigin, visible.intersects(NSRect(origin: saved, size: size)) {
            // Clamp rather than discard, so a bar nudged past an edge comes back.
            setFrameOrigin(NSPoint(
                x: min(max(saved.x, visible.minX), max(visible.maxX - size.width, visible.minX)),
                y: min(max(saved.y, visible.minY), max(visible.maxY - size.height, visible.minY))
            ))
        } else {
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                   y: visible.maxY - size.height - 20))
        }
    }

    func rememberPosition() {
        prefs.toolbarOrigin = frame.origin
    }
}
