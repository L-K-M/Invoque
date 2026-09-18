import XCTest
@testable import Invoque

final class CommandPermissionGrantsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var grants: CommandPermissionGrants!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A fresh suite per test — persisted grants must never leak
        // between tests or into the app's real defaults.
        suiteName = "CommandPermissionGrantsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        grants = CommandPermissionGrants(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        grants = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testUngrantedReturnsOnlyRiskyPermissions() throws {
        let command = try makeCommand(permissions: ["shell", "network", "clipboard.read"])
        XCTAssertEqual(grants.ungranted(for: command), [.shell])
    }

    func testNonRiskyCommandNeedsNoConsent() throws {
        let command = try makeCommand(permissions: ["network", "files"])
        XCTAssertTrue(grants.ungranted(for: command).isEmpty)
    }

    func testGrantRetiresTheRequest() throws {
        let command = try makeCommand(permissions: ["shell"])
        grants.grant([.shell], for: command)
        XCTAssertTrue(grants.ungranted(for: command).isEmpty)
    }

    /// A manifest that gains a risky permission re-asks for that one only —
    /// earlier grants are kept, not re-litigated.
    func testNewRiskyPermissionReAsks() throws {
        let command = try makeCommand(permissions: ["shell", "paste"])
        grants.grant([.shell], for: command)
        XCTAssertEqual(grants.ungranted(for: command), [.paste])
    }

    func testUngrantedSortsForStableDisplay() throws {
        let command = try makeCommand(permissions: ["shell", "paste"])
        XCTAssertEqual(grants.ungranted(for: command), [.paste, .shell])
    }

    func testConsentLineCoversEveryRiskyPermission() {
        for permission in CommandPermissionGrants.risky {
            XCTAssertFalse(CommandPermissionGrants.consentLine(for: permission).isEmpty)
        }
    }

    // MARK: Helpers

    private func makeCommand(name: String = "demo",
                             permissions: [String]) throws -> Command {
        let permissionList = permissions
            .map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
            {"schemaVersion": 1, "name": "\(name)", "title": "Demo",
             "runtime": "js", "entry": "main.js", "mode": "action",
             "permissions": [\(permissionList)]}
            """
        let manifest = try JSONDecoder().decode(CommandManifest.self,
                                                from: Data(json.utf8))
        return Command(manifest: manifest,
                       directory: URL(fileURLWithPath: "/tmp/\(name)"))
    }
}
