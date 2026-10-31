import AppKit

@MainActor
final class PreferencesController: NSObject {
    var onShortcutChange: ((ShortcutChoice) -> Bool)?
    var onTrackpadShortcutChange: ((Bool) -> Void)?
    var onStyleChange: ((AnnotationStyle) -> Void)?
    var onBorderColorChange: ((NSColor) -> Void)?
    private var window: NSWindow?
    private var paletteButtons: [GradientSwatchButton] = []
    private let sunsetStrengthSlider = NSSlider(value: 45, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let sunsetStrengthValue = NSTextField(labelWithString: "45%")
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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Point Settings"
        window.level = level
        window.center()
        window.isReleasedWhenClosed = false

        sunsetStrengthValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sunsetStrengthValue.alignment = .right
        sunsetStrengthValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let strengthRow = NSStackView(views: [sunsetStrengthSlider, sunsetStrengthValue])
        strengthRow.orientation = .horizontal
        strengthRow.spacing = 8
        paletteButtons = SunsetWashPalette.allCases.map { palette in
            let button = GradientSwatchButton(palette: palette)
            button.target = self
            button.action = #selector(paletteChanged(_:))
            return button
        }
        updatePaletteSelection()
        let paletteRow = NSStackView(views: paletteButtons)
        paletteRow.orientation = .horizontal
        paletteRow.spacing = 12
        let grid = NSGridView(views: [
            [label("Capture shortcut"), shortcutPopup],
            [label("Trackpad shortcut"), trackpadShortcutCheckbox],
            [label("Annotation color"), colorWell],
            [label("Glass border color"), borderColorWell],
            [label("Line width"), widthSlider],
            [label("Default text size"), fontSlider],
            [label("Backdrop"), backdropCheckbox],
            [label("Backdrop margin"), backdropMarginSlider],
            [label("Color mood"), paletteRow],
            [label("Overlay strength"), strengthRow],
            [label("Saving"), label("Clipboard only by default; ⌘S asks for a PNG destination")],
        ])
        grid.rowSpacing = 12
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

        sunsetStrengthSlider.doubleValue = Double(SunsetWashStrength.preferred() * 100)
        sunsetStrengthSlider.target = self
        sunsetStrengthSlider.action = #selector(sunsetStrengthChanged)
        sunsetStrengthSlider.isContinuous = true
        sunsetStrengthSlider.setAccessibilityLabel("Overlay strength")
        updateSunsetStrength()

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

    @objc private func paletteChanged(_ sender: GradientSwatchButton) {
        sender.palette.remember()
        updatePaletteSelection()
    }

    private func updatePaletteSelection() {
        let selected = SunsetWashPalette.preferred()
        for button in paletteButtons {
            button.state = button.palette == selected ? .on : .off
            button.needsDisplay = true
        }
    }

    @objc private func sunsetStrengthChanged() {
        SunsetWashStrength.remember(CGFloat(sunsetStrengthSlider.doubleValue / 100))
        updateSunsetStrength()
    }

    private func updateSunsetStrength() {
        sunsetStrengthValue.stringValue = "\(Int(sunsetStrengthSlider.doubleValue.rounded()))%"
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

@MainActor
private final class GradientSwatchButton: NSButton {
    let palette: SunsetWashPalette

    init(palette: SunsetWashPalette) {
        self.palette = palette
        super.init(frame: .zero)
        title = palette.title
        setButtonType(.toggle)
        isBordered = false
        setAccessibilityLabel(palette.title)
        toolTip = palette.title
        widthAnchor.constraint(equalToConstant: 82).isActive = true
        heightAnchor.constraint(equalToConstant: 54).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = NSRect(x: 4, y: 22, width: bounds.width - 8, height: 28)
        let path = NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8)
        NSGradient(colors: palette.colors)?.draw(in: path, angle: -35)
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: -2, dy: -2), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            ring.stroke()
            let check = "✓"
            check.draw(at: NSPoint(x: swatch.maxX - 19, y: swatch.midY - 9), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white,
            ])
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: state == .on ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 2), withAttributes: attributes)
    }
}
