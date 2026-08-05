import AppKit
import XCTest
@testable import X_Shot

final class XShotTests: XCTestCase {
    func testSelectionGeometryNormalizesAndClamps() {
        XCTAssertEqual(
            SelectionGeometry.normalized(from: CGPoint(x: 90, y: 80), to: CGPoint(x: 10, y: 20)),
            CGRect(x: 10, y: 20, width: 80, height: 60)
        )
        XCTAssertEqual(
            SelectionGeometry.moved(
                CGRect(x: 10, y: 10, width: 40, height: 30),
                by: CGPoint(x: -100, y: 200),
                within: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            CGRect(x: 0, y: 70, width: 40, height: 30)
        )
    }

    func testPointToPixelConversionAtOneAndTwoTimesScale() {
        let selection = CGRect(x: 12.5, y: 8, width: 100, height: 50)
        XCTAssertEqual(SelectionGeometry.pixelRect(for: selection, scale: 1), CGRect(x: 13, y: 8, width: 100, height: 50))
        XCTAssertEqual(SelectionGeometry.pixelRect(for: selection, scale: 2), CGRect(x: 25, y: 16, width: 200, height: 100))
    }

    func testWindowGeometryHandlesNegativeDisplayOriginAndFitsCanvas() {
        let local = CaptureGeometry.localRect(
            for: CGRect(x: -1500, y: 120, width: 600, height: 400),
            displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            canvasBounds: CGRect(x: 0, y: 0, width: 960, height: 540)
        )
        XCTAssertEqual(local, CGRect(x: 210, y: 60, width: 300, height: 200))

        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let fitted = CaptureGeometry.fitted(
            CGRect(x: -100, y: -50, width: 800, height: 450),
            within: bounds,
            margin: 16
        )
        let available = bounds.insetBy(dx: 16, dy: 16)
        XCTAssertTrue(available.contains(fitted))
        XCTAssertEqual(fitted.width / fitted.height, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testHistoryUndoRedoAndNewBranch() {
        let history = AnnotationHistory()
        let style = AnnotationStyle(color: .red, width: 3)
        history.append(.line(.zero, CGPoint(x: 10, y: 10), style))
        history.undo()
        XCTAssertEqual(history.annotations.count, 0)
        XCTAssertTrue(history.canRedo)
        history.redo()
        XCTAssertEqual(history.annotations.count, 1)
        history.undo()
        history.append(.rectangle(CGRect(x: 1, y: 1, width: 5, height: 5), style))
        XCTAssertFalse(history.canRedo)
    }

    func testRetinaExportUsesTwoPixelsPerPoint() throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 100,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: CGSize(width: 100, height: 50))
        image.addRepresentation(bitmap)

        let png = try XCTUnwrap(EditorRenderer.renderPNG(
            image: image,
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            selection: CGRect(x: 10, y: 5, width: 30, height: 20),
            annotations: [],
            scale: 2
        ))
        let output = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(output.pixelsWide, 60)
        XCTAssertEqual(output.pixelsHigh, 40)
    }

    func testWindowExportUsesPositionedImageBoundsAtNativeResolution() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 4, height: 2))
        let imageBounds = CGRect(x: 2, y: 1, width: 4, height: 2)

        let exactPNG = try XCTUnwrap(EditorRenderer.renderPNG(
            image: image,
            displayBounds: CGRect(x: 0, y: 0, width: 8, height: 4),
            imageBounds: imageBounds,
            selection: imageBounds,
            annotations: [],
            scale: 2
        ))
        let exact = try XCTUnwrap(NSBitmapImageRep(data: exactPNG))
        XCTAssertEqual(exact.pixelsWide, 8)
        XCTAssertEqual(exact.pixelsHigh, 4)

        let placedPNG = try XCTUnwrap(EditorRenderer.renderPNG(
            image: image,
            displayBounds: CGRect(x: 0, y: 0, width: 8, height: 4),
            imageBounds: imageBounds,
            selection: CGRect(x: 0, y: 0, width: 8, height: 4),
            annotations: [],
            scale: 2
        ))
        let placed = try XCTUnwrap(NSBitmapImageRep(data: placedPNG))
        XCTAssertEqual(placed.pixelsWide, 16)
        XCTAssertEqual(placed.pixelsHigh, 8)
        XCTAssertEqual(placed.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(placed.colorAt(x: 8, y: 4)?.redComponent ?? 0, 0.9)
    }

    func testRendererDoesNotFlipTheCapturedImage() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 4, height: 4))

        let png = try XCTUnwrap(EditorRenderer.renderPNG(
            image: image,
            displayBounds: CGRect(x: 0, y: 0, width: 4, height: 4),
            selection: CGRect(x: 0, y: 0, width: 4, height: 4),
            annotations: [],
            scale: 1
        ))
        let preview = try XCTUnwrap(renderPreviewPNG(image: image, size: CGSize(width: 4, height: 4)))
        XCTAssertEqual(png, preview)
    }

    func testClippedPreviewMatchesFullPreviewInsideDirtyRegion() throws {
        let source = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        source.setFillColor(NSColor.red.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        source.setFillColor(NSColor.blue.cgColor)
        source.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
        source.setFillColor(NSColor.green.cgColor)
        source.fill(CGRect(x: 0, y: 4, width: 4, height: 4))
        source.setFillColor(NSColor.yellow.cgColor)
        source.fill(CGRect(x: 4, y: 4, width: 4, height: 4))
        let image = NSImage(cgImage: try XCTUnwrap(source.makeImage()), size: CGSize(width: 8, height: 8))

        let full = try XCTUnwrap(renderPreviewBitmap(image: image, size: image.size))
        let dirtyRect = CGRect(x: 2, y: 1, width: 4, height: 3)
        let partial = try XCTUnwrap(renderPreviewBitmap(
            image: image,
            size: image.size,
            clipRect: dirtyRect
        ))

        var drawnPixels = 0
        for y in 0..<8 {
            for x in 0..<8 {
                guard let partialColor = partial.colorAt(x: x, y: y), partialColor.alphaComponent > 0 else { continue }
                drawnPixels += 1
                XCTAssertEqual(partialColor, full.colorAt(x: x, y: y))
            }
        }
        XCTAssertEqual(drawnPixels, Int(dirtyRect.width * dirtyRect.height))
    }

    func testToolbarStartsWithAValidIntrinsicFrame() throws {
        let canvas = EditorCanvasView(image: NSImage(size: CGSize(width: 100, height: 100)), pixelScale: 1)
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        XCTAssertGreaterThan(toolbar.frame.width, 0)
        XCTAssertGreaterThan(toolbar.frame.height, 0)

        let toolbarButtons = buttons(in: toolbar)
        let copyButton = try XCTUnwrap(toolbarButtons.first { $0.title == "Copy" })
        XCTAssertTrue(copyButton.imageHugsTitle)
        XCTAssertEqual(copyButton.alignment, .center)

        var didClose = false
        canvas.onCancel = { didClose = true }
        let closeButton = try XCTUnwrap(toolbarButtons.first { $0.toolTip == "Close (Esc)" })
        closeButton.performClick(nil)
        XCTAssertTrue(didClose)

        toolbar.showCopySuccess()
        XCTAssertTrue(toolbarButtons.contains { $0.title == "Copied" })
        toolbar.showSaveSuccess()
        XCTAssertFalse(toolbarButtons.contains { $0.title == "Copied" })
        XCTAssertTrue(toolbarButtons.contains { $0.title == "Saved" })
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton { result.append(button) }
            result.append(contentsOf: buttons(in: subview))
        }
        return result
    }

    private func renderPreviewPNG(image: NSImage, size: CGSize) -> Data? {
        guard let bitmap = renderPreviewBitmap(image: image, size: size), let output = bitmap.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }

    private func renderPreviewBitmap(image: NSImage, size: CGSize, clipRect: CGRect? = nil) -> NSBitmapImageRep? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if let clipRect { context.clip(to: clipRect) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        EditorRenderer.drawImage(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output)
    }
}
