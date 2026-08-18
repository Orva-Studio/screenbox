import Cocoa
import Carbon.HIToolbox

// MARK: - Overlay view

/// Transparent view that captures gestures and renders every mark.
final class OverlayView: NSView, NSTextFieldDelegate {
    private var marks: [Mark] = []
    private var inProgress: Mark?
    private var fadeTimer: Timer?
    private var spotlightTimer: Timer?
    private var lastMouse = NSEvent.mouseLocation
    private var textField: NSTextField?
    /// Marks in the order they were drawn, for undo. Identified by id because
    /// the fade timer removes them out from under the stack.
    private var undoStack: [UUID] = []
    /// Last seen `prefs.autoFade`, to spot the toggle in `settingsChanged`.
    private var wasAutoFading = Prefs.shared.autoFade

    private let prefs = Prefs.shared

    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    // Both timers hold the view weakly, so nothing keeps us alive past the
    // overlay being torn down — but they'd keep firing if we didn't stop them.
    deinit {
        fadeTimer?.invalidate()
        spotlightTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSpotlightTimer()
    }

    /// Claim the click that refocuses the overlay, instead of swallowing it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawSpotlight()
        for mark in marks {
            mark.draw(opacity: mark.opacity(hold: prefs.holdDuration, fade: prefs.fadeDuration))
        }
        inProgress?.draw(opacity: 1)
    }

    // MARK: Spotlight

    /// Dims the screen apart from a soft circle around the pointer. Drawn first,
    /// so marks stay at full strength on top of the dimming.
    private func drawSpotlight() {
        guard prefs.spotlight else { return }

        let dim = NSColor.black.withAlphaComponent(0.55)
        let centre = spotlightCentre
        let inner = prefs.spotlightRadius
        let outer = inner * 1.25 // the width of the soft edge

        // Everything beyond the falloff, in one flat fill.
        let beyond = NSBezierPath(rect: bounds)
        beyond.append(NSBezierPath(ovalIn: NSRect(x: centre.x - outer, y: centre.y - outer,
                                                  width: outer * 2, height: outer * 2)))
        beyond.windingRule = .evenOdd
        dim.setFill()
        beyond.fill()

        // ...and the ramp from clear at the edge of the lit circle out to it.
        NSGradient(colors: [.clear, dim])?
            .draw(fromCenter: centre, radius: inner, toCenter: centre, radius: outer, options: [])
    }

    /// Pointer position in view coordinates.
    ///
    /// Read from the global mouse location rather than the window's, which isn't
    /// meaningful until the freshly-opened overlay has seen an event of its own.
    private var spotlightCentre: NSPoint {
        guard let window else { return NSPoint(x: bounds.midX, y: bounds.midY) }
        let global = NSEvent.mouseLocation
        return convert(NSPoint(x: global.x - window.frame.minX,
                               y: global.y - window.frame.minY), from: nil)
    }

    /// Polls the pointer while the spotlight is up. A tracking area would miss
    /// every move made over the toolbar, which floats above the overlay.
    private func syncSpotlightTimer() {
        guard prefs.spotlight else {
            spotlightTimer?.invalidate()
            spotlightTimer = nil
            return
        }
        guard spotlightTimer == nil else { return }
        spotlightTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            guard mouse != self.lastMouse else { return }
            self.lastMouse = mouse
            self.needsDisplay = true
        }
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
        // Clicking away and back (common with two displays) leaves us non-key.
        if window?.isKeyWindow == false {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }

        let point = convert(event.locationInWindow, from: nil)
        commitTextField()
        inProgress = nil // drop anything stranded by a mouseUp we never saw

        switch prefs.tool {
        case .text:
            beginTextEntry(at: point)
        default:
            inProgress = newMark(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard inProgress != nil else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Follow the tool the stroke started with, so switching mid-drag
        // doesn't truncate it.
        if inProgress?.tool.isFreehandStyle == true {
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
        case .freehand, .highlighter:
            guard mark.points.count > 2 else { return }
        case .arrow:
            let dx = mark.end.x - mark.start.x, dy = mark.end.y - mark.start.y
            guard (dx * dx + dy * dy).squareRoot() > 8 else { return }
        default:
            guard mark.rect.width > 4, mark.rect.height > 4 else { return }
        }
        // ...and ones too small to actually stroke, which would otherwise sit
        // invisible but still absorb an undo.
        guard mark.isDrawable else { return }

        mark.finishedAt = prefs.autoFade ? Date() : nil
        marks.append(mark)
        undoStack.append(mark.id)
        if prefs.autoFade { startFadeTimerIfNeeded() }
    }

    override func resetCursorRects() {
        // With "keep normal cursor" on we claim no rect at all, so the pointer
        // stays the plain arrow the overlay window would show anyway.
        guard !prefs.keepNormalCursor else { return }
        addCursorRect(bounds, cursor: prefs.tool == .text ? .iBeam : .crosshair)
    }

    // MARK: Undo

    /// Removes the most recent mark. Entries naming marks that have since faded
    /// away are skipped rather than counted as an undo.
    private func undo() {
        while let id = undoStack.popLast() {
            guard let index = marks.firstIndex(where: { $0.id == id }) else { continue }
            marks.remove(at: index)
            needsDisplay = true
            return
        }
    }

    // MARK: Text entry

    /// Vertical padding between the editor's frame and its text baseline box,
    /// so the committed mark lands where the editor showed it.
    private func textInset(fontSize: CGFloat, height: CGFloat) -> CGFloat {
        max((height - fontSize * 1.2) / 2, 0)
    }

    private func beginTextEntry(at point: NSPoint) {
        // The editor has to grow with the stroke weight, or thick text clips.
        let fontSize = 14 + prefs.lineWidth * 4
        let size = NSSize(width: 320, height: ceil(fontSize * 1.2) + 16)

        // Keep it fully on screen even when clicked near an edge.
        let origin = NSPoint(
            x: min(max(point.x, bounds.minX), max(bounds.maxX - size.width, bounds.minX)),
            y: min(max(point.y - size.height / 2, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        )

        let field = NSTextField(frame: NSRect(origin: origin, size: size))
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = prefs.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Type, then ↩"
        field.delegate = self

        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    /// Commits any live text field from outside the view, for the transitions
    /// that leave it unusable — clicks passing through means no way to type
    /// into it, and no way to click it again either.
    func endTextEntry() { commitTextField() }

    /// Turns the live text field into a mark. Safe to call when there isn't one.
    @objc private func commitTextField() {
        guard let field = textField else { return }
        textField = nil // set first: tearing the field down re-enters here

        let value = field.stringValue
        let fontSize = field.font?.pointSize ?? prefs.lineWidth * 4 + 14
        let origin = NSPoint(x: field.frame.minX + 2,
                             y: field.frame.minY + textInset(fontSize: fontSize, height: field.frame.height))
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        var mark = newMark(at: origin)
        mark.tool = .text
        mark.text = value
        mark.finishedAt = prefs.autoFade ? Date() : nil
        marks.append(mark)
        undoStack.append(mark.id)
        if prefs.autoFade { startFadeTimerIfNeeded() }
        needsDisplay = true
    }

    /// Throws away the live field without committing it.
    private func discardTextField() {
        guard let field = textField else { return }
        textField = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // Return commits and Escape discards. Handling both here rather than via
    // target/action means the field can never be left behind holding the
    // keyboard hostage.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTextField()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            discardTextField()
            return true
        default:
            return false
        }
    }

    /// Tabbing or clicking away commits rather than stranding the field.
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextField()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // While typing, the field editor owns the keyboard and we never get
        // here. If a field is around but no longer focused it's stranded —
        // commit it and handle the key normally rather than going deaf.
        if textField != nil {
            guard window?.firstResponder === self else { return }
            commitTextField()
        }

        let chord = event.modifierFlags.intersection([.command, .control, .option])

        if chord == .command, Int(event.keyCode) == kVK_ANSI_Z || Int(event.keyCode) == kVK_Delete {
            undo()
            return
        }

        // Single-key shortcuts must not fire on chords, or ⌘C would wipe the
        // screen and ⌘T would switch tools.
        guard chord.isEmpty else { return super.keyDown(with: event) }

        switch Int(event.keyCode) {
        case kVK_Escape:
            clear()
            onDismiss?()

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
        case kVK_ANSI_H: prefs.tool = .highlighter

        case kVK_ANSI_S: prefs.spotlight.toggle()
        case kVK_ANSI_B: prefs.showToolbar.toggle()
        case kVK_ANSI_X: prefs.passThrough.toggle()

        // While the spotlight is up, the brackets size it — that's the thing
        // you're most likely reaching for.
        case kVK_ANSI_LeftBracket:
            if prefs.spotlight { prefs.spotlightRadius -= 20 } else { prefs.lineWidth -= 1 }
        case kVK_ANSI_RightBracket:
            if prefs.spotlight { prefs.spotlightRadius += 20 } else { prefs.lineWidth += 1 }
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

    /// Called when preferences change so the overlay tracks the active tool.
    func settingsChanged() {
        // Switching away from Text while typing would leave the editor live
        // under a toolbar that says otherwise.
        if prefs.tool != .text { commitTextField() }

        if prefs.autoFade != wasAutoFading {
            wasAutoFading = prefs.autoFade
            applyAutoFade()
        }

        syncSpotlightTimer()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Marks already on screen join or leave the fade when it's toggled —
    /// otherwise turning fade on strands them permanently.
    private func applyAutoFade() {
        let finishedAt = prefs.autoFade ? Date() : nil
        for index in marks.indices { marks[index].finishedAt = finishedAt }

        if prefs.autoFade {
            startFadeTimerIfNeeded()
        } else {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    func clear() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        marks.removeAll()
        inProgress = nil
        undoStack.removeAll()
        textField?.delegate = nil
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var window: OverlayWindow?
    private var overlay: OverlayView?
    private var toolbar: ToolbarPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var passThroughHotKeyRef: EventHotKeyRef?
    private var passThroughWasOn = false
    private var isDrawing = false

    private let prefs = Prefs.shared

    /// Marketing version and build, both stamped into Info.plist by `build.sh`
    /// from the current git tag.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        registerHotKey()

        prefs.onChange = { [weak self] in
            self?.syncMenuState()
            self?.toolbar?.syncSelection()
            self?.overlay?.settingsChanged()
            self?.applyPassThrough()
            self?.syncToolbarVisibility()
        }

        // Debug affordance: `ScreenBox --draw` opens draw mode immediately.
        if CommandLine.arguments.contains("--draw") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.toggleDrawing()
            }
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

        menu.addItem(submenu(title: "Spotlight Size", items: Prefs.spotlightRadiusChoices.enumerated().map { index, radius in
            item("\(Int(radius)) pt", #selector(pickSpotlightRadius), tag: index)
        }))

        let spotlight = NSMenuItem(title: "Spotlight", action: #selector(toggleSpotlight), keyEquivalent: "")
        spotlight.target = self
        spotlight.identifier = .init("spotlight")
        menu.addItem(spotlight)

        let passThrough = NSMenuItem(title: "Click Through  (⌃⌥⌘X)", action: #selector(togglePassThrough), keyEquivalent: "")
        passThrough.target = self
        passThrough.identifier = .init("passThrough")
        menu.addItem(passThrough)

        let cursor = NSMenuItem(title: "Keep Normal Cursor", action: #selector(toggleCursor), keyEquivalent: "")
        cursor.target = self
        cursor.identifier = .init("cursor")
        menu.addItem(cursor)

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
        for line in ["  P A R O T H — tool",
                     "  1–5 — colour",
                     "  S — spotlight",
                     "  X — click through",
                     "  B — show / hide the toolbar",
                     "  [ ] — thinner / thicker (spotlight size)",
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

        let version = NSMenuItem(title: "ScreenBox \(Self.versionString)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let about = NSMenuItem(title: "About ScreenBox", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.identifier = .init("about")
        menu.addItem(about)
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
        check("Spotlight Size", matching: Prefs.spotlightRadiusChoices.firstIndex(of: prefs.spotlightRadius))

        menu.items.first { $0.identifier?.rawValue == "fade" }?.state = prefs.autoFade ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "toolbar" }?.state = prefs.showToolbar ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "spotlight" }?.state = prefs.spotlight ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "cursor" }?.state = prefs.keepNormalCursor ? .on : .off
        menu.items.first { $0.identifier?.rawValue == "passThrough" }?.state = prefs.passThrough ? .on : .off
    }

    /// Click-through is only meaningful while drawing — grey it out otherwise,
    /// rather than accepting a click that quietly does nothing.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.identifier?.rawValue {
        case "passThrough":
            return isDrawing
        // The panel is an ordinary window, so the draw overlay (.screenSaver)
        // would bury it while taking key focus off the overlay — and under
        // click-through the only way back would be the global hotkey.
        case "about":
            return !isDrawing
        default:
            return true
        }
    }

    // MARK: Menu actions

    @objc private func pickColor(_ sender: NSMenuItem) { prefs.colorIndex = sender.tag }
    @objc private func pickLineWidth(_ sender: NSMenuItem) { prefs.lineWidth = Prefs.lineWidthChoices[sender.tag] }
    @objc private func pickCornerRadius(_ sender: NSMenuItem) { prefs.cornerRadius = Prefs.cornerRadiusChoices[sender.tag] }
    @objc private func toggleFade() { prefs.autoFade.toggle() }
    @objc private func toggleSpotlight() { prefs.spotlight.toggle() }
    @objc private func toggleCursor() { prefs.keepNormalCursor.toggle() }
    @objc private func pickSpotlightRadius(_ sender: NSMenuItem) {
        prefs.spotlightRadius = Prefs.spotlightRadiusChoices[sender.tag]
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        let choice = Prefs.speedChoices[sender.tag]
        prefs.holdDuration = choice.1
        prefs.fadeDuration = choice.2
    }

    @objc private func toggleToolbar() {
        // The panel follows from `onChange` → `syncToolbarVisibility`, so this
        // and the `B` key take the same path.
        prefs.showToolbar.toggle()
    }

    /// Brings the panel in line with the preference, from wherever it changed —
    /// the menu item, the `B` key, or a write from anywhere else.
    private func syncToolbarVisibility() {
        guard isDrawing else { return }
        if prefs.showToolbar {
            if toolbar == nil { showToolbar() }
        } else if toolbar != nil {
            hideToolbar()
        }
    }

    /// The standard AppKit About panel: icon, name, version and build from
    /// Info.plist, copyright, plus the repo link below.
    ///
    /// A menu bar app has nowhere else to put attribution — there's no main
    /// window and no app menu — so this is it.
    @objc private func showAbout() {
        let link = "https://github.com/Orva-Studio/screenbox"
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ]
        // Boxing the Optional straight into the dictionary would hand AppKit an
        // `Optional<URL>` it can't act on, and the link would draw but not open.
        if let url = URL(string: link) { attributes[.link] = url }
        let credits = NSMutableAttributedString(string: link, attributes: attributes)
        credits.addAttribute(.paragraphStyle, value: {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            return style
        }(), range: NSRange(location: 0, length: credits.length))

        // Without this the panel opens behind whatever is frontmost — an
        // accessory app isn't active just because its menu was clicked.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Global hotkey (Carbon — no Accessibility permission needed)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            // Which hotkey fired — both land in this one handler.
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)

            DispatchQueue.main.async {
                switch pressed.id {
                case 2: delegate.togglePassThrough()
                default: delegate.toggleDrawing()
                }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let signature = OSType(0x5342_4F58) // 'SBOX'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)

        RegisterEventHotKey(UInt32(kVK_ANSI_B), modifiers,
                            EventHotKeyID(signature: signature, id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        // Pass-through hands every click to the app underneath, including the
        // ones that would turn it off again — so it needs a way out that works
        // when ScreenBox isn't the active app.
        RegisterEventHotKey(UInt32(kVK_ANSI_X), modifiers,
                            EventHotKeyID(signature: signature, id: 2),
                            GetApplicationEventTarget(), 0, &passThroughHotKeyRef)
    }

    // MARK: Drawing mode

    @objc func toggleDrawing() {
        isDrawing ? endDrawing() : beginDrawing()
    }

    /// Only meaningful while drawing — outside it every click already passes
    /// through, and leaving the flag set would strand the next session.
    @objc func togglePassThrough() {
        guard isDrawing else { return }
        prefs.passThrough.toggle()
    }

    /// Marks stay visible either way; only mouse handling changes.
    private func applyPassThrough() {
        window?.ignoresMouseEvents = prefs.passThrough
        setIcon(drawing: isDrawing)

        let wasPassingThrough = passThroughWasOn
        passThroughWasOn = prefs.passThrough

        // A text field open when clicks start passing through is stranded: you
        // can't type into it (keys go to the app below once you click there)
        // and you can't click it either. Commit it on the way in.
        if !wasPassingThrough, prefs.passThrough {
            overlay?.endTextEntry()
        }

        // Turning it off from the toolbar (a non-activating panel) or the global
        // hotkey leaves whatever you clicked through to still frontmost, so the
        // overlay wouldn't see a keystroke — take focus back explicitly. Only on
        // the way out, so an ordinary colour change never steals focus.
        if wasPassingThrough, !prefs.passThrough, isDrawing, let window, let overlay {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(overlay)
        }
    }

    private func beginDrawing() {
        prefs.passThrough = false // never open a session that can't be clicked

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
        window.acceptsMouseMovedEvents = true // the spotlight follows the pointer

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
        // No screen at all means nothing to float the bar over — with the
        // overlay itself already gone, force-unwrapping here would just crash.
        guard let target = screen ?? window?.screen ?? NSScreen.main else { return }

        let panel = toolbar ?? ToolbarPanel()
        panel.onClose = { [weak self] in self?.endDrawing() }
        panel.onClear = { [weak self] in self?.overlay?.clear() }
        panel.position(on: target)
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
        // Before clearing the flag, so applyPassThrough doesn't yank focus back
        // to an overlay we're in the middle of tearing down.
        isDrawing = false
        prefs.passThrough = false // don't leave the menu claiming a mode we've left
        hideToolbar()
        overlay?.clear()
        window?.orderOut(nil)
        window = nil
        overlay = nil
        isDrawing = false
        setIcon(drawing: false)
    }

    private func setIcon(drawing: Bool) {
        // Pass-through gets its own icon: with clicks going straight through,
        // the menu bar is the only clue that draw mode is still on at all.
        let passing = drawing && prefs.passThrough
        let image = AppDelegate.menuBarIcon(drawing: drawing, passThrough: passing)
        image.isTemplate = true // let AppKit tint it for light/dark and highlight
        image.accessibilityDescription = passing ? "ScreenBox — clicks passing through"
            : drawing ? "ScreenBox — drawing" : "ScreenBox"
        statusItem.button?.image = image
    }

    /// The app mark — a highlighter drawing a box — at menu bar size.
    ///
    /// Drawn rather than shipped as an asset: an 18pt glyph downscaled from
    /// artwork loses the gap between pen and box, which is the whole read.
    private static func menuBarIcon(drawing: Bool, passThrough: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            let box = CGPath(roundedRect: CGRect(x: 0.9, y: 1.2, width: 11.2, height: 7.8),
                             cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)

            // The marker, built pointing straight up with its nib on the origin,
            // then swung to 45° and set down on the box's top-left corner.
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: -1.15, y: 0))          // nib
            marker.addLine(to: CGPoint(x: 1.15, y: 0))
            marker.addLine(to: CGPoint(x: 2.15, y: 2.1))
            marker.addLine(to: CGPoint(x: -2.15, y: 2.1))
            marker.closeSubpath()
            marker.addRoundedRect(in: CGRect(x: -2.15, y: 2.4, width: 4.3, height: 5.6),
                                  cornerWidth: 1.3, cornerHeight: 1.3)
            var place = CGAffineTransform(translationX: 8.0, y: 9.1).rotated(by: -.pi / 4)
            let pen = marker.copy(using: &place)!

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            // Drawing mode fills the box, so a glance at the menu bar says
            // whether the overlay is live — and breaks it into dashes while
            // clicks are passing through, which is the state you can't see.
            ctx.addPath(box)
            switch (drawing, passThrough) {
            case (true, false):
                ctx.fillPath()
            case (true, true):
                ctx.setLineWidth(1.7)
                ctx.setLineDash(phase: 0, lengths: [2.4, 1.8])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            default:
                ctx.setLineWidth(1.7)
                ctx.strokePath()
            }

            // Knock a hairline of clearance out from under the pen, or the two
            // shapes merge into one blob at this size.
            ctx.setBlendMode(.clear)
            ctx.addPath(pen.copy(strokingWithWidth: 2.2, lineCap: .round, lineJoin: .round,
                                 miterLimit: 10))
            ctx.fillPath()

            ctx.setBlendMode(.normal)
            ctx.addPath(pen)
            ctx.fillPath()
            return true
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
