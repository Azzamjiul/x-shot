import AppKit
import Carbon.HIToolbox

struct CaptureShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let `default` = CaptureShortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "9")

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown, event.keyCode != 53, !event.isARepeat else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              let character = event.charactersIgnoringModifiers?.uppercased().first,
              character.isLetter || character.isNumber
        else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: String(character))
    }

    var label: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }
}

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().invoke()
    return noErr
}

final class HotKeyManager {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private(set) var shortcut: CaptureShortcut?

    init(action: @escaping () -> Void) { self.action = action }

    func register(_ candidate: CaptureShortcut) -> Bool {
        if shortcut == candidate { return true }
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType,
                                      Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef) == noErr
            else { return false }
        }
        let identifier = EventHotKeyID(signature: 0x58534854, id: nextID)
        var newRef: EventHotKeyRef?
        guard RegisterEventHotKey(candidate.keyCode, candidate.modifiers, identifier,
                                  GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &newRef) == noErr
        else { return false }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = newRef
        shortcut = candidate
        nextID &+= 1
        return true
    }

    fileprivate func invoke() { DispatchQueue.main.async { [action] in action() } }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

final class ShortcutRecorderView: NSView {
    var onShortcut: ((CaptureShortcut) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if let shortcut = CaptureShortcut(event: event) { onShortcut?(shortcut) }
        else { NSSound.beep() }
    }
}
