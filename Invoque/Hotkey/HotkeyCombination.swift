import Foundation
import Carbon.HIToolbox

/// A global hotkey: a Carbon virtual key code plus Carbon modifier flags.
///
/// Stored as the raw Carbon values because they are exactly what
/// `RegisterEventHotKey` consumes — deliberately *not* `NSEvent.ModifierFlags`,
/// whose bit layout differs. A single `Codable` value so key code and
/// modifiers always travel (and persist) together.
struct HotkeyCombination: Codable, Equatable {

    /// Virtual key code — one of the `kVK_*` constants.
    let keyCode: UInt32

    /// Carbon modifier mask — a combination of `cmdKey`, `shiftKey`,
    /// `optionKey`, `controlKey`.
    let modifiers: UInt32

    /// ⌥Space, the default summon hotkey. Carbon hotkeys need no TCC
    /// permission and ⌥Space is unclaimed by the system (PLAN.md §5).
    static let `default` = HotkeyCombination(keyCode: UInt32(kVK_Space),
                                             modifiers: UInt32(optionKey))
}
