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
    private let onClose: () -> Void
    private var didClose = false

    init(
        screen: NSScreen,
        image: CGImage,
        backgroundImage: CGImage? = nil,
        imageBounds: CGRect? = nil,
        initialSelection: CGRect? = nil,
        selectionLocked: Bool = false,
        onClose: @escaping () -> Void
    ) {
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
            selectionLocked: selectionLocked
        )

        panel.contentView = canvas
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        canvas.onCancel = { [weak self] in self?.close() }
        canvas.onCopy = { [weak self] data in self?.copy(data) }
        canvas.onSave = { [weak self] data in self?.save(data) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(canvas)
    }

    private func copy(_ pngData: Data) {
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
}

private enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

private enum CanvasInteraction {
    case selecting(start: CGPoint)
    case moving(start: CGPoint, original: CGRect)
    case resizing(handle: ResizeHandle, original: CGRect)
    case drawing(tool: EditorTool, start: CGPoint)
}

final class EditorCanvasView: NSView, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onCopy: ((Data) -> Void)?
    var onSave: ((Data) -> Void)?

    private let image: NSImage
    private let pixelScale: CGFloat
    private let backgroundImage: NSImage?
    private let imageBounds: CGRect
    private let history = AnnotationHistory()
    private let toolbar = EditorToolbar()
    private var selection: CGRect?
    private var activeTool: EditorTool?
    private var selectedColor = NSColor.systemRed
    private var selectedWidth: CGFloat = 3
    private var interaction: CanvasInteraction?
    private var currentStrokePoints: [CGPoint] = []
    private var previewAnnotation: Annotation?
    private var selectionLocked = false
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        image: NSImage,
        pixelScale: CGFloat,
        backgroundImage: NSImage? = nil,
        imageBounds: CGRect? = nil,
        initialSelection: CGRect? = nil,
        selectionLocked: Bool = false
    ) {
        self.image = image
        self.pixelScale = pixelScale
        self.backgroundImage = backgroundImage
        self.imageBounds = imageBounds ?? CGRect(origin: .zero, size: image.size)
        super.init(frame: CGRect(origin: .zero, size: backgroundImage?.size ?? image.size))
        selection = initialSelection
        self.selectionLocked = selectionLocked
        toolbar.frame.size = toolbar.preferredSize
        toolbar.updateShadowPath()
        addSubview(toolbar)
        configureToolbar()
        toolbar.isHidden = initialSelection == nil
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionLocked && activeTool == nil ? .arrow : .crosshair)
        if activeTool == .text, let selection {
            addCursorRect(selection, cursor: .iBeam)
            return
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // AppKit already clips this draw pass to dirtyRect. Drawing the image in its
        // stable full-screen coordinate space avoids remapping partial NSImage source
        // rectangles, whose Y axis is opposite to this flipped canvas.
        if let backgroundImage {
            EditorRenderer.drawImage(backgroundImage, in: bounds)
            EditorRenderer.drawImage(image, in: imageBounds, operation: .sourceOver)
        } else {
            EditorRenderer.drawImage(image, in: imageBounds)
        }

        if let selection {
            let mask = CGMutablePath()
            mask.addRect(bounds)
            mask.addRect(selection)
            context.addPath(mask)
            context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
            context.drawPath(using: .eoFill)

            context.saveGState()
            context.clip(to: selection)
            EditorRenderer.drawAnnotations(history.annotations, in: context)
            if let previewAnnotation {
                EditorRenderer.drawAnnotations([previewAnnotation], in: context)
            }
            if case let .drawing(tool, start) = interaction,
               (tool == .pencil || tool == .highlighter),
               let end = currentStrokePoints.last,
               let stroke = makeAnnotation(tool: tool, start: start, end: end, points: currentStrokePoints) {
                EditorRenderer.drawAnnotations([stroke], in: context)
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

        guard selection.contains(point), let activeTool else { return }
        let clamped = SelectionGeometry.clamped(point, to: selection)
        if activeTool == .text {
            beginText(at: clamped)
        } else {
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
                previewAnnotation = makeAnnotation(tool: tool, start: start, end: current, points: currentStrokePoints)
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
        case .selecting:
            guard let selection,
                  selection.width >= SelectionGeometry.minimumSize,
                  selection.height >= SelectionGeometry.minimumSize
            else {
                if let selection { invalidate(selection.insetBy(dx: -8, dy: -8)) }
                self.selection = nil
                toolbar.isHidden = true
                return
            }
            showToolbar()
        case .moving, .resizing:
            break
        case let .drawing(tool, start):
            guard let selection else { return }
            let end = SelectionGeometry.clamped(point, to: selection)
            if let annotation = makeAnnotation(tool: tool, start: start, end: end, points: currentStrokePoints) {
                history.append(annotation)
                selectionLocked = true
                updateHistoryButtons()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if textField != nil { commitText() }
    }

    private func configureToolbar() {
        toolbar.isHidden = true
        toolbar.onTool = { [weak self] tool in
            self?.activeTool = tool
            self?.toolbar.activeTool = tool
            if let self { self.window?.invalidateCursorRects(for: self) }
        }
        toolbar.onColor = { [weak self] color in self?.selectedColor = color }
        toolbar.onWidth = { [weak self] width in self?.selectedWidth = width }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onRedo = { [weak self] in self?.redo() }
        toolbar.onCopy = { [weak self] in self?.copyImage() }
        toolbar.onSave = { [weak self] in self?.saveImage() }
        toolbar.onClose = { [weak self] in self?.onCancel?() }
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
        case .text:
            return nil
        }
    }

    private func beginText(at point: CGPoint) {
        cancelText()
        guard let selection else { return }
        let width = min(240, selection.width)
        let height = min(26, selection.height)
        let origin = CGPoint(x: min(point.x, selection.maxX - width), y: min(point.y, selection.maxY - height))
        let field = NSTextField(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        field.delegate = self
        field.font = .systemFont(ofSize: 18, weight: .medium)
        field.textColor = selectedColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        field.isBezeled = true
        field.focusRingType = .none
        addSubview(field)
        textField = field
        textOrigin = origin
        window?.makeFirstResponder(field)
    }

    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        textField = nil
        textOrigin = nil
        if !text.isEmpty {
            history.append(.text(text, origin, selectedColor))
            selectionLocked = true
            updateHistoryButtons()
        }
        window?.makeFirstResponder(self)
        if let selection { invalidate(selection) }
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        textOrigin = nil
        window?.makeFirstResponder(self)
    }

    private func undo() {
        history.undo()
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func redo() {
        history.redo()
        updateHistoryButtons()
        if let selection { invalidate(selection) }
    }

    private func updateHistoryButtons() {
        toolbar.updateHistory(canUndo: history.canUndo, canRedo: history.canRedo)
    }

    func showCopySuccess() {
        toolbar.showCopySuccess()
    }

    func showSaveSuccess() {
        toolbar.showSaveSuccess()
    }

    private func copyImage() {
        guard let data = pngData() else { return }
        onCopy?(data)
    }

    private func saveImage() {
        guard let data = pngData() else { return }
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
        let maxX = max(bounds.minX + 8, bounds.maxX - size.width - 8)
        let maxY = max(bounds.minY + 8, bounds.maxY - size.height - 8)
        x = min(max(x, bounds.minX + 8), maxX)
        y = min(max(y, bounds.minY + 8), maxY)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard toolbar.frame != frame else { return }
        toolbar.frame = frame
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
        case let .text(text, point, _):
            rect = CGRect(x: point.x, y: point.y, width: CGFloat(text.count) * 11, height: 24)
            padding = 2
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
        setNeedsDisplay(clipped)
    }
}

final class EditorToolbar: NSVisualEffectView {
    var onTool: ((EditorTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    var activeTool: EditorTool? { didSet { updateToolButtons() } }
    private let stack = NSStackView()
    private var toolButtons: [EditorTool: ToolbarIconButton] = [:]
    private let undoButton = ToolbarIconButton()
    private let redoButton = ToolbarIconButton()
    private let closeButton = ToolbarIconButton()
    private let colorButton = ColorPaletteButton(color: .systemRed)
    private let widthButton = ToolbarActionButton(title: "3 px", symbol: "lineweight", prominent: false, width: 64)
    private let copyButton = ToolbarActionButton(title: "Copy", symbol: "doc.on.doc", prominent: false, width: 70)
    private let saveButton = ToolbarActionButton(title: "Save", symbol: "square.and.arrow.down", prominent: true, width: 70)
    private var selectedWidthIndex = 1
    private var colorPopover: NSPopover?
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

        for tool in EditorTool.allCases {
            let button = iconButton(symbol: tool.symbolName, label: tool.title, action: #selector(selectTool(_:)))
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
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
        let popover = NSPopover()
        let controller = ColorPaletteViewController(colors: choices, selectedColor: colorButton.color) { [weak self, weak popover] color in
            self?.colorButton.color = color
            self?.onColor?(color)
            popover?.performClose(nil)
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = CGSize(width: 166, height: 86)
        colorPopover = popover
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
    }

    @objc private func showWidthMenu() {
        let labels = ["Thin — 1 px", "Medium — 3 px", "Thick — 6 px"]
        let widths: [CGFloat] = [1, 3, 6]
        let menu = NSMenu()
        for index in labels.indices {
            let item = NSMenuItem(title: labels[index], action: #selector(selectWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedWidthIndex ? .on : .off
            item.image = Self.strokeSample(width: widths[index])
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: selectedWidthIndex), at: CGPoint(x: 0, y: widthButton.bounds.maxY + 4), in: widthButton)
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        let widths: [CGFloat] = [1, 3, 6]
        selectedWidthIndex = sender.tag
        let width = widths[sender.tag]
        widthButton.title = "\(Int(width)) px"
        widthButton.toolTip = "Line thickness: \(Int(width)) pixels"
        widthButton.setAccessibilityValue("\(Int(width)) pixels")
        onWidth?(width)
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

    private static func strokeSample(width: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: 24, height: 14), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: 3, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
            path.stroke()
            return true
        }
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

    init(colors: [(NSColor, String)], selectedColor: NSColor, onSelect: @escaping (NSColor) -> Void) {
        self.colors = colors
        self.selectedColor = selectedColor
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let vertical = NSStackView()
        vertical.orientation = .vertical
        vertical.alignment = .centerX
        vertical.spacing = 8
        for rowStart in stride(from: 0, to: colors.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for index in rowStart..<min(rowStart + 4, colors.count) {
                let choice = colors[index]
                let button = ColorSwatchButton(color: choice.0, name: choice.1, selected: choice.0.isEqual(selectedColor))
                button.tag = index
                button.target = self
                button.action = #selector(selectColor(_:))
                row.addArrangedSubview(button)
            }
            vertical.addArrangedSubview(row)
        }

        let container = NSView(frame: CGRect(origin: .zero, size: CGSize(width: 166, height: 86)))
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
