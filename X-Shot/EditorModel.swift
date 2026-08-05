import AppKit

enum EditorTool: Int, CaseIterable {
    case pencil
    case rectangle
    case line
    case arrow
    case highlighter
    case text

    var symbolName: String {
        switch self {
        case .pencil: "pencil"
        case .rectangle: "rectangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .highlighter: "highlighter"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .pencil: "Pencil"
        case .rectangle: "Rectangle"
        case .line: "Line"
        case .arrow: "Arrow"
        case .highlighter: "Highlighter"
        case .text: "Text"
        }
    }
}

struct AnnotationStyle {
    var color: NSColor
    var width: CGFloat
}

enum Annotation {
    case freehand([CGPoint], AnnotationStyle)
    case rectangle(CGRect, AnnotationStyle)
    case line(CGPoint, CGPoint, AnnotationStyle)
    case arrow(CGPoint, CGPoint, AnnotationStyle)
    case highlighter([CGPoint], AnnotationStyle)
    case text(String, CGPoint, NSColor)
}

final class AnnotationHistory {
    private(set) var annotations: [Annotation] = []
    private(set) var redoAnnotations: [Annotation] = []

    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !redoAnnotations.isEmpty }

    func append(_ annotation: Annotation) {
        annotations.append(annotation)
        redoAnnotations.removeAll()
    }

    func undo() {
        guard let annotation = annotations.popLast() else { return }
        redoAnnotations.append(annotation)
    }

    func redo() {
        guard let annotation = redoAnnotations.popLast() else { return }
        annotations.append(annotation)
    }
}

enum SelectionGeometry {
    static let minimumSize: CGFloat = 12

    static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    static func moved(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: rect.origin.x + delta.x, y: rect.origin.y + delta.y)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - rect.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(origin: origin, size: rect.size)
    }

    static func pixelRect(for selection: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (selection.minX * scale).rounded(),
            y: (selection.minY * scale).rounded(),
            width: (selection.width * scale).rounded(),
            height: (selection.height * scale).rounded()
        )
    }
}

enum CaptureGeometry {
    static func localRect(for globalRect: CGRect, displayFrame: CGRect, canvasBounds: CGRect) -> CGRect {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return .zero }
        let scaleX = canvasBounds.width / displayFrame.width
        let scaleY = canvasBounds.height / displayFrame.height
        return CGRect(
            x: canvasBounds.minX + (globalRect.minX - displayFrame.minX) * scaleX,
            y: canvasBounds.minY + (globalRect.minY - displayFrame.minY) * scaleY,
            width: globalRect.width * scaleX,
            height: globalRect.height * scaleY
        )
    }

    static func fitted(_ rect: CGRect, within bounds: CGRect, margin: CGFloat = 16) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: min(margin, bounds.width / 4), dy: min(margin, bounds.height / 4))
        let scale = min(1, available.width / rect.width, available.height / rect.height)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, available.minX), available.maxX - size.width)
        origin.y = min(max(origin.y, available.minY), available.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
