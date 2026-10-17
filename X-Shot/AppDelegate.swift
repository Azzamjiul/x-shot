import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var captureAreaItem: NSMenuItem?
    private var shortcutPanel: NSPanel?
    private var shortcutRecorder: ShortcutRecorderView?
    private let shortcutKey = "captureShortcut"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "X-Shot")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let captureScreenItem = NSMenuItem(title: "Capture Full Screen", action: #selector(captureFullScreen), keyEquivalent: "")
        captureScreenItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Capture Full Screen")
        captureScreenItem.target = self
        menu.addItem(captureScreenItem)

        let captureWindowItem = NSMenuItem(title: "Capture Window", action: #selector(captureWindow), keyEquivalent: "")
        captureWindowItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Capture Window")
        captureWindowItem.target = self
        menu.addItem(captureWindowItem)

        let captureAreaItem = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "")
        captureAreaItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Capture Area")
        captureAreaItem.target = self
        menu.addItem(captureAreaItem)
        self.captureAreaItem = captureAreaItem
        menu.addItem(.separator())

        let shortcutItem = NSMenuItem(title: "Set Capture Shortcut…", action: #selector(setCaptureShortcut), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit X-Shot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item

        let hotKey = HotKeyManager { [weak self] in
            guard let self, self.shortcutPanel == nil else { return }
            self.captureArea()
        }
        hotKeyManager = hotKey
        let shortcut = savedShortcut() ?? .default
        captureAreaItem.title = "Capture Area (\(shortcut.label))"
        if !hotKey.register(shortcut) {
            captureAreaItem.title = "Capture Area (shortcut unavailable)"
            showAlert(
                title: "Shortcut unavailable",
                message: "\(shortcut.label) is reserved by macOS or another app. Capture Area remains available from the X-Shot menu. Choose another shortcut in Set Capture Shortcut…"
            )
        }
    }

    @objc private func captureArea() {
        captureCoordinator.startCapture(.area)
    }

    @objc private func captureWindow() {
        captureCoordinator.startCapture(.window)
    }

    @objc private func captureFullScreen() {
        captureCoordinator.startCapture(.fullScreen)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        captureCoordinator.savePendingCaptureBeforeQuit() ? .terminateNow : .terminateCancel
    }

    @objc private func setCaptureShortcut() {
        if let shortcutPanel { shortcutPanel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 350, height: 130),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Set Capture Shortcut"
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let recorder = ShortcutRecorderView(frame: CGRect(x: 0, y: 0, width: 350, height: 130))
        let label = NSTextField(labelWithString: "Press a letter or number with ⌘, ⌥, or ⌃.\nPress Esc to cancel.")
        label.alignment = .center
        label.frame = CGRect(x: 20, y: 35, width: 310, height: 55)
        recorder.addSubview(label)
        recorder.onCancel = { [weak self] in self?.closeShortcutPanel() }
        recorder.onShortcut = { [weak self] shortcut in self?.applyShortcut(shortcut) }
        panel.contentView = recorder
        shortcutPanel = panel
        shortcutRecorder = recorder
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(recorder)
    }

    private func applyShortcut(_ shortcut: CaptureShortcut) {
        guard hotKeyManager?.register(shortcut) == true else {
            NSSound.beep()
            showAlert(title: "Shortcut unavailable", message: "\(shortcut.label) is already in use. Your previous shortcut is still active.")
            shortcutPanel?.makeKeyAndOrderFront(nil)
            if let shortcutRecorder { shortcutPanel?.makeFirstResponder(shortcutRecorder) }
            return
        }
        UserDefaults.standard.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers, "keyLabel": shortcut.keyLabel], forKey: shortcutKey)
        captureAreaItem?.title = "Capture Area (\(shortcut.label))"
        closeShortcutPanel()
    }

    private func savedShortcut() -> CaptureShortcut? {
        guard let value = UserDefaults.standard.dictionary(forKey: shortcutKey),
              let keyCode = (value["keyCode"] as? NSNumber)?.uint32Value,
              let modifiers = (value["modifiers"] as? NSNumber)?.uint32Value,
              let keyLabel = value["keyLabel"] as? String,
              !keyLabel.isEmpty,
              modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        else { return nil }
        return CaptureShortcut(keyCode: keyCode, modifiers: modifiers, keyLabel: keyLabel)
    }

    private func closeShortcutPanel() {
        shortcutPanel?.orderOut(nil)
        shortcutPanel = nil
        shortcutRecorder = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === shortcutPanel else { return }
        shortcutPanel = nil
        shortcutRecorder = nil
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
