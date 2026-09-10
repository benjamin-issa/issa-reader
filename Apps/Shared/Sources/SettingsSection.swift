import IssaUI
import SwiftUI

/// A settings section and the sentence that explains it, put wherever this
/// platform will actually draw that sentence in full.
///
/// Every settings screen here is the same shape: an optional header, some rows,
/// and one sentence underneath saying what the rows do. On iOS and tvOS that
/// sentence is a `Section(footer:)`, which is where it belongs and where it has
/// always rendered correctly. On the Mac it cannot be, and this view exists so
/// that no call site has to know which platform it is on.
///
/// The Mac's reason is layout, and it was arrived at by watching four fixes
/// fail on a running build. A macOS section footer is handed a row sized for a
/// single line, and nothing supplied from the outside talks it out of that:
/// `fixedSize` alone still truncated to an ellipsis; adding `lineLimit(nil)`
/// wrapped the text inside a row still one line high, so the first and last
/// lines were cut through the middle; adding an `HStack` with a `Spacer` got a
/// two-line sentence right and still clipped a three-line one; and moving
/// `fixedSize` outwards, with `.listStyle(.inset)` on the List, changed
/// nothing. The identical sentence placed in the section's *content* wraps to
/// three lines and grows the row to fit, because an ordinary row is measured
/// against the list's real width rather than a footer's one-line proposal.
///
/// So on macOS the note is the section's last row. It still wears
/// `.settingsFooter()` there, so that a sentence which has changed position has
/// not also changed type, colour or weight.
struct SettingsSection<Content: View, Header: View>: View {
    /// The sentence under the section. A plain `String` rather than a view: it
    /// is prose, the same prose on every platform, and only this view gets to
    /// decide how it is dressed and where it is put.
    private let note: String

    /// The rows.
    private let content: Content

    /// Nil for the sections that have none. An optional that is branched on,
    /// rather than an `EmptyView` handed to `Section(header:)`, because those
    /// are two different sections: branching keeps a header-less section on the
    /// same initialiser it used before this view existed, so the only thing
    /// this change moves is the Mac's note.
    private let header: Header?

    init(
        note: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
    ) {
        self.note = note
        self.content = content()
        self.header = header()
    }

    init(note: String, @ViewBuilder content: () -> Content) where Header == EmptyView {
        self.note = note
        self.content = content()
        header = nil
    }

    var body: some View {
        #if os(macOS)
        if let header {
            Section { rowsAndNote } header: { header }
        } else {
            Section { rowsAndNote }
        }
        #else
        if let header {
            Section { content } header: { header } footer: { noteText }
        } else {
            Section { content } footer: { noteText }
        }
        #endif
    }

    #if os(macOS)
    /// The rows with the note after them, as one more row of the section.
    @ViewBuilder private var rowsAndNote: some View {
        content
        noteText
    }
    #endif

    private var noteText: some View {
        Text(note).settingsFooter()
    }
}
