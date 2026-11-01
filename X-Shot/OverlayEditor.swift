import AppKit
import QuartzCore
import UniformTypeIdentifiers

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayEditorController {
    private let panel: OverlayPanel
    private let canvas: EditorCanvasView
    private let selectionOnly: Bool
    private let onCapture: ((Data, CGRect) -> Void)?
    private let onCopy: ((Data) -> Bool)?
    private let onSave: ((Data) -> Bool)?
    private let onClose: () -> Void
    private let originalPNGData: Data?
    private var didClose = false

    init(
        screen: NSScreen,
        image: CGImage,
        backgroundImage: CGImage? = nil,
        imageBounds: CGRect? = nil,
        initialSelection: CGRect? = nil,
        selectionLocked: Bool = false,
        selectionOnly: Bool = false,
        originalPNGData: Data? = nil,
        onCapture: ((Data, CGRect) -> Void)? = nil,
        onCopy: ((Data) -> Bool)? = nil,
        onSave: ((Data) -> Bool)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.selectionOnly = selectionOnly
        self.originalPNGData = originalPNGData
        self.onCapture = onCapture
        self.onCopy = onCopy
        self.onSave = onSave
        self.onClose = onClose
        panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let resolvedImageBounds = imageBounds ?? CGRect(origin: .zero, size: screen.frame.size)
        let displayImage = NSImage(cgImage: image, size: resolvedImageBounds.size)
        let previewBackground = backgroundImage.map { NSImage(cgImage: $0, size: screen.frame.size) }
        let scale = CGFloat(image.width) / resolvedImageBounds.width
        canvas = EditorCanvasView(
            image: displayImage,
            pixelScale: scale,
            backgroundImage: previewBackground,
            imageBounds: resolvedImageBounds,
            initialSelection: initialSelection,
            selectionLocked: selectionLocked,
            selectionOnly: selectionOnly,
            canvasSize: screen.frame.size,
            originalPNGData: originalPNGData
        )

        panel.contentView = canvas
        panel.setFrame(screen.frame, display: false)
        panel.level = selectionOnly ? .screenSaver : .floating
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        canvas.onCancel = { [weak self] in self?.close() }
        canvas.onCapture = { [weak self] data, selection in self?.capture(data, selection: selection) }
        canvas.onCopy = { [weak self] data in self?.copy(data) }
        canvas.onSave = { [weak self] data in self?.save(data) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(canvas)
    }

    func currentPNGData() -> Data? { selectionOnly ? nil : canvas.currentPNGData(originalData: originalPNGData) }

    func finish() { close() }

    private func copy(_ pngData: Data) {
        if let onCopy {
            if onCopy(pngData) { canvas.showCopySuccess() }
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let image = NSImage(data: pngData), let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        guard pasteboard.writeObjects([item]) else {
            showError("Could not write the screenshot to the clipboard.")
            return
        }
        canvas.showCopySuccess()
    }

    private func save(_ pngData: Data) {
        if let onSave {
            if onSave(pngData) { canvas.showSaveSuccess() }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.allowsOtherFileTypes = false
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "X-Shot \(formatter.string(from: Date())).png"
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .OK, let url = savePanel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
                self.canvas.showSaveSuccess()
            } catch {
                self.showError("Could not save the screenshot: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "X-Shot"
        alert.informativeText = message
        alert.beginSheetModal(for: panel)
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        panel.orderOut(nil)
        onClose()
    }

    private func capture(_ data: Data, selection: CGRect) {
        guard !didClose else { return }
        didClose = true
        panel.orderOut(nil)
        onCapture?(data, selection)
    }
}

private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private enum CanvasInteraction {
    case selecting(start: CGPoint)
    case moving(start: CGPoint, original: CGRect)
    case resizing(handle: ResizeHandle, original: CGRect)
    case drawing(tool: EditorTool, start: CGPoint)
    case editingShape(index: Int, start: CGPoint, original: Annotation, handle: Int?)
    case placingText(start: CGPoint, current: CGPoint)
    case movingText(index: Int, start: CGPoint, original: Annotation)
    case resizingText(index: Int, start: CGPoint, original: Annotation, left: Bool)
}

final class EditorCanvasView: NSView, NSTextViewDelegate {
    var onCancel: (() -> Void)?
    var onCapture: ((Data, CGRect) -> Void)?
    var onCopy: ((Data) -> Void)?
    var onSave: ((Data) -> Void)?

    private let image: NSImage
    private let pixelScale: CGFloat
    private let imageBounds: CGRect
    private let history: AnnotationHistory
    private let toolbar = EditorToolbar()
    private var toolbarOrigin: CGPoint?
    private var selection: CGRect?
    private var activeTool: EditorTool?
    private var selectedColor = EditorPreferences.color
    private var selectedWidth = EditorPreferences.width
    private var selectedFontSize: CGFloat = 18
    private var interaction: CanvasInteraction?
    private var currentStrokePoints: [CGPoint] = []
    private var previewAnnotation: Annotation?
    private var selectionLocked = false
    private let selectionOnly: Bool
    private let originalPNGData: Data?
    private var textView: AnnotationTextView?
    private var textEditor: NSScrollView?
    private var editingTextIndex: Int?
    /// Click-placed text grows with its content; a dragged box keeps its width.
    private var textAutoWidth = false
    private var selectedTextIndex: Int?
    private var selectedShapeIndex: Int?
    private let overlay = AnnotationOverlayView()
    /// The frozen screen, composited once and shown through the layer so drags
    /// never re-blit a full-screen bitmap.
    private var screenImage: CGImage?
    private lazy var pixelSource: PixelSource? = screenImage.flatMap { PixelSource(image: $0, in: bounds) }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        image: NSImage,
        pixelScale: CGFloat,
        backgroundImage: NSImage? = nil,
        imageBounds: CGRect? = nil,
        initialSelection: CGRect? = nil,
        selectionLocked: Bool = false,
        selectionOnly: Bool = false,
        canvasSize: CGSize? = nil,
        originalPNGData: Data? = nil
    ) {
        self.image = image
        self.pixelScale = pixelScale
        self.imageBounds = imageBounds ?? CGRect(origin: .zero, size: image.size)
        self.selectionOnly = selectionOnly
        self.originalPNGData = originalPNGData
        history = AnnotationHistory(crop: initialSelection)
        super.init(frame: CGRect(origin: .zero, size: canvasSize ?? backgroundImage?.size ?? image.size))
        selection = initialSelection
        self.selectionLocked = selectionLocked
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        screenImage = Self.compositeScreen(image: image, imageBounds: self.imageBounds,
                                           backgroundImage: backgroundImage, size: bounds.size, scale: pixelScale)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.canvas = self
        addSubview(overlay)
        toolbar.frame.size = toolbar.preferredSize
        toolbar.updateShadowPath()
        addSubview(toolbar)
        configureToolbar()
        toolbar.isHidden = initialSelection == nil
    }

    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.contents = screenImage
    }

    private static func compositeScreen(image: NSImage, imageBounds: CGRect, backgroundImage: NSImage?, size: CGSize, scale: CGFloat) -> CGImage? {
        // Common case: the capture already covers the whole canvas, so reuse it without a copy.
        if backgroundImage == nil, imageBounds == CGRect(origin: .zero, size: size),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage
        }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        if let backgroundImage { EditorRenderer.drawImage(backgroundImage, in: CGRect(origin: .zero, size: size)) }
        EditorRenderer.drawImage(image, in: imageBounds, operation: backgroundImage == nil ? .copy : .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionLocked && activeTool == nil ? .arrow : .crosshair)
        if activeTool == .text, let selection {
            addCursorRect(selection, cursor: .iBeam)
            for case let .text(text, origin, _, width, fontSize) in history.annotations {
                addCursorRect(EditorRenderer.textBounds(text, at: origin, width: width, fontSize: fontSize).insetBy(dx: -4, dy: -4).intersection(selection), cursor: .openHand)
            }
            if textEditor == nil, let box = selectedTextBox() {
                for left in [true, false] {
                    addCursorRect(textResizeHandle(box, left: left).intersection(selection), cursor: .resizeLeftRight)
                }
            }
            return
        }
        if let selection, let tool = activeTool, [.rectangle, .line, .arrow].contains(tool) {
            if let annotation = selectedShape() {
                for point in ShapeGeometry.handles(for: annotation) {
                    addCursorRect(shapeHandle(at: point).intersection(selection), cursor: .crosshair)
                }
            }
        }
        guard !selectionLocked, activeTool == nil, let selection else { return }
        addCursorRect(selection, cursor: .openHand)
        for handle in ResizeHandle.allCases {
            let cursor: NSCursor
            switch handle {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight: cursor = .crosshair
            }
            addCursorRect(handleRect(handle, for: selection).insetBy(dx: -4, dy: -4), cursor: cursor)
        }
    }

    /// Draws the dim mask, annotations, and handles above the layer-backed screenshot.
    /// Only annotations that intersect the dirty rectangle are rendered.
    fileprivate func drawOverlay(_ dirtyRect: NSRect, in context: CGContext) {
        if let selection {
            let mask = CGMutablePath()
            mask.addRect(bounds)
            mask.addRect(selection)
            context.addPath(mask)
            context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
            context.drawPath(using: .eoFill)

            context.saveGState()
            context.clip(to: selection)
            var annotations = history.annotations
            if let editingTextIndex { annotations.remove(at: editingTextIndex) }
            switch interaction {
            case let .movingText(index, _, _), let .resizingText(index, _, _, _), let .editingShape(index, _, _, _):
                if let previewAnnotation { annotations[index] = previewAnnotation }
            default: break
            }
            if case .drawing = interaction, let previewAnnotation { annotations.append(previewAnnotation) }
            let visible = annotations.filter { annotationBounds($0).intersects(dirtyRect) }
            EditorRenderer.drawAnnotations(visible, in: context, pixelSource: pixelSource)
            if case let .drawing(tool, start) = interaction,
               (tool == .pencil || tool == .highlighter),
               let end = currentStrokePoints.last,
               let stroke = makeAnnotation(tool: tool, start: start, end: end, points: currentStrokePoints) {
                EditorRenderer.drawAnnotations([stroke], in: context, pixelSource: pixelSource)
            }
            if let annotation = selectedShape() {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                for point in ShapeGeometry.handles(for: annotation) { context.fill(shapeHandle(at: point)) }
            }
            if activeTool == .text, textEditor == nil, let box = selectedTextBox() {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1)
                context.stroke(box)
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                for left in [true, false] { context.fill(textResizeHandle(box, left: left)) }
            }
            if case let .placingText(start, current) = interaction {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1)
                context.stroke(SelectionGeometry.normalized(from: start, to: current))
            }
            context.restoreGState()

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
            if !selectionLocked { drawHandles(for: selection, in: context) }
        } else {
            context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
            context.fill(bounds)
        }
    }

    override func layout() {
        super.layout()
        positionToolbar()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        guard let selection else {
            interaction = .selecting(start: point)
            self.selection = CGRect(origin: point, size: .zero)
            toolbar.isHidden = true
            return
        }

        if !selectionLocked, let handle = resizeHandle(at: point, for: selection) {
            interaction = .resizing(handle: handle, original: selection)
            return
        }

        if !selectionLocked, activeTool == nil {
            if selection.contains(point) {
                interaction = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
            } else {
                interaction = .selecting(start: point)
                self.selection = CGRect(origin: point, size: .zero)
                toolbar.isHidden = true
                invalidateSelection(from: selection, to: self.selection)
            }
            return
        }

        // Clicking away while typing only finishes the text instead of opening another box.
        if let textEditor, !textEditor.frame.contains(point) {
            commitText()
            return
        }
        guard selection.contains(point), let activeTool else { return }
        let clamped = SelectionGeometry.clamped(point, to: selection)
        if activeTool == .text {
            if let index = selectedTextIndex, let box = selectedTextBox(),
               let left = [true, false].first(where: { textResizeHandle(box, left: $0).contains(point) }) {
                interaction = .resizingText(index: index, start: point, original: history.annotations[index], left: left)
                return
            }
            if let index = history.annotations.indices.reversed().first(where: { index in
                guard case let .text(text, origin, _, width, fontSize) = history.annotations[index] else { return false }
                return EditorRenderer.textBounds(text, at: origin, width: width, fontSize: fontSize).insetBy(dx: -4, dy: -4).contains(point)
            }) {
                selectedTextIndex = index
                updateSelectedStyle()
                invalidate(selection)
                window?.invalidateCursorRects(for: self)
                if event.clickCount >= 2 {
                    beginText(at: point, editing: index)
                } else {
                    interaction = .movingText(index: index, start: point, original: history.annotations[index])
                    NSCursor.closedHand.set()
                }
            } else {
                selectedTextIndex = nil
                invalidate(selection)
                interaction = .placingText(start: clamped, current: clamped)
            }
        } else {
            if [.rectangle, .line, .arrow].contains(activeTool) {
                if let index = selectedShapeIndex, let annotation = selectedShape(),
                   let handle = ShapeGeometry.handles(for: annotation).firstIndex(where: { shapeHandle(at: $0).contains(point) }) {
                    interaction = .editingShape(index: index, start: point, original: history.annotations[index], handle: handle)
                    return
                }
                selectedShapeIndex = history.annotations.indices.reversed().first {
                    ShapeGeometry.tool(for: history.annotations[$0]) == activeTool
                        && ShapeGeometry.contains(point, in: history.annotations[$0])
                }
                selectedTextIndex = nil
                updateSelectedStyle()
                invalidate(selection)
                window?.invalidateCursorRects(for: self)
                if let index = selectedShapeIndex {
                    interaction = .editingShape(index: index, start: point, original: history.annotations[index], handle: nil)
                    NSCursor.closedHand.set()
                    return
                }
            }
            currentStrokePoints = [clamped]
            interaction = .drawing(tool: activeTool, start: clamped)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let interaction else { return }
        let oldSelection = selection
        let oldPreview = previewAnnotation

        switch interaction {
        case let .editingShape(_, start, original, handle):
            guard let selection else { return }
            if let handle {
                let anchor = ShapeGeometry.handles(for: original)[handle]
                previewAnnotation = ShapeGeometry.resized(original, handle: handle,
                    to: CGPoint(x: anchor.x + point.x - start.x, y: anchor.y + point.y - start.y), within: selection)
            } else {
                previewAnnotation = ShapeGeometry.moved(original,
                    by: CGPoint(x: point.x - start.x, y: point.y - start.y), within: selection)
            }
            invalidate(selection)
            return
        case let .resizingText(_, start, original, left):
            guard let selection, case let .text(text, origin, color, width, fontSize) = original else { return }
            let right = min(origin.x + width, selection.maxX)
            let delta = point.x - start.x
            let minimumWidth = min(24, right - selection.minX)
            let x = left ? min(max(origin.x + delta, selection.minX), right - minimumWidth) : origin.x
            let newWidth = left ? right - x : min(max(width + delta, min(24, selection.maxX - x)), selection.maxX - x)
            previewAnnotation = .text(text, CGPoint(x: x, y: origin.y), color, width: newWidth, fontSize: fontSize)
            invalidate(selection)
            return
        case let .placingText(start, current):
            guard let selection else { return }
            let next = SelectionGeometry.clamped(point, to: selection)
            self.interaction = .placingText(start: start, current: next)
            invalidate(SelectionGeometry.normalized(from: start, to: current)
                .union(SelectionGeometry.normalized(from: start, to: next)).insetBy(dx: -2, dy: -2))
            return
        case let .movingText(_, start, original):
            guard let selection, case let .text(text, origin, color, width, fontSize) = original else { return }
            let textBounds = EditorRenderer.textBounds(text, at: origin, width: width, fontSize: fontSize)
            let movableBounds = CGRect(origin: origin, size: CGSize(
                width: min(textBounds.width, selection.width),
                height: min(textBounds.height, selection.height)
            ))
            let moved = SelectionGeometry.moved(movableBounds,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y), within: selection)
            let oldBox = selectedTextBox()
            previewAnnotation = .text(text, moved.origin, color, width: width, fontSize: fontSize)
            invalidateAnnotations(oldPreview ?? original, previewAnnotation)
            if let oldBox, let newBox = selectedTextBox() {
                invalidate(oldBox.union(newBox).insetBy(dx: -6, dy: -6))
            }
            return
        case let .selecting(start):
            selection = SelectionGeometry.normalized(from: start, to: SelectionGeometry.clamped(point, to: bounds))
        case let .moving(start, original):
            selection = SelectionGeometry.moved(
                original,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                within: bounds
            )
        case let .resizing(handle, original):
            selection = resized(original, with: handle, to: SelectionGeometry.clamped(point, to: bounds))
        case let .drawing(tool, start):
            guard let selection else { return }
            let current = SelectionGeometry.clamped(point, to: selection)
            if tool == .pencil || tool == .highlighter {
                let last = currentStrokePoints.last ?? current
                guard hypot(current.x - last.x, current.y - last.y) >= 0.75 else { return }
                currentStrokePoints.append(current)
                let width = selectedWidth * (tool == .highlighter ? 3 : 1)
                // Adding a point reshapes the previous quadratic tail too.
                let changedPoints = Array(currentStrokePoints.suffix(3))
                invalidate(pointsBounds(changedPoints).insetBy(dx: -width - 2, dy: -width - 2))
            } else {
                let end = event.modifierFlags.contains(.shift) ? ShapeGeometry.constrained(tool: tool, start: start, end: current) : current
                previewAnnotation = makeAnnotation(tool: tool, start: start, end: SelectionGeometry.clamped(end, to: selection), points: currentStrokePoints)
                invalidateAnnotations(oldPreview, previewAnnotation)
            }
        }
        if case .drawing = interaction {
            return
        } else {
            positionToolbar()
            invalidateSelection(from: oldSelection, to: selection)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            interaction = nil
            previewAnnotation = nil
            currentStrokePoints.removeAll(keepingCapacity: true)
            positionToolbar()
            if let selection { invalidate(selection.insetBy(dx: -8, dy: -8)) }
            window?.invalidateCursorRects(for: self)
        }
        guard let interaction else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch interaction {
        case let .placingText(start, _):
            guard let selection else { return }
            let rect = SelectionGeometry.normalized(from: start, to: SelectionGeometry.clamped(point, to: selection))
            beginText(at: start, box: rect.width >= 24 && rect.height >= 24 ? rect : nil)
        case .selecting:
            guard let selection,
                  selection.width >= SelectionGeometry.minimumSize,
                  selection.height >= SelectionGeometry.minimumSize
            else {
                invalidateSelection(from: self.selection, to: history.crop)
                self.selection = history.crop
                toolbar.isHidden = self.selection == nil
                return
            }
            if selectionOnly {
                if let data = pngData() { onCapture?(data, selection) }
            } else {
                history.setCrop(selection)
                updateHistoryButtons()
                showToolbar()
            }
        case let .editingShape(index, _, original, _):
            guard let previewAnnotation,
                  ShapeGeometry.handles(for: original) != ShapeGeometry.handles(for: previewAnnotation) else { return }
            history.replace(at: index, with: previewAnnotation)
            updateHistoryButtons()
        case let .movingText(index, _, original), let .resizingText(index, _, original, _):
            guard let previewAnnotation,
                  case let .text(_, oldOrigin, _, oldWidth, _) = original,
                  case let .text(_, newOrigin, _, newWidth, _) = previewAnnotation,
                  oldOrigin != newOrigin || oldWidth != newWidth else { return }
            history.replace(at: index, with: previewAnnotation)
            updateHistoryButtons()
        case .moving, .resizing:
            if !selectionOnly {
                history.setCrop(selection)
                updateHistoryButtons()
            }
        case let .drawing(tool, start):
            guard let selection else { return }
            var end = SelectionGeometry.clamped(point, to: selection)
            if event.modifierFlags.contains(.shift) {
                end = SelectionGeometry.clamped(ShapeGeometry.constrained(tool: tool, start: start, end: end), to: selection)
            }
            if let annotation = makeAnnotation(tool: tool, start: start, end: end, points: currentStrokePoints) {
                history.append(annotation)
                if ShapeGeometry.tool(for: annotation) != nil { selectedShapeIndex = history.annotations.count - 1 }
                updateHistoryButtons()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if (event.keyCode == 51 || event.keyCode == 117), textView == nil {
            let index = activeTool == .text ? selectedTextIndex : selectedShapeIndex
            guard interaction == nil, let index, history.annotations.indices.contains(index),
                  (activeTool == .text && selectedTextIndex == index) || selectedShape() != nil else { return }
            selectedTextIndex = nil
            selectedShapeIndex = nil
            history.remove(at: index)
            updateHistoryButtons()
            if let selection { invalidate(selection) }
        } else if textView == nil, handleShortcut(event) {
            return
        } else {
            super.keyDown(with: event)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, interaction == nil, selection != nil, !toolbar.isHidden,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "[", "]":
            let delta: CGFloat = key == "]" ? 1 : -1
            if activeTool == .text { setTextFontSize(selectedFontSize + delta * 2) }
            else { setAnnotationWidth(min(max(selectedWidth + delta, StrokeWidth.range.lowerBound), StrokeWidth.range.upperBound)) }
            return true
        default:
            guard let tool = EditorTool.forShortcut(key), tool != .crop || !selectionLocked else { return false }
            toolbar.onTool?(tool)
            return true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": copyImage(); return true
        case "s": saveImage(); return true
        case "z" where modifiers.contains(.shift): redo(); return true
        case "z": undo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === textView else { return }
        fitTextEditor()
    }

    private func fitTextEditor() {
        guard let view = textView, let editor = textEditor, let selection else { return }
        let font = view.font ?? EditorRenderer.font(size: selectedFontSize)
        let size = font.pointSize
        var frame = editor.frame
        if textAutoWidth {
            let natural = EditorRenderer.textBounds(view.string, at: .zero, fontSize: size).width
            frame.size.width = min(max(natural + size, size * 2) + 8, selection.maxX - frame.minX)
        }
        let textHeight = EditorRenderer.textBounds(view.string.isEmpty ? " " : view.string, at: .zero,
                                                   width: frame.width - 8, fontSize: size).height
        frame.size.height = min(max(textHeight, ceil(font.ascender - font.descender + font.leading)) + 8, selection.maxY - frame.minY)
        guard frame != editor.frame else { return }
        editor.frame = frame
        view.textContainer?.containerSize = CGSize(width: max(1, frame.width - 8), height: .greatestFiniteMagnitude)
        view.frame.size = editor.contentSize
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, view === textView else { return }
        commitText()
    }

    private func configureToolbar() {
        toolbar.isHidden = true
        toolbar.setCropEnabled(!selectionLocked)
        if !selectionLocked { toolbar.activeTool = .crop }
        toolbar.onMove = { [weak self] origin in
            self?.toolbarOrigin = origin
            self?.positionToolbar()
        }
        toolbar.onTool = { [weak self] tool in
            self?.commitText()
            self?.activeTool = tool == .crop ? nil : tool
            self?.toolbar.activeTool = tool
            self?.updateSelectedStyle()
            if let self { self.window?.invalidateCursorRects(for: self) }
        }
        toolbar.onColor = { [weak self] color in self?.setAnnotationColor(color) }
        toolbar.onWidth = { [weak self] width in self?.setAnnotationWidth(width) }
        toolbar.onFontSize = { [weak self] size in self?.setTextFontSize(size) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onCopy = { [weak self] in self?.copyImage() }
        toolbar.onSave = { [weak self] in self?.saveImage() }
        toolbar.onClose = { [weak self] in self?.onCancel?() }
        toolbar.annotationColor = selectedColor
        toolbar.strokeWidth = selectedWidth
    }

    private func makeAnnotation(tool: EditorTool, start: CGPoint, end: CGPoint, points: [CGPoint]) -> Annotation? {
        let style = AnnotationStyle(color: selectedColor, width: selectedWidth)
        switch tool {
        case .pencil:
            return .freehand(points.isEmpty ? [start, end] : points, style)
        case .rectangle:
            let rect = SelectionGeometry.normalized(from: start, to: end)
            return rect.width > 1 && rect.height > 1 ? .rectangle(rect, style) : nil
        case .line:
            return hypot(end.x - start.x, end.y - start.y) > 1 ? .line(start, end, style) : nil
        case .arrow:
            return hypot(end.x - start.x, end.y - start.y) > 1 ? .arrow(start, end, style) : nil
        case .highlighter:
            return .highlighter(points.isEmpty ? [start, end] : points, style)
        case .pixelate:
            let rect = SelectionGeometry.normalized(from: start, to: end)
            return rect.width > 2 && rect.height > 2 ? .pixelate(rect) : nil
        case .step:
            let next = history.annotations.reduce(0) { if case let .step(number, _, _) = $1 { max($0, number) } else { $0 } } + 1
            return .step(next, end, style)
        case .text, .crop:
            return nil
        }
    }

    private func updateSelectedStyle() {
        if let index = selectedTextIndex, history.annotations.indices.contains(index),
           case let .text(_, _, color, _, fontSize) = history.annotations[index] {
            selectedFontSize = fontSize
            if activeTool == .text { selectedColor = color }
        }
        if let annotation = selectedShape(), let style = ShapeGeometry.style(for: annotation) {
            selectedColor = style.color
            selectedWidth = style.width
        }
        toolbar.textFontSize = selectedFontSize
        toolbar.annotationColor = selectedColor
        toolbar.strokeWidth = selectedWidth
    }

    private func setAnnotationWidth(_ width: CGFloat) {
        guard StrokeWidth.isValid(width) else { return }
        selectedWidth = width
        EditorPreferences.width = width
        toolbar.strokeWidth = width
        guard let annotation = selectedShape(), var style = ShapeGeometry.style(for: annotation) else { return }
        style.width = width
        setShapeStyle(style)
    }

    private func setShapeStyle(_ style: AnnotationStyle) {
        guard let index = selectedShapeIndex, let annotation = selectedShape(),
              let oldStyle = ShapeGeometry.style(for: annotation),
              oldStyle.width != style.width || !oldStyle.color.isEqual(style.color),
              let updated = ShapeGeometry.styled(annotation, with: style) else { return }
        history.replace(at: index, with: updated)
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func setAnnotationColor(_ color: NSColor) {
        selectedColor = color
        EditorPreferences.color = color
        EditorPreferences.addRecentColor(color)
        toolbar.annotationColor = color
        if let annotation = selectedShape(), var style = ShapeGeometry.style(for: annotation) {
            style.color = color
            setShapeStyle(style)
            return
        }
        guard activeTool == .text else { return }
        if let view = textView {
            view.textColor = color
            view.typingAttributes[.foregroundColor] = color
            view.insertionPointColor = color
            return
        }
        guard let index = selectedTextIndex, history.annotations.indices.contains(index),
              case let .text(text, origin, oldColor, width, fontSize) = history.annotations[index],
              !oldColor.isEqual(color) else { return }
        history.replace(at: index, with: .text(text, origin, color, width: width, fontSize: fontSize))
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func setTextFontSize(_ size: CGFloat) {
        guard size.isFinite, (8...144).contains(size) else { return }
        selectedFontSize = size
        toolbar.textFontSize = size
        if let view = textView {
            view.font = EditorRenderer.font(size: size)
            view.typingAttributes[.font] = EditorRenderer.font(size: size)
            fitTextEditor()
            return
        }
        guard let index = selectedTextIndex, history.annotations.indices.contains(index),
              case let .text(text, origin, color, width, oldSize) = history.annotations[index],
              oldSize != size else { return }
        history.replace(at: index, with: .text(text, origin, color, width: width, fontSize: size))
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func selectedShape() -> Annotation? {
        guard let index = selectedShapeIndex, history.annotations.indices.contains(index),
              let tool = activeTool, ShapeGeometry.tool(for: history.annotations[index]) == tool else { return nil }
        if case .editingShape = interaction { return previewAnnotation ?? history.annotations[index] }
        return history.annotations[index]
    }

    private func shapeHandle(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }

    private func selectedTextBox() -> CGRect? {
        guard let index = selectedTextIndex, history.annotations.indices.contains(index), let selection else { return nil }
        let annotation = previewAnnotation ?? history.annotations[index]
        guard case let .text(text, origin, _, width, fontSize) = annotation else { return nil }
        let height = max(24, EditorRenderer.textBounds(text, at: origin, width: width, fontSize: fontSize).height)
        return CGRect(origin: origin, size: CGSize(width: min(width, selection.maxX - origin.x), height: height)).intersection(selection)
    }

    private func textResizeHandle(_ box: CGRect, left: Bool) -> CGRect {
        CGRect(x: (left ? box.minX : box.maxX) - 4, y: box.midY - 4, width: 8, height: 8)
    }

    private func beginText(at point: CGPoint, box: CGRect? = nil, editing index: Int? = nil) {
        commitText()
        guard let selection else { return }
        var text = ""
        var color = selectedColor
        textAutoWidth = box == nil
        var rect = box ?? CGRect(origin: point, size: CGSize(width: 40, height: 30))
        if let index, case let .text(value, origin, originalColor, width, fontSize) = history.annotations[index] {
            text = value
            color = originalColor
            selectedFontSize = fontSize
            toolbar.textFontSize = fontSize
            let size = EditorRenderer.textBounds(value, at: origin, width: width, fontSize: fontSize).size
            textAutoWidth = false
            rect = CGRect(x: origin.x - 4, y: origin.y - 4,
                          width: min(width + 8, selection.width), height: size.height + 8)
        }
        rect.size.width = min(rect.width, selection.width)
        rect.size.height = min(rect.height, selection.height)
        rect = SelectionGeometry.moved(rect, by: .zero, within: selection)
        // Transparent, borderless-looking editor: what you type is what gets exported.
        let editor = NSScrollView(frame: rect)
        editor.hasVerticalScroller = false
        editor.drawsBackground = false
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 3
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        editor.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        let view = AnnotationTextView(frame: CGRect(origin: .zero, size: editor.contentSize))
        view.delegate = self
        view.font = EditorRenderer.font(size: selectedFontSize)
        view.textColor = color
        view.drawsBackground = false
        view.insertionPointColor = color
        view.isRichText = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = CGSize(width: 0, height: editor.contentSize.height)
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainerInset = CGSize(width: 4, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = CGSize(width: max(1, rect.width - 8), height: .greatestFiniteMagnitude)
        view.string = text
        view.typingAttributes = [.font: EditorRenderer.font(size: selectedFontSize), .foregroundColor: color]
        view.toolTip = "Enter: new line · ⌘Enter or click outside: finish · Esc: cancel"
        view.setAccessibilityLabel("Screenshot text")
        view.onCommit = { [weak self] in self?.commitText() }
        view.onCancel = { [weak self] in self?.cancelText() }
        editor.documentView = view
        textEditor = editor
        textView = view
        editingTextIndex = index
        addSubview(editor)
        window?.makeFirstResponder(view)
        fitTextEditor()
        if let selection = self.selection { invalidate(selection) }
    }

    private func commitText() {
        guard let view = textView, let editor = textEditor else { return }
        let text = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = editingTextIndex
        let origin = CGPoint(x: editor.frame.minX + 4, y: editor.frame.minY + 4)
        let width = max(1, editor.contentSize.width - 8)
        let color = view.textColor ?? selectedColor
        let fontSize = view.font?.pointSize ?? selectedFontSize
        // Clear editing state before focus/removal can send another end-edit notification.
        textView = nil
        textEditor = nil
        editingTextIndex = nil
        window?.makeFirstResponder(self)
        editor.removeFromSuperview()
        if !text.isEmpty {
            let annotation = Annotation.text(text, origin, color, width: width, fontSize: fontSize)
            if let index { history.replace(at: index, with: annotation) }
            else { history.append(annotation) }
            selectedTextIndex = index ?? history.annotations.count - 1
            updateHistoryButtons()
        }
        if let selection { invalidate(selection) }
        window?.invalidateCursorRects(for: self)
    }

    private func cancelText() {
        let editor = textEditor
        textView = nil
        textEditor = nil
        editingTextIndex = nil
        window?.makeFirstResponder(self)
        editor?.removeFromSuperview()
        updateSelectedStyle()
        if let selection { invalidate(selection) }
    }

    private func undo() {
        commitText()
        selectedTextIndex = history.undo()
        selectedShapeIndex = selectedTextIndex
        restoreHistoryCrop()
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func redo() {
        commitText()
        selectedTextIndex = history.redo()
        selectedShapeIndex = selectedTextIndex
        restoreHistoryCrop()
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func restoreHistoryCrop() {
        let previous = selection
        selection = history.crop
        toolbar.isHidden = selection == nil
        positionToolbar()
        invalidateSelection(from: previous, to: selection)
    }

    private func updateHistoryButtons() {
        if let index = selectedShapeIndex,
           !history.annotations.indices.contains(index) || ShapeGeometry.tool(for: history.annotations[index]) == nil {
            selectedShapeIndex = nil
        }
        if let index = selectedTextIndex {
            if !history.annotations.indices.contains(index) { selectedTextIndex = nil }
            else {
                switch history.annotations[index] {
                case .text: break
                default: selectedTextIndex = nil
                }
            }
        }
        updateSelectedStyle()
        toolbar.updateHistory(canUndo: history.canUndo, canRedo: history.canRedo)
        window?.invalidateCursorRects(for: self)
    }

    func showCopySuccess() {
        toolbar.showCopySuccess()
    }

    func showSaveSuccess() {
        toolbar.showSaveSuccess()
    }

    private func copyImage() {
        guard let data = currentPNGData(originalData: originalPNGData) else { return }
        onCopy?(data)
    }

    private func saveImage() {
        guard let data = currentPNGData(originalData: originalPNGData) else { return }
        onSave?(data)
    }

    private func pngData() -> Data? {
        guard let selection,
              selection.width >= SelectionGeometry.minimumSize,
              selection.height >= SelectionGeometry.minimumSize
        else { return nil }
        commitText()
        return EditorRenderer.renderPNG(
            image: image,
            displayBounds: bounds,
            imageBounds: imageBounds,
            selection: selection,
            annotations: history.annotations,
            scale: pixelScale
        )
    }

    func currentPNGData(originalData: Data? = nil) -> Data? {
        commitText()
        if selectionLocked, history.annotations.isEmpty, let originalData { return originalData }
        return pngData()
    }

    private func drawHandles(for selection: CGRect, in context: CGContext) {
        context.setFillColor(NSColor.white.cgColor)
        for handle in ResizeHandle.allCases {
            context.fill(handleRect(handle, for: selection))
        }
    }

    private func resizeHandle(at point: CGPoint, for selection: CGRect) -> ResizeHandle? {
        ResizeHandle.allCases.first { handleRect($0, for: selection).insetBy(dx: -3, dy: -3).contains(point) }
    }

    private func handleRect(_ handle: ResizeHandle, for rect: CGRect) -> CGRect {
        let point: CGPoint
        switch handle {
        case .topLeft: point = CGPoint(x: rect.minX, y: rect.minY)
        case .top: point = CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: point = CGPoint(x: rect.maxX, y: rect.minY)
        case .right: point = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: point = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: point = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: point = CGPoint(x: rect.minX, y: rect.maxY)
        case .left: point = CGPoint(x: rect.minX, y: rect.midY)
        }
        return CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }

    private func resized(_ rect: CGRect, with handle: ResizeHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        }
        minX = min(minX, maxX - SelectionGeometry.minimumSize)
        minY = min(minY, maxY - SelectionGeometry.minimumSize)
        maxX = max(maxX, minX + SelectionGeometry.minimumSize)
        maxY = max(maxY, minY + SelectionGeometry.minimumSize)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func positionToolbar() {
        guard let selection else { return }
        let size = toolbar.preferredSize
        var x = selection.minX
        let below = selection.maxY + 8
        let above = selection.minY - size.height - 8
        var y: CGFloat
        if below + size.height <= bounds.maxY {
            y = below
        } else if above >= bounds.minY {
            y = above
        } else {
            x = selection.midX - size.width / 2
            y = bounds.maxY - size.height - 8
        }
        if let toolbarOrigin {
            x = toolbarOrigin.x
            y = toolbarOrigin.y
        }
        let maxX = max(bounds.minX + 8, bounds.maxX - size.width - 8)
        let maxY = max(bounds.minY + 8, bounds.maxY - size.height - 8)
        x = min(max(x, bounds.minX + 8), maxX)
        y = min(max(y, bounds.minY + 8), maxY)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard toolbar.frame != frame else { return }
        toolbar.frame = frame
        if toolbarOrigin != nil { toolbarOrigin = frame.origin }
        toolbar.updateShadowPath()
    }

    private func showToolbar() {
        positionToolbar()
        toolbar.alphaValue = 0
        toolbar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toolbar.animator().alphaValue = 1
        }
    }

    private func invalidateSelection(from old: CGRect?, to new: CGRect?) {
        var dirty = CGRect.null
        if let old { dirty = dirty.union(old.insetBy(dx: -8, dy: -8)) }
        if let new { dirty = dirty.union(new.insetBy(dx: -8, dy: -8)) }
        invalidate(dirty)
    }

    private func invalidateAnnotations(_ old: Annotation?, _ new: Annotation?) {
        var dirty = CGRect.null
        if let old { dirty = dirty.union(annotationBounds(old)) }
        if let new { dirty = dirty.union(annotationBounds(new)) }
        invalidate(dirty)
    }

    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        let rect: CGRect
        let padding: CGFloat
        switch annotation {
        case let .freehand(points, style):
            rect = pointsBounds(points)
            padding = style.width + 2
        case let .highlighter(points, style):
            rect = pointsBounds(points)
            padding = style.width * 3 + 2
        case let .rectangle(value, style):
            rect = value
            padding = style.width + 2
        case let .line(start, end, style):
            rect = pointsBounds([start, end])
            padding = style.width + 2
        case let .arrow(start, end, style):
            rect = pointsBounds([start, end])
            padding = max(14, style.width * 5)
        case let .text(text, point, _, width, fontSize):
            rect = EditorRenderer.textBounds(text, at: point, width: width, fontSize: fontSize)
            padding = 2
        case let .pixelate(value):
            rect = value
            padding = 1
        case let .step(_, center, style):
            rect = CGRect(origin: center, size: .zero)
            padding = ShapeGeometry.stepRadius(for: style.width) + 4
        }
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    private func pointsBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func invalidate(_ rect: CGRect) {
        guard !rect.isNull else { return }
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        overlay.setNeedsDisplay(clipped)
    }
}

/// Transparent drawing surface for annotations. Mouse events pass through to the canvas.
private final class AnnotationOverlayView: NSView {
    weak var canvas: EditorCanvasView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawOverlay(dirtyRect, in: context)
    }
}

final class EditorToolbar: NSVisualEffectView {
    var onMove: ((CGPoint) -> Void)?
    private var dragOffset: CGPoint?
    var onTool: ((EditorTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    var activeTool: EditorTool? { didSet { updateToolButtons(); updateSizeButton() } }
    var textFontSize: CGFloat = 18 { didSet { updateSizeButton() } }
    var annotationColor: NSColor = .systemRed { didSet { colorButton.color = annotationColor } }
    private let stack = NSStackView()
    private var toolButtons: [EditorTool: ToolbarIconButton] = [:]
    private let undoButton = ToolbarIconButton()
    private let redoButton = ToolbarIconButton()
    private let closeButton = ToolbarIconButton()
    private let colorButton = ColorPaletteButton(color: .systemRed)
    private let widthButton = ToolbarActionButton(title: "3 px", symbol: "lineweight", prominent: false, width: 64)
    private let copyButton = ToolbarActionButton(title: "Copy", symbol: "doc.on.doc", prominent: false, width: 70)
    private let saveButton = ToolbarActionButton(title: "Save", symbol: "square.and.arrow.down", prominent: true, width: 70)
    var strokeWidth: CGFloat = 3 { didSet { updateSizeButton() } }
    private var colorPopover: NSPopover?
    private var widthPopover: NSPopover?
    private var feedbackTask: Task<Void, Never>?

    private(set) lazy var preferredSize: CGSize = {
        let fitting = stack.fittingSize
        return CGSize(width: fitting.width + 16, height: max(46, fitting.height + 14))
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])

        let grip = NSImageView()
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move toolbar")
        grip.contentTintColor = .secondaryLabelColor
        grip.toolTip = "Drag to move toolbar"
        grip.widthAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(grip)

        for tool in EditorTool.allCases {
            let button = iconButton(symbol: tool.symbolName, label: tool.title, action: #selector(selectTool(_:)))
            button.toolTip = "\(tool.title) (\(tool.shortcutKey.uppercased()))"
            button.tag = tool.rawValue
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())

        colorButton.target = self
        colorButton.action = #selector(showColorPalette)
        colorButton.toolTip = "Color"
        colorButton.setAccessibilityLabel("Annotation color")
        stack.addArrangedSubview(colorButton)

        widthButton.target = self
        widthButton.action = #selector(showWidthMenu)
        widthButton.toolTip = "Line thickness: 3 pixels"
        widthButton.setAccessibilityLabel("Line thickness")
        widthButton.setAccessibilityValue("3 pixels")
        stack.addArrangedSubview(widthButton)
        stack.addArrangedSubview(separator())

        configure(button: undoButton, symbol: "arrow.uturn.backward", label: "Undo", action: #selector(undo))
        configure(button: redoButton, symbol: "arrow.uturn.forward", label: "Redo", action: #selector(redo))
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        stack.addArrangedSubview(separator())
        configureAction(button: copyButton, label: "Copy", toolTip: "Copy (⌘C)", action: #selector(copyImage))
        configureAction(button: saveButton, label: "Save", toolTip: "Save (⌘S)", action: #selector(saveImage))
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(saveButton)
        stack.addArrangedSubview(separator())
        configure(button: closeButton, symbol: "xmark", label: "Close screenshot editor", action: #selector(closeEditor))
        closeButton.toolTip = "Close (Esc)"
        closeButton.setAccessibilityHelp("Discards this capture")
        stack.addArrangedSubview(closeButton)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSControl, !(current is NSImageView) { return hit }
            view = current.superview
        }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        dragOffset = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview, let dragOffset else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        onMove?(CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    func setCropEnabled(_ enabled: Bool) {
        toolButtons[.crop]?.isEnabled = enabled
    }

    func updateHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    func showCopySuccess() {
        showSuccess(on: copyButton, title: "Copied", announcement: "Copied to clipboard")
    }

    func showSaveSuccess() {
        showSuccess(on: saveButton, title: "Saved", announcement: "Screenshot saved")
    }

    func updateShadowPath() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = EditorTool(rawValue: sender.tag) else { return }
        onTool?(tool)
    }

    @objc private func showColorPalette() {
        let choices: [(NSColor, String)] = [
            (.systemRed, "Red"), (.systemOrange, "Orange"), (.systemYellow, "Yellow"), (.systemGreen, "Green"),
            (.systemBlue, "Blue"), (.systemPurple, "Purple"), (.black, "Black"), (.white, "White")
        ]
        let recents = EditorPreferences.recentColors
            .filter { recent in !choices.contains { $0.0.hexString == recent.hexString } }
            .map { ($0, $0.hexString.map { "Recent \($0.prefix(7))" } ?? "Recent") }
        let popover = NSPopover()
        let controller = ColorPaletteViewController(colors: choices, recentColors: recents, selectedColor: colorButton.color) { [weak self, weak popover] color in
            self?.colorButton.color = color
            self?.onColor?(color)
            popover?.performClose(nil)
        } onCustom: { [weak self, weak popover] in
            popover?.performClose(nil)
            self?.showColorPanel()
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        colorPopover = popover
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
    }

    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = false
        panel.color = colorButton.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        // The editor floats above normal windows; keep the picker reachable.
        panel.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? NSWindow.Level.floating.rawValue) + 1)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        colorButton.color = sender.color
        onColor?(sender.color)
    }

    @objc private func showWidthMenu() {
        if activeTool == .text {
            let menu = NSMenu()
            for size in [12, 14, 18, 24, 32, 48, 64, 96] {
                let item = NSMenuItem(title: "\(size) pt", action: #selector(selectFontSize(_:)), keyEquivalent: "")
                item.target = self
                item.tag = size
                item.state = CGFloat(size) == textFontSize ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: widthButton.bounds.maxY + 4), in: widthButton)
            return
        }
        let popover = NSPopover()
        let controller = StrokeWidthViewController(width: strokeWidth, color: annotationColor) { [weak self] width in
            self?.strokeWidth = width
            self?.onWidth?(width)
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        widthPopover = popover
        popover.show(relativeTo: widthButton.bounds, of: widthButton, preferredEdge: .maxY)
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        onFontSize?(CGFloat(sender.tag))
    }

    private func updateSizeButton() {
        let isText = activeTool == .text
        let size = isText ? textFontSize : strokeWidth
        widthButton.title = "\(Int(size)) \(isText ? "pt" : "px")"
        widthButton.toolTip = isText ? "Font size: \(Int(size)) points" : "Line thickness: \(Int(size)) pixels"
        widthButton.setAccessibilityLabel(isText ? "Font size" : "Line thickness")
        widthButton.setAccessibilityValue("\(Int(size)) \(isText ? "points" : "pixels")")
    }

    @objc private func undo() { onUndo?() }
    @objc private func redo() { onRedo?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func saveImage() { onSave?() }
    @objc private func closeEditor() { onClose?() }

    private func updateToolButtons() {
        for (tool, button) in toolButtons { button.isSelected = tool == activeTool }
    }

    private func iconButton(symbol: String, label: String, action: Selector) -> ToolbarIconButton {
        let button = ToolbarIconButton()
        configure(button: button, symbol: symbol, label: label, action: action)
        return button
    }

    private func configure(button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func configureAction(button: ToolbarActionButton, label: String, toolTip: String, action: Selector) {
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setAccessibilityLabel(label)
    }

    private func showSuccess(on button: ToolbarActionButton, title: String, announcement: String) {
        feedbackTask?.cancel()
        resetExportFeedback()
        button.showSuccess(title: title)
        NSAccessibility.post(
            element: button,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.resetExportFeedback()
        }
    }

    private func resetExportFeedback() {
        copyButton.resetFeedback()
        saveButton.resetFeedback()
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return separator
    }
}

private class PointingHandButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class ToolbarIconButton: PointingHandButton {
    var isSelected = false { didSet { refreshAppearance() } }
    private var isHovered = false
    private var isPressed = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { refreshAppearance() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.cornerRadius = 8
        let fill: NSColor
        if isSelected {
            fill = .controlAccentColor
        } else if isPressed {
            fill = NSColor.white.withAlphaComponent(0.18)
        } else if isHovered {
            fill = NSColor.white.withAlphaComponent(0.11)
        } else {
            fill = .clear
        }
        animateBackground(to: fill.cgColor)
        contentTintColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.88)
        alphaValue = isEnabled ? 1 : 0.38
        setAccessibilityValue(isSelected ? "Selected" : "")
    }

    private func animateBackground(to color: CGColor) {
        guard let layer else { return }
        if window != nil, let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = current
            animation.toValue = color
            animation.duration = 0.09
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "backgroundColor")
        }
        layer.backgroundColor = color
    }
}

private final class ToolbarActionButton: PointingHandButton {
    private let prominent: Bool
    private let defaultTitle: String
    private let defaultSymbol: String
    private var isHovered = false
    private var isPressed = false
    private var isSuccessful = false
    private var hoverTrackingArea: NSTrackingArea?

    init(title: String, symbol: String, prominent: Bool, width: CGFloat) {
        self.prominent = prominent
        defaultTitle = title
        defaultSymbol = symbol
        super.init(frame: .zero)
        self.title = title
        image = configuredSymbol(symbol, description: title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleProportionallyDown
        alignment = .center
        font = .systemFont(ofSize: 12, weight: .semibold)
        isBordered = false
        wantsLayer = true
        contentTintColor = .white
        setButtonType(.momentaryPushIn)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refreshAppearance() }
    override func highlight(_ flag: Bool) { super.highlight(flag); isPressed = flag; refreshAppearance() }

    func showSuccess(title: String) {
        self.title = title
        image = configuredSymbol("checkmark", description: title)
        isSuccessful = true
        setAccessibilityValue(title)
        refreshAppearance()
    }

    func resetFeedback() {
        guard isSuccessful else { return }
        title = defaultTitle
        image = configuredSymbol(defaultSymbol, description: defaultTitle)
        isSuccessful = false
        setAccessibilityValue("")
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.cornerRadius = 8
        let base = isSuccessful ? NSColor.systemGreen : prominent ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.11)
        let hover = (prominent || isSuccessful) ? base.blended(withFraction: 0.16, of: .white) ?? base : NSColor.white.withAlphaComponent(0.18)
        let color = (isPressed ? base.withAlphaComponent(0.72) : isHovered ? hover : base).cgColor
        guard let layer else { return }
        if window != nil, let current = layer.presentation()?.backgroundColor ?? layer.backgroundColor {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = current
            animation.toValue = color
            animation.duration = 0.09
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "backgroundColor")
        }
        layer.backgroundColor = color
    }

    private func configuredSymbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }
}

private final class ColorPaletteButton: PointingHandButton {
    var color: NSColor { didSet { needsDisplay = true; setAccessibilityValue(color.accessibilityName) } }
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityValue(color.accessibilityName)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 5, dy: 5)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.22 : isHovered ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        color.setFill()
        let swatch = NSBezierPath(ovalIn: circle)
        swatch.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        swatch.lineWidth = 1
        swatch.stroke()
    }
}

private final class ColorPaletteViewController: NSViewController {
    private let colors: [(NSColor, String)]
    private let selectedColor: NSColor
    private let onSelect: (NSColor) -> Void
    private let onCustom: () -> Void

    init(colors: [(NSColor, String)], recentColors: [(NSColor, String)] = [], selectedColor: NSColor,
         onSelect: @escaping (NSColor) -> Void, onCustom: @escaping () -> Void = {}) {
        self.colors = colors + recentColors
        self.presetCount = colors.count
        self.selectedColor = selectedColor
        self.onSelect = onSelect
        self.onCustom = onCustom
        super.init(nibName: nil, bundle: nil)
    }

    private let presetCount: Int

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .centerX
        vertical.spacing = 8
        func addRows(_ range: Range<Int>) {
            for rowStart in stride(from: range.lowerBound, to: range.upperBound, by: 4) {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 8
                for index in rowStart..<min(rowStart + 4, range.upperBound) {
                    let choice = colors[index]
                    let selected = choice.0.isEqual(selectedColor) || choice.0.hexString == selectedColor.hexString
                    let button = ColorSwatchButton(color: choice.0, name: choice.1, selected: selected)
                    button.tag = index
                    button.target = self
                    button.action = #selector(selectColor(_:))
                    row.addArrangedSubview(button)
                }
                vertical.addArrangedSubview(row)
            }
        }
        addRows(0..<presetCount)
        if colors.count > presetCount {
            let label = NSTextField(labelWithString: "Recent")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            vertical.addArrangedSubview(label)
            addRows(presetCount..<colors.count)
        }
        let custom = NSButton(title: "Custom Color…", target: self, action: #selector(chooseCustom))
        custom.bezelStyle = .rounded
        custom.controlSize = .small
        custom.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        custom.imagePosition = .imageLeading
        vertical.addArrangedSubview(custom)

        let height = vertical.fittingSize.height + 24
        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: 166, height: height)))
        vertical.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vertical)
        NSLayoutConstraint.activate([
            vertical.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            vertical.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    @objc private func selectColor(_ sender: ColorSwatchButton) {
        onSelect(colors[sender.tag].0)
    }

    @objc private func chooseCustom() { onCustom() }
}

private final class StrokeWidthViewController: NSViewController {
    private var width: CGFloat
    private let color: NSColor
    private let onChange: (CGFloat) -> Void
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let preview = StrokePreviewView()

    init(width: CGFloat, color: NSColor, onChange: @escaping (CGFloat) -> Void) {
        self.width = width
        self.color = color
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        slider.minValue = Double(StrokeWidth.range.lowerBound)
        slider.maxValue = Double(StrokeWidth.range.upperBound)
        slider.doubleValue = Double(width)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.setAccessibilityLabel("Line thickness")
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        preview.color = color
        preview.heightAnchor.constraint(equalToConstant: 44).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        let presets = NSStackView(views: [1, 3, 6, 12, 24].map { value in
            let button = NSButton(title: "\(value)", target: self, action: #selector(selectPreset(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = value
            return button
        })
        presets.orientation = .horizontal
        presets.spacing = 4
        let stack = NSStackView(views: [preview, row, presets])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.frame.size = stack.fittingSize
        view = stack
        update()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        width = CGFloat(sender.doubleValue.rounded())
        update()
        // Apply on release so one drag is one undo step.
        if NSApp.currentEvent?.type != .leftMouseDragged { onChange(width) }
    }

    @objc private func selectPreset(_ sender: NSButton) {
        width = CGFloat(sender.tag)
        slider.doubleValue = Double(width)
        update()
        onChange(width)
    }

    private func update() {
        valueLabel.stringValue = "\(Int(width)) px"
        preview.width = width
    }
}

private final class StrokePreviewView: NSView {
    var width: CGFloat = 3 { didSet { needsDisplay = true } }
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: 12 + width / 2, y: bounds.midY))
        path.curve(to: CGPoint(x: bounds.maxX - 12 - width / 2, y: bounds.midY),
                   controlPoint1: CGPoint(x: bounds.midX - 30, y: bounds.minY + 4),
                   controlPoint2: CGPoint(x: bounds.midX + 30, y: bounds.maxY - 4))
        color.setStroke()
        path.stroke()
    }
}

private final class ColorSwatchButton: PointingHandButton {
    private let color: NSColor
    private let selected: Bool

    init(color: NSColor, name: String, selected: Bool) {
        self.color = color
        self.selected = selected
        super.init(frame: .zero)
        isBordered = false
        toolTip = name
        setAccessibilityLabel(name)
        setAccessibilityValue(selected ? "Selected" : "")
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 1, dy: 1)
        if selected || isHighlighted {
            (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setStroke()
            let ring = NSBezierPath(ovalIn: outer)
            ring.lineWidth = selected ? 2.5 : 1.5
            ring.stroke()
        }
        let swatch = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        color.setFill()
        swatch.fill()
        NSColor.separatorColor.setStroke()
        swatch.lineWidth = 1
        swatch.stroke()
    }
}

private extension NSColor {
    var accessibilityName: String {
        if isEqual(NSColor.systemRed) { return "Red" }
        if isEqual(NSColor.systemOrange) { return "Orange" }
        if isEqual(NSColor.systemYellow) { return "Yellow" }
        if isEqual(NSColor.systemGreen) { return "Green" }
        if isEqual(NSColor.systemBlue) { return "Blue" }
        if isEqual(NSColor.systemPurple) { return "Purple" }
        if isEqual(NSColor.black) { return "Black" }
        if isEqual(NSColor.white) { return "White" }
        return "Color"
    }
}

private final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            onCommit?()
        } else if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
