import AppKit

@MainActor
final class PreferencesController: NSObject {
    var onShortcutChange: ((ShortcutChoice) -> Bool)?
    var onTrackpadShortcutChange: ((Bool) -> Void)?
    var onStyleChange: ((AnnotationStyle) -> Void)?
    var onBorderColorChange: ((NSColor) -> Void)?
    private var window: NSWindow?
    private let shortcutPopup = NSPopUpButton()
    private let colorWell = NSColorWell()
    private let borderColorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 2, maxValue: 12, target: nil, action: nil)
    private let fontSlider = NSSlider(value: 15, minValue: 11, maxValue: 28, target: nil, action: nil)
    private let backdropCheckbox = NSButton(checkboxWithTitle: "Show selected background around captures", target: nil, action: nil)
    private let backdropMarginSlider = NSSlider(value: 48, minValue: 32, maxValue: 80, target: nil, action: nil)
    private let trackpadShortcutCheckbox = NSButton(
        checkboxWithTitle: "Three-finger double-tap to capture",
        target: nil,
        action: nil
    )

    func show(level: NSWindow.Level = .normal) {
        if let window {
            window.level = level
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Point Settings"
        window.level = level
        window.center()
        window.isReleasedWhenClosed = false

        let grid = NSGridView(views: [
            [label("Capture shortcut"), shortcutPopup],
            [label("Trackpad shortcut"), trackpadShortcutCheckbox],
            [label("Annotation color"), colorWell],
            [label("Glass border color"), borderColorWell],
            [label("Line width"), widthSlider],
            [label("Default text size"), fontSlider],
            [label("Backdrop"), backdropCheckbox],
            [label("Backdrop margin"), backdropMarginSlider],
            [label("Saving"), label("Clipboard only by default; ⌘S asks for a PNG destination")],
        ])
        grid.rowSpacing = 16
        grid.columnSpacing = 18
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        window.contentView = NSView()
        window.contentView?.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            grid.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])

        for choice in ShortcutChoice.allCases { shortcutPopup.addItem(withTitle: choice.title) }
        shortcutPopup.selectItem(at: ShortcutChoice.preferred.rawValue)
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged)
        trackpadShortcutCheckbox.state = TrackpadShortcutPreference.isEnabled ? .on : .off
        trackpadShortcutCheckbox.target = self
        trackpadShortcutCheckbox.action = #selector(trackpadShortcutChanged)
        let style = AnnotationStyle.preferred
        colorWell.color = style.color
        widthSlider.doubleValue = style.lineWidth
        fontSlider.doubleValue = style.fontSize
        let appearance = CaptureAppearance.preferred
        borderColorWell.color = appearance.borderColor
        backdropCheckbox.state = appearance.usesDesktopBackdrop ? .on : .off
        backdropMarginSlider.doubleValue = appearance.backdropMargin
        backdropMarginSlider.isEnabled = appearance.usesDesktopBackdrop
        colorWell.target = self; colorWell.action = #selector(styleChanged)
        borderColorWell.target = self; borderColorWell.action = #selector(borderColorChanged)
        widthSlider.target = self; widthSlider.action = #selector(styleChanged)
        fontSlider.target = self; fontSlider.action = #selector(styleChanged)
        colorWell.setAccessibilityLabel("Annotation color")
        borderColorWell.setAccessibilityLabel("Glass border color")
        widthSlider.setAccessibilityLabel("Default arrow size")
        fontSlider.setAccessibilityLabel("Default text annotation size")
        backdropCheckbox.target = self; backdropCheckbox.action = #selector(backdropChanged)
        backdropMarginSlider.target = self; backdropMarginSlider.action = #selector(backdropChanged)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.maximumNumberOfLines = 2
        return field
    }

    @objc private func shortcutChanged() {
        guard let choice = ShortcutChoice(rawValue: shortcutPopup.indexOfSelectedItem) else { return }
        if onShortcutChange?(choice) == true {
            UserDefaults.standard.set(choice.rawValue, forKey: "shortcutChoice")
        } else {
            shortcutPopup.selectItem(at: ShortcutChoice.preferred.rawValue)
        }
    }

    @objc private func trackpadShortcutChanged() {
        let enabled = trackpadShortcutCheckbox.state == .on
        UserDefaults.standard.set(enabled, forKey: TrackpadShortcutPreference.defaultsKey)
        onTrackpadShortcutChange?(enabled)
    }

    @objc private func styleChanged() {
        let color = colorWell.color.usingColorSpace(.sRGB) ?? colorWell.color
        UserDefaults.standard.set(color.redComponent, forKey: "annotationColorRed")
        UserDefaults.standard.set(color.greenComponent, forKey: "annotationColorGreen")
        UserDefaults.standard.set(color.blueComponent, forKey: "annotationColorBlue")
        UserDefaults.standard.set(widthSlider.doubleValue, forKey: "annotationLineWidth")
        UserDefaults.standard.set(fontSlider.doubleValue, forKey: "annotationFontSize")
        onStyleChange?(
            AnnotationStyle(
                color: color,
                lineWidth: CGFloat(widthSlider.doubleValue),
                fontSize: CGFloat(fontSlider.doubleValue)
            )
        )
    }

    @objc private func borderColorChanged() {
        let color = borderColorWell.color.usingColorSpace(.sRGB) ?? borderColorWell.color
        UserDefaults.standard.set(color.redComponent, forKey: "borderColorRed")
        UserDefaults.standard.set(color.greenComponent, forKey: "borderColorGreen")
        UserDefaults.standard.set(color.blueComponent, forKey: "borderColorBlue")
        onBorderColorChange?(color)
    }

    @objc private func backdropChanged() {
        let enabled = backdropCheckbox.state == .on
        backdropMarginSlider.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "usesDesktopBackdrop")
        UserDefaults.standard.set(backdropMarginSlider.doubleValue, forKey: "backdropMargin")
    }
}
