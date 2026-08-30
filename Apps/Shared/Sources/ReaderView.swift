import IssaCore
import IssaRender
import IssaUI
import SwiftUI

/// The reading surface.
///
/// A page is drawn straight from the chapter's existing TextKit 2 layout, so
/// turning a page translates geometry rather than laying anything out again.
public struct ReaderView: View {
    @State private var model: ReaderModel
    @State private var showsPlayer = false
    @Environment(\.dismiss) private var dismiss
    @Environment(NowPlayingController.self) private var nowPlaying

    public init(book: Book, session: Session) {
        _model = State(initialValue: ReaderModel(book: book, session: session))
    }

    public var body: some View {
        GeometryReader { geometry in
            let pageSize = CGSize(
                width: max(geometry.size.width - model.style.pageMargin * 2, 1),
                height: max(geometry.size.height - model.style.pageMargin * 2 - 44, 1),
            )

            ZStack {
                model.style.theme.background.ignoresSafeArea()

                switch model.phase {
                case let .loading(message):
                    VStack(spacing: Metrics.spacing12) {
                        ProgressView()
                        Text(message).font(Typography.footnote).foregroundStyle(Palette.inkTertiary)
                    }
                case let .failed(reason):
                    ContentUnavailableView(
                        "Couldn't open this book",
                        systemImage: "book.closed",
                        description: Text(reason),
                    )
                case .ready:
                    pageContent(size: pageSize)
                }
            }
            .task(id: geometry.size) {
                if case .loading = model.phase {
                    await model.open(pageSize: pageSize)
                } else {
                    await model.resize(to: pageSize)
                }
            }
        }
        #if !os(tvOS)
        .navigationBarBackButtonHidden(false)
        #endif
        .onDisappear { Task { await model.saveProgress() } }
        #if !os(tvOS)
        .sheet(isPresented: $showsPlayer) {
            PlayerView(book: model.book, session: model.readerSession, coordinator: model.readalong)
                .presentationDetents([.large])
        }
        #endif
    }

    @ViewBuilder
    private func pageContent(size: CGSize) -> some View {
        VStack(spacing: 0) {
            PageCanvas(model: model, pageSize: size)
                .padding(model.style.pageMargin)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .onTapGesture { location in
                    Task {
                        // Left third goes back, the rest goes forward — the
                        // convention readers already expect.
                        if location.x < size.width * 0.33 { await model.previousPage() }
                        else { await model.nextPage() }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            Task {
                                if value.translation.width < -24 { await model.nextPage() }
                                else if value.translation.width > 24 { await model.previousPage() }
                            }
                        },
                )
                #endif

            footer
        }
        .onAppear {
            model.setReaderVisible(true)
            nowPlaying.attach(coordinator: model.readalong, book: model.book)
        }
        .onDisappear { model.setReaderVisible(false) }
    }

    private var footer: some View {
        HStack(spacing: Metrics.spacing12) {
            if model.hasNarration {
                Button {
                    Task { await model.togglePlayback() }
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.tangerine)
                }
                .buttonStyle(.plain)
                Button {
                    showsPlayer = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .buttonStyle(.plain)
            }
            Text(model.chapterTitle)
                .font(Typography.caption)
                .foregroundStyle(model.style.theme.text.opacity(0.55))
                .lineLimit(1)
            Spacer()
            if model.pageCount > 0 {
                Text("\(model.pageIndex + 1) / \(model.pageCount)")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(model.style.theme.text.opacity(0.55))
            }
        }
        .padding(.horizontal, model.style.pageMargin)
        .frame(height: 44)
    }
}

/// Draws one page, plus the read-along highlight when audio is playing.
struct PageCanvas: View {
    let model: ReaderModel
    let pageSize: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            guard let layout = model.layout, let page = model.currentPage else { return }

            // The highlight is drawn beneath the glyphs so it reads as paper
            // tint rather than a wash over the type.
            if let fragment = model.activeFragmentID {
                for rect in layout.highlightRects(forFragment: fragment, on: page) {
                    let rounded = Path(roundedRect: rect.insetBy(dx: -2, dy: -1), cornerRadius: 3)
                    context.fill(rounded, with: .color(model.style.theme.highlight))
                }
            }

            context.withCGContext { cgContext in
                layout.draw(page: page, in: cgContext)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
    }
}
