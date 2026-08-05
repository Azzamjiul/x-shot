import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?

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

        let captureAreaItem = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: "9")
        captureAreaItem.keyEquivalentModifierMask = [.command, .shift]
        captureAreaItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Capture Area")
        captureAreaItem.target = self
        menu.addItem(captureAreaItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit X-Shot", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item

        let hotKey = HotKeyManager { [weak self] in self?.captureArea() }
        if hotKey.registerCommandShift9() {
            hotKeyManager = hotKey
        } else {
            captureAreaItem.title = "Capture Area (shortcut unavailable)"
            showAlert(
                title: "Shortcut unavailable",
                message: "Shift-Command-9 is already reserved. You can still capture from the X-Shot menu bar icon."
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

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
