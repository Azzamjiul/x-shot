import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureMode {
    case area
    case window
    case fullScreen
}

@MainActor
final class CaptureCoordinator {
    private var activeSession: UUID?
    private var editor: OverlayEditorController?
    private var windowPicker: WindowPickerController?

    func startCapture(_ mode: CaptureMode = .area) {
        guard activeSession == nil else {
            editor?.show()
            windowPicker?.show()
            return
        }
        guard ensureScreenCapturePermission() else { return }

        let session = UUID()
        activeSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await captureDisplayUnderPointer()
                guard activeSession == session else { return }
                switch mode {
                case .area:
                    openEditor(session: session, snapshot: snapshot)
                case .fullScreen:
                    let bounds = CGRect(origin: .zero, size: snapshot.screen.frame.size)
                    openEditor(
                        session: session,
                        snapshot: snapshot,
                        imageBounds: bounds,
                        initialSelection: bounds,
                        selectionLocked: true
                    )
                case .window:
                    try beginWindowSelection(session: session, snapshot: snapshot)
                }
            } catch {
                failSession(session, message: "Could not start capture: \(error.localizedDescription)")
            }
        }
    }

    private func ensureScreenCapturePermission() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }

        let granted = CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = granted ? "Reopen X-Shot" : "Screen Recording permission required"
        alert.informativeText = granted
            ? "macOS granted access. Quit and reopen X-Shot before taking your first screenshot."
            : "Enable X-Shot in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen the app."
        if granted {
            alert.addButton(withTitle: "Quit X-Shot")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
        } else {
            alert.runModal()
        }
        return false
    }

    private func captureDisplayUnderPointer() async throws -> DisplaySnapshot {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            throw CaptureError.displayUnavailable
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = max(1, CGFloat(filter.pointPixelScale))
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.queueDepth = 1
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return DisplaySnapshot(
            screen: screen,
            displayFrame: display.frame,
            image: image,
            windows: orderedCaptureableWindows(content.windows, on: display.frame)
        )
    }

    private func beginWindowSelection(session: UUID, snapshot: DisplaySnapshot) throws {
        let canvasBounds = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        let targets = snapshot.windows.map { window in
            WindowTarget(
                windowID: window.windowID,
                frame: CaptureGeometry.localRect(
                    for: window.frame,
                    displayFrame: snapshot.displayFrame,
                    canvasBounds: canvasBounds
                ),
                label: windowLabel(window)
            )
        }
        guard !targets.isEmpty else { throw CaptureError.noWindows }

        let picker = WindowPickerController(screen: snapshot.screen, image: snapshot.image, targets: targets)
        picker.onCancel = { [weak self, weak picker] in
            picker?.close()
            self?.endSession(session)
        }
        picker.onSelect = { [weak self, weak picker] target in
            picker?.setCapturing()
            self?.captureWindow(target, session: session, snapshot: snapshot)
        }
        windowPicker = picker
        picker.show()
    }

    private func captureWindow(_ target: WindowTarget, session: UUID, snapshot: DisplaySnapshot) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    throw CaptureError.windowUnavailable
                }

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = max(1, CGFloat(filter.pointPixelScale))
                guard filter.contentRect.width > 0, filter.contentRect.height > 0 else {
                    throw CaptureError.windowUnavailable
                }
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
                configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
                configuration.showsCursor = false
                configuration.queueDepth = 1
                configuration.ignoreShadowsSingleWindow = true
                configuration.ignoreGlobalClipSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard activeSession == session else { return }

                let canvasBounds = CGRect(origin: .zero, size: snapshot.screen.frame.size)
                let localFrame = CaptureGeometry.localRect(
                    for: window.frame,
                    displayFrame: snapshot.displayFrame,
                    canvasBounds: canvasBounds
                )
                let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                let preferredFrame = CGRect(
                    x: localFrame.midX - pointSize.width / 2,
                    y: localFrame.midY - pointSize.height / 2,
                    width: pointSize.width,
                    height: pointSize.height
                )
                let imageBounds = CaptureGeometry.fitted(preferredFrame, within: canvasBounds)

                openEditor(
                    session: session,
                    snapshot: snapshot,
                    image: image,
                    backgroundImage: snapshot.image,
                    imageBounds: imageBounds,
                    initialSelection: imageBounds,
                    selectionLocked: true
                )
                windowPicker?.close()
                windowPicker = nil
            } catch {
                failSession(session, message: "Could not capture the window: \(error.localizedDescription)")
            }
        }
    }

    private func openEditor(
        session: UUID,
        snapshot: DisplaySnapshot,
        image: CGImage? = nil,
        backgroundImage: CGImage? = nil,
        imageBounds: CGRect? = nil,
        initialSelection: CGRect? = nil,
        selectionLocked: Bool = false
    ) {
        guard activeSession == session else { return }
        let editor = OverlayEditorController(
            screen: snapshot.screen,
            image: image ?? snapshot.image,
            backgroundImage: backgroundImage,
            imageBounds: imageBounds,
            initialSelection: initialSelection,
            selectionLocked: selectionLocked
        ) { [weak self] in
            self?.endSession(session)
        }
        self.editor = editor
        editor.show()
    }

    private func orderedCaptureableWindows(_ windows: [SCWindow], on displayFrame: CGRect) -> [SCWindow] {
        let processID = ProcessInfo.processInfo.processIdentifier
        let candidates = windows.filter {
            $0.isOnScreen
                && $0.windowLayer == 0
                && $0.owningApplication?.processID != processID
                && $0.frame.width >= 40
                && $0.frame.height >= 40
                && $0.frame.intersects(displayFrame)
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return candidates
        }
        var seen = Set<CGWindowID>()
        var ordered = windowInfo.compactMap { info -> SCWindow? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            let id = CGWindowID(number.uint32Value)
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        ordered.append(contentsOf: candidates.filter { seen.insert($0.windowID).inserted })
        return ordered
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [app, title].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " — ")
    }

    private func failSession(_ session: UUID, message: String) {
        guard activeSession == session else { return }
        windowPicker?.close()
        endSession(session)
        showError(message)
    }

    private func endSession(_ session: UUID) {
        guard activeSession == session else { return }
        editor = nil
        windowPicker = nil
        activeSession = nil
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "X-Shot"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct DisplaySnapshot {
    let screen: NSScreen
    let displayFrame: CGRect
    let image: CGImage
    let windows: [SCWindow]
}

private struct WindowTarget {
    let windowID: CGWindowID
    let frame: CGRect
    let label: String
}

@MainActor
private final class WindowPickerController {
    var onCancel: (() -> Void)?
    var onSelect: ((WindowTarget) -> Void)?

    private let panel: OverlayPanel
    private let pickerView: WindowPickerView
    private var didClose = false

    init(screen: NSScreen, image: CGImage, targets: [WindowTarget]) {
        panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        pickerView = WindowPickerView(
            image: NSImage(cgImage: image, size: screen.frame.size),
            targets: targets
        )
        panel.contentView = pickerView
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        pickerView.onCancel = { [weak self] in self?.onCancel?() }
        pickerView.onSelect = { [weak self] target in self?.onSelect?(target) }
    }

    func show() {
        guard !didClose else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(pickerView)
    }

    func setCapturing() {
        pickerView.isCapturing = true
    }

    func close() {
        guard !didClose else { return }
        didClose = true
        panel.orderOut(nil)
    }
}

private final class WindowPickerView: NSView {
    var onCancel: (() -> Void)?
    var onSelect: ((WindowTarget) -> Void)?
    var isCapturing = false {
        didSet {
            needsDisplay = true
            NSCursor.operationNotAllowed.set()
        }
    }

    private let image: NSImage
    private let targets: [WindowTarget]
    private var hoveredIndex: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, targets: [WindowTarget]) {
        self.image = image
        self.targets = targets
        super.init(frame: CGRect(origin: .zero, size: image.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Select a window to capture")
        setAccessibilityHelp("Move the pointer over a window and click. Press Escape to cancel.")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isCapturing ? .operationNotAllowed : .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        EditorRenderer.drawImage(image, in: bounds)
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.fill(bounds)

        if let hoveredIndex {
            let frame = targets[hoveredIndex].frame
            context.saveGState()
            context.clip(to: frame)
            EditorRenderer.drawImage(image, in: bounds)
            context.restoreGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(3)
            context.stroke(frame.insetBy(dx: 1.5, dy: 1.5))
        }
        drawHint(isCapturing ? "Capturing window…" : "Click a window  •  Esc to cancel")
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isCapturing else { return }
        updateHover(to: hitTargetIndex(with: event))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isCapturing else { return }
        updateHover(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCapturing, let index = hitTargetIndex(with: event) else { return }
        updateHover(to: index)
        isCapturing = true
        onSelect?(targets[index])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard !isCapturing else { return }
        switch event.keyCode {
        case 48, 123, 124, 125, 126:
            let backwards = event.keyCode == 123 || event.keyCode == 126
                || (event.keyCode == 48 && event.modifierFlags.contains(.shift))
            cycleSelection(backwards: backwards)
        case 36, 49, 76:
            let index = hoveredIndex ?? 0
            isCapturing = true
            onSelect?(targets[index])
        default:
            super.keyDown(with: event)
        }
    }

    private func hitTargetIndex(with event: NSEvent) -> Int? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        var belowWindow = window.windowNumber
        while true {
            let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: belowWindow)
            guard number > 0, number != belowWindow else { return nil }
            let id = CGWindowID(truncatingIfNeeded: number)
            if let index = targets.firstIndex(where: { $0.windowID == id }) { return index }
            belowWindow = number
        }
    }

    private func cycleSelection(backwards: Bool) {
        let offset = backwards ? -1 : 1
        let current = hoveredIndex ?? (backwards ? 0 : targets.count - 1)
        updateHover(to: (current + offset + targets.count) % targets.count)
    }

    private func updateHover(to index: Int?) {
        guard hoveredIndex != index else { return }
        let oldFrame = hoveredIndex.map { targets[$0].frame }
        hoveredIndex = index
        let newFrame = index.map { targets[$0].frame }
        if let oldFrame { setNeedsDisplay(oldFrame.insetBy(dx: -4, dy: -4)) }
        if let newFrame { setNeedsDisplay(newFrame.insetBy(dx: -4, dy: -4)) }
        if let index {
            NSCursor.pointingHand.set()
            setAccessibilityValue(targets[index].label.isEmpty ? "Window" : targets[index].label)
            NSAccessibility.post(element: self, notification: .valueChanged)
        } else {
            NSCursor.arrow.set()
            setAccessibilityValue("")
        }
    }

    private func drawHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let pill = CGRect(
            x: bounds.midX - textSize.width / 2 - 16,
            y: 24,
            width: textSize.width + 32,
            height: textSize.height + 14
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        attributed.draw(at: CGPoint(x: pill.minX + 16, y: pill.minY + 7))
    }
}

enum CaptureError: LocalizedError {
    case displayUnavailable
    case noWindows
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            "The display under the pointer is no longer available."
        case .noWindows:
            "No capturable windows are visible on this display."
        case .windowUnavailable:
            "The selected window is no longer available."
        }
    }
}
