import Cocoa

/// Everything the user can tweak, persisted to UserDefaults.
///
/// Adding a new preference means: add a `Key` case, add a stored property using
/// the `@Persisted` pattern below, register its default in `registerDefaults`,
/// and (optionally) expose it in the menu. Nothing else needs to change —
/// `onChange` fires for every write, so the live overlay picks it up.
final class Prefs {
    static let shared = Prefs()

    private enum Key: String {
        case colorIndex, lineWidth, cornerRadius, autoFade, holdDuration, fadeDuration
        case tool, toolbarX, toolbarY, showToolbar
    }

    /// Fired after any preference changes, so the UI and overlay can resync.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.colorIndex.rawValue: 3,        // yellow
            Key.lineWidth.rawValue: 4.0,
            Key.cornerRadius.rawValue: 0.0,
            Key.autoFade.rawValue: true,
            Key.holdDuration.rawValue: 0.15,
            Key.fadeDuration.rawValue: 0.2,
            Key.tool.rawValue: Tool.rectangle.rawValue,
            Key.showToolbar.rawValue: true,
        ])
    }

    // MARK: Tool

    var tool: Tool {
        get { Tool(rawValue: defaults.integer(forKey: Key.tool.rawValue)) ?? .rectangle }
        set { write(Key.tool, newValue.rawValue) }
    }

    /// Whether the floating toolbar appears with the overlay.
    var showToolbar: Bool {
        get { defaults.bool(forKey: Key.showToolbar.rawValue) }
        set { write(Key.showToolbar, newValue) }
    }

    /// Last toolbar position, so it reopens where you left it.
    var toolbarOrigin: NSPoint? {
        get {
            guard defaults.object(forKey: Key.toolbarX.rawValue) != nil else { return nil }
            return NSPoint(x: defaults.double(forKey: Key.toolbarX.rawValue),
                           y: defaults.double(forKey: Key.toolbarY.rawValue))
        }
        set {
            guard let newValue else { return }
            defaults.set(newValue.x, forKey: Key.toolbarX.rawValue)
            defaults.set(newValue.y, forKey: Key.toolbarY.rawValue)
        }
    }

    // MARK: Palette

    /// Selectable colors, in the order the 1–4 keys pick them.
    static let palette: [(name: String, color: NSColor)] = [
        ("Blue", .systemBlue),
        ("Red", .systemRed),
        ("Green", .systemGreen),
        ("Yellow", .systemYellow),
        ("Purple", .systemPurple),
    ]

    var colorIndex: Int {
        get { min(max(defaults.integer(forKey: Key.colorIndex.rawValue), 0), Prefs.palette.count - 1) }
        set { write(Key.colorIndex, newValue) }
    }

    var color: NSColor { Prefs.palette[colorIndex].color }

    // MARK: Box appearance

    /// Stroke thickness in points.
    var lineWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.lineWidth.rawValue)) }
        set { write(Key.lineWidth, Double(min(max(newValue, 1), 16))) }
    }

    /// Corner radius in points. 0 is a sharp rectangle.
    var cornerRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.cornerRadius.rawValue)) }
        set { write(Key.cornerRadius, Double(min(max(newValue, 0), 60))) }
    }

    // MARK: Fade

    var autoFade: Bool {
        get { defaults.bool(forKey: Key.autoFade.rawValue) }
        set { write(Key.autoFade, newValue) }
    }

    /// Seconds a finished box stays at full strength before fading.
    var holdDuration: TimeInterval {
        get { defaults.double(forKey: Key.holdDuration.rawValue) }
        set { write(Key.holdDuration, max(newValue, 0)) }
    }

    /// Seconds the fade itself takes.
    var fadeDuration: TimeInterval {
        get { defaults.double(forKey: Key.fadeDuration.rawValue) }
        set { write(Key.fadeDuration, max(newValue, 0.05)) }
    }

    // MARK: Presets offered in the menu

    static let lineWidthChoices: [CGFloat] = [2, 3, 4, 6, 8, 12]
    static let cornerRadiusChoices: [CGFloat] = [0, 4, 8, 16, 28]
    /// (label, hold, fade)
    static let speedChoices: [(String, TimeInterval, TimeInterval)] = [
        ("Instant", 0.0, 0.15),
        ("Fast", 0.15, 0.2),
        ("Medium", 0.35, 0.4),
        ("Slow", 1.0, 0.8),
    ]

    private func write(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
        onChange?()
    }
}
