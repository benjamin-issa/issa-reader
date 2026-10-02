import Foundation
import IssaCore
import IssaPlayback
import IssaUI
import Observation

/// The books the reader added from their own files, and everything they write.
///
/// One per process, like `AskCoordinator`, held by the app's services and
/// handed to every scene. It owns `Local/` — a folder per book holding the copy,
/// its cover, the narration extracted from it and the publisher's face — and
/// the device store (`LibraryStore.deviceBooksKey`), which keeps each book's
/// row, place, highlights and narration anchor. Neither is anything an
/// account's reset reaches: they are the device's, and nothing in them is ever
/// sent to a server.
///
/// It is also the books' `ReaderPersistence`: `AppModel.reader(for:persistence:)`
/// points a local reader's writes here, through a position guard of this
/// library's own that applies the server writer's rules.
@Observable
@MainActor
public final class LocalLibrary: ReaderPersistence {
    /// Every book, most recently opened first — then most recently added.
    public private(set) var books: [Book] = []
    /// Whether `load()` has run, so a window restored before it can wait
    /// rather than say a book is not here.
    public private(set) var isLoaded = false
    /// Books whose copy is missing: a backup restored the row and not the file.
    /// They keep their place and highlights, and read "Not on iPhone" until the
    /// reader adds the file again.
    public private(set) var missingFiles: Set<String> = []
    /// Files on their way in, and the ones that could not be added, in the
    /// order chosen.
    public private(set) var imports: [LocalImport] = []
    /// A removal the reader can still take back.
    public private(set) var pendingRemoval: PendingRemoval?
    /// Set by File › Add Book… and the Mac's sign-in link, and taken by the
    /// list window, which opens the picker: the request can arrive before the
    /// window does, and is waiting for it when it opens.
    public var addRequested = false
    /// Whether the list has been shown this session, which is when the Mac's
    /// File menu gains Add Book… — never for a reader who has not looked.
    public private(set) var wasShown = false

    public func requestAdd() { addRequested = true }
    public func noteShown() { if !wasShown { wasShown = true } }
    /// The book an import found already here, for the "already on this
    /// iPhone" toast and the outline on its row. Cleared by `clearDuplicate`.
    public private(set) var duplicate: Book?

    /// A removal waiting out its undo window. Several books at once on the Mac.
    public struct PendingRemoval: Equatable, Sendable {
        public let books: [Book]
        public var titles: [String] { books.map(\.title) }
        /// The toast's words.
        @MainActor public var message: String { LocalBooksCopy.removed(titles) }
    }

    /// Told as a book leaves the list, before anything is deleted: whatever is
    /// reading or narrating it has to stop now, undo or not. The app releases
    /// the reader here (`AppModel.releaseLocalBook`).
    @ObservationIgnored public var onRemove: ((String) -> Void)?
    /// Told once a removal can no longer be taken back, as its files go: the
    /// state other objects keep per book — a question index, a reader style —
    /// goes with it.
    @ObservationIgnored public var onForget: ((String) -> Void)?

    /// `Local/`.
    public let root: URL
    let store: LibraryStore?
    var importer: LocalBookImporter
    /// How long a removal waits before it is carried out.
    @ObservationIgnored var undoWindow: Duration = AppModel.removalUndoWindow
    /// How long an added row stays before it goes.
    @ObservationIgnored var addedHold: Duration = .milliseconds(1500)
    /// Mints each new book's uuid. Injectable so a test knows the next one.
    @ObservationIgnored var makeUUID: () -> String = { UUID().uuidString.lowercased() }

    /// One high-water mark per book and clock, as `AppModel.positionGuards`.
    var positionGuards: [String: PositionGuard] = [:]

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var running: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var removalTask: Task<Void, Never>?

    /// - Parameters:
    ///   - root: the `Local` folder; a test passes a temporary one.
    ///   - storeDirectory: where the device store's file goes; the app's
    ///     `Store/` by default, beside every server's, and backed up like them.
    public init(root: URL = LocalBookFiles.defaultRoot, storeDirectory: URL? = nil) {
        self.root = root
        store = try? LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: storeDirectory)
        importer = LocalBookImporter(root: root)
        if store == nil {
            IssaLog.warning("local library store could not be opened", [:])
        }
    }

    // MARK: - Loading

    /// Reads the library from the device store and squares it with the disk.
    ///
    /// Copies still in `.incoming/` are from a run that never finished, and
    /// go. A folder with no row is an import that crashed before its row was
    /// written — the row is written last for exactly this — and goes too. A row
    /// whose copy is gone is a book restored from a backup, and is kept, marked
    /// missing.
    public func load() async {
        LocalBookImporter.excludeFromBackup(root)
        try? FileManager.default.removeItem(at: LocalBookFiles.incoming(in: root))
        let stored = ((try? await store?.allBooks()) ?? []).filter(\.isLocal)
        let known = Set(stored.map { LocalBookFiles(bookUUID: $0.uuid, root: root).folder.lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders where !folder.lastPathComponent.hasPrefix(".")
            && !known.contains(folder.lastPathComponent)
        {
            IssaLog.info("local folder with no book removed", ["folder": folder.lastPathComponent])
            try? FileManager.default.removeItem(at: folder)
        }
        missingFiles = Set(stored.filter {
            !FileManager.default.fileExists(atPath: files(for: $0.uuid).epub.path)
        }.map(\.uuid))
        books = Self.ordered(stored)
        isLoaded = true
        IssaLog.info("local library loaded", [
            "books": String(books.count), "missing": String(missingFiles.count),
        ])
    }

    /// The order the list shows: most recently opened, then most recently
    /// added, then by title so the order is stable.
    static func ordered(_ books: [Book]) -> [Book] {
        books.sorted { a, b in
            let left = a.localCopy.map { $0.lastOpenedAt ?? $0.importedAt } ?? .distantPast
            let right = b.localCopy.map { $0.lastOpenedAt ?? $0.importedAt } ?? .distantPast
            if left != right { return left > right }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Every book's uuid, for the account reset's kept set — the books in the
    /// list and the ones a removal is still holding.
    public var uuids: Set<String> {
        Set(books.map(\.uuid)).union(pendingRemoval?.books.map(\.uuid) ?? [])
    }

    public func book(_ uuid: String) -> Book? { books.first { $0.uuid == uuid } }

    /// Whether the list has anything on it at all: a book, a book waiting for
    /// its file, or a file on its way in.
    public var hasAnything: Bool { !books.isEmpty || !missingFiles.isEmpty || !imports.isEmpty }

    /// What each book takes on this device, by uuid: its copy, its cover, and
    /// the narration and face extracted from it, which are this library's to
    /// remove. A walk of the disk, so the list asks off the main actor.
    public nonisolated static func sizes(of uuids: [String], root: URL) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: uuids.map {
            ($0, size(of: LocalBookFiles(bookUUID: $0, root: root).folder))
        })
    }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Importing

    /// Queues files the reader chose. Each gets its row at once, as Waiting;
    /// they are added one at a time.
    ///
    /// - Parameter reattaching: the book whose missing file these are meant to
    ///   put back ("Add Again…"), when that is the reason.
    public func importBooks(_ urls: [URL], reattaching: String? = nil) {
        for url in urls { imports.append(LocalImport(source: url, reattaching: reattaching)) }
        IssaLog.info("local import queued", ["files": String(urls.count)])
        startRunner()
    }

    /// Runs the same file again, after a problem whose action is Try Again.
    public func retry(_ id: UUID) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        imports[index].stage = .waiting
        startRunner()
    }

    /// Stops one file. A cancelled file leaves no trace and no message.
    public func cancelImport(_ id: UUID) {
        guard let index = imports.firstIndex(where: { $0.id == id }), imports[index].isUnfinished
        else { return }
        imports.remove(at: index)
        if running?.id == id { running?.task.cancel() }
    }

    /// Stops every file still to finish.
    public func cancelAllImports() {
        for item in imports where item.isUnfinished { cancelImport(item.id) }
    }

    /// Takes a problem row away.
    public func dismissImport(_ id: UUID) {
        imports.removeAll { $0.id == id && !$0.isUnfinished }
    }

    /// The toast about a duplicate has been seen.
    public func clearDuplicate() { duplicate = nil }

    /// Waits for every queued file to finish, for tests.
    func importsSettled() async {
        await runner?.value
    }

    private func startRunner() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let next = self.imports.first(where: { $0.stage == .waiting }) {
                await self.run(next)
            }
            self?.runner = nil
        }
    }

    /// Runs one file through the importer and, if it passes, adds it.
    private func run(_ item: LocalImport) async {
        let id = item.id
        let importer = importer
        // Holds the library for the length of one import, which it outlives
        // anyway: it is the process's.
        let stage: @Sendable (LocalImport.Stage) -> Void = { stage in
            Task { @MainActor in self.advance(id, to: stage) }
        }
        let task = Task<Void, Never> { [weak self] in
            let result: Result<LocalBookImporter.Prepared, LocalImportError>
            do throws(LocalImportError) {
                result = .success(try await importer.run(item.source, id: id, stage: stage))
            } catch {
                result = .failure(error)
            }
            await self?.finish(item, with: result)
        }
        running = (id, task)
        await task.value
        running = nil
    }

    /// A progress report from the importer, which runs elsewhere. Ignored for a
    /// row that has finished or gone, so a late report cannot bring it back.
    private func advance(_ id: UUID, to stage: LocalImport.Stage) {
        guard let index = imports.firstIndex(where: { $0.id == id }), imports[index].isUnfinished
        else { return }
        imports[index].stage = stage
    }

    private func finish(
        _ item: LocalImport, with result: Result<LocalBookImporter.Prepared, LocalImportError>,
    ) async {
        // Cancelled: the row is already gone, and so must the copy be.
        guard let index = imports.firstIndex(where: { $0.id == item.id }) else {
            if case let .success(prepared) = result { prepared.discard() }
            return
        }
        switch result {
        case let .failure(error):
            imports[index].stage = .failed(error)
            IssaLog.info("local import refused", ["reason": String(describing: error)])
        case let .success(prepared):
            do {
                let book = try await add(prepared, reattaching: item.reattaching)
                guard let row = imports.firstIndex(where: { $0.id == item.id }) else { return }
                if let book {
                    imports[row].stage = .added(bookUUID: book.uuid)
                    holdAddedRow(item.id)
                } else {
                    // A duplicate: nothing added, and the toast says which.
                    imports.remove(at: row)
                }
            } catch {
                prepared.discard()
                if let row = imports.firstIndex(where: { $0.id == item.id }) {
                    imports[row].stage = .failed(error)
                }
            }
        }
    }

    private func holdAddedRow(_ id: UUID) {
        let hold = addedHold
        Task { [weak self] in
            try? await Task.sleep(for: hold)
            self?.imports.removeAll { $0.id == id }
        }
    }

    /// Adds a checked copy to the library, or finds it already here.
    ///
    /// Matched first by the package's unique identifier and then by the file's
    /// hash, as the design asks. A match whose copy is present is a duplicate:
    /// nothing is added and `duplicate` names it. A match whose copy is missing
    /// is a book restored from a backup: the file goes back under its record,
    /// with its place and highlights. Anything else is a new book, under a
    /// fresh uuid, with its row written last.
    ///
    /// - Returns: the book added or restored, or nil for a duplicate.
    private func add(_ prepared: LocalBookImporter.Prepared, reattaching: String?) async throws(LocalImportError) -> Book? {
        let match = books.first {
            guard let id = prepared.packageIdentifier, !id.isEmpty else { return false }
            return $0.localCopy?.packageIdentifier == id
        } ?? books.first { $0.localCopy?.fingerprint == prepared.fingerprint }

        if let reattaching {
            guard let target = book(reattaching) else { throw .copyFailed }
            guard match?.uuid == reattaching else {
                throw .notTheSameBook(expectedFileName: target.localCopy?.fileName ?? "the same file")
            }
        }

        if let match {
            if missingFiles.contains(match.uuid) {
                return try await reattach(prepared, to: match)
            }
            prepared.discard()
            duplicate = match
            IssaLog.info("local import already here", ["book": match.uuid])
            return nil
        }

        let uuid = makeUUID()
        let files = files(for: uuid)
        do {
            try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: prepared.copy, to: files.epub)
            if let cover = prepared.cover { try? FileManager.default.moveItem(at: cover, to: files.cover) }
        } catch {
            try? FileManager.default.removeItem(at: files.folder)
            throw .copyFailed
        }
        let copy = LocalCopy(
            fileName: prepared.fileName,
            fingerprint: prepared.fingerprint,
            byteCount: prepared.byteCount,
            importedAt: Date(),
            hasCover: FileManager.default.fileExists(atPath: files.cover.path),
            packageIdentifier: prepared.packageIdentifier,
            epubVersion: prepared.epubVersion,
            isFixedLayout: prepared.isFixedLayout,
            notices: prepared.notices)
        let book = Book.local(
            uuid: uuid, metadata: prepared.metadata,
            narrationDuration: prepared.narrationDuration, copy: copy)
        // Last, so a crash before it leaves a folder `load()` removes, never a
        // row with nothing behind it.
        do {
            guard let store else { throw LocalImportError.copyFailed }
            try await store.upsert(book)
        } catch {
            try? FileManager.default.removeItem(at: files.folder)
            throw .copyFailed
        }
        books = Self.ordered(books + [book])
        IssaLog.info("local book added", [
            "book": uuid,
            "narration": String(book.hasReadalong),
            "notices": prepared.notices.map(\.rawValue).joined(separator: ","),
        ])
        return book
    }

    /// Puts a file back under the record a backup restored without it.
    private func reattach(_ prepared: LocalBookImporter.Prepared, to existing: Book) async throws(LocalImportError) -> Book {
        let files = files(for: existing.uuid)
        do {
            try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: files.epub)
            try FileManager.default.moveItem(at: prepared.copy, to: files.epub)
            if let cover = prepared.cover {
                try? FileManager.default.removeItem(at: files.cover)
                try? FileManager.default.moveItem(at: cover, to: files.cover)
            }
        } catch {
            throw .copyFailed
        }
        var copy = existing.localCopy ?? LocalCopy(
            fileName: prepared.fileName, fingerprint: prepared.fingerprint,
            byteCount: prepared.byteCount, importedAt: Date())
        copy.fileName = prepared.fileName
        copy.fingerprint = prepared.fingerprint
        copy.byteCount = prepared.byteCount
        copy.hasCover = FileManager.default.fileExists(atPath: files.cover.path)
        copy.epubVersion = prepared.epubVersion
        copy.isFixedLayout = prepared.isFixedLayout
        // The same book, perhaps a fresher copy: what it says about itself and
        // whether it narrates are read again, and the reader's place kept.
        var restored = Book.local(
            uuid: existing.uuid, metadata: prepared.metadata,
            narrationDuration: prepared.narrationDuration, copy: copy)
        restored.position = existing.position
        try? await store?.upsert(restored)
        missingFiles.remove(existing.uuid)
        replace(restored)
        IssaLog.info("local book reattached", ["book": existing.uuid])
        return restored
    }

    private func replace(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.uuid == book.uuid }) else { return }
        books[index] = book
        books = Self.ordered(books)
    }

    // MARK: - Notices

    /// The reader has read a notice on a book's row: it goes for good.
    public func dismissNotice(_ notice: LocalNotice, for uuid: String) {
        guard let index = books.firstIndex(where: { $0.uuid == uuid }),
              books[index].localCopy?.notices.contains(notice) == true
        else { return }
        books[index].localCopy?.notices.removeAll { $0 == notice }
        persist(uuid)
    }

    // MARK: - Removing

    /// Takes books off the list at once, and off the device once the undo
    /// window closes. Whatever is reading or narrating them stops now.
    /// - Parameter undoManager: the window's, so Edit › Undo (⌘Z) takes the
    ///   removal back while its toast is up, as the toast's Undo does (5 Spec,
    ///   §7 and 3c: "Edit › Undo ⌘Z also restores it").
    public func remove(_ uuids: [String], undoManager: UndoManager? = nil) {
        let leaving = books.filter { uuids.contains($0.uuid) }
        guard !leaving.isEmpty else { return }
        // One at a time, like the server's downloads: a second removal carries
        // out the first.
        commitPendingRemoval()
        for book in leaving { onRemove?(book.uuid) }
        books.removeAll { uuids.contains($0.uuid) }
        pendingRemoval = PendingRemoval(books: leaving)
        IssaLog.info("local book removal pending", ["books": String(leaving.count)])
        if let undoManager {
            let removed = leaving.map(\.uuid)
            undoManager.registerUndo(withTarget: self) { library in
                MainActor.assumeIsolated { library.undoRemoval(of: removed) }
            }
            undoManager.setActionName(
                leaving.count == 1 ? "Remove \(leaving[0].title)" : "Remove \(leaving.count) Books")
        }
        let window = undoWindow
        removalTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
        }
    }

    /// Puts the books back, with their place, highlights and bookmarks.
    /// Playback that stopped stays stopped.
    /// Takes back this removal and no other: an undo registered for a removal
    /// a later one has since carried out finds nothing to do.
    public func undoRemoval(of uuids: [String]) {
        guard pendingRemoval?.books.map(\.uuid) == uuids else { return }
        undoRemoval()
    }

    public func undoRemoval() {
        guard let pending = pendingRemoval else { return }
        removalTask?.cancel()
        removalTask = nil
        pendingRemoval = nil
        books = Self.ordered(books + pending.books)
    }

    /// Carries out the removal still waiting: the folder, the row, the
    /// highlights, the anchor and the guard — and tells the rest of the app.
    /// The original, wherever it was chosen from, is never touched.
    public func commitPendingRemoval() {
        guard let pending = pendingRemoval else { return }
        removalTask?.cancel()
        removalTask = nil
        pendingRemoval = nil
        for book in pending.books {
            let files = files(for: book.uuid)
            // Under the locks an extraction into these folders holds, so one
            // still running neither tears them nor puts them back.
            AudioExtraction.removeExtractedAudio(at: files.narration)
            CustomFonts.removeExtracted(at: files.fonts)
            try? FileManager.default.removeItem(at: files.folder)
            missingFiles.remove(book.uuid)
            positionGuards = positionGuards.filter { !$0.key.hasPrefix(book.uuid + "#") }
            onForget?(book.uuid)
            let uuid = book.uuid
            Task { [store] in
                try? await store?.deleteBook(uuid)
                try? await store?.deleteAnnotations(forBook: uuid)
                try? await store?.deleteAudioAnchor(forBook: uuid)
            }
        }
        IssaLog.info("local books removed", ["books": String(pending.books.count)])
    }

    // MARK: - ReaderPersistence

    public func files(for bookUUID: String) -> LocalBookFiles {
        LocalBookFiles(bookUUID: bookUUID, root: root)
    }

    public func storedPosition(for bookUUID: String) async -> StoredPosition? {
        if let held = book(bookUUID)?.position { return held }
        return try? await store?.book(bookUUID)?.position
    }

    /// The local twin of `AppModel.writePosition`: the same guard, seeded and
    /// keyed the same way, so a derived move below the mark is refused here as
    /// it would be for a server book. An accepted position is adopted and
    /// written to the device store; nothing is queued, because nothing is sent.
    public func writePosition(
        _ locator: ReadiumLocator, timestamp: Double,
        origin: PositionOrigin, for bookUUID: String,
    ) async -> Bool {
        // A book that is not in the list — removed, or waiting out its undo
        // window — takes no writes: its reader was let go of as it left.
        guard let index = books.firstIndex(where: { $0.uuid == bookUUID }) else {
            IssaLog.info("local position dropped: book not here", ["book": bookUUID])
            return false
        }
        let key = AppModel.positionGuardKey(bookUUID, isAudioScaled: locator.isAudioScaled)
        var state = positionGuards[key]
            ?? AppModel.seededGuard(for: books[index], isAudioScaled: locator.isAudioScaled)
        let decision = state.decide(locator.locations?.totalProgression, origin: origin)
        positionGuards[key] = state
        guard decision.isAllowed else {
            IssaLog.info("local position refused", [
                "book": bookUUID, "origin": origin.rawValue,
                "held": String(format: "%.4f", state.highWater),
            ])
            return false
        }
        books[index].adopt(position: locator, timestamp: timestamp)
        // Checked and submitted with nothing suspending between, as
        // `AppModel.persist` is: the book was in the list a moment ago, so a
        // removal carried out after this has its DELETE queued behind this
        // upsert, never in front of it.
        do {
            try await store?.upsert(books[index])
        } catch {
            return false
        }
        return true
    }

    /// Writes a book's row, unless it has left the list by the time the write
    /// would be submitted — the check and the submission with nothing
    /// suspending between, so a removal cannot be undone by a late write.
    private func persist(_ uuid: String) {
        Task { @MainActor [weak self] in
            guard let self, let book = book(uuid) else { return }
            try? await store?.upsert(book)
        }
    }

    public func recordAudioAnchor(_ anchor: AudioAnchor, for bookUUID: String) async {
        guard book(bookUUID) != nil else { return }
        try? await store?.setAudioAnchor(anchor, forBook: bookUUID)
    }

    public func audioAnchor(for bookUUID: String) async -> AudioAnchor? {
        try? await store?.audioAnchor(forBook: bookUUID)
    }

    public func annotations(for bookUUID: String) async -> [Annotation] {
        (try? await store?.annotations(for: bookUUID)) ?? []
    }

    public func save(_ annotation: Annotation) {
        Task { [store] in try? await store?.save(annotation) }
    }

    public func delete(_ annotation: Annotation) {
        Task { [store] in try? await store?.deleteAnnotation(id: annotation.id) }
    }

    public func didOpen(_ bookUUID: String) {
        guard let index = books.firstIndex(where: { $0.uuid == bookUUID }) else { return }
        books[index].localCopy?.lastOpenedAt = Date()
        books = Self.ordered(books)
        persist(bookUUID)
    }
}
