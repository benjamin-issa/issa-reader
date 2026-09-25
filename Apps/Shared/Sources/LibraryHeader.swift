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
                .accessibilityIdentifier("field.librarySearch")
            shelfChips
            // A count and a sort describe a grid. Browse has rails, and
            // search results are already the answer to a question — but the
            // number of them is worth a line. Mode and search are the
            // reader's doing, never something that loads, so the height
            // changing here cannot inflate the refresh control.
            if app.libraryMode == .all || isSearching {
                countAndSort
            }
            #else
            countAndSort
            #endif
        }
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.top, Metrics.spacing8)
        .padding(.bottom, Metrics.spacing12)
        .background(Palette.paper)
    }

    // MARK: - Chips

    #if os(iOS)
    /// Browse first, then the shelves. Browse is the rails; a shelf is the
    /// flat grid cut that way, so tapping one leaves Browse. The tags a reader
    /// picked travel with them from shelf to shelf, as they always have.
    private var shelfChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacing8) {
                ShelfChip(title: "Browse", count: nil, isSelected: app.libraryMode == .browse) {
                    app.libraryMode = .browse
                }
                ForEach(LibraryArrangement.Shelf.allCases) { shelf in
                    ShelfChip(
                        title: shelf.title,
                        count: app.facets.count(shelf),
                        isSelected: app.libraryMode == .all && app.arrangement.shelf == shelf,
                    ) {
                        app.showAllBooks(shelf: shelf, tags: app.arrangement.tags)
                    }
                }
                tagsChip
            }
            .padding(.horizontal, Metrics.screenMargin)
        }
        // The row is padded internally so chips can scroll to the screen edge,
        // which is why the outer padding is removed here and added back inside.
        .padding(.horizontal, -Metrics.screenMargin)
        .accessibilityIdentifier("chips.shelf")
    }
    #endif

    #if os(iOS) || os(macOS)
    /// Tags overflow into a menu: a library's tag list runs long, and a chip
    /// each would push every shelf off the row.
    private var tagsChip: some View {
        @Bindable var app = app
        let selected = app.arrangement.tags
        #if os(macOS)
        // A system pull-down, not the chip. On the Mac a `Menu` is an AppKit
        // pull-down button, which draws its own bezel and indicator around
        // whatever label it is handed — so the chip's capsule and chevron
        // came out as a second button inside the first, with two arrows. The
        // label is bare text and the system draws the rest. Each tag is a
        // `Toggle`, which the menu shows as a checkmarked item: this is a
        // many-of choice, and a checkmark is how the Mac says so.
        return Menu {
            if !selected.isEmpty {
                Button("Clear tags") { app.arrangement.tags = [] }
                Divider()
            }
            ForEach(app.facets.tagCounts.prefix(12), id: \.name) { tag in
                Toggle("\(tag.name) (\(tag.count))", isOn: tagBinding(tag.name))
            }
        } label: {
            Text(selected.isEmpty ? "Tags" : "Tags · \(selected.count)")
        }
        .controlSize(.small)
        .help("Filter by tag")
        .accessibilityLabel(selected.isEmpty ? "Filter by tag" : "\(selected.count) tags selected")
        #else
        return Menu {
            if !selected.isEmpty {
                Button("Clear tags") { app.arrangement.tags = [] }
                Divider()
            }
            ForEach(app.facets.tagCounts.prefix(12), id: \.name) { tag in
                Button {
                    // A tag is a cut through the grid, so picking one opens
                    // the grid — Browse has its own tag rails.
                    var tags = app.arrangement.tags
                    if tags.contains(tag.name) { tags.remove(tag.name) } else { tags.insert(tag.name) }
                    app.showAllBooks(shelf: app.arrangement.shelf, tags: tags)
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
        #endif
    }
    #endif

    #if os(macOS)
    /// One tag's checkmark in the Mac's pull-down.
    ///
    /// Setting it makes the same cut the phone's tag button does, through the
    /// same call: a tag is a cut through the grid, so picking one opens the
    /// grid, and the shelf the reader is on stays the shelf.
    private func tagBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { app.arrangement.tags.contains(name) },
            set: { isOn in
                var tags = app.arrangement.tags
                if isOn { tags.insert(name) } else { tags.remove(name) }
                app.showAllBooks(shelf: app.arrangement.shelf, tags: tags)
            },
        )
    }
    #endif

    // MARK: - Count and sort

    private var countAndSort: some View {
        HStack {
            Text(countText)
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.inkTertiary)
                #if os(macOS)
                // One line, at its own width, and first to be given room.
                // Beside the Mac's rigid tags and sort controls this was the
                // only child of the row that would give way, so with the book
                // column open in a 900pt window the row squeezed it down to a
                // letter's width and "1 result" wrapped one letter per line.
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                #endif
            Spacer()
            // The Mac has no chip row, and a tag rail's "See all" narrows the
            // grid by a tag. Without this the reader would be left looking at
            // "3 of 300 books" with nothing on screen able to undo it.
            #if os(macOS)
            tagsChip
            #endif
            #if !os(tvOS)
            sortMenu
            #endif
        }
    }

    private var countText: String {
        if isSearching {
            return "\(displayedCount) result\(displayedCount == 1 ? "" : "s")"
        }
        // A tag filter narrows the grid below the selected shelf's own number,
        // and the plain "3 books" sitting under a chip reading "All books 6"
        // reads as a contradiction — the chips count the whole library, this
        // counts what's on screen. When tags are in force, count against that
        // shelf's total ("3 of 6") so the line and the highlighted chip
        // describe the same set out loud. Without tags the shelf filter and the
        // chip share a predicate, so the plain count cannot disagree with it.
        if !app.arrangement.tags.isEmpty {
            let shelfTotal = app.facets.count(app.arrangement.shelf)
            return "\(displayedCount) of \(shelfTotal) book\(shelfTotal == 1 ? "" : "s")"
        }
        return "\(displayedCount) book\(displayedCount == 1 ? "" : "s")"
    }

    /// A control, not a caption: a bordered, tinted capsule with a sort glyph,
    /// the current sort's name and a disclosure chevron, so it reads as
    /// something you press rather than a note about how the grid is ordered.
    /// The current sort is still legible without opening anything, which was the
    /// original point of labelling it.
    #if !os(tvOS)
    private var sortMenu: some View {
        @Bindable var app = app
        #if os(macOS)
        // The capsule above is the phone's. Handed to a Mac `Menu`, it sat
        // inside the pull-down's own bezel with a second chevron beside its
        // first, as the tags menu did. The Mac says the same things with two
        // standard controls: a pop-up button, whose title is the current sort
        // — so it is still legible without opening anything — and a toggle
        // for the direction, since a pop-up holds one choice and this row
        // has two. Unlabelled on screen, where the pop-up's title says what
        // it is; VoiceOver hears "Sort by" and the sort as its value.
        return HStack(spacing: Metrics.spacing4) {
            Picker("Sort by", selection: $app.arrangement.sort) {
                ForEach(LibraryArrangement.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help("Changes how your library is ordered")
            .accessibilityHint("Changes how your library is ordered")
            Toggle(isOn: $app.arrangement.ascending) {
                Label("Reverse order", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Reverse order")
            .accessibilityLabel("Reverse order")
        }
        .controlSize(.small)
        #else
        return Menu {
            Picker("Sort by", selection: $app.arrangement.sort) {
                ForEach(LibraryArrangement.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            Toggle("Reverse order", isOn: $app.arrangement.ascending)
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(app.arrangement.sort.title)
                    .font(Typography.subhead.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Palette.tangerinePressed)
            .padding(.horizontal, Metrics.spacing12)
            .padding(.vertical, Metrics.spacing8)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.borderStrong, lineWidth: 1))
            .fixedSize()
            // The capsule sits shy of the 44pt floor, so the tap area is grown
            // to meet it without inflating the visible pill.
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .accessibilityLabel("Sort by \(app.arrangement.sort.title)")
        .accessibilityHint("Changes how your library is ordered")
        #endif
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

#endif

#if os(iOS)
struct ShelfChip: View {
    let title: String
    /// Nil for a chip that is not a shelf — Browse counts nothing.
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, count: count, isSelected: isSelected, showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0) book\($0 == 1 ? "" : "s")" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#endif

/// The capsule both a chip and the phone's tags menu wear, so they cannot
/// drift. The Mac's tags menu does not wear it: a Mac `Menu` draws its own
/// bezel and chevron around its label, so there the label is bare text (see
/// `LibraryHeader.tagsChip`).
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
        PalettePlaceholder(
            symbol: "books.vertical",
            title: "Nothing on \(shelf)",
            message: "No books match this shelf right now.",
            actionTitle: "Show all books",
            action: showAll,
        )
    }
}

/// An empty or failed state, drawn from the palette.
///
/// `ContentUnavailableView` is entirely system-coloured, which on warm paper
/// reads as a different app — the reason `ListeningView` hand-rolled its own
/// long before this existed. One shape now, so they cannot drift again.
struct PalettePlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Metrics.spacing12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Palette.inkQuaternary)
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.tangerinePressed)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.spacing32)
    }
}
