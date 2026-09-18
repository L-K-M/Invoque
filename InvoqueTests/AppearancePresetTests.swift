import XCTest
@testable import Invoque

final class AppearancePresetTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "InvoqueTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func encode(_ preset: AppearancePreset) throws -> Data {
        try JSONEncoder().encode(preset)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Round-trip

    func testRoundTripPreservesEveryField() throws {
        let preset = AppearancePreset.summon
        let decoded = AppearancePreset.decode(from: try encode(preset))
        XCTAssertEqual(decoded, preset)
    }

    func testSnapshotCapturesPreferences() {
        let preferences = Preferences(defaults: defaults)
        preferences.panelMaterial = .gradient
        preferences.highlightHex = "#FF6AD5"
        preferences.adaptiveAccent = false

        let preset = AppearancePreset(name: "Snap", from: preferences)
        XCTAssertEqual(preset.material, .gradient)
        XCTAssertEqual(preset.highlightHex, "#FF6AD5")
        XCTAssertFalse(preset.adaptiveAccent)
    }

    // MARK: Tolerant decode

    func testMissingFieldsFallToDefaults() throws {
        // Only Invoque keys present so the sniffer picks our format.
        let decoded = AppearancePreset.decode(from: try json(["highlightHex": "#123456"]))
        XCTAssertEqual(decoded?.highlightHex, "#123456")
        XCTAssertEqual(decoded?.material, Preferences.Default.panelMaterial)
        XCTAssertEqual(decoded?.name, "Imported")
    }

    func testUnknownMaterialRawValueFallsToDefault() throws {
        let decoded = AppearancePreset.decode(from: try json([
            "highlightHex": "#123456",
            "material": "unobtainium",
        ]))
        XCTAssertEqual(decoded?.material, Preferences.Default.panelMaterial)
    }

    // MARK: Cross-app sniffing

    func testJettyThemeMaps() throws {
        let decoded = AppearancePreset.decode(from: try json([
            "name": "Vapor",
            "material": "gradient",
            "tintHex": "#FF6AD5",
            "gradientHex": "#8795E8",
            "gradientAngle": 60,
            "backgroundOpacity": 0.7,
            "iconSize": 50,
            "cornerRadius": 24,
            "accentGlow": false,
            "decorationStyle": "vaporwave",
            "crtEnabled": true,
        ]))
        XCTAssertEqual(decoded?.name, "Vapor")
        XCTAssertEqual(decoded?.material, .gradient)
        XCTAssertEqual(decoded?.tintHex, "#FF6AD5")
        XCTAssertEqual(decoded?.gradientHex, "#8795E8")
        XCTAssertEqual(decoded?.cornerRadius, 24)
        // Jetty's accentGlow maps to our adaptiveAccent.
        XCTAssertEqual(decoded?.adaptiveAccent, false)
        XCTAssertEqual(decoded?.decorationStyle, "vaporwave")
        XCTAssertTrue(decoded?.crtEnabled ?? false)
        // Fields Jetty doesn't carry fall to Invoque defaults.
        XCTAssertEqual(decoded?.highlightHex, Preferences.Default.highlightHex)
    }

    func testZapThemeMaps() throws {
        let decoded = AppearancePreset.decode(from: try json([
            "name": "ZX Night",
            "backgroundColorHex": "#0B0B1A",
            "useGradientBackground": true,
            "gradientColorHex": "#1A1140",
            "gradientAngle": 20,
            "highlightColorHex": "#00AEEF",
            "highlightOpacity": 0.85,
            "labelColorHex": "#EEEEEE",
            "showAppName": true,
            "decorationStyle": "zxSpectrum",
        ]))
        XCTAssertEqual(decoded?.material, .gradient)
        XCTAssertEqual(decoded?.tintHex, "#0B0B1A")
        XCTAssertEqual(decoded?.highlightHex, "#00AEEF")
        XCTAssertEqual(decoded?.labelHex, "#EEEEEE")
        XCTAssertEqual(decoded?.decorationStyle, "zxSpectrum")
    }

    func testZapSolidBackgroundMapsToSolidMaterial() throws {
        let decoded = AppearancePreset.decode(from: try json([
            "backgroundColorHex": "#1C1C1E",
            "useGradientBackground": false,
        ]))
        XCTAssertEqual(decoded?.material, .solid)
    }

    func testUnrelatedJSONIsRejected() throws {
        XCTAssertNil(AppearancePreset.decode(from: try json(["version": 1, "items": []])))
        XCTAssertNil(AppearancePreset.decode(from: Data("not json".utf8)))
    }

    // MARK: apply() validation

    func testApplyClampsAndValidates() throws {
        var preset = AppearancePreset.summon
        preset.highlightOpacity = 4
        preset.backgroundOpacity = -1
        preset.gradientAngle = 730
        preset.decorationSize = 999
        preset.labelHex = "not-a-color"
        preset.decorationStyle = "bogus"
        preset.cornerRadius = 999

        let preferences = Preferences(defaults: defaults)
        preset.apply(to: preferences)

        XCTAssertEqual(preferences.highlightOpacity, 1)
        XCTAssertEqual(preferences.backgroundOpacity, 0)
        XCTAssertEqual(preferences.gradientAngle, 10)
        XCTAssertEqual(preferences.decorationSize, 30)
        XCTAssertEqual(preferences.labelHex, Preferences.Default.labelHex)
        XCTAssertEqual(preferences.decorationStyle, Preferences.Default.decorationStyle)
        XCTAssertEqual(preferences.panelCornerRadius, 32)
    }

    func testApplyRoundTripsThroughPreferences() {
        let preferences = Preferences(defaults: defaults)
        AppearancePreset.zxNight.apply(to: preferences)

        let snapshot = AppearancePreset(name: "Echo", from: preferences)
        XCTAssertEqual(snapshot.material, AppearancePreset.zxNight.material)
        XCTAssertEqual(snapshot.tintHex, AppearancePreset.zxNight.tintHex)
        XCTAssertEqual(snapshot.highlightHex, AppearancePreset.zxNight.highlightHex)
        XCTAssertEqual(snapshot.crtEnabled, AppearancePreset.zxNight.crtEnabled)
    }

    func testBuiltInsHaveUniqueNames() {
        XCTAssertEqual(Set(AppearancePreset.builtIns.map(\.name)).count,
                       AppearancePreset.builtIns.count)
    }
}
