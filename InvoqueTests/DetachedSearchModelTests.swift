import XCTest
@testable import Invoque

/// `DetachedSearchModel` drives the detached file-search window: it mirrors
/// a live `FileSearchSession`, routes the picked row's action to `onSubmit`,
/// and applies pin/block through `EntryRules`. Sessions hop to the main
/// queue, so tests poll like `PanelModelTests` does.
final class DetachedSearchModelTests: XCTestCase {

    private func fileItem(_ name: String) -> Item {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return Item(id: Item.fileIDPrefix + url.path, title: name,
                    subtitle: "/tmp", icon: .fileURL(url),
                    action: .openFile(url), matchText: name)
    }

    /// A session whose walk has already finished with `items` — the
    /// settled case the window can also attach to.
    private func settledSession(_ items: [Item]) async -> FileSearchSession {
        let session = FileSearchSession(
            query: "find x", text: "x", debounceNanoseconds: 0,
            searcher: { _, _, emit in emit(items) })
        session.start()
        let deadline = Date().addingTimeInterval(7)
        while session.isPending, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(session.isPending,
                       "settledSession timed out before the walk finished")
        return session
    }

    /// A session that never starts — `isPending` stays true forever, so
    /// the model shows the streaming state without a live walk.
    private func pendingSession() -> FileSearchSession {
        FileSearchSession(query: "find x", text: "x",
                          debounceNanoseconds: 0,
                          searcher: { _, _, _ in })
    }

    /// Polls `predicate` against the model — session callbacks land on the
    /// main queue, so the test yields until they drain (or fails on the
    /// deadline).
    private func awaitCondition(
        _ predicate: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(7)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for the model",
                      file: file, line: line)
    }

    /// Attaching to a pending session mirrors its state: empty rows and
    /// the spinner flag, before any emission.
    func testPendingSessionShowsStreamingState() {
        let model = DetachedSearchModel(session: pendingSession(),
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        XCTAssertTrue(model.isPending)
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Emissions after attach land in `rows` — the window accumulates
    /// without the panel; a finished walk clears `isPending`.
    func testEmissionsStreamIntoRows() async {
        let emitReady = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() } // never leave the searcher blocked
        let slot = EmitSlot()
        let session = FileSearchSession(
            query: "find x", text: "x", debounceNanoseconds: 0,
            searcher: { _, _, emit in
                slot.emit = emit
                emitReady.signal()
                release.wait() // hold the walk open until the test ends it
            })
        session.start()
        XCTAssertEqual(emitReady.wait(timeout: .now() + 5), .success,
                       "searcher never handed off emit")
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        slot.emit?([fileItem("first.txt")])
        await awaitCondition { model.rows.map(\.title) == ["first.txt"] }
        XCTAssertTrue(model.isPending)

        slot.emit?([fileItem("first.txt"), fileItem("second.txt")])
        await awaitCondition {
            model.rows.map(\.title) == ["first.txt", "second.txt"]
        }
        release.signal()
        await awaitCondition { !model.isPending }
    }

    /// ⏎ forwards the selected row's action through `onSubmit`.
    func testSubmitPerformsFileAction() async {
        let session = await settledSession([fileItem("notes.txt")])
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        var performed: Item.Action?
        model.onSubmit = { performed = $0 }
        model.submit()
        guard case .openFile(let url)? = performed else {
            return XCTFail("expected .openFile, got \(String(describing: performed))")
        }
        XCTAssertEqual(url.lastPathComponent, "notes.txt")
    }

    /// ⌘⏎ swaps open for reveal — the same rule `PanelModel.submit`
    /// applies to file and app rows.
    func testCommandSubmitReveals() async {
        let session = await settledSession([fileItem("notes.txt")])
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        var performed: Item.Action?
        model.onSubmit = { performed = $0 }
        model.submit(commandModifier: true)
        guard case .revealInFinder(let url)? = performed else {
            return XCTFail("expected .revealInFinder, got \(String(describing: performed))")
        }
        XCTAssertEqual(url.lastPathComponent, "notes.txt")
    }

    /// Pin round-trips through `EntryRules` and returns the HUD toast —
    /// the window's ⌘P chord depends on both halves.
    func testTogglePinReturnsToastAndPersists() async {
        let item = fileItem("notes.txt")
        let rules = RulesRecorder()
        let session = await settledSession([item])
        let model = DetachedSearchModel(session: session,
                                        entryRules: rules.rules,
                                        iconResolver: nil)
        XCTAssertEqual(model.togglePin(), "Pinned notes.txt")
        XCTAssertEqual(rules.pinned, [item.id])
        // Pinned rows lead the shaped list.
        XCTAssertEqual(model.rows.first?.id, item.id)
    }

    /// Block drops the row on the spot — no rescan, same as the panel.
    func testToggleBlockRemovesRow() async {
        let item = fileItem("notes.txt")
        let rules = RulesRecorder()
        let session = await settledSession([item])
        let model = DetachedSearchModel(session: session,
                                        entryRules: rules.rules,
                                        iconResolver: nil)
        XCTAssertEqual(model.toggleBlock(), "Blocked notes.txt")
        XCTAssertEqual(rules.blocked, [item.id])
        XCTAssertTrue(model.rows.isEmpty)
    }

    /// Selection wraps at both ends — the same loop the panel's j/k
    /// navigation uses.
    func testSelectionWraps() async {
        let items = [fileItem("a.txt"), fileItem("b.txt")]
        let session = await settledSession(items)
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        model.selection = 1
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedRow?.title, "a.txt")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedRow?.title, "b.txt")
    }

    /// Page moves jump by the page step and clamp at the ends rather than
    /// wrapping — overshooting the last page lands on the last row.
    func testPageSelectionClampsAtEnds() async {
        let items = (0..<25).map { fileItem("f\($0).txt") }
        let session = await settledSession(items)
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        model.pageSelection(by: 1)
        XCTAssertEqual(model.selection, DetachedSearchModel.pageStep)
        model.pageSelection(by: 1)
        XCTAssertEqual(model.selection, 20)
        // 20 + pageStep overshoots the 25-row list — clamp, not wrap.
        model.pageSelection(by: 1)
        XCTAssertEqual(model.selection, 24)
        model.pageSelection(by: -1)
        XCTAssertEqual(model.selection, 14)
        model.pageSelection(by: -3)
        XCTAssertEqual(model.selection, 0)
    }

    /// Home/End (⌘↑/⌘↓ in the window) select the boundary rows directly.
    func testSelectBoundary() async {
        let items = [fileItem("a.txt"), fileItem("b.txt"), fileItem("c.txt")]
        let session = await settledSession(items)
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        model.selectBoundary(.last)
        XCTAssertEqual(model.selectedRow?.title, "c.txt")
        model.selectBoundary(.first)
        XCTAssertEqual(model.selectedRow?.title, "a.txt")
    }

    /// Empty lists must not trap page/boundary keys — the guards keep a
    /// pending session's navigation a no-op.
    func testPageAndBoundaryKeysOnEmptyList() {
        let model = DetachedSearchModel(session: pendingSession(),
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        model.pageSelection(by: 1)
        model.selectBoundary(.last)
        XCTAssertEqual(model.selection, 0)
        XCTAssertNil(model.selectedRow)
    }

    /// A streamed batch inserting above the picked row must not snap the
    /// selection back to the top — refresh tracks it by row id.
    func testRefreshKeepsSelectionOnRow() async {
        let emitReady = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() } // never leave the searcher blocked
        let slot = EmitSlot()
        let session = FileSearchSession(
            query: "find x", text: "x", debounceNanoseconds: 0,
            searcher: { _, _, emit in
                slot.emit = emit
                emitReady.signal()
                release.wait()
            })
        session.start()
        XCTAssertEqual(emitReady.wait(timeout: .now() + 5), .success,
                       "searcher never handed off emit")
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        slot.emit?([fileItem("bbb.txt")])
        await awaitCondition { model.rows.count == 1 }
        XCTAssertEqual(model.selectedRow?.title, "bbb.txt")

        slot.emit?([fileItem("aaa.txt"), fileItem("bbb.txt")])
        await awaitCondition { model.rows.count == 2 }
        XCTAssertEqual(model.selectedRow?.title, "bbb.txt")
        release.signal()
    }

    /// Close retires the session — the window's esc/⌘W/close button all
    /// land here.
    func testCloseCancelsSession() {
        let session = pendingSession()
        let model = DetachedSearchModel(session: session,
                                        entryRules: EntryRules(),
                                        iconResolver: nil)
        XCTAssertTrue(session.isPending)
        model.close()
        XCTAssertFalse(session.isPending)
    }

    /// Carries the captured `emit` across the searcher → test handoff;
    /// `emitReady`'s wait establishes the happens-before.
    private final class EmitSlot {
        var emit: (([Item]) -> Void)?
    }

    /// The `EntryRules` stub — records the writes pin/block generate.
    private final class RulesRecorder {
        var pinned: [String] = []
        var blocked: [String] = []
        private var pinnedSet = Set<String>()
        private var blockedSet = Set<String>()
        var rules: EntryRules {
            EntryRules(
                isPinned: { [self] in pinnedSet.contains($0) },
                isBlocked: { [self] in blockedSet.contains($0) },
                togglePin: { [self] id, _ in
                    pinned.append(id)
                    if pinnedSet.contains(id) { pinnedSet.remove(id); return false }
                    blockedSet.remove(id)
                    pinnedSet.insert(id)
                    return true
                },
                toggleBlock: { [self] id, _ in
                    blocked.append(id)
                    if blockedSet.contains(id) { blockedSet.remove(id); return false }
                    pinnedSet.remove(id)
                    blockedSet.insert(id)
                    return true
                })
        }
    }
}
