import AppKit

/// A low-resolution copy of the screenshot. Drawing it without interpolation
/// produces the pixelate effect at the cost of one small image blit.
struct PixelSource {
    static let blockSize: CGFloat = 10

    let image: CGImage
    let rect: CGRect

    init?(image: CGImage, in rect: CGRect) {
        let width = max(1, Int((rect.width / Self.blockSize).rounded(.up)))
        let height = max(1, Int((rect.height / Self.blockSize).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        self.image = small
        self.rect = CGRect(origin: rect.origin, size: CGSize(width: CGFloat(width) * Self.blockSize, height: CGFloat(height) * Self.blockSize))
    }
}

enum EditorRenderer {
    static let textFont = NSFont.systemFont(ofSize: 18, weight: .medium)

    static func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    static func textBounds(_ text: String, at point: CGPoint, width: CGFloat = .greatestFiniteMagnitude, fontSize: CGFloat = 18) -> CGRect {
        let rect = NSAttributedString(string: text, attributes: [.font: font(size: fontSize)]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGRect(origin: point, size: CGSize(width: min(width, ceil(rect.width)), height: ceil(rect.height)))
    }

    static func drawImage(
        _ image: NSImage,
        in rect: CGRect,
        respectFlipped: Bool = true,
        operation: NSCompositingOperation = .copy
    ) {
        image.draw(
            in: rect,
            from: .zero,
            operation: operation,
            fraction: 1,
            respectFlipped: respectFlipped,
            hints: [.interpolation: NSImageInterpolation.none]
        )
    }

    static func drawAnnotations(_ annotations: [Annotation], in context: CGContext, pixelSource: PixelSource? = nil) {
        for annotation in annotations { draw(annotation, in: context, pixelSource: pixelSource) }
    }

    /// Draws a CGImage upright into a flipped (top-left origin) context.
    static func drawFlipped(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    static func renderPNG(
        image: NSImage,
        displayBounds: CGRect,
        imageBounds: CGRect? = nil,
        selection: CGRect,
        annotations: [Annotation],
        scale: CGFloat
    ) -> Data? {
        let pixelWidth = max(1, Int((selection.width * scale).rounded()))
        let pixelHeight = max(1, Int((selection.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        context.clip(to: selection)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let imageRect = imageBounds ?? displayBounds
        drawImage(image, in: imageRect)
        let needsPixels = annotations.contains { if case .pixelate = $0 { true } else { false } }
        let pixelSource = needsPixels ? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .flatMap { PixelSource(image: $0, in: imageRect) } : nil
        drawAnnotations(annotations, in: context, pixelSource: pixelSource)
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: output)
        return representation.representation(using: .png, properties: [:])
    }

    private static func draw(_ annotation: Annotation, in context: CGContext, pixelSource: PixelSource?) {
        context.saveGState()
        switch annotation {
        case let .pixelate(rect):
            context.clip(to: rect)
            if let pixelSource {
                context.interpolationQuality = .none
                drawFlipped(pixelSource.image, in: pixelSource.rect, context: context)
            } else {
                context.setFillColor(NSColor.gray.cgColor)
                context.fill(rect)
            }
        case let .step(number, center, style):
            let radius = ShapeGeometry.stepRadius(for: style.width)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setFillColor(style.color.cgColor)
            context.fillEllipse(in: circle)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(max(1.5, radius / 8))
            context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold),
                .foregroundColor: style.color.contrastingLabelColor
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        case let .freehand(points, style):
            stroke(points: points, style: style, in: context)
        case let .highlighter(points, style):
            var highlighted = style
            highlighted.color = style.color.withAlphaComponent(0.35)
            highlighted.width *= 3
            stroke(points: points, style: highlighted, in: context)
        case let .rectangle(rect, style):
            apply(style, to: context)
            context.stroke(rect)
        case let .line(start, end, style):
            apply(style, to: context)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        case let .arrow(start, end, style):
            apply(style, to: context)
            context.move(to: start)
            context.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(10, style.width * 4)
            let spread = CGFloat.pi / 7
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
            context.move(to: end)
            context.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
            context.strokePath()
        case let .text(text, point, color, width, fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: fontSize),
                .foregroundColor: color
            ]
            NSAttributedString(string: text, attributes: attributes).draw(
                with: CGRect(origin: point, size: CGSize(width: width, height: textBounds(text, at: point, width: width, fontSize: fontSize).height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
        context.restoreGState()
    }

    private static func stroke(points: [CGPoint], style: AnnotationStyle, in context: CGContext) {
        guard let first = points.first else { return }
        apply(style, to: context)
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y + 0.01))
        } else {
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                context.addQuadCurve(to: midpoint, control: previous)
            }
            if let last = points.last { context.addLine(to: last) }
        }
        context.strokePath()
    }

    private static func apply(_ style: AnnotationStyle, to context: CGContext) {
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }
}

private extension NSColor {
    var contrastingLabelColor: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.65 ? .black : .white
    }
}
