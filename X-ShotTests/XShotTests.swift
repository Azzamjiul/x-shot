import AppKit
import XCTest
@testable import X_Shot

final class XShotTests: XCTestCase {
    func testCaptureShortcutRequiresNonShiftModifierAndFormatsLabel() throws {
        let valid = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "8", charactersIgnoringModifiers: "8", isARepeat: false, keyCode: 28))
        XCTAssertEqual(CaptureShortcut(event: valid)?.label, "⇧⌘8")
        let invalid = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "8", charactersIgnoringModifiers: "8", isARepeat: false, keyCode: 28))
        XCTAssertNil(CaptureShortcut(event: invalid))
    }

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

    func testHistoryRestoresTextMoveAndPreservesOtherAnnotations() throws {
        let history = AnnotationHistory()
        history.append(.text("Hello", CGPoint(x: 10, y: 20), .red))
        history.append(.rectangle(CGRect(x: 50, y: 50, width: 20, height: 20), AnnotationStyle(color: .blue, width: 3)))
        history.replace(at: 0, with: .text("Hello", CGPoint(x: 80, y: 90), .red))
        history.undo()
        guard case let .text(text, origin, color, _, _) = history.annotations[0] else { return XCTFail("Missing text") }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(color, .red)
        XCTAssertEqual(history.annotations.count, 2)
        history.redo()
        guard case let .text(_, moved, _, _, _) = history.annotations[0] else { return XCTFail("Missing moved text") }
        XCTAssertEqual(moved, CGPoint(x: 80, y: 90))
        history.undo()
        history.undo()
        XCTAssertEqual(history.annotations.count, 1)
        history.redo()
        history.redo()
        XCTAssertEqual(history.annotations.count, 2)
        history.undo()
        history.replace(at: 0, with: .text("Hello", .zero, .red))
        XCTAssertFalse(history.canRedo)
    }

    func testTextDragExportsMovedTextAndUndoesAsOneAction() throws {
        let canvas = EditorCanvasView(
            image: NSImage(size: CGSize(width: 1000, height: 700)), pixelScale: 1,
            initialSelection: CGRect(x: 0, y: 0, width: 1000, height: 700), selectionLocked: true
        )
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let textTool = try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" })
        textTool.performClick(nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let field = try XCTUnwrap(editor.documentView as? NSTextView)
        field.string = "Move me 👋 WWW"
        let original = try XCTUnwrap(canvas.currentPNGData())
        let start = CGPoint(x: 110, y: 110)
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 150, y: 150)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 250, y: 200)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 250, y: 200)))
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        let moved = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertNotEqual(original, moved)
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), moved)
        // A click without movement must not add another history entry.
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 250, y: 200)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 250, y: 200)))
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        // The text stays reachable when dragged outside the screenshot.
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: -500, y: -500)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: -500, y: -500)))
        let atEdge = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertNotEqual(atEdge, original)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
    }

    func testTextBoxWrapsCommitsOnceAndReopensWithoutDuplicate() throws {
        let canvas = EditorCanvasView(
            image: NSImage(size: CGSize(width: 1000, height: 700)), pixelScale: 1,
            initialSelection: CGRect(x: 0, y: 0, width: 1000, height: 700), selectionLocked: true
        )
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" }).performClick(nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 0
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 240, y: 220)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 240, y: 220)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(editor.frame.width, 140)
        let view = try XCTUnwrap(editor.documentView as? NSTextView)
        view.string = "Long text with several words to wrap inside this box 👋"
        view.insertNewline(nil)
        view.insertText("Second paragraph", replacementRange: view.selectedRange())
        XCTAssertTrue(view.string.contains("\n"))
        view.layoutManager?.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let used = try XCTUnwrap(view.layoutManager?.usedRect(for: try XCTUnwrap(view.textContainer)))
        let measured = EditorRenderer.textBounds(view.string, at: .zero, width: editor.contentSize.width - 8)
        XCTAssertGreaterThan(measured.height, EditorRenderer.textFont.pointSize * 2)
        XCTAssertEqual(ceil(used.height), measured.height, accuracy: 1)
        let text = view.string
        let committed = try XCTUnwrap(canvas.currentPNGData())
        canvas.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: view))
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        let sentinel = Data("original".utf8)
        XCTAssertEqual(canvas.currentPNGData(originalData: sentinel), sentinel)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), committed)

        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 110, y: 110), clicks: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 110, y: 110), clicks: 2))
        let reopened = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let editView = try XCTUnwrap(reopened.documentView as? NSTextView)
        XCTAssertEqual(editView.string, text)
        editView.string = "Updated text"
        let changed = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertNotEqual(changed, committed)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), committed)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(originalData: sentinel), sentinel)
        redo.performClick(nil)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 110, y: 110), clicks: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 110, y: 110), clicks: 2))
        let activeEditor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        try XCTUnwrap(activeEditor.documentView as? NSTextView).string = "Undo while typing"
        undo.performClick(nil)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSScrollView }.isEmpty)
        XCTAssertEqual(canvas.currentPNGData(), committed)
    }

    func testTextResizeRewrapsInPlaceAndUndoesAsOneAction() throws {
        let image = NSImage(size: CGSize(width: 1000, height: 700))
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" }).performClick(nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: end.y)))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = "Resize this text box to wrap these words onto more lines 👋"
        let typed = try XCTUnwrap(editor.documentView as? NSTextView)
        typed.string = text
        typed.didChangeText()
        let width = editor.contentSize.width - 8
        let origin = CGPoint(x: 104, y: 104)
        let original = try XCTUnwrap(canvas.currentPNGData())
        func height(_ width: CGFloat) -> CGFloat {
            max(24, EditorRenderer.textBounds(text, at: origin, width: width).height)
        }
        func expected(_ origin: CGPoint, _ width: CGFloat) throws -> Data {
            try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
                selection: selection, annotations: [.text(text, origin, .systemRed, width: width)], scale: 1))
        }
        let right = CGPoint(x: origin.x + width, y: origin.y + height(width) / 2)
        try drag(right, CGPoint(x: origin.x + 140, y: right.y))
        let narrow = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertEqual(narrow, try expected(origin, 140))
        XCTAssertNotEqual(narrow, original)
        XCTAssertGreaterThan(height(140), height(width))
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), narrow)

        // Select the existing text, then resize its left edge without moving its right edge.
        let point = CGPoint(x: 114, y: 114)
        canvas.mouseDown(with: try event(.leftMouseDown, point))
        canvas.mouseUp(with: try event(.leftMouseUp, point))
        let left = CGPoint(x: origin.x, y: origin.y + height(140) / 2)
        try drag(left, CGPoint(x: origin.x + 40, y: left.y))
        XCTAssertEqual(canvas.currentPNGData(), try expected(CGPoint(x: 144, y: 104), 100))
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), narrow)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)

        canvas.mouseDown(with: try event(.leftMouseDown, point))
        canvas.mouseUp(with: try event(.leftMouseUp, point))
        try drag(right, CGPoint(x: 5000, y: right.y))
        XCTAssertEqual(canvas.currentPNGData(), try expected(origin, selection.maxX - origin.x))
        undo.performClick(nil)
        canvas.mouseDown(with: try event(.leftMouseDown, point))
        canvas.mouseUp(with: try event(.leftMouseUp, point))
        try drag(right, CGPoint(x: -5000, y: right.y))
        XCTAssertEqual(canvas.currentPNGData(), try expected(origin, 24))
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
    }

    func testFontSizeUpdatesExistingTextAndSurvivesMoveResizeAndUndo() throws {
        let image = NSImage(size: CGSize(width: 1000, height: 700))
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" }).performClick(nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 0
            ))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100, y: 100)))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = "Font size keeps this text and wraps it"
        let typed = try XCTUnwrap(editor.documentView as? NSTextView)
        typed.string = text
        typed.didChangeText()
        let width = editor.contentSize.width - 8
        let original = try XCTUnwrap(canvas.currentPNGData())
        toolbar.onFontSize?(32)
        let enlarged = try XCTUnwrap(canvas.currentPNGData())
        func expected(_ origin: CGPoint, _ width: CGFloat, _ size: CGFloat) throws -> Data {
            try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
                selection: selection, annotations: [.text(text, origin, .systemRed, width: width, fontSize: size)], scale: 1))
        }
        XCTAssertEqual(enlarged, try expected(CGPoint(x: 104, y: 104), width, 32))
        XCTAssertNotEqual(enlarged, original)
        let sizeButton = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Font size: 32 points" })
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        XCTAssertEqual(sizeButton.title, "18 pt")
        redo.performClick(nil)
        XCTAssertEqual(sizeButton.title, "32 pt")
        toolbar.onFontSize?(32)
        toolbar.onFontSize?(.nan)
        toolbar.onFontSize?(0)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        redo.performClick(nil)
        try drag(CGPoint(x: 114, y: 114), CGPoint(x: 214, y: 164))
        let movedOrigin = CGPoint(x: 204, y: 154)
        XCTAssertEqual(canvas.currentPNGData(), try expected(movedOrigin, width, 32))
        let height = max(24, EditorRenderer.textBounds(text, at: movedOrigin, width: width, fontSize: 32).height)
        try drag(CGPoint(x: movedOrigin.x + width, y: movedOrigin.y + height / 2),
                 CGPoint(x: movedOrigin.x + 180, y: movedOrigin.y + height / 2))
        let resized = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertEqual(resized, try expected(movedOrigin, 180, 32))

        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 214, y: 164), clicks: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 214, y: 164), clicks: 2))
        let reopened = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let view = try XCTUnwrap(reopened.documentView as? NSTextView)
        XCTAssertEqual(view.font?.pointSize, 32)
        toolbar.onFontSize?(48)
        XCTAssertEqual(view.font?.pointSize, 48)
        XCTAssertEqual(view.string, text)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertEqual(canvas.currentPNGData(), resized)
        XCTAssertEqual(sizeButton.title, "32 pt")
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 214, y: 164), clicks: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 214, y: 164), clicks: 2))
        toolbar.onFontSize?(48)
        XCTAssertEqual(canvas.currentPNGData(), try expected(movedOrigin, 180, 48))
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), resized)
        XCTAssertEqual(sizeButton.title, "32 pt")
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Pencil" }).performClick(nil)
        XCTAssertEqual(sizeButton.title, "3 px")
    }

    func testColorUpdatesExistingTextAndSupportsUndoAndActiveEditing() throws {
        let image = NSImage(size: CGSize(width: 1000, height: 700))
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let textTool = try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" })
        textTool.performClick(nil)
        toolbar.onFontSize?(32)
        func event(_ type: NSEvent.EventType, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(CGPoint(x: 110, y: 110), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 0
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown))
        canvas.mouseUp(with: try event(.leftMouseUp))
        let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let text = "Change my color without duplicating me"
        try XCTUnwrap(editor.documentView as? NSTextView).string = text
        let width = editor.contentSize.width - 8
        let original = try XCTUnwrap(canvas.currentPNGData())
        func expected(_ color: NSColor) throws -> Data {
            try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
                selection: selection, annotations: [.text(text, CGPoint(x: 114, y: 114), color, width: width, fontSize: 32)], scale: 1))
        }
        toolbar.onColor?(.systemBlue)
        let blue = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertEqual(blue, try expected(.systemBlue))
        XCTAssertNotEqual(blue, original)
        XCTAssertEqual(toolbar.annotationColor, .systemBlue)
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        XCTAssertEqual(toolbar.annotationColor, .systemRed)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), blue)
        toolbar.onColor?(.systemBlue)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        redo.performClick(nil)

        // Reopening and cancelling an edit restores the selected text's saved color.
        let inside = CGPoint(x: 124, y: 124)
        func reopen() throws -> NSTextView {
            let point = canvas.convert(inside, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 0))
            canvas.mouseDown(with: down)
            let editor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
            return try XCTUnwrap(editor.documentView as? NSTextView)
        }
        let view = try reopen()
        XCTAssertEqual(view.textColor, .systemBlue)
        toolbar.onColor?(.systemGreen)
        XCTAssertEqual(view.textColor, .systemGreen)
        XCTAssertEqual(view.string, text)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertEqual(canvas.currentPNGData(), blue)
        XCTAssertEqual(toolbar.annotationColor, .systemBlue)
        _ = try reopen()
        toolbar.onColor?(.systemGreen)
        XCTAssertEqual(canvas.currentPNGData(), try expected(.systemGreen))
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), blue)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Pencil" }).performClick(nil)
        toolbar.onColor?(.systemYellow)
        XCTAssertEqual(canvas.currentPNGData(), blue)
        textTool.performClick(nil)
        XCTAssertEqual(toolbar.annotationColor, .systemBlue)
    }

    func testHistoryDeletionRestoresOrderStyleAndRedoBranch() throws {
        let history = AnnotationHistory()
        history.append(.text("First", CGPoint(x: 10, y: 20), .blue, width: 200, fontSize: 32))
        history.append(.rectangle(CGRect(x: 50, y: 50, width: 20, height: 20), AnnotationStyle(color: .red, width: 3)))
        history.append(.text("Last", CGPoint(x: 80, y: 90), .green))
        history.remove(at: 0)
        XCTAssertEqual(history.annotations.count, 2)
        XCTAssertEqual(history.undo(), 0)
        XCTAssertEqual(history.annotations.count, 3)
        guard case let .text(text, origin, color, width, size) = history.annotations[0] else { return XCTFail("Missing restored text") }
        XCTAssertEqual(text, "First")
        XCTAssertEqual(origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(color, .blue)
        XCTAssertEqual(width, 200)
        XCTAssertEqual(size, 32)
        guard case .rectangle = history.annotations[1] else { return XCTFail("Annotation order changed") }
        history.redo()
        XCTAssertEqual(history.annotations.count, 2)
        history.undo()
        history.replace(at: 0, with: .text("Changed", .zero, .red))
        XCTAssertFalse(history.canRedo)
    }

    func testDeleteSelectedTextRestoresWithUndoAndKeepsTypingDeletionLocal() throws {
        let image = NSImage(size: CGSize(width: 1000, height: 700))
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Text" }).performClick(nil)
        toolbar.onFontSize?(32)
        func click(_ point: CGPoint, clicks: Int = 1) throws {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: 0))
                if type == .leftMouseDown { canvas.mouseDown(with: event) }
                else { canvas.mouseUp(with: event) }
            }
        }
        func deleteKey(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code))
        }
        try click(CGPoint(x: 50, y: 50))
        let firstEditor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let width = firstEditor.contentSize.width - 8
        try XCTUnwrap(firstEditor.documentView as? NSTextView).string = "First"
        _ = canvas.currentPNGData()
        try click(CGPoint(x: 500, y: 100))
        let secondEditor = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        try XCTUnwrap(secondEditor.documentView as? NSTextView).string = "Second"
        let both = try XCTUnwrap(canvas.currentPNGData())
        try click(CGPoint(x: 64, y: 64))
        canvas.keyDown(with: try deleteKey(51))
        let onlySecond = try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
            selection: selection, annotations: [.text("Second", CGPoint(x: 504, y: 104), .systemRed, width: width, fontSize: 32)], scale: 1))
        XCTAssertEqual(canvas.currentPNGData(), onlySecond)
        canvas.keyDown(with: try deleteKey(117))
        XCTAssertEqual(canvas.currentPNGData(), onlySecond)
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), both)
        canvas.keyDown(with: try deleteKey(117))
        XCTAssertEqual(canvas.currentPNGData(), onlySecond)
        undo.performClick(nil)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), onlySecond)
        undo.performClick(nil)
        toolbar.onColor?(.systemBlue)
        XCTAssertFalse(redo.isEnabled)
        try click(CGPoint(x: 514, y: 114), clicks: 2)
        let editing = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSScrollView }.first)
        let view = try XCTUnwrap(editing.documentView as? NSTextView)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "Secon")
        let expected = try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
            selection: selection, annotations: [
                .text("First", CGPoint(x: 54, y: 54), .systemBlue, width: width, fontSize: 32),
                .text("Secon", CGPoint(x: 504, y: 104), .systemRed, width: width, fontSize: 32)
            ], scale: 1))
        XCTAssertEqual(canvas.currentPNGData(), expected)
    }

    func testShapeHitTestingAndGeometryHandleReversedAndAxisAlignedSegments() throws {
        let style = AnnotationStyle(color: .blue, width: 3)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let diagonal = Annotation.line(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300), style)
        XCTAssertTrue(ShapeGeometry.contains(CGPoint(x: 200, y: 200), in: diagonal))
        XCTAssertFalse(ShapeGeometry.contains(CGPoint(x: 100, y: 300), in: diagonal))
        let rectangle = Annotation.rectangle(CGRect(x: 100, y: 100, width: 200, height: 100), style)
        XCTAssertTrue(ShapeGeometry.contains(CGPoint(x: 200, y: 100), in: rectangle))
        XCTAssertFalse(ShapeGeometry.contains(CGPoint(x: 200, y: 150), in: rectangle))
        let reversed = Annotation.arrow(CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 300), style)
        let moved = try XCTUnwrap(ShapeGeometry.moved(reversed, by: CGPoint(x: -900, y: 900), within: bounds))
        XCTAssertEqual(ShapeGeometry.handles(for: moved), [CGPoint(x: 200, y: 400), CGPoint(x: 0, y: 600)])
        let horizontal = Annotation.line(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), style)
        let resized = try XCTUnwrap(ShapeGeometry.resized(horizontal, handle: 0, to: CGPoint(x: 500, y: 100), within: bounds))
        XCTAssertEqual(ShapeGeometry.handles(for: resized), [CGPoint(x: 500, y: 100), CGPoint(x: 300, y: 100)])
        XCTAssertNil(ShapeGeometry.resized(horizontal, handle: 0, to: CGPoint(x: 300, y: 100), within: bounds))
        XCTAssertNil(ShapeGeometry.resized(rectangle, handle: 8, to: .zero, within: bounds))
        let arrow = Annotation.arrow(CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), AnnotationStyle(color: .red, width: 10))
        XCTAssertTrue(ShapeGeometry.contains(CGPoint(x: 264, y: 183), in: arrow))
        XCTAssertFalse(ShapeGeometry.contains(CGPoint(x: 200, y: 240), in: arrow))
    }

    func testShapesMoveResizeDeleteAndRestoreWithUndoRedo() throws {
        for tool in [EditorTool.rectangle, .line, .arrow] {
            let image = NSImage(size: CGSize(width: 1000, height: 700))
            let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
            let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = canvas
            let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
            try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == tool.title }).performClick(nil)
            toolbar.onColor?(.systemBlue)
            toolbar.onWidth?(6)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0))
            }
            func drag(_ start: CGPoint, _ end: CGPoint) throws {
                canvas.mouseDown(with: try event(.leftMouseDown, start))
                canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
                canvas.mouseDragged(with: try event(.leftMouseDragged, end))
                canvas.mouseUp(with: try event(.leftMouseUp, end))
            }
            func expected(_ start: CGPoint, _ end: CGPoint) throws -> Data {
                let style = AnnotationStyle(color: .systemBlue, width: 6)
                let annotation: Annotation
                switch tool {
                case .rectangle: annotation = .rectangle(SelectionGeometry.normalized(from: start, to: end), style)
                case .line: annotation = .line(start, end, style)
                default: annotation = .arrow(start, end, style)
                }
                return try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection,
                    selection: selection, annotations: [annotation], scale: 1))
            }
            try drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
            let original = try XCTUnwrap(canvas.currentPNGData())
            XCTAssertEqual(original, try expected(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)), tool.title)
            let moveStart = CGPoint(x: 200, y: tool == .rectangle ? 100 : 150)
            try drag(moveStart, CGPoint(x: moveStart.x + 50, y: moveStart.y + 50))
            let moved = try XCTUnwrap(canvas.currentPNGData())
            XCTAssertEqual(moved, try expected(CGPoint(x: 150, y: 150), CGPoint(x: 350, y: 250)), tool.title)
            let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
            let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), original, tool.title)
            redo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), moved, tool.title)
            try drag(CGPoint(x: 350, y: 250), CGPoint(x: 100, y: 100))
            let resized = try XCTUnwrap(canvas.currentPNGData())
            XCTAssertEqual(resized, try expected(CGPoint(x: 150, y: 150), CGPoint(x: 100, y: 100)), tool.title)
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), moved, tool.title)
            redo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), resized, tool.title)
            let delete = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
            canvas.keyDown(with: delete)
            let sentinel = Data("empty".utf8)
            XCTAssertEqual(canvas.currentPNGData(originalData: sentinel), sentinel, tool.title)
            canvas.keyDown(with: delete)
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), resized, tool.title)
            redo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(originalData: sentinel), sentinel, tool.title)
            undo.performClick(nil)
            // A click on a handle without a drag must not create a history entry.
            let handle = tool == .rectangle ? CGPoint(x: 150, y: 150) : CGPoint(x: 100, y: 100)
            canvas.mouseDown(with: try event(.leftMouseDown, handle))
            canvas.mouseUp(with: try event(.leftMouseUp, handle))
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), moved, tool.title)
        }
    }

    func testSelectedShapeStyleChangesOnlyThatShapeAndRestoresToolbarWithUndo() throws {
        for tool in [EditorTool.rectangle, .line, .arrow] {
            let image = NSImage(size: CGSize(width: 1000, height: 700))
            let selection = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let canvas = EditorCanvasView(image: image, pixelScale: 1, initialSelection: selection, selectionLocked: true)
            let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = canvas
            let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
            try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == tool.title }).performClick(nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0))
            }
            func draw(_ start: CGPoint, _ end: CGPoint) throws {
                canvas.mouseDown(with: try event(.leftMouseDown, start))
                canvas.mouseDragged(with: try event(.leftMouseDragged, end))
                canvas.mouseUp(with: try event(.leftMouseUp, end))
            }
            func click(_ point: CGPoint) throws {
                canvas.mouseDown(with: try event(.leftMouseDown, point))
                canvas.mouseUp(with: try event(.leftMouseUp, point))
            }
            func annotation(_ start: CGPoint, _ end: CGPoint, _ style: AnnotationStyle) -> Annotation {
                switch tool {
                case .rectangle: .rectangle(SelectionGeometry.normalized(from: start, to: end), style)
                case .line: .line(start, end, style)
                default: .arrow(start, end, style)
                }
            }
            func expected(_ first: AnnotationStyle, _ second: AnnotationStyle) throws -> Data {
                try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: selection, selection: selection,
                    annotations: [annotation(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200), first),
                                  annotation(CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 500), second)], scale: 1))
            }
            try draw(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200))
            try draw(CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 500))
            let red = AnnotationStyle(color: .systemRed, width: 3)
            let green = AnnotationStyle(color: .systemGreen, width: 3)
            let thickGreen = AnnotationStyle(color: .systemGreen, width: 6)
            try click(CGPoint(x: 200, y: tool == .rectangle ? 100 : 150))
            toolbar.onColor?(.systemGreen)
            toolbar.onWidth?(6)
            XCTAssertEqual(canvas.currentPNGData(), try expected(thickGreen, red), tool.title)
            XCTAssertEqual(toolbar.strokeWidth, 6)
            XCTAssertEqual(toolbar.annotationColor, .systemGreen)
            let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
            let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), try expected(green, red), tool.title)
            XCTAssertEqual(toolbar.strokeWidth, 3)
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), try expected(red, red), tool.title)
            XCTAssertEqual(toolbar.annotationColor, .systemRed)
            redo.performClick(nil)
            redo.performClick(nil)
            toolbar.onColor?(.systemGreen)
            toolbar.onWidth?(6)
            toolbar.onWidth?(.nan)
            toolbar.onWidth?(0)
            undo.performClick(nil)
            XCTAssertEqual(canvas.currentPNGData(), try expected(green, red), tool.title)
            redo.performClick(nil)
            try click(CGPoint(x: 600, y: tool == .rectangle ? 400 : 450))
            XCTAssertEqual(toolbar.annotationColor, .systemRed)
            XCTAssertEqual(toolbar.strokeWidth, 3)
            XCTAssertTrue(buttons(in: toolbar).contains { $0.title == "3 px" })
            toolbar.onWidth?(1)
            toolbar.onColor?(.systemBlue)
            XCTAssertEqual(canvas.currentPNGData(), try expected(thickGreen, AnnotationStyle(color: .systemBlue, width: 1)), tool.title)
        }
    }

    func testFrozenScreenCropMovesExpandsAndRemainsEditableAfterAnnotations() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 400, y: 0, width: 400, height: 600))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 400, height: 300))
        let canvas = EditorCanvasView(image: image, pixelScale: 2,
            initialSelection: CGRect(x: 20, y: 30, width: 100, height: 80))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let crop = try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Crop" })
        XCTAssertTrue(crop.isEnabled)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        let initial = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.currentPNGData())))
        XCTAssertEqual(initial.pixelsWide, 200)
        XCTAssertEqual(initial.pixelsHigh, 160)
        XCTAssertGreaterThan(try XCTUnwrap(initial.colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        try drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 60))
        let moved = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.currentPNGData())))
        XCTAssertGreaterThan(try XCTUnwrap(moved.colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB)).blueComponent, 0.9)
        try drag(CGPoint(x: 320, y: 110), CGPoint(x: 380, y: 200))
        let expanded = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.currentPNGData())))
        XCTAssertEqual(expanded.pixelsWide, 320)
        XCTAssertEqual(expanded.pixelsHigh, 340)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Line" }).performClick(nil)
        try drag(CGPoint(x: 250, y: 60), CGPoint(x: 300, y: 100))
        crop.performClick(nil)
        try drag(CGPoint(x: 380, y: 200), CGPoint(x: 390, y: 240))
        let resized = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.currentPNGData())))
        XCTAssertEqual(resized.pixelsWide, 340)
        XCTAssertEqual(resized.pixelsHigh, 420)
        try drag(CGPoint(x: 300, y: 150), CGPoint(x: 100, y: 150))
        let expected = try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: canvas.bounds,
            selection: CGRect(x: 20, y: 30, width: 170, height: 210), annotations: [
                .line(CGPoint(x: 250, y: 60), CGPoint(x: 300, y: 100), AnnotationStyle(color: .systemRed, width: 3))
            ], scale: 2))
        XCTAssertEqual(canvas.currentPNGData(originalData: Data("stale crop".utf8)), expected)
        var copied: Data?
        canvas.onCopy = { copied = $0 }
        try XCTUnwrap(buttons(in: toolbar).first { $0.title == "Copy" }).performClick(nil)
        XCTAssertEqual(copied, expected)
    }

    func testCropHistoryInterleavesWithAnnotationsAndKeepsRedoForNoOp() {
        let original = CGRect(x: 10, y: 20, width: 100, height: 80)
        let moved = original.offsetBy(dx: 50, dy: 30)
        let resized = CGRect(x: 60, y: 50, width: 200, height: 150)
        let history = AnnotationHistory(crop: original)
        history.setCrop(moved)
        history.append(.text("Keep me", CGPoint(x: 80, y: 80), .red))
        history.setCrop(resized)
        history.undo()
        XCTAssertEqual(history.crop, moved)
        XCTAssertEqual(history.annotations.count, 1)
        history.undo()
        XCTAssertTrue(history.annotations.isEmpty)
        history.undo()
        XCTAssertEqual(history.crop, original)
        XCTAssertFalse(history.canUndo)
        history.setCrop(original)
        XCTAssertTrue(history.canRedo)
        history.redo()
        history.redo()
        history.redo()
        XCTAssertEqual(history.crop, resized)
        XCTAssertEqual(history.annotations.count, 1)
        history.undo()
        history.setCrop(original)
        XCTAssertFalse(history.canRedo)
    }

    func testCropUndoRedoRestoresExportAndSharesHistoryWithDrawing() throws {
        let image = NSImage(size: CGSize(width: 1000, height: 700), flipped: true) { rect in
            NSColor.red.setFill()
            rect.fill()
            NSColor.blue.setFill()
            CGRect(x: 250, y: 0, width: 750, height: 700).fill()
            return true
        }
        let originalCrop = CGRect(x: 100, y: 100, width: 200, height: 150)
        let canvas = EditorCanvasView(image: image, pixelScale: 2, initialSelection: originalCrop)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let crop = try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Crop" })
        let undo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Undo" })
        let redo = try XCTUnwrap(buttons(in: toolbar).first { $0.toolTip == "Redo" })
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        let original = try XCTUnwrap(canvas.currentPNGData())
        try drag(CGPoint(x: 200, y: 180), CGPoint(x: 250, y: 200))
        let moved = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertNotEqual(moved, original)
        XCTAssertTrue(undo.isEnabled)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        XCTAssertFalse(undo.isEnabled)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), moved)
        // A no-op click and an invalid replacement crop leave history intact.
        try drag(CGPoint(x: 250, y: 200), CGPoint(x: 250, y: 200))
        try drag(CGPoint(x: 900, y: 600), CGPoint(x: 901, y: 601))
        XCTAssertEqual(canvas.currentPNGData(), moved)
        try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Line" }).performClick(nil)
        toolbar.onColor?(.systemGreen)
        try drag(CGPoint(x: 180, y: 150), CGPoint(x: 250, y: 200))
        let drawn = try XCTUnwrap(canvas.currentPNGData())
        XCTAssertNotEqual(drawn, moved)
        crop.performClick(nil)
        try drag(CGPoint(x: 350, y: 270), CGPoint(x: 450, y: 350))
        let expanded = try XCTUnwrap(canvas.currentPNGData())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: expanded))
        XCTAssertEqual(bitmap.pixelsWide, 600)
        XCTAssertEqual(bitmap.pixelsHigh, 460)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), drawn)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), moved)
        undo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), original)
        XCTAssertFalse(undo.isEnabled)
        redo.performClick(nil)
        redo.performClick(nil)
        redo.performClick(nil)
        XCTAssertEqual(canvas.currentPNGData(), expanded)
        undo.performClick(nil)
        // A new crop edit after Undo replaces the abandoned redo branch.
        try drag(CGPoint(x: 350, y: 270), CGPoint(x: 400, y: 300))
        XCTAssertFalse(redo.isEnabled)
        var copied: Data?
        canvas.onCopy = { copied = $0 }
        try XCTUnwrap(buttons(in: toolbar).first { $0.title == "Copy" }).performClick(nil)
        XCTAssertEqual(copied, canvas.currentPNGData())
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

    @MainActor
    func testExportFeedbackKeepsEditorOpenAndCloseUsesLatestEdits() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        var shouldSucceed = false
        var exports: [Data] = []
        var didClose = false
        let controller = OverlayEditorController(
            screen: screen, image: try XCTUnwrap(bitmap.cgImage),
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            initialSelection: CGRect(x: 0, y: 0, width: 100, height: 100),
            selectionLocked: true,
            onCopy: { data in exports.append(data); return shouldSucceed },
            onSave: { data in exports.append(data); return shouldSucceed }
        ) { didClose = true }
        controller.show()
        defer { controller.finish() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is OverlayPanel && $0.isVisible })
        let canvas = try XCTUnwrap(panel.contentView as? EditorCanvasView)
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let copy = try XCTUnwrap(buttons(in: toolbar).first { $0.title == "Copy" })
        let save = try XCTUnwrap(buttons(in: toolbar).first { $0.title == "Save" })
        copy.performClick(nil)
        save.performClick(nil)
        XCTAssertEqual(copy.title, "Copy")
        XCTAssertEqual(save.title, "Save")
        XCTAssertFalse(didClose)

        shouldSucceed = true
        copy.performClick(nil)
        XCTAssertEqual(copy.title, "Copied")
        XCTAssertTrue(panel.isVisible)
        save.performClick(nil)
        XCTAssertEqual(save.title, "Saved")
        XCTAssertFalse(didClose)
        XCTAssertTrue(panel.isVisible)

        let rectangle = try XCTUnwrap(buttons(in: toolbar).first { $0.accessibilityLabel() == "Rectangle" })
        rectangle.performClick(nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 10, y: 10)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 70, y: 70)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 70, y: 70)))
        let edited = try XCTUnwrap(controller.currentPNGData())
        XCTAssertNotEqual(edited, exports.last)
        copy.performClick(nil)
        XCTAssertEqual(exports.last, edited)
        controller.finish()
        XCTAssertTrue(didClose)
    }

    func testAreaCapturePassesOriginalSelectionToEditor() throws {
        let canvas = EditorCanvasView(
            image: NSImage(size: CGSize(width: 800, height: 600)), pixelScale: 2,
            selectionOnly: true
        )
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        var capturedRect: CGRect?
        var capturedData: Data?
        canvas.onCapture = { data, rect in
            capturedRect = rect
            capturedData = data
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 120, y: 80)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 420, y: 280)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 420, y: 280)))
        XCTAssertEqual(capturedRect, CGRect(x: 120, y: 80, width: 300, height: 200))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(capturedData)))
        XCTAssertEqual(bitmap.pixelsWide, 600)
        XCTAssertEqual(bitmap.pixelsHigh, 400)
    }

    func testToolbarDragPersistsAndStaysInsideCanvas() throws {
        let canvas = EditorCanvasView(
            image: NSImage(size: CGSize(width: 1400, height: 900)),
            pixelScale: 1,
            initialSelection: CGRect(x: 100, y: 100, width: 400, height: 300)
        )
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(canvas.subviews.compactMap { $0 as? EditorToolbar }.first)
        let original = toolbar.frame
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0
            ))
        }
        let start = CGPoint(x: original.minX + 10, y: original.minY + 10)
        toolbar.mouseDown(with: try event(.leftMouseDown, at: start))
        toolbar.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: start.x + 80, y: start.y - 60)))
        XCTAssertEqual(toolbar.frame.origin, CGPoint(x: original.minX + 80, y: original.minY - 60))
        canvas.layout()
        XCTAssertEqual(toolbar.frame.origin, CGPoint(x: original.minX + 80, y: original.minY - 60))

        toolbar.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: -1000, y: -1000)))
        XCTAssertEqual(toolbar.frame.origin, CGPoint(x: 8, y: 8))
        toolbar.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 5000, y: 5000)))
        XCTAssertEqual(toolbar.frame.maxX, canvas.bounds.maxX - 8)
        XCTAssertEqual(toolbar.frame.maxY, canvas.bounds.maxY - 8)
        toolbar.mouseUp(with: try event(.leftMouseUp, at: start))

        toolbar.layoutSubtreeIfNeeded()
        let copy = try XCTUnwrap(buttons(in: toolbar).first { $0.title == "Copy" })
        let copyPoint = canvas.convert(CGPoint(x: copy.bounds.midX, y: copy.bounds.midY), from: copy)
        XCTAssertTrue(toolbar.hitTest(copyPoint) === copy)
        let background = CGPoint(x: toolbar.frame.minX + 2, y: toolbar.frame.minY + 2)
        XCTAssertTrue(toolbar.hitTest(background) === toolbar)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton { result.append(button) }
            result.append(contentsOf: buttons(in: subview))
        }
        return result
    }

    func testCanvasLayerShowsScreenshotUpright() throws {
        // Top half red, bottom half blue in a flipped (top-left) coordinate space.
        let image = NSImage(size: CGSize(width: 40, height: 40), flipped: true) { _ in
            NSColor.red.setFill(); CGRect(x: 0, y: 0, width: 40, height: 20).fill()
            NSColor.blue.setFill(); CGRect(x: 0, y: 20, width: 40, height: 20).fill()
            return true
        }
        let canvas = EditorCanvasView(image: image, pixelScale: 1, backgroundImage: NSImage(size: CGSize(width: 40, height: 40)),
                                      imageBounds: CGRect(x: 0, y: 0, width: 40, height: 40), canvasSize: CGSize(width: 40, height: 40))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.displayIfNeeded()
        let layer = try XCTUnwrap(canvas.layer)
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if layer.isGeometryFlipped || layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: 40)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let top = try XCTUnwrap(bitmap.colorAt(x: 20, y: 5)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 20, y: 35)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(top.redComponent, 0.8)
        XCTAssertGreaterThan(bottom.blueComponent, 0.8)
    }

    func testShiftConstraintSquaresRectanglesAndSnapsLines() {
        let square = ShapeGeometry.constrained(tool: .rectangle, start: .zero, end: CGPoint(x: -30, y: 10))
        XCTAssertEqual(square, CGPoint(x: -30, y: 30))
        let snapped = ShapeGeometry.constrained(tool: .line, start: .zero, end: CGPoint(x: 100, y: 8))
        XCTAssertEqual(snapped.x, hypot(100, 8), accuracy: 0.001)
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
        let diagonal = ShapeGeometry.constrained(tool: .arrow, start: .zero, end: CGPoint(x: 50, y: 45))
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }

    func testColorHexRoundTripsAndToolShortcutsAreUnique() throws {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        let hex = try XCTUnwrap(color.hexString)
        XCTAssertEqual(NSColor(hex: hex)?.hexString, hex)
        XCTAssertNil(NSColor(hex: "#12"))
        XCTAssertEqual(Set(EditorTool.allCases.map(\.shortcutKey)).count, EditorTool.allCases.count)
        XCTAssertTrue(StrokeWidth.isValid(17))
        XCTAssertFalse(StrokeWidth.isValid(0))
        XCTAssertFalse(StrokeWidth.isValid(.infinity))
    }

    func testPixelateAndStepAnnotationsChangeExport() throws {
        let size = CGSize(width: 60, height: 60)
        let image = NSImage(size: size, flipped: true) { _ in
            for x in 0..<60 { (x % 2 == 0 ? NSColor.black : NSColor.white).setFill(); CGRect(x: x, y: 0, width: 1, height: 60).fill() }
            return true
        }
        let bounds = CGRect(origin: .zero, size: size)
        func render(_ annotations: [Annotation]) throws -> NSBitmapImageRep {
            let data = try XCTUnwrap(EditorRenderer.renderPNG(image: image, displayBounds: bounds, selection: bounds, annotations: annotations, scale: 1))
            return try XCTUnwrap(NSBitmapImageRep(data: data))
        }
        let pixelated = try render([.pixelate(CGRect(x: 0, y: 0, width: 30, height: 30))])
        // Stripes inside the pixelated area become one averaged block.
        XCTAssertEqual(pixelated.colorAt(x: 2, y: 2), pixelated.colorAt(x: 3, y: 2))
        XCTAssertNotEqual(pixelated.colorAt(x: 42, y: 42), pixelated.colorAt(x: 43, y: 42))
        let step = try render([.step(1, CGPoint(x: 30, y: 30), AnnotationStyle(color: .systemBlue, width: 3))])
        let edge = try XCTUnwrap(step.colorAt(x: 30, y: 19)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(edge.blueComponent, 0.6)
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
