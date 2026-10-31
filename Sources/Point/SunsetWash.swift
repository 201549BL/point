import AppKit

enum SunsetWashStrength {
    static let defaultsKey = "sunsetWashStrength"

    static func preferred(defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = defaults.object(forKey: defaultsKey) as? NSNumber,
              value.doubleValue.isFinite else { return 0.45 }
        return min(1, max(0, CGFloat(value.doubleValue)))
    }

    static func remember(_ value: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(value), forKey: defaultsKey)
    }
}

enum SunsetWashPalette: String, CaseIterable {
    case sunset, lagoon, twilight

    static let defaultsKey = "sunsetWashPalette"

    var title: String {
        switch self {
        case .sunset: return "Sunset"
        case .lagoon: return "Lagoon"
        case .twilight: return "Twilight"
        }
    }

    var colors: [NSColor] {
        switch self {
        case .sunset:
            return [color(243, 148, 95), color(223, 93, 155), color(102, 85, 216)]
        case .lagoon:
            return [color(110, 213, 169), color(65, 178, 184), color(78, 133, 211)]
        case .twilight:
            return [color(117, 153, 235), color(111, 101, 205), color(153, 80, 188)]
        }
    }

    static func preferred(defaults: UserDefaults = .standard) -> Self {
        let value = defaults.string(forKey: defaultsKey)
        if value == "rose" { return .lagoon }
        return value.flatMap(Self.init(rawValue:)) ?? .sunset
    }

    func remember(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

enum SunsetWash {
    static func image(size: CGSize, scale: CGFloat, darkMode: Bool = false) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(in: context, size: size, darkMode: darkMode)
        return context.makeImage()
    }

    static func draw(in context: CGContext, size: CGSize, opacity: CGFloat = 1, darkMode: Bool = false) {
        let strength = SunsetWashStrength.preferred()
        let alphas: [CGFloat] = [156/255, 161/255, 176/255]
        let colors = zip(SunsetWashPalette.preferred().colors, alphas).map { color, alpha in
            color.withAlphaComponent(alpha * strength).cgColor
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: [0, 0.46, 1]) else { return }
        let angle = CGFloat(125) * .pi / 180
        let direction = CGPoint(x: sin(angle), y: cos(angle))
        let length = abs(size.width * direction.x) + abs(size.height * direction.y)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.saveGState()
        context.setAlpha(opacity * (darkMode ? 0.7 : 1))
        context.drawLinearGradient(gradient,
            start: CGPoint(x: center.x - direction.x * length / 2, y: center.y - direction.y * length / 2),
            end: CGPoint(x: center.x + direction.x * length / 2, y: center.y + direction.y * length / 2),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

}
