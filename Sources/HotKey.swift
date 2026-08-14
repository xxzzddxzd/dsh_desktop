import Carbon
import Foundation

/// Global hotkey (⌃⌥D) to summon the DSH panel, via Carbon hotkey API.
final class HotKey {
    static let shared = HotKey()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func install() {
        guard hotKeyRef == nil else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D),
                                         UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x44534848, id: 1),
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return }
        hotKeyRef = ref

        if !handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
                HotKey.shared.onTrigger?()
                return noErr
            }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
    }

    func uninstall() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
