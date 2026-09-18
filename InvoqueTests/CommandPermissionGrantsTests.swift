import XCTest
@testable import Invoque

final class CommandPermissionGrantsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var grants: CommandPermissionGrants!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A fresh suite per test — persisted grants must never leak
        // between tests or into the app's real defaults.
        suiteName = "CommandPermissionGrantsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        grants = CommandPermissionGrants(defaults: defaults)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoque-grants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        grants = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testUngrantedReturnsOnlyRiskyPermissions() throws {
        // clipboard.read is intentionally NOT consent-gated — it is declared
        // (and surfaced on the permission badge) but only shell/paste gate.
        // If that classification changes, this fixture must change with it.
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

    /// Consent attaches to the code the user saw: the same command name
    /// with different entry content never inherits a grant — that's what
    /// stops a regenerated or replaced command from running `shell`
    /// silently under an old Allow.
    func testChangedEntryReAsksUnderTheSameName() throws {
        let v1 = try makeCommandOnDisk(name: "demo",
                                       entry: "return { title: \"v1\" };",
                                       directoryName: "v1")
        let v2 = try makeCommandOnDisk(name: "demo",
                                       entry: "return { title: \"v2\" };",
                                       directoryName: "v2")
        grants.grant([.shell], for: v1)
        XCTAssertTrue(grants.ungranted(for: v1).isEmpty)
        XCTAssertEqual(grants.ungranted(for: v2), [.shell],
                       "changed code must not inherit the old code's grant")
    }

    /// Consenting to new bytes retires the old bytes' grant — one entry per
    /// name, not a growing pile of stale hashes. Reverting to the old code
    /// re-asks, which is the safe direction.
    func testNewHashSupersedesOldGrantUnderSameName() throws {
        let v1 = try makeCommandOnDisk(name: "demo",
                                       entry: "return { title: \"v1\" };",
                                       directoryName: "v1")
        let v2 = try makeCommandOnDisk(name: "demo",
                                       entry: "return { title: \"v2\" };",
                                       directoryName: "v2")
        grants.grant([.shell], for: v1)
        grants.grant([.shell], for: v2)
        XCTAssertEqual(grants.ungranted(for: v1), [.shell],
                       "the superseded hash's grant must be gone")
        XCTAssertTrue(grants.ungranted(for: v2).isEmpty)
    }

    /// Identical code under the same name keeps its grant — reinstalls and
    /// the Maker's stage-then-save path don't re-prompt.
    func testIdenticalEntryKeepsGrantAcrossDirectories() throws {
        let source = "return { title: \"same\" };"
        let one = try makeCommandOnDisk(name: "demo", entry: source,
                                        directoryName: "one")
        let two = try makeCommandOnDisk(name: "demo", entry: source,
                                        directoryName: "two")
        grants.grant([.shell], for: one)
        XCTAssertTrue(grants.ungranted(for: two).isEmpty)
    }

    func testConsentLineCoversEveryRiskyPermission() {
        for permission in CommandPermissionGrants.risky {
            XCTAssertFalse(CommandPermissionGrants.consentLine(for: permission).isEmpty)
        }
    }

    // MARK: Helpers

    /// A real command on disk — the grant key hashes the entry file, so
    /// content-scoping tests need actual bytes, not just a manifest.
    private func makeCommandOnDisk(name: String, entry: String,
                                   directoryName: String? = nil) throws -> Command {
        let directory = tempRoot.appendingPathComponent(directoryName ?? name)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let json = """
            {"schemaVersion": 1, "name": "\(name)", "title": "Demo",
             "runtime": "js", "entry": "main.js", "mode": "action",
             "permissions": ["shell"]}
            """
        try Data(json.utf8).write(to: directory.appendingPathComponent("command.json"))
        try entry.write(to: directory.appendingPathComponent("main.js"),
                        atomically: true, encoding: .utf8)
        return try Command(directory: directory)
    }

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
