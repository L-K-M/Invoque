import Foundation

/// One `find`/`f`/`search` scan as a shareable object: the debounce, the
/// walk task, and the accumulated items live here so the list's owner can
/// change mid-scan — ⏎ while searching hands the session to a detached
/// results window (`PanelModel.releaseFileSession`) and the same walk
/// keeps streaming there instead of restarting or dying with the panel.
///
/// State and callbacks are main-queue only — both subscribers
/// (`PanelModel`, `DetachedSearchModel`) are main-affine. The walk itself
/// runs in a detached task so a caller on main can't drag the disk scan
/// onto the UI thread. Emissions hop to the main queue via
/// `DispatchQueue.main.async` — FIFO ordering guarantees `items` only
/// ever advances forward and `finish` lands after the last absorb.
final class FileSearchSession {

    /// The scan backend — `FileSearch.stream` in production, a stub in
    /// tests. `emit` delivers the accumulated ranked snapshot (never a
    /// delta) and may fire on the walk's thread; the session hops.
    typealias Searcher = (_ text: String,
                          _ isCancelled: @escaping () -> Bool,
                          _ emit: @escaping ([Item]) -> Void) -> Void

    /// The full typed query — "find hello.pdf". The detached window shows
    /// it as title and header.
    let query: String
    /// The post-keyword scan text — "hello.pdf".
    let text: String

    /// The latest accumulated snapshot — ranked, pins leading, at most
    /// `SearchModel.maxResults`. Read on the main queue.
    private(set) var items: [Item] = []

    /// True until the walk finishes or `cancel` runs.
    private(set) var isPending = true

    /// A newer snapshot landed in `items`. Main queue. One subscriber —
    /// detaching reassigns the slot to the window's model.
    var onUpdate: (() -> Void)?
    /// The walk ended — complete, cancelled, or abandoned. Main queue,
    /// fires once.
    var onFinish: (() -> Void)?
    /// The debounce passed and the walk started — the model's
    /// `fileRunsStarted` hook. Main queue, fires once.
    var onStart: (() -> Void)?

    private let debounceNanoseconds: UInt64
    private let searcher: Searcher
    private var task: Task<Void, Never>?
    private var finished = false

    init(query: String, text: String, debounceNanoseconds: UInt64,
         searcher: @escaping Searcher) {
        self.query = query
        self.text = text
        self.debounceNanoseconds = debounceNanoseconds
        self.searcher = searcher
    }

    deinit {
        task?.cancel()
    }

    /// Starts the debounce-then-walk task. The closure captures values,
    /// not `self`, so the session can deinit mid-walk (both owners gone)
    /// — its deinit cancels the task and stragglers no-op on the weak
    /// hops.
    func start() {
        // One walk per session — a second start would interleave
        // snapshots, and start-after-cancel would burn a doomed scan
        // whose emissions `absorb` drops anyway.
        guard task == nil, !finished else { return }
        let text = self.text
        let searcher = self.searcher
        let debounce = self.debounceNanoseconds
        task = Task.detached {
            try? await Task.sleep(nanoseconds: debounce)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                // The cancel probe above is a TOCTOU window: a cancel on
                // main can run `finish` while this hop sits queued.
                // `isPending` is the same guard `absorb` uses — a start
                // after finish would fire the hook outside the pending
                // window it documents.
                if self?.isPending == true { self?.onStart?() }
            }
            searcher(text, { Task.isCancelled }) { items in
                DispatchQueue.main.async { [weak self] in
                    self?.absorb(items)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish()
            }
        }
    }

    /// Stops the walk and settles the session — `isPending` flips and
    /// `onFinish` fires like a completed scan, so the subscriber's state
    /// never dangles at "searching".
    func cancel() {
        task?.cancel()
        finish()
    }

    // MARK: Internals (main queue)

    /// One emission landing. Called only from the main-queue hops, which
    /// are FIFO — `items` can never regress to an earlier snapshot. A
    /// post-cancel straggler drops: the walk polls `Task.isCancelled` on
    /// a stride, so a few emissions can outlive `cancel`.
    private func absorb(_ newItems: [Item]) {
        guard isPending else { return }
        items = newItems
        onUpdate?()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        isPending = false
        onFinish?()
    }
}
