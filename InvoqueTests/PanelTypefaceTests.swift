import AppKit
import XCTest
@testable import Invoque

final class PanelTypefaceTests: XCTestCase {

    /// The enum's contract is that every option resolves on a stock macOS
    /// install — a typo'd or removed family name must fail here, not at
    /// render time. `NSFontDescriptor`'s family attribute resolves to the
    /// real family, so `familyName` reads back the same name.
    func testEveryNamedFamilyResolves() {
        for typeface in PanelTypeface.allCases {
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

    /// Raw-value round trip: the stored form decodes back to the case.
    func testRawValueRoundTrips() {
        for typeface in PanelTypeface.allCases {
            XCTAssertEqual(PanelTypeface(rawValue: typeface.rawValue), typeface)
        }
        XCTAssertNil(PanelTypeface(rawValue: "comicSans"))
    }
}
