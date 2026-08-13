import Cocoa
import Carbon.HIToolbox

// MARK: - Overlay view

/// Transparent view that captures gestures and renders every mark.
final class OverlayView: NSView {
    private var marks: [Mark] = []
    private var inProgress: Mark?
    private var fadeTimer: Timer?
    private var textField: NSTextField?

    private let prefs = Prefs.shared

    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            mark.draw(opacity: mark.opacity(hold: prefs.holdDuration, fade: prefs.fadeDuration))
        }
        inProgress?.draw(opacity: 1)
    }

    /// Drives the fade animation and drops marks once they're invisible.
    private func startFadeTimerIfNeeded() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.marks.count
            self.marks.removeAll {
                $0.opacity(hold: self.prefs.holdDuration, fade: self.prefs.fadeDuration) <= 0
            }

            let stillFading = self.marks.contains { $0.finishedAt != nil }
            if !stillFading && before == self.marks.count {
                self.fadeTimer?.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    /// A mark carrying the settings active at the moment it's drawn.
    private func newMark(at point: NSPoint) -> Mark {
        Mark(
            tool: prefs.tool,
            color: prefs.color,
            lineWidth: prefs.lineWidth,
            cornerRadius: prefs.cornerRadius,
            points: [point],
            start: point,
            end: point
        )
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitTextField()

        switch prefs.tool {
        case .eraser:
            erase(at: point)
        case .text:
            beginTextEntry(at: point)
        default:
            inProgress = newMark(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard inProgress != nil else { return }
        let point = convert(event.locationInWindow, from: nil)

        if prefs.tool == .freehand {
            inProgress?.points.append(point)
        }
        inProgress?.end = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }
        guard var mark = inProgress else { return }
        inProgress = nil

        // Discard accidental clicks that never became a real mark.
        switch mark.tool {
        case .freehand:
            guard mark.points.count > 2 else { return }
        case .arrow:
            let dx = mark.end.x - mark.start.x, dy = mark.end.y - mark.start.y
            guard (dx * dx + dy * dy).squareRoot() > 8 else { return }
        default:
            guard mark.rect.width > 4, mark.rect.height > 4 else { return }
        }

        mark.finishedAt = prefs.autoFade ? Date() : nil
        marks.append(mark)
        if prefs.autoFade { startFadeTimerIfNeeded() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: prefs.tool == .text ? .iBeam : .crosshair)
    }

    private func erase(at point: NSPoint) {
        if let index = marks.lastIndex(where: { $0.hitBounds.contains(point) }) {
            marks.remove(at: index)
            needsDisplay = true
        }
    }

    // MARK: Text entry

    private func beginTextEntry(at point: NSPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 6, width: 320, height: 34))
        field.font = .systemFont(ofSize: 14 + prefs.lineWidth * 4, weight: .semibold)
        field.textColor = prefs.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Type, then ↩"
        field.target = self
        field.action = #selector(commitTextField)

        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    /// Turns the live text field into a mark. Safe to call when there isn't one.
    @objc private func commitTextField() {
        guard let field = textField else { return }
        textField = nil

        let value = field.stringValue
        let origin = NSPoint(x: field.frame.minX, y: field.frame.minY + 6)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        var mark = newMark(at: origin)
        mark.tool = .text
        mark.text = value
        mark.finishedAt = prefs.autoFade ? Date() : nil
        marks.append(mark)
        if prefs.autoFade { startFadeTimerIfNeeded() }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // While typing, the text field owns the keyboard.
        if textField != nil {
            if Int(event.keyCode) == kVK_Escape {
                textField?.removeFromSuperview()
                textField = nil
                window?.makeFirstResponder(self)
            }
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            clear()
            onDismiss?()

        case kVK_Delete where event.modifierFlags.contains(.command),
             kVK_ANSI_Z where event.modifierFlags.contains(.command):
            if !marks.isEmpty { marks.removeLast() }
            needsDisplay = true

        case kVK_ANSI_1: prefs.colorIndex = 0
        case kVK_ANSI_2: prefs.colorIndex = 1
        case kVK_ANSI_3: prefs.colorIndex = 2
        case kVK_ANSI_4: prefs.colorIndex = 3
        case kVK_ANSI_5: prefs.colorIndex = 4

        case kVK_ANSI_P: prefs.tool = .freehand
        case kVK_ANSI_A: prefs.tool = .arrow
        case kVK_ANSI_R: prefs.tool = .rectangle
        case kVK_ANSI_O: prefs.tool = .ellipse
        case kVK_ANSI_T: prefs.tool = .text
        case kVK_ANSI_E: prefs.tool = .eraser

        case kVK_ANSI_LeftBracket:  prefs.lineWidth -= 1
        case kVK_ANSI_RightBracket: prefs.lineWidth += 1
        case kVK_ANSI_Minus:        prefs.cornerRadius -= 4
        case kVK_ANSI_Equal:        prefs.cornerRadius += 4

        case kVK_ANSI_C:
            clear()

        case kVK_ANSI_F:
            prefs.autoFade.toggle()

        default:
            super.keyDown(with: event)
        }
    }

    /// Called when preferences change so the cursor tracks the active tool.
    func settingsChanged() {
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func clear() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        marks.removeAll()
        inProgress = nil
        textField?.removeFromSuperview()
        textField = nil
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
    private var toolbar: ToolbarPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var isDrawing = false

    private let prefs = Prefs.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()

        prefs.onChange = { [weak self] in
            self?.syncMenuState()
            self?.toolbar?.syncSelection()
            self?.overlay?.settingsChanged()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(drawing: false)

        let menu = NSMenu()

        let draw = NSMenuItem(title: "Draw  (⌃⌥⌘B)", action: #selector(toggleDrawing), keyEquivalent: "")
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

        let fade = NSMenuItem(title: "Marks Fade Out", action: #selector(toggleFade), keyEquivalent: "")
        fade.target = self
        fade.identifier = .init("fade")
        menu.addItem(fade)

        let toolbarItem = NSMenuItem(title: "Show Toolbar", action: #selector(toggleToolbar), keyEquivalent: "")
        toolbarItem.target = self
        toolbarItem.identifier = .init("toolbar")
        menu.addItem(toolbarItem)
        menu.addItem(.separator())

        let help = NSMenuItem(title: "While drawing:", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        for line in ["  P A R O T E — tool",
                     "  1–5 — colour",
                     "  [ ] — thinner / thicker",
                     "  − = — corner radius",
                     "  F — toggle fade",
                     "  ⌘Z — undo",
                     "  C — clear all",
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
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                swatch.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                return true
            }
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
        menu.items.first { $0.identifier?.rawValue == "toolbar" }?.state = prefs.showToolbar ? .on : .off
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

    @objc private func toggleToolbar() {
        prefs.showToolbar.toggle()
        guard isDrawing else { return }
        if prefs.showToolbar {
            showToolbar()
        } else {
            hideToolbar()
        }
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
        guard let screen, case let frame = screen.frame else { return }

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

        if prefs.showToolbar { showToolbar(on: screen) }
        setIcon(drawing: true)
    }

    private func showToolbar(on screen: NSScreen? = nil) {
        let panel = toolbar ?? ToolbarPanel()
        panel.onClose = { [weak self] in self?.endDrawing() }
        panel.onClear = { [weak self] in self?.overlay?.clear() }
        panel.position(on: screen ?? window?.screen ?? NSScreen.main!)
        panel.orderFront(nil)
        panel.syncSelection()
        toolbar = panel
    }

    private func hideToolbar() {
        toolbar?.rememberPosition()
        toolbar?.orderOut(nil)
        toolbar = nil
    }

    private func endDrawing() {
        hideToolbar()
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
