import IssaCore
import IssaUI
import SwiftUI

/// The library's navigation, made visible.
///
/// Search used to be a `.searchable` that scrolled away under the nav bar, and
/// shelf, sort and tags all lived behind one unlabeled filter glyph that
/// scrolled away too. So the shelf read as an undifferentiated wall of covers
/// headed "All books", and the current sort was invisible until you opened a
/// menu to look.
///
/// This sits **outside** the scroll view rather than at the top of its content.
/// A `LazyVStack` child would scroll away — the very problem — and the library's
/// refresh control has a history here: the first item in the scroll content is
/// exactly where its inset lives, and a first item whose height changes with
/// async state permanently inflated it. Keeping the header out of the scroll
/// view means that cannot happen again.
///
/// Its height must therefore never depend on anything that loads. Counts change
/// the *width* of a label, never the height of a row, and the chip row renders
/// even when the library is empty.
struct LibraryHeader: View {
    @Environment(AppModel.self) private var app
    @Binding var search: String
    /// How many books are on screen right now.
    ///
    /// Deliberately the *displayed* count, not the library total: a line
    /// reading "6 books" above a grid of three reads as a bug in the library.
    /// On the All books shelf the two are the same number anyway.
    let displayedCount: Int
    let isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            #if os(iOS)
            LibrarySearchField(text: $search)
            shelfChips
            #endif
            countAndSort
        }
        .padding(.horizontal, Metrics.spacing16)
        .padding(.top, Metrics.spacing8)
        .padding(.bottom, Metrics.spacing12)
        .background(Palette.paper)
    }

    // MARK: - Chips

    #if os(iOS)
    private var shelfChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacing8) {
                ForEach(LibraryArrangement.Shelf.allCases) { shelf in
                    ShelfChip(
                        title: shelf.title,
                        count: app.facets.count(shelf),
                        isSelected: app.arrangement.shelf == shelf,
                    ) {
                        app.arrangement.shelf = shelf
                    }
                }
                tagsChip
            }
            .padding(.horizontal, Metrics.spacing16)
        }
        // The row is padded internally so chips can scroll to the screen edge,
        // which is why the outer padding is removed here and added back inside.
        .padding(.horizontal, -Metrics.spacing16)
    }

    /// Tags overflow into a menu: a library's tag list runs long, and a chip
    /// each would push every shelf off the row.
    private var tagsChip: some View {
        @Bindable var app = app
        let selected = app.arrangement.tags
        return Menu {
            if !selected.isEmpty {
                Button("Clear tags") { app.arrangement.tags = [] }
                Divider()
            }
            ForEach(app.facets.tagCounts.prefix(12), id: \.name) { tag in
                Button {
                    if app.arrangement.tags.contains(tag.name) {
                        app.arrangement.tags.remove(tag.name)
                    } else {
                        app.arrangement.tags.insert(tag.name)
                    }
                } label: {
                    Label(
                        "\(tag.name) (\(tag.count))",
                        systemImage: app.arrangement.tags.contains(tag.name) ? "checkmark" : "",
                    )
                }
            }
        } label: {
            ChipLabel(
                title: selected.isEmpty ? "Tags" : "Tags · \(selected.count)",
                count: nil,
                isSelected: !selected.isEmpty,
                showsChevron: true,
            )
        }
        .accessibilityLabel(selected.isEmpty ? "Filter by tag" : "\(selected.count) tags selected")
    }
    #endif

    // MARK: - Count and sort

    private var countAndSort: some View {
        HStack {
            Text(countText)
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.inkTertiary)
            Spacer()
            #if !os(tvOS)
            sortMenu
            #endif
        }
    }

    private var countText: String {
        if isSearching {
            return "\(displayedCount) result\(displayedCount == 1 ? "" : "s")"
        }
        return "\(displayedCount) book\(displayedCount == 1 ? "" : "s")"
    }

    /// Labelled, never a bare glyph: the whole complaint was that the current
    /// sort could not be read without opening something.
    #if !os(tvOS)
    private var sortMenu: some View {
        @Bindable var app = app
        return Menu {
            Picker("Sort by", selection: $app.arrangement.sort) {
                ForEach(LibraryArrangement.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            Toggle("Reverse order", isOn: $app.arrangement.ascending)
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Text(app.arrangement.sort.title)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.tangerinePressed)
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, Metrics.spacing4)
            .background(Palette.surfaceRaised, in: Capsule())
            .fixedSize()
        }
        .accessibilityLabel("Sort by \(app.arrangement.sort.title)")
    }
    #endif
}

#if os(iOS)
/// An always-visible search field.
///
/// Built from the palette rather than `.regularMaterial`, which is the only
/// surface in the app not made from it.
struct LibrarySearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.inkTertiary)
            // The placeholder names every field the index actually covers.
            TextField("Title, author, narrator, series, tag", text: $text)
                .font(Typography.callout)
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            // A fixed slot, so the field does not resize as the button appears.
            Group {
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.inkQuaternary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .frame(width: 16)
        }
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
    }
}

struct ShelfChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, count: count, isSelected: isSelected, showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) book\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The capsule both a chip and the tags menu wear, so they cannot drift.
struct ChipLabel: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing4) {
            Text(title)
            if let count {
                Text("\(count)")
                    // Monospaced so a count settling from 0 does not shift the
                    // chips beside it.
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Palette.inkTertiary)
            }
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .font(Typography.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isSelected ? Color.white : Palette.inkSecondary)
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
        .background(isSelected ? Palette.tangerine : Palette.surface, in: Capsule())
        .overlay(
            Capsule().stroke(isSelected ? Color.clear : Palette.border, lineWidth: 1))
        .contentShape(Capsule())
    }
}
#endif

/// What a shelf with nothing on it says.
///
/// The library's own answer was a single grey line, while `ListeningView` had a
/// properly styled one — and the chips make an empty shelf a one-tap
/// destination rather than somewhere you arrive by accident, so it needs a way
/// back out rather than just an apology.
struct EmptyShelfView: View {
    let shelf: String
    let showAll: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spacing12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34))
                .foregroundStyle(Palette.inkQuaternary)
            Text("Nothing on \(shelf)")
                .font(Typography.headline)
                .foregroundStyle(Palette.ink)
            Text("No books match this shelf right now.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
            Button("Show all books", action: showAll)
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerinePressed)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spacing32)
    }
}
