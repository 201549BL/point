import AppKit

@MainActor
final class PreferencesController: NSObject, NSWindowDelegate {
    var onShortcutChange: ((ShortcutChoice) -> Bool)?
    var onTrackpadShortcutChange: ((Bool) -> Void)?
    var onStyleChange: ((AnnotationStyle) -> Void)?
    var onBorderColorChange: ((NSColor) -> Void)?

    private var window: NSWindow?
    private var paneButtons: [SettingsPaneButton] = []
    private var paneViews: [SettingsPane: NSView] = [:]
    private var previews: [SettingsPreviewView] = []
    private var overlayOptionsHover: SettingsHoverView?
    private var paletteButtons: [GradientSwatchButton] = []
    private var hoveredPalette: SunsetWashPalette?
    private let shortcutPopup = NSPopUpButton()
    private let trackpadSwitch = NSSwitch()
    private let colorWell = NSColorWell()
    private let borderColorWell = NSColorWell()
    private let widthSlider = NSSlider(value: 4, minValue: 2, maxValue: 12, target: nil, action: nil)
    private let fontSlider = NSSlider(value: 15, minValue: 11, maxValue: 28, target: nil, action: nil)
    private let backdropSwitch = NSSwitch()
    private let backdropMarginSlider = NSSlider(value: 48, minValue: 32, maxValue: 80, target: nil, action: nil)
    private let sunsetStrengthSlider = NSSlider(value: 45, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let widthValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let backdropMarginValue = NSTextField(labelWithString: "")
    private let sunsetStrengthValue = NSTextField(labelWithString: "")

    func show(level: NSWindow.Level = .normal) {
        if window == nil { buildWindow() }
        synchronizeControls()
        window?.level = level
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
        overlayOptionsHover?.updateHoverFromPointer()
        updatePaletteHoverFromPointer()
    }

    private func buildWindow() {
        configureControls()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1080, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("point.settings")
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        self.window = window

        let root = SettingsSurfaceView()
        window.contentView = root
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        paneButtons = SettingsPane.allCases.map { pane in
            let button = SettingsPaneButton(pane: pane)
            button.target = self
            button.action = #selector(paneChanged(_:))
            return button
        }
        let navigation = stack(paneButtons, spacing: 3)
        sidebar.addSubview(navigation)
        let links = NSStackView(views: [
            SettingsLinkButton(title: "GitHub", url: URL(string: "https://github.com/201549BL/point")!,
                               logo: NSImage(named: "GitHubMark")),
            SettingsLinkButton(title: "Website", url: URL(string: "https://201549bl.github.io/point/")!,
                               logo: NSApplication.shared.applicationIconImage),
        ])
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 14
        links.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(links)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        for pane in SettingsPane.allCases {
            let view = makePane(pane)
            paneViews[pane] = view
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 216),
            navigation.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 56),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            links.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            links.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -18),
            links.topAnchor.constraint(greaterThanOrEqualTo: navigation.bottomAnchor, constant: 12),
            links.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            host.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 58),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        let selected = UserDefaults.standard.string(forKey: "settingsSelectedPane")
            .flatMap(SettingsPane.init(rawValue:)) ?? .capture
        selectPane(selected)
        window.center()
    }

    private func configureControls() {
        for choice in ShortcutChoice.allCases { shortcutPopup.addItem(withTitle: choice.title) }
        configure(shortcutPopup, id: "shortcut", label: "Capture shortcut", action: #selector(shortcutChanged))
        configure(trackpadSwitch, id: "trackpad", label: "Three-finger double-tap to capture", action: #selector(trackpadShortcutChanged))
        configure(colorWell, id: "annotationColor", label: "Annotation color", action: #selector(styleChanged))
        configure(borderColorWell, id: "borderColor", label: "Glass border color", action: #selector(borderColorChanged))
        configure(widthSlider, id: "arrowSize", label: "Default arrow size", action: #selector(styleChanged))
        configure(fontSlider, id: "textSize", label: "Default text annotation size", action: #selector(styleChanged))
        configure(backdropSwitch, id: "backdrop", label: "Include background", action: #selector(backdropChanged))
        configure(backdropMarginSlider, id: "backdropMargin", label: "Background margin", action: #selector(backdropChanged))
        configure(sunsetStrengthSlider, id: "overlayStrength", label: "Overlay strength", action: #selector(sunsetStrengthChanged))
        for slider in [widthSlider, fontSlider, backdropMarginSlider, sunsetStrengthSlider] {
            slider.isContinuous = true
        }
        for well in [colorWell, borderColorWell] {
            well.colorWellStyle = .minimal
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        paletteButtons = SunsetWashPalette.allCases.map { palette in
            let button = GradientSwatchButton(palette: palette)
            button.target = self
            button.action = #selector(paletteChanged(_:))
            button.onHoverChange = { [weak self] hovering in
                self?.paletteHoverChanged(palette, hovering: hovering)
            }
            return button
        }
    }

    private func configure(_ control: NSControl, id: String, label: String, action: Selector) {
        control.identifier = NSUserInterfaceItemIdentifier("settings.\(id)")
        control.setAccessibilityLabel(label)
        control.target = self
        control.action = action
        control.controlSize = .regular
        control.translatesAutoresizingMaskIntoConstraints = false
    }

    private func synchronizeControls() {
        shortcutPopup.selectItem(at: ShortcutChoice.preferred.rawValue)
        trackpadSwitch.state = TrackpadShortcutPreference.isEnabled ? .on : .off
        let style = AnnotationStyle.preferred
        colorWell.color = style.color
        widthSlider.doubleValue = style.lineWidth
        fontSlider.doubleValue = style.fontSize
        let appearance = CaptureAppearance.preferred
        borderColorWell.color = appearance.borderColor
        backdropSwitch.state = appearance.usesDesktopBackdrop ? .on : .off
        backdropMarginSlider.doubleValue = appearance.backdropMargin
        sunsetStrengthSlider.doubleValue = Double(SunsetWashStrength.preferred() * 100)
        updatePaletteSelection()
        updateValues()
    }

    private func makePane(_ pane: SettingsPane) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.identifier = NSUserInterfaceItemIdentifier("settings.content.\(pane.rawValue)")
        let heading = text(pane.title, size: 22, weight: .bold)
        heading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heading)

        let controls: NSView
        switch pane {
        case .capture:
            controls = section("Shortcuts", rows: [
                settingRow("Keyboard shortcut", control: shortcutPopup),
                settingRow("Three-finger double-tap", control: trackpadSwitch),
            ])
        case .appearance:
            controls = section("Screenshot", rows: [
                settingRow("Include background", control: backdropSwitch, height: 40),
                sliderRow("Margin", slider: backdropMarginSlider, value: backdropMarginValue, height: 40),
                settingRow("Border color", control: borderColorWell, height: 40),
            ])
        case .annotations:
            controls = section("Defaults", rows: [
                settingRow("Color", control: colorWell),
                sliderRow("Arrow size", slider: widthSlider, value: widthValue),
                sliderRow("Text size", slider: fontSlider, value: fontValue),
            ])
        }
        var contents = [controls]
        var preview: SettingsPreviewView?
        if pane != .capture {
            let kind: SettingsPreviewView.Kind = pane == .appearance ? .appearance : .annotations
            let panePreview = SettingsPreviewView(kind: kind)
            previews.append(panePreview)
            panePreview.translatesAutoresizingMaskIntoConstraints = false
            panePreview.heightAnchor.constraint(equalToConstant: 300).isActive = true
            preview = panePreview
        }
        if pane == .appearance {
            let paletteRow = NSStackView(views: paletteButtons)
            paletteRow.orientation = .horizontal
            paletteRow.distribution = .fillEqually
            paletteRow.spacing = 10
            paletteRow.translatesAutoresizingMaskIntoConstraints = false
            paletteRow.widthAnchor.constraint(equalToConstant: 258).isActive = true
            let overlaySection = section("Selection overlay", rows: [
                settingRow("Color", control: paletteRow, height: 66),
                sliderRow("Strength", slider: sunsetStrengthSlider, value: sunsetStrengthValue, height: 40),
            ])
            let hover = SettingsHoverView(content: overlaySection)
            hover.identifier = NSUserInterfaceItemIdentifier("settings.overlayOptions")
            hover.onHoverChange = { [weak self, weak preview] visible in
                preview?.setSelectionOverlayVisible(visible)
                if !visible { self?.setHoveredPalette(nil) }
            }
            overlayOptionsHover = hover
            contents.append(hover)
        }
        let content: NSStackView
        if let preview {
            let settings = stack(contents, spacing: 24)
            settings.widthAnchor.constraint(equalToConstant: 430).isActive = true
            content = NSStackView(views: [settings, preview])
            content.orientation = .horizontal
            content.alignment = .top
            content.spacing = 24
            content.translatesAutoresizingMaskIntoConstraints = false
        } else {
            content = stack(contents, spacing: 20)
        }
        view.addSubview(content)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heading.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])
        return view
    }

    private func section(_ title: String, rows: [NSView]) -> NSStackView {
        stack([text(title, size: 12, weight: .semibold, color: .secondaryLabelColor), group(rows: rows)], spacing: 8)
    }

    private func group(rows: [NSView]) -> NSView {
        var contents: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { contents.append(inset(separator(), horizontal: 14, vertical: 0)) }
            contents.append(row)
        }
        let panel = SettingsSurfaceView(isPanel: true)
        let rows = stack(contents, spacing: 0)
        panel.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            rows.topAnchor.constraint(equalTo: panel.topAnchor),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    private func settingRow(_ title: String, control: NSView, height: CGFloat = 48) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = text(title, size: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleLabel)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)
        (control as? NSControl)?.setAccessibilityTitleUIElement(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: height),
        ])
        return row
    }

    private func sliderRow(_ title: String, slider: NSSlider, value: NSTextField, height: CGFloat = 48) -> NSView {
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.identifier = NSUserInterfaceItemIdentifier("\(slider.identifier!.rawValue).value")
        value.setAccessibilityLabel("\(title) value")
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let range = NSStackView(views: [slider, value])
        range.orientation = .horizontal
        range.spacing = 10
        range.translatesAutoresizingMaskIntoConstraints = false
        range.widthAnchor.constraint(equalToConstant: 270).isActive = true
        return settingRow(title, control: range, height: height)
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func inset(_ content: NSView, horizontal: CGFloat = 13, vertical: CGFloat = 12) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -vertical),
        ])
        return view
    }

    private func text(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: title)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func selectPane(_ pane: SettingsPane) {
        if pane != .appearance {
            overlayOptionsHover?.resetHover()
            setHoveredPalette(nil)
        }
        colorWell.deactivate()
        borderColorWell.deactivate()
        for button in paneButtons { button.state = button.pane == pane ? .on : .off }
        for (key, view) in paneViews { view.isHidden = key != pane }
        window?.title = pane.title
        refreshPreviews()
        updatePreviewVisibility()
        if pane == .appearance {
            overlayOptionsHover?.updateHoverFromPointer()
            updatePaletteHoverFromPointer()
        }
    }

    func windowWillClose(_ notification: Notification) {
        overlayOptionsHover?.resetHover()
        setHoveredPalette(nil)
        for preview in previews { preview.setPreviewVisible(false) }
        colorWell.deactivate()
        borderColorWell.deactivate()
    }

    func windowDidResignKey(_ notification: Notification) {
        overlayOptionsHover?.resetHover()
        setHoveredPalette(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updatePreviewVisibility()
        overlayOptionsHover?.updateHoverFromPointer()
        updatePaletteHoverFromPointer()
    }

    @objc private func paneChanged(_ sender: SettingsPaneButton) {
        selectPane(sender.pane)
        UserDefaults.standard.set(sender.pane.rawValue, forKey: "settingsSelectedPane")
    }

    @objc private func paletteChanged(_ sender: GradientSwatchButton) {
        sender.palette.remember()
        updatePaletteSelection()
        refreshPreviews()
    }

    private func paletteHoverChanged(_ palette: SunsetWashPalette, hovering: Bool) {
        if hovering {
            setHoveredPalette(palette)
        } else if hoveredPalette == palette {
            setHoveredPalette(nil)
        }
    }

    private func setHoveredPalette(_ palette: SunsetWashPalette?) {
        guard hoveredPalette != palette else { return }
        hoveredPalette = palette
        for preview in previews { preview.setSelectionOverlayPalette(palette) }
    }

    private func updatePaletteHoverFromPointer() {
        guard let window, window.isVisible, window.isKeyWindow,
              paneViews[.appearance]?.isHidden == false else {
            setHoveredPalette(nil)
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        let hovered = paletteButtons.first { $0.bounds.contains($0.convert(location, from: nil)) }
        setHoveredPalette(hovered?.palette)
    }

    private func updatePaletteSelection() {
        let selected = SunsetWashPalette.preferred()
        for button in paletteButtons {
            button.state = button.palette == selected ? .on : .off
            button.needsDisplay = true
        }
    }

    private func updateValues() {
        widthValue.stringValue = "\(Int(widthSlider.doubleValue.rounded())) pt"
        fontValue.stringValue = "\(Int(fontSlider.doubleValue.rounded())) pt"
        backdropMarginValue.stringValue = "\(Int(backdropMarginSlider.doubleValue.rounded())) pt"
        sunsetStrengthValue.stringValue = "\(Int(sunsetStrengthSlider.doubleValue.rounded()))%"
        backdropMarginSlider.isEnabled = backdropSwitch.state == .on
        backdropMarginValue.textColor = backdropMarginSlider.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        refreshPreviews()
    }

    private func refreshPreviews() {
        for preview in previews where !preview.isHiddenOrHasHiddenAncestor { preview.refresh() }
    }

    private func updatePreviewVisibility() {
        for preview in previews {
            preview.setPreviewVisible(window?.isVisible == true && !preview.isHiddenOrHasHiddenAncestor)
        }
    }

    @objc private func sunsetStrengthChanged() {
        SunsetWashStrength.remember(CGFloat(sunsetStrengthSlider.doubleValue / 100))
        updateValues()
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
        let enabled = trackpadSwitch.state == .on
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
        onStyleChange?(AnnotationStyle(color: color, lineWidth: CGFloat(widthSlider.doubleValue), fontSize: CGFloat(fontSlider.doubleValue)))
        borderColorWell.color = CaptureAppearance.preferred.borderColor
        updateValues()
    }

    @objc private func borderColorChanged() {
        let color = borderColorWell.color.usingColorSpace(.sRGB) ?? borderColorWell.color
        UserDefaults.standard.set(color.redComponent, forKey: "borderColorRed")
        UserDefaults.standard.set(color.greenComponent, forKey: "borderColorGreen")
        UserDefaults.standard.set(color.blueComponent, forKey: "borderColorBlue")
        onBorderColorChange?(color)
        refreshPreviews()
    }

    @objc private func backdropChanged() {
        UserDefaults.standard.set(backdropSwitch.state == .on, forKey: "usesDesktopBackdrop")
        UserDefaults.standard.set(backdropMarginSlider.doubleValue, forKey: "backdropMargin")
        updateValues()
    }
}

private enum SettingsPane: String, CaseIterable {
    case capture, appearance, annotations

    var title: String {
        switch self {
        case .capture: "Capture"
        case .appearance: "Appearance"
        case .annotations: "Annotations"
        }
    }

    var symbolName: String {
        switch self {
        case .capture: "viewfinder"
        case .appearance: "sparkles"
        case .annotations: "pencil.tip"
        }
    }

    var iconColor: NSColor {
        switch self {
        case .capture: .systemBlue
        case .appearance: .systemPink
        case .annotations: .systemOrange
        }
    }
}

@MainActor
private final class SettingsHoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false

    init(content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                           .inVisibleRect, .enabledDuringMouseDrag],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        updateHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        setHovering(true)
    }
    override func mouseExited(with event: NSEvent) { resetHover() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetHover() }
    }

    func updateHoverFromPointer() {
        guard let window, window.isVisible, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else {
            resetHover()
            return
        }
        setHovering(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    func resetHover() { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChange?(hovering)
    }
}

@MainActor
private final class SettingsLinkButton: NSButton {
    private let url: URL

    override var allowsVibrancy: Bool { false }

    init(title: String, url: URL, logo: NSImage?) {
        self.url = url
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        if let logo = logo?.copy() as? NSImage, logo.size.width > 0, logo.size.height > 0 {
            let scale = 16 / max(logo.size.width, logo.size.height)
            logo.size = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
            image = logo
        }
        imagePosition = .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(openLink)
        toolTip = url.absoluteString
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openLink() {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class SettingsSurfaceView: NSView {
    private let isPanel: Bool

    init(isPanel: Bool = false) {
        self.isPanel = isPanel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isPanel {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            path.fill()
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                NSColor.secondaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        } else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }
}

@MainActor
private final class SettingsPaneButton: NSButton {
    let pane: SettingsPane

    // The sidebar's vibrancy otherwise recolors unselected icon tiles.
    override var allowsVibrancy: Bool { false }

    init(pane: SettingsPane) {
        self.pane = pane
        super.init(frame: .zero)
        title = pane.title
        identifier = NSUserInterfaceItemIdentifier("settings.pane.\(pane.rawValue)")
        setButtonType(.toggle)
        isBordered = false
        setAccessibilityLabel(pane.title)
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let iconRect = CGRect(x: 8, y: bounds.midY - 12, width: 24, height: 24)
        pane.iconColor.setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 6, yRadius: 6).fill()
        let symbol = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        symbol?.draw(in: iconRect.insetBy(dx: 5, dy: 5))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: state == .on ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: CGPoint(x: 43, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class GradientSwatchButton: NSButton {
    let palette: SunsetWashPalette
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    init(palette: SunsetWashPalette) {
        self.palette = palette
        super.init(frame: .zero)
        title = palette.title
        identifier = NSUserInterfaceItemIdentifier("settings.palette.\(palette.rawValue)")
        setButtonType(.toggle)
        isBordered = false
        setAccessibilityLabel(palette.title)
        toolTip = palette.title
        widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 54).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let swatch = NSRect(x: 4, y: 22, width: bounds.width - 8, height: 28)
        let path = NSBezierPath(roundedRect: swatch, xRadius: 6, yRadius: 6)
        NSGradient(colors: palette.colors)?.draw(in: path, angle: -35)
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2
            ring.stroke()
            "✓".draw(at: NSPoint(x: swatch.maxX - 18, y: swatch.midY - 8), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white,
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
