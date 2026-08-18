import Cocoa

/// The keyboard reference, and the small window that shows it.
///
/// This is the single source of truth for what the docs claim: the panel reads
/// it, and the README table should match. Adding a shortcut means adding a row
/// here as well as handling the key in `OverlayView.keyDown`.
enum Shortcuts {
    /// (keys, what they do). An empty `keys` marks a section heading.
    static let rows: [(keys: String, action: String)] = [
        ("", "Anywhere"),
        ("⌃⌥⌘B", "Start or stop draw mode"),
        ("⌃⌥⌘X", "Click through — hand clicks to the app underneath"),

        ("", "While drawing"),
        ("P A R O T H", "Freehand, arrow, rectangle, ellipse, text, highlighter"),
        ("1 – 5", "Blue, red, green, yellow, purple"),
        ("S", "Turn the spotlight on or off"),
        ("X", "Click through"),
        ("B", "Show or hide the toolbar"),
        ("[  ]", "Thinner or thicker stroke — spotlight size, while it's up"),
        ("−  =", "Less or more corner radius"),
        ("F", "Fade marks out automatically, on or off"),
        ("⌘Z", "Undo the last mark"),
        ("C", "Clear every mark, stay in draw mode"),
        ("esc", "Clear and leave draw mode"),
    ]
}

/// A plain reference window listing `Shortcuts.rows`.
///
/// Deliberately not a preferences window: nothing here is editable, so it needs
/// no tabs, no toolbar, and no settings framework — it's the About panel's
/// sibling, opened from the menu and closed when you're done.
final class ShortcutsWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Keyboard Shortcuts"
        isReleasedWhenClosed = false // the app delegate keeps and reuses one

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 18
        grid.rowSpacing = 7
        grid.column(at: 0).xPlacement = .trailing

        for (index, row) in Shortcuts.rows.enumerated() {
            // A heading spans both columns, with air above it — except the
            // first, which would leave a gap under the title bar.
            guard !row.keys.isEmpty else {
                let heading = label(row.action, weight: .semibold, color: .secondaryLabelColor)
                let gridRow = grid.addRow(with: [heading])
                gridRow.mergeCells(in: NSRange(location: 0, length: 2))
                // The merged cell would otherwise inherit the key column's
                // trailing alignment and strand the heading on the right.
                gridRow.cell(at: 0).xPlacement = .leading
                if index > 0 { gridRow.topPadding = 14 }
                continue
            }

            grid.addRow(with: [
                label(row.keys, weight: .medium, color: .labelColor, monospaced: true),
                label(row.action, weight: .regular, color: .labelColor),
            ])
        }

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        contentView = content

        // The grid decides the height; letting the window size itself keeps the
        // two in step when a row is added.
        setContentSize(content.fittingSize)
    }

    private func label(_ text: String,
                       weight: NSFont.Weight,
                       color: NSColor,
                       monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        let size = NSFont.systemFontSize
        // Keys line up in a column, so they want fixed-width digits and letters.
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
}
