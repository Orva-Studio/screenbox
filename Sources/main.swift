import Cocoa
import Carbon.HIToolbox

// MARK: - Overlay view

/// Transparent view that captures drag gestures and strokes rectangles.
final class OverlayView: NSView {
    private struct Shape {
        var rect: NSRect
        var color: NSColor
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

    var color: NSColor = .systemBlue
    var lineWidth: CGFloat = 4
    var onDismiss: (() -> Void)?
    var onFadeModeChanged: ((Bool) -> Void)?

    /// When true, a box fades away on its own after you release the mouse.
    var autoFade = true
    var holdDuration: TimeInterval = 0.15
    var fadeDuration: TimeInterval = 0.2

    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for shape in shapes {
            stroke(shape.rect, shape.color, opacity: shape.opacity(hold: holdDuration, fade: fadeDuration))
        }
        if let origin = dragOrigin, let current = dragCurrent {
            stroke(OverlayView.rect(from: origin, to: current), color, opacity: 1)
        }
    }

    private func stroke(_ rect: NSRect, _ color: NSColor, opacity: CGFloat) {
        guard rect.width > 1, rect.height > 1, opacity > 0 else { return }
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        // Dark halo so the box stays visible on light and dark backgrounds alike.
        let halo = NSBezierPath(rect: inset)
        halo.lineWidth = lineWidth + 2
        NSColor.black.withAlphaComponent(0.35 * opacity).setStroke()
        halo.stroke()

        let path = NSBezierPath(rect: inset)
        path.lineWidth = lineWidth
        path.lineJoinStyle = .miter
        color.withAlphaComponent(opacity).setStroke()
        path.stroke()
    }

    /// Drives the fade animation and drops boxes once they're invisible.
    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.shapes.count
            self.shapes.removeAll { $0.opacity(hold: self.holdDuration, fade: self.fadeDuration) <= 0 }

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
        shapes.append(Shape(rect: final, color: color, finishedAt: autoFade ? Date() : nil))
        if autoFade { startFadeTimerIfNeeded() }
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
        case kVK_ANSI_1: color = .systemBlue
        case kVK_ANSI_2: color = .systemRed
        case kVK_ANSI_3: color = .systemGreen
        case kVK_ANSI_4: color = .systemYellow
        case kVK_ANSI_C:
            clear()
            needsDisplay = true
        case kVK_ANSI_F:
            // Toggle fade mode. Boxes already on screen keep their current behaviour.
            autoFade.toggle()
            onFadeModeChanged?(autoFade)
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
    private var fadeItem: NSMenuItem!

    /// Persisted so the mode survives a restart.
    private var autoFade: Bool {
        get {
            UserDefaults.standard.object(forKey: "autoFade") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoFade")
            fadeItem.state = newValue ? .on : .off
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.dashed",
            accessibilityDescription: "ScreenBox"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Draw Box  (⌃⌥⌘B)", action: #selector(toggleDrawing), keyEquivalent: "")

        fadeItem = NSMenuItem(title: "Boxes Fade Out", action: #selector(toggleFade), keyEquivalent: "")
        fadeItem.target = self
        menu.addItem(fadeItem)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "While drawing:", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        for line in ["  drag — draw a box",
                     "  1–4 — blue / red / green / yellow",
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

        for item in menu.items where item.action == #selector(toggleDrawing) {
            item.target = self
        }
        statusItem.menu = menu
        fadeItem.state = autoFade ? .on : .off
    }

    @objc private func toggleFade() {
        autoFade.toggle()
        overlay?.autoFade = autoFade
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
        view.autoFade = autoFade
        view.onDismiss = { [weak self] in self?.endDrawing() }
        view.onFadeModeChanged = { [weak self] enabled in self?.autoFade = enabled }
        window.contentView = view

        self.window = window
        self.overlay = view
        isDrawing = true

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.dashed.badge.record",
            accessibilityDescription: "ScreenBox — drawing"
        )
    }

    private func endDrawing() {
        overlay?.clear()
        window?.orderOut(nil)
        window = nil
        overlay = nil
        isDrawing = false
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.dashed",
            accessibilityDescription: "ScreenBox"
        )
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
