import AppKit

enum EditorRenderer {
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

    static func drawAnnotations(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations { draw(annotation, in: context) }
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
        drawImage(image, in: imageBounds ?? displayBounds)
        drawAnnotations(annotations, in: context)
        NSGraphicsContext.restoreGraphicsState()

        guard let output = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: output)
        return representation.representation(using: .png, properties: [:])
    }

    private static func draw(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        switch annotation {
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
        case let .text(text, point, color):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: color
            ]
            NSAttributedString(string: text, attributes: attributes).draw(at: point)
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
