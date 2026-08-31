import AppKit

enum AnnotationRenderer {
    static func render(
        source: CGImage,
        canvasSize: CGSize,
        annotations: [Annotation],
        style: AnnotationStyle
    ) throws -> CGImage {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.width,
            pixelsHigh: source.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let representation, let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw CaptureError.cropFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(
            x: CGFloat(source.width) / canvasSize.width,
            y: CGFloat(source.height) / canvasSize.height
        )
        NSImage(cgImage: source, size: canvasSize).draw(in: CGRect(origin: .zero, size: canvasSize))
        draw(annotations: annotations, source: source, canvasSize: canvasSize, style: style)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let result = representation.cgImage else { throw CaptureError.cropFailed }
        return result
    }

    static func draw(annotations: [Annotation], source: CGImage, canvasSize: CGSize, style: AnnotationStyle) {
        // Concealment is always composited beneath communicative markup, regardless
        // of creation order. A later blur must never soften an existing arrow.
        let concealment = annotations.filter {
            switch $0 {
            case .blur, .redaction: true
            case .arrow, .text: false
            }
        }
        let markup = annotations.filter {
            switch $0 {
            case .arrow, .text: true
            case .blur, .redaction: false
            }
        }
        for annotation in concealment + markup {
            switch annotation {
            case let .arrow(value): drawArrow(value, style: style, canvas: CGRect(origin: .zero, size: canvasSize))
            case let .blur(value): drawIrregularMosaic(source: source, annotation: value, canvasSize: canvasSize)
            case let .redaction(value):
                NSColor.black.setFill()
                value.rect.standardized.fill()
            case let .text(value): drawStandaloneText(value, style: style, canvas: CGRect(origin: .zero, size: canvasSize))
            }
        }
    }

    static func drawStandaloneText(_ annotation: TextAnnotation, style: AnnotationStyle, canvas: CGRect) {
        guard !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let rect = Geometry.standaloneTextRect(for: annotation, style: style, canvas: canvas)
        let background = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        background.fill()
        style.color.setStroke()
        background.lineWidth = 2.5
        background.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.fontSize ?? style.fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        (annotation.text as NSString).draw(with: rect.insetBy(dx: 8, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    static func drawArrow(_ arrow: ArrowAnnotation, style: AnnotationStyle, canvas: CGRect) {
        let angle = atan2(arrow.head.y - arrow.tail.y, arrow.head.x - arrow.tail.x)
        let headLength = max(13, style.lineWidth * 4)
        let headAngle: CGFloat = .pi / 7
        let left = CGPoint(x: arrow.head.x - headLength * cos(angle - headAngle), y: arrow.head.y - headLength * sin(angle - headAngle))
        let right = CGPoint(x: arrow.head.x - headLength * cos(angle + headAngle), y: arrow.head.y - headLength * sin(angle + headAngle))
        let path = NSBezierPath()
        path.move(to: arrow.tail)
        path.line(to: arrow.head)
        path.move(to: left)
        path.line(to: arrow.head)
        path.line(to: right)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        NSColor.black.withAlphaComponent(0.62).setStroke()
        path.lineWidth = style.lineWidth + 3
        path.stroke()
        style.color.setStroke()
        path.lineWidth = style.lineWidth
        path.stroke()

        guard !arrow.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let captionRect = Geometry.captionRect(for: arrow, text: arrow.caption, style: style, canvas: canvas)
        let background = NSBezierPath(roundedRect: captionRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        background.fill()
        style.color.setStroke()
        background.lineWidth = 2.5
        background.stroke()

        let textRect = captionRect.insetBy(dx: 8, dy: 5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: arrow.captionFontSize ?? style.fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        (arrow.caption as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    static func drawIrregularMosaic(source: CGImage, annotation: RectangleAnnotation, canvasSize: CGSize) {
        let standardized = annotation.rect.standardized.intersection(CGRect(origin: .zero, size: canvasSize))
        guard standardized.width >= 1, standardized.height >= 1 else { return }
        let pixelRect = CoordinateTransform.pixelCropRect(
            selectionInPoints: standardized,
            screenSizeInPoints: canvasSize,
            imageSizeInPixels: CGSize(width: source.width, height: source.height)
        )
        guard let crop = source.cropping(to: pixelRect) else { return }
        let scaleX = CGFloat(source.width) / canvasSize.width
        let scaleY = CGFloat(source.height) / canvasSize.height
        let pixelAlignedRect = CGRect(
            x: pixelRect.minX / scaleX,
            y: canvasSize.height - pixelRect.maxY / scaleY,
            width: pixelRect.width / scaleX,
            height: pixelRect.height / scaleY
        )
        guard let mosaic = IrregularMosaicRenderer.makeImage(source: crop, seed: annotation.id) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        NSImage(cgImage: mosaic, size: pixelAlignedRect.size).draw(
            in: pixelAlignedRect,
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

enum IrregularMosaicRenderer {
    static let nativeTileSize = 22

    static func makeImage(source: CGImage, seed: UUID) -> CGImage? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let sampleContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let outputContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let sampleData = sampleContext.data else { return nil }

        sampleContext.interpolationQuality = .none
        sampleContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let samples = sampleData.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let columns = max(1, Int(ceil(Double(width) / Double(nativeTileSize))))
        let rows = max(1, Int(ceil(Double(height) / Double(nativeTileSize))))
        var random = StableMosaicRandom(seed: seed)
        var sites = [CGPoint]()
        sites.reserveCapacity(columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let centerX = (CGFloat(column) + 0.5) * CGFloat(nativeTileSize)
                let centerY = (CGFloat(row) + 0.5) * CGFloat(nativeTileSize)
                let jitter = CGFloat(nativeTileSize) * 0.32
                sites.append(CGPoint(
                    x: min(CGFloat(width) - 0.5, max(0.5, centerX + random.signedUnit() * jitter)),
                    y: min(CGFloat(height) - 0.5, max(0.5, centerY + random.signedUnit() * jitter))
                ))
            }
        }

        outputContext.setShouldAntialias(false)
        outputContext.setAllowsAntialiasing(false)
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let site = sites[index]
                var polygon = [
                    CGPoint(x: imageBounds.minX, y: imageBounds.minY),
                    CGPoint(x: imageBounds.maxX, y: imageBounds.minY),
                    CGPoint(x: imageBounds.maxX, y: imageBounds.maxY),
                    CGPoint(x: imageBounds.minX, y: imageBounds.maxY),
                ]
                let minimumRow = max(0, row - 2)
                let maximumRow = min(rows - 1, row + 2)
                let minimumColumn = max(0, column - 2)
                let maximumColumn = min(columns - 1, column + 2)
                for neighborRow in minimumRow...maximumRow {
                    for neighborColumn in minimumColumn...maximumColumn {
                        let neighborIndex = neighborRow * columns + neighborColumn
                        guard neighborIndex != index else { continue }
                        polygon = clip(polygon, closerTo: site, than: sites[neighborIndex])
                        if polygon.isEmpty { break }
                    }
                    if polygon.isEmpty { break }
                }
                guard polygon.count >= 3 else { continue }

                let color = averageColor(around: site, samples: samples, width: width, height: height)
                outputContext.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
                outputContext.beginPath()
                outputContext.move(to: polygon[0])
                for point in polygon.dropFirst() { outputContext.addLine(to: point) }
                outputContext.closePath()
                outputContext.fillPath()
            }
        }
        return outputContext.makeImage()
    }

    private static func clip(_ polygon: [CGPoint], closerTo site: CGPoint, than neighbor: CGPoint) -> [CGPoint] {
        guard !polygon.isEmpty else { return [] }
        let normal = CGPoint(x: neighbor.x - site.x, y: neighbor.y - site.y)
        let boundary = (neighbor.x * neighbor.x + neighbor.y * neighbor.y - site.x * site.x - site.y * site.y) / 2
        func signedDistance(_ point: CGPoint) -> CGFloat {
            boundary - (normal.x * point.x + normal.y * point.y)
        }

        var result = [CGPoint]()
        var previous = polygon[polygon.count - 1]
        var previousDistance = signedDistance(previous)
        for current in polygon {
            let currentDistance = signedDistance(current)
            let previousInside = previousDistance >= 0
            let currentInside = currentDistance >= 0
            if previousInside != currentInside {
                let amount = previousDistance / (previousDistance - currentDistance)
                result.append(CGPoint(
                    x: previous.x + (current.x - previous.x) * amount,
                    y: previous.y + (current.y - previous.y) * amount
                ))
            }
            if currentInside { result.append(current) }
            previous = current
            previousDistance = currentDistance
        }
        return result
    }

    private static func averageColor(
        around point: CGPoint,
        samples: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let centerX = min(width - 1, max(0, Int(point.x.rounded())))
        // Voronoi geometry uses Quartz's bottom-left origin, while the bitmap's
        // first scanline represents the top of the cropped screenshot.
        let centerY = height - 1 - min(height - 1, max(0, Int(point.y.rounded())))
        let radius = max(2, nativeTileSize / 5)
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        var count = 0
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let offset = (y * width + x) * 4
                red += Int(samples[offset])
                green += Int(samples[offset + 1])
                blue += Int(samples[offset + 2])
                alpha += Int(samples[offset + 3])
                count += 1
            }
        }
        let divisor = CGFloat(max(1, count) * 255)
        return (CGFloat(red) / divisor, CGFloat(green) / divisor, CGFloat(blue) / divisor, CGFloat(alpha) / divisor)
    }
}

private struct StableMosaicRandom {
    private var state: UInt64

    init(seed: UUID) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        withUnsafeBytes(of: seed.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        state = hash
    }

    mutating func signedUnit() -> CGFloat {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        let unit = Double(value >> 11) / Double(1 << 53)
        return CGFloat(unit * 2 - 1)
    }
}

enum BackdropRenderer {
    private static let borderWidthInPoints: CGFloat = 12

    static func compose(
        screenshot: CGImage,
        wallpaper: CGImage,
        canvasSize: CGSize,
        margin: CGFloat,
        borderColor: NSColor
    ) throws -> CGImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else { throw CaptureError.invalidSelection }
        let scaleX = CGFloat(screenshot.width) / canvasSize.width
        let scaleY = CGFloat(screenshot.height) / canvasSize.height
        let marginX = max(1, Int((margin * scaleX).rounded()))
        let marginY = max(1, Int((margin * scaleY).rounded()))
        let outputWidth = screenshot.width + marginX * 2
        let outputHeight = screenshot.height + marginY * 2

        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputWidth,
            pixelsHigh: outputHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let representation, let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw CaptureError.cropFailed
        }

        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let screenshotRect = CGRect(
            x: marginX,
            y: marginY,
            width: screenshot.width,
            height: screenshot.height
        )
        let averageScale = (scaleX + scaleY) / 2
        let borderWidth = borderWidthInPoints * averageScale
        let screenshotRadius = 13 * averageScale

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawAspectFill(image: wallpaper, in: outputRect)
        NSColor.black.withAlphaComponent(0.12).setFill()
        outputRect.fill()

        NSGraphicsContext.saveGraphicsState()
        let cardShape = NSBezierPath(
            roundedRect: screenshotRect,
            xRadius: screenshotRadius,
            yRadius: screenshotRadius
        )
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
        shadow.shadowBlurRadius = 12 * averageScale
        shadow.shadowOffset = CGSize(width: 0, height: -3 * averageScale)
        shadow.set()
        NSColor.black.withAlphaComponent(0.2).setFill()
        cardShape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let outerRect = screenshotRect.insetBy(dx: -borderWidth, dy: -borderWidth)
        let glassRing = NSBezierPath(
            roundedRect: outerRect,
            xRadius: screenshotRadius + borderWidth,
            yRadius: screenshotRadius + borderWidth
        )
        glassRing.append(cardShape)
        glassRing.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        GlassBorderPalette.fillColor(accent: borderColor, wallpaperReveal: 1).setFill()
        glassRing.fill()
        glassRing.addClip()
        let colors = GlassBorderPalette.gradientColors(accent: borderColor, wallpaperReveal: 1)
        NSGradient(colorsAndLocations:
            (colors[0], 0),
            (colors[1], 0.42),
            (colors[2], 0.7),
            (colors[3], 1)
        )?.draw(in: outerRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        cardShape.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: screenshot, size: screenshotRect.size).draw(in: screenshotRect)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.7).setStroke()
        let highlight = NSBezierPath(
            roundedRect: outerRect.insetBy(dx: averageScale, dy: averageScale),
            xRadius: screenshotRadius + borderWidth - averageScale,
            yRadius: screenshotRadius + borderWidth - averageScale
        )
        highlight.lineWidth = averageScale
        highlight.stroke()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let result = representation.cgImage else { throw CaptureError.cropFailed }
        return result
    }

    private static func drawAspectFill(image: CGImage, in rect: CGRect) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: drawSize).draw(in: drawRect)
    }
}

enum GlassBorderPalette {
    static func fillColor(accent: NSColor, wallpaperReveal: CGFloat) -> NSColor {
        resolved(accent).withAlphaComponent(0.24 - 0.05 * min(1, max(0, wallpaperReveal)))
    }

    static func gradientColors(accent: NSColor, wallpaperReveal: CGFloat) -> [NSColor] {
        let accent = resolved(accent)
        let reveal = min(1, max(0, wallpaperReveal))
        return [
            blend(accent, with: .white, fraction: 0.72).withAlphaComponent(0.64 - 0.12 * reveal),
            blend(accent, with: .white, fraction: 0.42).withAlphaComponent(0.38 - 0.07 * reveal),
            accent.withAlphaComponent(0.26 - 0.05 * reveal),
            blend(accent, with: .white, fraction: 0.56).withAlphaComponent(0.48 - 0.09 * reveal),
        ]
    }

    static func innerEdgeColor(accent: NSColor) -> NSColor {
        blend(resolved(accent), with: .white, fraction: 0.62).withAlphaComponent(0.76)
    }

    private static func resolved(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func blend(_ color: NSColor, with other: NSColor, fraction: CGFloat) -> NSColor {
        color.blended(withFraction: fraction, of: other) ?? color
    }
}
