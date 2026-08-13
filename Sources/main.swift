import Cocoa
import Carbon.HIToolbox

// MARK: - Overlay view

/// Transparent view that captures drag gestures and strokes rectangles.
final class OverlayView: NSView {
    private struct Shape {
        var rect: NSRect
        var color: NSColor
        var lineWidth: CGFloat
        var cornerRadius: CGFloat
        /// When the box was finished. `nil` means it never fades.
        var finishedAt: Date?

        /// 1 while held, easing to 0 across the fade, then gone.
        func opacity(hold: TimeInterval, fade: TimeInterval) -> CGFloat {
            guard let finishedAt else { return 1 }
            let age = Date().timeIntervalSince(finishedAt)
            if age <= hold { return 1 }
            let t = (age - hold) / fade
            if t >= 1 { return 0 }
            return CGFloat(1 - t * t) // ease-out: lingers, then drops off
        }
    }

    private var shapes: [Shape] = []
    private var dragOrigin: NSPoint?
    private var dragCurrent: NSPoint?
    private var fadeTimer: Timer?

    private let prefs = Prefs.shared

    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for shape in shapes {
            stroke(shape, opacity: shape.opacity(hold: prefs.holdDuration, fade: prefs.fadeDuration))
        }
        if let origin = dragOrigin, let current = dragCurrent {
            // The in-progress box always uses the current settings.
            let preview = Shape(
                rect: OverlayView.rect(from: origin, to: current),
                color: prefs.color,
                lineWidth: prefs.lineWidth,
                cornerRadius: prefs.cornerRadius,
                finishedAt: nil
            )
            stroke(preview, opacity: 1)
        }
    }

    private func stroke(_ shape: Shape, opacity: CGFloat) {
        guard shape.rect.width > 1, shape.rect.height > 1, opacity > 0 else { return }
        let inset = shape.rect.insetBy(dx: shape.lineWidth / 2, dy: shape.lineWidth / 2)
        // Keep the radius from exceeding what the box can actually accommodate.
        let radius = min(shape.cornerRadius, min(inset.width, inset.height) / 2)

        func path(_ width: CGFloat) -> NSBezierPath {
            let p = radius > 0
                ? NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
                : NSBezierPath(rect: inset)
            p.lineWidth = width
            p.lineJoinStyle = radius > 0 ? .round : .miter
            return p
        }

        // Dark halo so the box stays visible on light and dark backgrounds alike.
        NSColor.black.withAlphaComponent(0.35 * opacity).setStroke()
        path(shape.lineWidth + 2).stroke()

        shape.color.withAlphaComponent(opacity).setStroke()
        path(shape.lineWidth).stroke()
    }

    /// Drives the fade animation and drops boxes once they're invisible.
    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.shapes.count
            self.shapes.removeAll {
                $0.opacity(hold: self.prefs.holdDuration, fade: self.prefs.fadeDuration) <= 0
            }

            let stillFading = self.shapes.contains { $0.finishedAt != nil }
            if !stillFading && before == self.shapes.count {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    private static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            dragCurrent = nil
            needsDisplay = true
        }
        guard let origin = dragOrigin else { return }
        let final = OverlayView.rect(from: origin, to: convert(event.locationInWindow, from: nil))
        guard final.width > 4, final.height > 4 else { return }

        shapes.append(Shape(
            rect: final,
            color: prefs.color,
            lineWidth: prefs.lineWidth,
            cornerRadius: prefs.cornerRadius,
            finishedAt: prefs.autoFade ? Date() : nil
        ))
        if prefs.autoFade { startFadeTimerIfNeeded() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            clear()
            onDismiss?()

        case kVK_Delete where event.modifierFlags.contains(.command),
             kVK_ANSI_Z where event.modifierFlags.contains(.command):
            if !shapes.isEmpty { shapes.removeLast() }
            needsDisplay = true

        case kVK_ANSI_1: prefs.colorIndex = 0
        case kVK_ANSI_2: prefs.colorIndex = 1
        case kVK_ANSI_3: prefs.colorIndex = 2
        case kVK_ANSI_4: prefs.colorIndex = 3

        case kVK_ANSI_LeftBracket:  prefs.lineWidth -= 1
        case kVK_ANSI_RightBracket: prefs.lineWidth += 1
        case kVK_ANSI_Minus:        prefs.cornerRadius -= 4
        case kVK_ANSI_Equal:        prefs.cornerRadius += 4

        case kVK_ANSI_C:
            clear()

        case kVK_ANSI_F:
            // Toggle fade mode. Boxes already on screen keep their behaviour.
            prefs.autoFade.toggle()

        default:
            super.keyDown(with: event)
        }
    }

    func clear() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        shapes.removeAll()
        dragOrigin = nil
        dragCurrent = nil
        needsDisplay = true
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: OverlayWindow?
    private var overlay: OverlayView?
    private var hotKeyRef: EventHotKeyRef?
    private var isDrawing = false

    private let prefs = Prefs.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()

        prefs.onChange = { [weak self] in
            self?.syncMenuState()
            self?.overlay?.needsDisplay = true
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(drawing: false)

        let menu = NSMenu()

        let draw = NSMenuItem(title: "Draw Box  (⌃⌥⌘B)", action: #selector(toggleDrawing), keyEquivalent: "")
        draw.target = self
        menu.addItem(draw)
        menu.addItem(.separator())

        menu.addItem(submenu(title: "Colour", items: Prefs.palette.enumerated().map { index, entry in
            item(entry.name, #selector(pickColor), tag: index, swatch: entry.color)
        }))

        menu.addItem(submenu(title: "Thickness", items: Prefs.lineWidthChoices.enumerated().map { index, width in
            item("\(Int(width)) pt", #selector(pickLineWidth), tag: index)
        }))

        menu.addItem(submenu(title: "Corner Radius", items: Prefs.cornerRadiusChoices.enumerated().map { index, radius in
            item(radius == 0 ? "Square" : "\(Int(radius)) pt", #selector(pickCornerRadius), tag: index)
        }))

        menu.addItem(submenu(title: "Fade Speed", items: Prefs.speedChoices.enumerated().map { index, choice in
            item(choice.0, #selector(pickSpeed), tag: index)
        }))

        let fade = NSMenuItem(title: "Boxes Fade Out", action: #selector(toggleFade), keyEquivalent: "")
        fade.target = self
        fade.identifier = .init("fade")
        menu.addItem(fade)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "While drawing:", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        for line in ["  drag — draw a box",
                     "  1–4 — colour",
                     "  [ ] — thinner / thicker",
                     "  − = — less / more corner radius",
                     "  F — toggle fade on/off",
                     "  ⌘Z — undo last box",
                     "  C — clear all, stay drawing",
                     "  esc — clear and exit"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenBox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        syncMenuState()
    }

    private func item(_ title: String, _ action: Selector, tag: Int, swatch: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        if let swatch {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size, flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                return true
            }
            item.image = image
        }
        return item
    }

    private func submenu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    /// Ticks the menu item matching each current preference.
    private func syncMenuState() {
        guard let menu = statusItem?.menu else { return }

        func check(_ title: String, matching index: Int?) {
            guard let sub = menu.items.first(where: { $0.title == title })?.submenu else { return }
            for (i, item) in sub.items.enumerated() {
                item.state = (i == index) ? .on : .off
            }
        }

        check("Colour", matching: prefs.colorIndex)
        check("Thickness", matching: Prefs.lineWidthChoices.firstIndex(of: prefs.lineWidth))
        check("Corner Radius", matching: Prefs.cornerRadiusChoices.firstIndex(of: prefs.cornerRadius))
        check("Fade Speed", matching: Prefs.speedChoices.firstIndex {
            $0.1 == prefs.holdDuration && $0.2 == prefs.fadeDuration
        })

        menu.items.first { $0.identifier?.rawValue == "fade" }?.state = prefs.autoFade ? .on : .off
    }

    // MARK: Menu actions

    @objc private func pickColor(_ sender: NSMenuItem) { prefs.colorIndex = sender.tag }
    @objc private func pickLineWidth(_ sender: NSMenuItem) { prefs.lineWidth = Prefs.lineWidthChoices[sender.tag] }
    @objc private func pickCornerRadius(_ sender: NSMenuItem) { prefs.cornerRadius = Prefs.cornerRadiusChoices[sender.tag] }
    @objc private func toggleFade() { prefs.autoFade.toggle() }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        let choice = Prefs.speedChoices[sender.tag]
        prefs.holdDuration = choice.1
        prefs.fadeDuration = choice.2
    }

    // MARK: Global hotkey (Carbon — no Accessibility permission needed)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleDrawing() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let id = EventHotKeyID(signature: OSType(0x5342_4F58), id: 1) // 'SBOX'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Drawing mode

    @objc func toggleDrawing() {
        isDrawing ? endDrawing() : beginDrawing()
    }

    private func beginDrawing() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.frame else { return }

        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = false

        let view = OverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.onDismiss = { [weak self] in self?.endDrawing() }
        window.contentView = view

        self.window = window
        self.overlay = view
        isDrawing = true

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        setIcon(drawing: true)
    }

    private func endDrawing() {
        overlay?.clear()
        window?.orderOut(nil)
        window = nil
        overlay = nil
        isDrawing = false
        setIcon(drawing: false)
    }

    private func setIcon(drawing: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: drawing ? "rectangle.dashed.badge.record" : "rectangle.dashed",
            accessibilityDescription: drawing ? "ScreenBox — drawing" : "ScreenBox"
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
