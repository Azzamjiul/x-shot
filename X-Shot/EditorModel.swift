import AppKit

enum EditorTool: Int, CaseIterable {
    case pencil
    case rectangle
    case line
    case arrow
    case highlighter
    case text
    case crop

    var symbolName: String {
        switch self {
        case .pencil: "pencil"
        case .rectangle: "rectangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .crop: "crop"
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
        case .crop: "Crop"
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
    case text(String, CGPoint, NSColor, width: CGFloat = .greatestFiniteMagnitude, fontSize: CGFloat = 18)
}

final class AnnotationHistory {
    private(set) var annotations: [Annotation] = []
    private enum Edit {
        case annotation(index: Int, before: Annotation?, after: Annotation?)
        case crop(before: CGRect?, after: CGRect?)
    }
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []
    private(set) var crop: CGRect?

    init(crop: CGRect? = nil) { self.crop = crop }

    var canUndo: Bool { !undoEdits.isEmpty }
    var canRedo: Bool { !redoEdits.isEmpty }

    func append(_ annotation: Annotation) {
        undoEdits.append(.annotation(index: annotations.count, before: nil, after: annotation))
        annotations.append(annotation)
        redoEdits.removeAll()
    }

    func replace(at index: Int, with annotation: Annotation) {
        undoEdits.append(.annotation(index: index, before: annotations[index], after: annotation))
        annotations[index] = annotation
        redoEdits.removeAll()
    }

    func remove(at index: Int) {
        undoEdits.append(.annotation(index: index, before: annotations[index], after: nil))
        annotations.remove(at: index)
        redoEdits.removeAll()
    }

    func setCrop(_ rect: CGRect?) {
        guard crop != rect else { return }
        undoEdits.append(.crop(before: crop, after: rect))
        crop = rect
        redoEdits.removeAll()
    }

    @discardableResult
    func undo() -> Int? {
        guard let edit = undoEdits.popLast() else { return nil }
        redoEdits.append(edit)
        switch edit {
        case let .crop(before, _):
            crop = before
            return nil
        case let .annotation(index, before, after):
            if let before {
                if after == nil { annotations.insert(before, at: index) }
                else { annotations[index] = before }
            } else { annotations.remove(at: index) }
            return before == nil ? nil : index
        }
    }

    @discardableResult
    func redo() -> Int? {
        guard let edit = redoEdits.popLast() else { return nil }
        undoEdits.append(edit)
        switch edit {
        case let .crop(_, after):
            crop = after
            return nil
        case let .annotation(index, before, after):
            if let after {
                if before == nil { annotations.insert(after, at: index) }
                else { annotations[index] = after }
            } else { annotations.remove(at: index) }
            return after == nil ? nil : index
        }
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

enum ShapeGeometry {
    static func style(for annotation: Annotation) -> AnnotationStyle? {
        switch annotation {
        case let .rectangle(_, style), let .line(_, _, style), let .arrow(_, _, style): style
        default: nil
        }
    }

    static func styled(_ annotation: Annotation, with style: AnnotationStyle) -> Annotation? {
        switch annotation {
        case let .rectangle(rect, _): .rectangle(rect, style)
        case let .line(start, end, _): .line(start, end, style)
        case let .arrow(start, end, _): .arrow(start, end, style)
        default: nil
        }
    }

    static func tool(for annotation: Annotation) -> EditorTool? {
        switch annotation {
        case .rectangle: .rectangle
        case .line: .line
        case .arrow: .arrow
        default: nil
        }
    }

    static func handles(for annotation: Annotation) -> [CGPoint] {
        switch annotation {
        case let .rectangle(rect, _):
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case let .line(start, end, _), let .arrow(start, end, _): [start, end]
        default: []
        }
    }

    static func contains(_ point: CGPoint, in annotation: Annotation) -> Bool {
        func nearSegment(_ start: CGPoint, _ end: CGPoint, tolerance: CGFloat) -> Bool {
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)) : 0
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= tolerance
        }
        switch annotation {
        case let .rectangle(rect, style):
            let tolerance = max(6, style.width / 2 + 3)
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case let .line(start, end, style), let .arrow(start, end, style):
            let tolerance = max(6, style.width / 2 + 3)
            if nearSegment(start, end, tolerance: tolerance) { return true }
            guard case .arrow = annotation else { return false }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(10, style.width * 4)
            return [-CGFloat.pi / 7, CGFloat.pi / 7].contains { spread in
                let tip = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
                return nearSegment(end, tip, tolerance: tolerance)
            }
        default: return false
        }
    }

    static func moved(_ annotation: Annotation, by delta: CGPoint, within bounds: CGRect) -> Annotation? {
        let points = handles(for: annotation)
        guard let first = points.first, let last = points.count == 4 ? points[2] : points.last else { return nil }
        let rect = SelectionGeometry.normalized(from: first, to: last)
        let moved = SelectionGeometry.moved(rect, by: delta, within: bounds)
        let dx = moved.minX - rect.minX, dy = moved.minY - rect.minY
        switch annotation {
        case let .rectangle(rect, style): return .rectangle(rect.offsetBy(dx: dx, dy: dy), style)
        case let .line(start, end, style):
            return .line(CGPoint(x: start.x + dx, y: start.y + dy), CGPoint(x: end.x + dx, y: end.y + dy), style)
        case let .arrow(start, end, style):
            return .arrow(CGPoint(x: start.x + dx, y: start.y + dy), CGPoint(x: end.x + dx, y: end.y + dy), style)
        default: return nil
        }
    }

    static func resized(_ annotation: Annotation, handle: Int, to point: CGPoint, within bounds: CGRect) -> Annotation? {
        let points = handles(for: annotation)
        guard points.indices.contains(handle) else { return nil }
        let point = SelectionGeometry.clamped(point, to: bounds)
        switch annotation {
        case let .rectangle(_, style):
            let rect = SelectionGeometry.normalized(from: points[(handle + 2) % 4], to: point)
            return rect.width >= 1 && rect.height >= 1 ? .rectangle(rect, style) : nil
        case let .line(start, end, style), let .arrow(start, end, style):
            let newStart = handle == 0 ? point : start
            let newEnd = handle == 1 ? point : end
            guard hypot(newEnd.x - newStart.x, newEnd.y - newStart.y) > 1 else { return nil }
            if case .line = annotation { return .line(newStart, newEnd, style) }
            return .arrow(newStart, newEnd, style)
        default: return nil
        }
    }
}
