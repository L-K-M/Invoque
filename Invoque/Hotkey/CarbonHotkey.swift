import AppKit
import Carbon.HIToolbox

/// A global hotkey registered via Carbon's `RegisterEventHotKey`.
///
/// This is the panel's summon trigger: Carbon hotkeys need no TCC permission,
/// unlike an event tap (PLAN.md §5). They report key-down only — no
/// modifier-release observation — which is all summoning requires.
final class CarbonHotkey {

    /// Invoked on the main thread when the hotkey fires.
    var onPressed: (() -> Void)?

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Four-char signature `'INVQ'`.
    private static let signature: OSType = 0x494E_5651

    init(identifier: UInt32) {
        self.identifier = identifier
    }

    deinit { unregister() }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerCallback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let me = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()

            var pressedID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )

            if pressedID.signature == CarbonHotkey.signature && pressedID.id == me.identifier {
                DispatchQueue.main.async { me.onPressed?() }
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            // Roll back the installed handler so a failed registration doesn't
            // leave a dangling event handler behind.
            unregister()
            NSLog("Invoque: failed to register Carbon hotkey \(identifier): status \(registerStatus)")
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
