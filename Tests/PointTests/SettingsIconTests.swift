import AppKit
import XCTest
@testable import Point

final class SettingsIconTests: XCTestCase {
    @MainActor
    func testSidebarIconsKeepTheirColorsWhenSelectionAndActivityChange() throws {
        let defaults = UserDefaults.standard
        let previousPane = defaults.object(forKey: "settingsSelectedPane")
        defer {
            if let previousPane { defaults.set(previousPane, forKey: "settingsSelectedPane") }
            else { defaults.removeObject(forKey: "settingsSelectedPane") }
        }

        let controller = PreferencesController()
        controller.show()
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "point.settings" && $0.isVisible
        })
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let sidebar = try XCTUnwrap(content.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        let buttons = try ["capture", "appearance", "annotations"].map { pane in
            try XCTUnwrap(descendants(content).first {
                $0.identifier?.rawValue == "settings.pane.\(pane)"
            } as? NSButton)
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            var baseline: [Data]?
            for activity in [NSVisualEffectView.State.active, .inactive] {
                sidebar.state = activity
                for selected in buttons {
                    selected.performClick(nil)
                    content.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    let icons = try buttons.map { try iconPixels($0, in: content, bitmap: bitmap) }
                    if let baseline {
                        XCTAssertEqual(icons, baseline, "Sidebar icons changed in \(appearance.rawValue)")
                    } else {
                        baseline = icons
                    }
                }
            }
        }
    }

    @MainActor
    private func iconPixels(_ button: NSButton, in content: NSView, bitmap: NSBitmapImageRep) throws -> Data {
        let bounds = button.convert(button.bounds, to: content)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        // Stay inside the opaque tile, excluding its antialiased rounded edge.
        let interior = CGRect(x: (bounds.minX + 12) * scale,
                              y: (content.bounds.maxY - bounds.midY - 7) * scale,
                              width: 16 * scale, height: 14 * scale)
        let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: interior))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
