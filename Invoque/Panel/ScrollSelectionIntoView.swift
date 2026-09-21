import SwiftUI

extension View {

    /// Keeps the row identified by `selection` visible in the enclosing
    /// `ScrollView` whenever the selection changes — the arrow-key follow
    /// shared by `PanelView`'s result list and `DetachedSearchView`.
    ///
    /// `.task(id:)` stands in for `onChange`: the non-deprecated form
    /// requires macOS 14 and the app targets 13. The key is the row's
    /// identity, not its index — a new query can replace every row while
    /// the index stays put. No anchor is passed, so the scroll is
    /// minimal: an already-visible row is not dragged back to center on
    /// every keypress.
    func scrollSelectionIntoView<ID: Hashable>(
        _ selection: ID?, proxy: ScrollViewProxy
    ) -> some View {
        task(id: selection) {
            guard let selection else { return }
            proxy.scrollTo(selection)
        }
    }
}
