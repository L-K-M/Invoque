import Foundation

/// The launcher panel's background material — the same family of choices as
/// Jetty's `DockMaterial`. The glass variants render genuine Liquid Glass on
/// macOS 26 (with a blurred-panel fallback below); `solid` and `gradient` draw
/// the user's own colors — see `PanelBackground`.
enum PanelMaterial: String, Codable, CaseIterable, Identifiable {
    case liquidGlass
    case glassClear
    case glassTinted
    case solid
    case gradient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .glassClear: return "Liquid Glass (Clear)"
        case .glassTinted: return "Liquid Glass (Tinted)"
        case .solid: return "Solid"
        case .gradient: return "Gradient"
        }
    }

    /// Whether the Tint and Background-opacity controls actually affect this
    /// material. On macOS 26, `liquidGlass`/`glassClear` render as system glass
    /// and ignore both — so Settings can flag those controls as inert rather
    /// than looking broken. (Same rule as Jetty's `DockMaterial`.)
    var usesTintAndOpacity: Bool {
        switch self {
        case .liquidGlass, .glassClear: return false
        case .glassTinted, .solid, .gradient: return true
        }
    }

    /// Whether the theme's own text color (`labelHex`) applies.
    ///
    /// A fixed hex color can't follow the system appearance: on the glass
    /// materials the *system* owns the background and adapts `.primary` to it,
    /// so the theme defers to it. On `solid`/`gradient` the user picked the
    /// background color outright, so they own the foreground too — otherwise a
    /// dark tint under a light system appearance would leave dark-on-dark text.
    var usesThemeTextColor: Bool {
        switch self {
        case .solid, .gradient: return true
        case .liquidGlass, .glassClear, .glassTinted: return false
        }
    }
}
