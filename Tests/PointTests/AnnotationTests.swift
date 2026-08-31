import AppKit
import XCTest
@testable import Point

final class AnnotationTests: XCTestCase {
    @MainActor
    func testCaptionEditorInputAreaGrowsWhileTypingWrappedText() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 20 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let session = AnnotationSession()
        let text = TextAnnotation(id: UUID(), anchor: CGPoint(x: 460, y: 300), text: "")
        session.append(.text(text))
        let canvas = AnnotationCanvasView(
            sourceImage: try XCTUnwrap(context.makeImage()),
            session: session,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 24)
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        canvas.beginTextEditing(annotationID: text.id)
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? CaptionTextView }.first)
        XCTAssertFalse(editor.isHorizontallyResizable, "The annotation editor must wrap instead of scrolling horizontally")
        XCTAssertTrue(editor.isVerticallyResizable, "The annotation editor must grow for wrapped lines")

        window.makeFirstResponder(editor)
        for character in "hello" {
            editor.insertText(
                String(character),
                replacementRange: editor.selectedRange()
            )
        }
        editor.textStorage?.replaceCharacters(
            in: NSRange(location: editor.string.utf16.count, length: 0),
            with: " world"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        editor.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(editor.textContainer)
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        layoutManager.ensureLayout(for: container)
        let requiredHeight = layoutManager.usedRect(for: container).height + editor.textContainerInset.height * 2
        var completedText = text
        completedText.text = "hello world"
        let expectedFrame = Geometry.standaloneTextRect(
            for: completedText,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 24),
            canvas: canvas.bounds
        ).insetBy(dx: 1, dy: 1)
        XCTAssertEqual(
            editor.frame.width,
            expectedFrame.width,
            accuracy: 0.5,
            "The input area remained sized for the text before the storage edit"
        )
        XCTAssertEqual(
            editor.frame.height,
            expectedFrame.height,
            accuracy: 0.5,
            "The live editor wrapped differently from the accepted annotation"
        )
        XCTAssertLessThanOrEqual(
            requiredHeight,
            editor.bounds.height + 0.5,
            "Typed text wrapped below the visible input area"
        )
        let editorLayer = try XCTUnwrap(editor.layer)
        XCTAssertEqual(
            editorLayer.bounds.height,
            editor.bounds.height,
            accuracy: 0.5,
            "The editor grew, but its visible background and border layer stayed one line tall"
        )
    }

    func testThreeFingerDoubleTapRecognizesTwoQuickStationaryTaps() {
        var detector = ThreeFingerDoubleTapDetector()
        XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.12, hadMotion: false, timestamp: 1))
        XCTAssertTrue(detector.registerTap(fingerCount: 3, duration: 0.11, hadMotion: false, timestamp: 1.31))
    }

    func testThreeFingerDoubleTapRejectsWrongFingerCountMotionAndSlowSecondTap() {
        var detector = ThreeFingerDoubleTapDetector()
        XCTAssertFalse(detector.registerTap(fingerCount: 2, duration: 0.1, hadMotion: false, timestamp: 1))
        XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: true, timestamp: 2))
        XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: 3))
        XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: 3.6))
        XCTAssertTrue(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: 3.9))
    }

    func testThreeFingerDoubleTapContinuesRecognizingRepeatedly() {
        var detector = ThreeFingerDoubleTapDetector()
        for pair in 0..<20 {
            let start = TimeInterval(pair)
            XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: start + 0.1))
            XCTAssertTrue(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: start + 0.35))
        }
    }

    func testThreeFingerDoubleTapAcceptsObservedHalfSecondPair() {
        var detector = ThreeFingerDoubleTapDetector()
        XCTAssertFalse(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: 1))
        XCTAssertTrue(detector.registerTap(fingerCount: 3, duration: 0.1, hadMotion: false, timestamp: 1.495))
    }

    func testThreeFingerContactMotionRejectsCapturedDesktopSwipe() {
        var motion = ThreeFingerContactMotion()
        motion.observe(fingerCount: 3, position: CGPoint(x: 0.437, y: 0.447))
        motion.observe(fingerCount: 3, position: CGPoint(x: 0.535, y: 0.482))
        XCTAssertTrue(motion.hadMotion)
    }

    func testThreeFingerContactMotionAllowsCapturedStationaryTap() {
        var motion = ThreeFingerContactMotion()
        motion.observe(fingerCount: 3, position: CGPoint(x: 0.760, y: 0.771))
        motion.observe(fingerCount: 3, position: CGPoint(x: 0.754, y: 0.748))
        XCTAssertFalse(motion.hadMotion)
    }

    func testPermissionIsRequestedAgainAfterTCCResetEvenIfPreviousRequestWasRemembered() {
        XCTAssertTrue(
            ScreenCapturePermissionRequestPolicy.shouldRequest(
                hasAccess: false,
                hasRequestedBefore: true
            )
        )
    }

    func testTCCCaptureErrorIsRecognizedAsAuthorizationFailure() {
        let error = NSError(domain: "com.apple.ScreenCaptureKit", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
        ])
        XCTAssertTrue(CaptureAuthorizationFailure.isAuthorizationDenial(error))
    }

    func testIrregularMosaicIsStableAndUsesAConcealingColorPalette() throws {
        let width = 88
        let height = 66
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.35, blue: 1 - CGFloat(x) / CGFloat(width), alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let source = try XCTUnwrap(context.makeImage())
        let seed = UUID(uuidString: "70A87EC4-14B9-4BCE-9685-FD830135148F")!
        let first = try XCTUnwrap(IrregularMosaicRenderer.makeImage(source: source, seed: seed))
        let second = try XCTUnwrap(IrregularMosaicRenderer.makeImage(source: source, seed: seed))
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        let secondBitmap = NSBitmapImageRep(cgImage: second)
        var palette = Set<UInt32>()
        var differingPixels = 0

        for y in 0..<height {
            for x in 0..<width {
                let firstColor = try XCTUnwrap(firstBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let secondColor = try XCTUnwrap(secondBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let packed = UInt32((firstColor.redComponent * 255).rounded()) << 16
                    | UInt32((firstColor.greenComponent * 255).rounded()) << 8
                    | UInt32((firstColor.blueComponent * 255).rounded())
                palette.insert(packed)
                if firstColor != secondColor { differingPixels += 1 }
                XCTAssertGreaterThan(firstColor.alphaComponent, 0.99)
            }
        }

        XCTAssertEqual(differingPixels, 0, "A mosaic must not shimmer between redraws")
        XCTAssertGreaterThan(palette.count, 4)
        XCTAssertLessThanOrEqual(palette.count, 20, "Mosaic tiles should collapse detailed source colors")
    }

    func testIrregularMosaicSamplesColorsFromTheMatchingScreenshotLocation() throws {
        let size = 176
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let quadrants: [(CGRect, NSColor)] = [
            (CGRect(x: 0, y: 0, width: 88, height: 88), .systemRed),
            (CGRect(x: 88, y: 0, width: 88, height: 88), .systemGreen),
            (CGRect(x: 0, y: 88, width: 88, height: 88), .systemBlue),
            (CGRect(x: 88, y: 88, width: 88, height: 88), .systemYellow),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        let source = try XCTUnwrap(context.makeImage())
        let canvasSize = CGSize(width: size, height: size)
        let style = AnnotationStyle(color: .systemPink, lineWidth: 4, fontSize: 15)
        let baseline = try AnnotationRenderer.render(
            source: source,
            canvasSize: canvasSize,
            annotations: [],
            style: style
        )
        let mosaic = try AnnotationRenderer.render(
            source: source,
            canvasSize: canvasSize,
            annotations: [.blur(RectangleAnnotation(
                id: UUID(uuidString: "45069966-BC2A-453C-AC70-8924924B8200")!,
                rect: CGRect(origin: .zero, size: canvasSize)
            ))],
            style: style
        )
        let baselineBitmap = NSBitmapImageRep(cgImage: baseline)
        let mosaicBitmap = NSBitmapImageRep(cgImage: mosaic)
        let samplePoints = [(44, 44), (132, 44), (44, 132), (132, 132)]

        for (x, y) in samplePoints {
            let expected = try XCTUnwrap(baselineBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(mosaicBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let delta = max(
                abs(expected.redComponent - actual.redComponent),
                abs(expected.greenComponent - actual.greenComponent),
                abs(expected.blueComponent - actual.blueComponent)
            )
            XCTAssertLessThan(delta, 0.08, "Mosaic sampled a different screenshot location at (\(x), \(y))")
        }
    }

    func testCaptionPlacementStaysInsideCanvas() {
        let arrow = ArrowAnnotation(id: UUID(), tail: CGPoint(x: 195, y: 95), head: CGPoint(x: 100, y: 50), caption: "Near the edge")
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let result = Geometry.captionRect(
            for: arrow,
            text: arrow.caption,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15),
            canvas: canvas
        )

        XCTAssertGreaterThanOrEqual(result.minX, canvas.minX)
        XCTAssertGreaterThanOrEqual(result.minY, canvas.minY)
        XCTAssertLessThanOrEqual(result.maxX, canvas.maxX)
        XCTAssertLessThanOrEqual(result.maxY, canvas.maxY)
    }

    @MainActor
    func testSessionUndoAndRedoCreationAndDeletion() {
        let session = AnnotationSession()
        let arrow = Annotation.arrow(ArrowAnnotation(id: UUID(), tail: .zero, head: CGPoint(x: 20, y: 20), caption: "Test"))
        session.append(arrow)
        XCTAssertEqual(session.annotations, [arrow])

        session.deleteSelection()
        XCTAssertTrue(session.annotations.isEmpty)
        session.undo()
        XCTAssertEqual(session.annotations, [arrow])
        session.undo()
        XCTAssertTrue(session.annotations.isEmpty)
        session.redo()
        XCTAssertEqual(session.annotations, [arrow])
    }

    @MainActor
    func testCancellingNewEmptyTextLeavesNoGhostUndoStep() {
        let session = AnnotationSession()
        let text = Annotation.text(TextAnnotation(id: UUID(), anchor: CGPoint(x: 10, y: 10), text: ""))
        session.append(text)
        session.cancelNewAnnotation(id: text.id)
        session.undo()

        XCTAssertTrue(session.annotations.isEmpty)
    }

    func testRendererPreservesNativeDimensionsAndFlattensRedaction() throws {
        let width = 200
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let source = context.makeImage()!
        let redaction = Annotation.redaction(RectangleAnnotation(id: UUID(), rect: CGRect(x: 10, y: 10, width: 30, height: 20)))

        let rendered = try AnnotationRenderer.render(
            source: source,
            canvasSize: CGSize(width: 100, height: 50),
            annotations: [redaction],
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15)
        )

        XCTAssertEqual(rendered.width, width)
        XCTAssertEqual(rendered.height, height)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let redactedPixel = bitmap.colorAt(x: 40, y: 40)
        XCTAssertLessThan(redactedPixel?.redComponent ?? 1, 0.02)
        XCTAssertLessThan(redactedPixel?.greenComponent ?? 1, 0.02)
        XCTAssertLessThan(redactedPixel?.blueComponent ?? 1, 0.02)
    }

    func testArrowRendersAboveLaterRedaction() throws {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let source = context.makeImage()!
        let arrow = Annotation.arrow(ArrowAnnotation(id: UUID(), tail: CGPoint(x: 10, y: 25), head: CGPoint(x: 90, y: 25), caption: ""))
        let redaction = Annotation.redaction(RectangleAnnotation(id: UUID(), rect: CGRect(x: 0, y: 0, width: 100, height: 50)))

        let rendered = try AnnotationRenderer.render(
            source: source,
            canvasSize: CGSize(width: 100, height: 50),
            annotations: [arrow, redaction],
            style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 15)
        )
        let center = NSBitmapImageRep(cgImage: rendered).colorAt(x: 100, y: 50)?.usingColorSpace(.sRGB)

        XCTAssertGreaterThan(center?.redComponent ?? 0, 0.7)
        XCTAssertGreaterThan((center?.redComponent ?? 0) - (center?.greenComponent ?? 1), 0.25)
    }

    func testMosaicDoesNotIntroduceAGrayEdge() throws {
        let width = 203
        let height = 101
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in stride(from: 0, to: height, by: 7) {
            for x in stride(from: 0, to: width, by: 7) {
                let even = ((x / 7) + (y / 7)).isMultiple(of: 2)
                context.setFillColor((even ? NSColor.systemPink : NSColor.systemTeal).cgColor)
                context.fill(CGRect(x: x, y: y, width: 7, height: 7))
            }
        }
        let source = try XCTUnwrap(context.makeImage())
        let blurID = UUID()
        let fractionalBlur = Annotation.blur(RectangleAnnotation(
            id: blurID,
            rect: CGRect(x: 13.25, y: 9.75, width: 63.5, height: 27.5)
        ))
        let pixelAlignedBlur = Annotation.blur(RectangleAnnotation(
            id: blurID,
            rect: CGRect(x: 13, y: 9.5, width: 64, height: 28)
        ))

        let fractionalRender = try AnnotationRenderer.render(
            source: source,
            canvasSize: CGSize(width: 101.5, height: 50.5),
            annotations: [fractionalBlur],
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15)
        )
        let alignedRender = try AnnotationRenderer.render(
            source: source,
            canvasSize: CGSize(width: 101.5, height: 50.5),
            annotations: [pixelAlignedBlur],
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15)
        )
        let fractionalBitmap = NSBitmapImageRep(cgImage: fractionalRender)
        let alignedBitmap = NSBitmapImageRep(cgImage: alignedRender)
        var differingPixels = 0

        for y in 0..<height {
            for x in 0..<width {
                let fractional = try XCTUnwrap(fractionalBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let aligned = try XCTUnwrap(alignedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let delta = max(
                    abs(fractional.redComponent - aligned.redComponent),
                    abs(fractional.greenComponent - aligned.greenComponent),
                    abs(fractional.blueComponent - aligned.blueComponent),
                    abs(fractional.alphaComponent - aligned.alphaComponent)
                )
                if delta > 0.01 { differingPixels += 1 }
            }
        }
        XCTAssertEqual(differingPixels, 0, "Fractional blur bounds introduced a sampled edge")
    }

    func testBackdropUsesWallpaperOutsideTheOriginalScreenshot() throws {
        let screenshotContext = CGContext(
            data: nil,
            width: 100,
            height: 50,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        screenshotContext.setFillColor(NSColor.white.cgColor)
        screenshotContext.fill(CGRect(x: 0, y: 0, width: 100, height: 50))

        let wallpaperContext = CGContext(
            data: nil,
            width: 20,
            height: 20,
            bitsPerComponent: 8,
            bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        wallpaperContext.setFillColor(NSColor.systemRed.cgColor)
        wallpaperContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))

        let result = try BackdropRenderer.compose(
            screenshot: screenshotContext.makeImage()!,
            wallpaper: wallpaperContext.makeImage()!,
            canvasSize: CGSize(width: 100, height: 50),
            margin: 32,
            borderColor: .systemBlue
        )
        let bitmap = NSBitmapImageRep(cgImage: result)
        let backdropPixel = bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB)
        let screenshotPixel = bitmap.colorAt(x: 82, y: 57)?.usingColorSpace(.sRGB)

        XCTAssertEqual(result.width, 164)
        XCTAssertEqual(result.height, 114)
        XCTAssertGreaterThan(backdropPixel?.redComponent ?? 0, 0.7)
        XCTAssertLessThan(backdropPixel?.greenComponent ?? 1, 0.3)
        XCTAssertGreaterThan(screenshotPixel?.redComponent ?? 0, 0.9)
        XCTAssertGreaterThan(screenshotPixel?.greenComponent ?? 0, 0.9)
        XCTAssertGreaterThan(screenshotPixel?.blueComponent ?? 0, 0.9)
    }

    func testGlassBorderPaletteTracksSelectedBorderColor() {
        let blue = GlassBorderPalette.gradientColors(accent: .systemBlue, wallpaperReveal: 1)[2]
            .usingColorSpace(.sRGB)
        let red = GlassBorderPalette.gradientColors(accent: .systemRed, wallpaperReveal: 1)[2]
            .usingColorSpace(.sRGB)

        XCTAssertGreaterThan((blue?.blueComponent ?? 0) - (blue?.redComponent ?? 1), 0.35)
        XCTAssertGreaterThan((red?.redComponent ?? 0) - (red?.blueComponent ?? 1), 0.35)
    }

    func testCustomTextWidthIsUsedByPreviewAndFinalLayout() {
        let arrow = ArrowAnnotation(
            id: UUID(),
            tail: CGPoint(x: 20, y: 20),
            head: CGPoint(x: 120, y: 60),
            caption: "A longer annotation that should wrap predictably",
            captionWidth: 180,
            captionFontSize: 22
        )
        let rect = Geometry.captionRect(
            for: arrow,
            text: arrow.caption,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15),
            canvas: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(rect.width, 180)
        XCTAssertGreaterThan(rect.height, 30)
    }

    func testTextBoxCannotBeWiderThanItsContent() {
        let annotation = TextAnnotation(
            id: UUID(),
            anchor: CGPoint(x: 20, y: 20),
            text: "Short",
            width: 400,
            fontSize: 15
        )
        let rect = Geometry.standaloneTextRect(
            for: annotation,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15),
            canvas: CGRect(x: 0, y: 0, width: 600, height: 300)
        )

        XCTAssertLessThan(rect.width, 100)
        XCTAssertGreaterThanOrEqual(rect.width, Geometry.minimumTextBoxWidth)
    }

    func testEmptyTextBoxCannotBeStretched() {
        let annotation = TextAnnotation(id: UUID(), anchor: CGPoint(x: 20, y: 20), text: "", width: 400)
        let rect = Geometry.standaloneTextRect(
            for: annotation,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15),
            canvas: CGRect(x: 0, y: 0, width: 600, height: 300)
        )

        XCTAssertLessThan(rect.width, 100)
    }

    @MainActor
    func testToolbarKeepsStableFrameAcrossToolSelections() {
        let controls = AnnotationControlsView(
            tool: .arrow,
            arrowSize: 4,
            textSize: 18,
            enabled: false,
            margin: 48,
            backdropAvailable: true
        )
        let arrowSize = controls.frame.size

        controls.select(tool: .blur)
        let blurSize = controls.frame.size
        controls.select(tool: .redaction)
        let redactionSize = controls.frame.size

        XCTAssertEqual(blurSize.width, arrowSize.width, accuracy: 1)
        XCTAssertEqual(blurSize.height, arrowSize.height, accuracy: 1)
        XCTAssertEqual(redactionSize.width, arrowSize.width, accuracy: 1)
        XCTAssertEqual(redactionSize.height, arrowSize.height, accuracy: 1)
        XCTAssertEqual(AnnotationTool.allCases.count, 3)
    }

}
