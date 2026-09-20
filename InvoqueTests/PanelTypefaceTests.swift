import AppKit
import XCTest
@testable import Invoque

final class PanelTypefaceTests: XCTestCase {

    /// The bundled contract is that every listed option resolves on a
    /// stock macOS install — a typo'd or removed family name must fail
    /// here, not at render time. Iterates `bundled`, not the
    /// installed-filtered `curated`, so a bad name can't be filtered out
    /// before this test sees it. `NSFontDescriptor`'s family attribute
    /// resolves to the real family, so `familyName` reads back the same
    /// name.
    func testEveryNamedFamilyResolves() {
        for typeface in PanelTypeface.bundled {
            guard let family = typeface.family else { continue }
            XCTAssertEqual(typeface.nsFont(size: 13).familyName, family,
                           "\(typeface.label) did not resolve to its family")
        }
    }

    /// The system designs must not silently fall back to plain SF Pro —
    /// `.monospaced` is verifiably fixed-pitch, and every design resolves to
    /// a face distinct from the default.
    func testSystemDesignsApply() {
        XCTAssertTrue(PanelTypeface.monospaced.nsFont(size: 13).isFixedPitch)
        let systemName = PanelTypeface.system.nsFont(size: 13).fontName
        for typeface in [PanelTypeface.rounded, .serif, .monospaced] {
            XCTAssertNotEqual(typeface.nsFont(size: 13).fontName, systemName,
                              "\(typeface.label) did not apply its design")
        }
    }

    /// Named families answer the fixed-pitch question honestly — Menlo and
    /// Courier New are monospace, Avenir Next is not.
    func testFixedPitchReflectsFamily() {
        XCTAssertTrue(PanelTypeface.menlo.nsFont(size: 13).isFixedPitch)
        XCTAssertTrue(PanelTypeface.courierNew.nsFont(size: 13).isFixedPitch)
        XCTAssertFalse(PanelTypeface.avenirNext.nsFont(size: 13).isFixedPitch)
    }

    /// Raw-value round trip: the stored form decodes back to the face.
    func testRawValueRoundTrips() {
        for typeface in PanelTypeface.curated {
            XCTAssertEqual(PanelTypeface(rawValue: typeface.rawValue), typeface)
        }
        XCTAssertNil(PanelTypeface(rawValue: "comicSans"))
    }

    /// CamelCase keys persisted by the enum form of this type must still
    /// decode — to the same family face the canonical `family:` form uses.
    func testLegacyKeysDecode() {
        XCTAssertEqual(PanelTypeface(rawValue: "futura"), .futura)
        XCTAssertEqual(PanelTypeface(rawValue: "menlo"), .menlo)
        XCTAssertEqual(PanelTypeface.futura.rawValue, "family:Futura")
    }

    /// Any installed family is a valid typeface, not just the curated
    /// list — decode validates against the font manager, so an absent
    /// family falls back instead of persisting a phantom.
    func testCustomFamilies() {
        XCTAssertEqual(PanelTypeface(rawValue: "family:Menlo"), .menlo)
        XCTAssertEqual(PanelTypeface.custom("Menlo"), .menlo)
        XCTAssertEqual(PanelTypeface.custom("Menlo").label, "Menlo")
        XCTAssertNil(PanelTypeface(rawValue: "family:No Such Family XYZ"))
    }

    /// The full list covers what the picker shows: every installed family
    /// minus the curated ones — no duplicates, none hidden.
    func testMoreFamilies() {
        let curatedFamilies = Set(PanelTypeface.curated.compactMap(\.family))
        XCTAssertFalse(curatedFamilies.isEmpty)
        for family in PanelTypeface.moreFamilies {
            XCTAssertFalse(family.hasPrefix("."), "hidden system face listed")
            XCTAssertFalse(curatedFamilies.contains(family),
                           "\(family) is already curated")
        }
    }
}
