import Foundation
import IssaEPUB
import Testing

@testable import IssaAsk

@Suite("What a reader's own provider is sent")
struct BookIdentityScrubberTests {
    @Test("heading lines go, an author's full name is replaced, and prose keeps its words")
    func scrubsHeadingsAndAuthor() {
        let scrubber = BookIdentityScrubber(
            title: "Alice’s Adventures in Wonderland",
            authors: ["Carroll, Lewis"],
            chapterTitles: ["CHAPTER I. Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears", "Run"],
        )
        let text = """
        ALICE'S ADVENTURES IN WONDERLAND
        by Lewis Carroll
        CHAPTER I.
        Down the Rabbit-Hole.
        Alice was beginning to get very tired of sitting by her sister on the bank.
        A letter from Lewis Carroll lay on the table.
        “Run.”
        She went down a rabbit-hole after it.
        """
        let scrubbed = scrubber.scrub(text)
        #expect(!scrubbed.lowercased().contains("adventures in wonderland"), "the title line is front matter")
        #expect(!scrubbed.contains("Lewis Carroll"))
        #expect(!scrubbed.contains("CHAPTER I."))
        #expect(!scrubbed.lowercased().contains("down the rabbit-hole."))
        #expect(scrubbed.contains("A letter from [author] lay on the table."))
        #expect(scrubbed.contains("“Run.”"), "a short chapter title must not take dialogue with it")
        #expect(scrubbed.contains("She went down a rabbit-hole after it."))
    }

    @Test("a title that is a character's name or a word is never rewritten in prose")
    func titlesStayInProse() {
        let dracula = BookIdentityScrubber(title: "Dracula", authors: ["Stoker, Bram"], chapterTitles: [])
        #expect(dracula.scrub("Count Dracula smiled.") == "Count Dracula smiled.")
        let it = BookIdentityScrubber(title: "It", authors: ["King, Stephen"], chapterTitles: [])
        #expect(it.scrub("It was raining, and it did not stop.") == "It was raining, and it did not stop.")
    }

    @Test(
        "everything read so far reaches the model with no title, author or chapter heading",
        arguments: [AskFixture.alice, AskFixture.franklin],
    )
    func everythingReadIsScrubbed(book: AskBook) async throws {
        let (store, source, directory) = try await book.preparedStore()
        defer { AskFixture.remove(directory) }
        let package = try book.package()
        // Most of the way through the book.
        let boundary = try book.endOf(spine: max(package.spine.count - 2, 0))
        let model = ScriptedAnswerModel(
            turns: [.answer("Somebody did something.\nSources: 1")], contextSize: 1_000_000,
        )
        let engine = AskEngine.forQuestion(
            model: model, store: store, bookUUID: source.bookUUID, boundary: boundary,
            profile: .provider(shape: .everythingRead, usesSearchTool: false), package: package,
        )
        for try await _ in engine.ask(question: "What has happened so far?", source: source, boundary: boundary) {}
        let received = try #require(await model.received.first)
        Self.expectNoIdentity(in: received.prompt, package: package)
        #expect(received.prompt.count > 20_000, "everything read should be most of the book")
    }

    @Test(
        "the passages a provider is sent are scrubbed too",
        arguments: [AskFixture.alice, AskFixture.franklin],
    )
    func passagesAreScrubbed(book: AskBook) async throws {
        let (store, source, directory) = try await book.preparedStore()
        defer { AskFixture.remove(directory) }
        let package = try book.package()
        let boundary = try book.endOf(spine: max(package.spine.count - 2, 0))
        let model = ScriptedAnswerModel(contextSize: 200_000)
        let engine = AskEngine.forQuestion(
            model: model, store: store, bookUUID: source.bookUUID, boundary: boundary,
            profile: .provider(shape: .passages, usesSearchTool: false), package: package,
        )
        for try await _ in engine.ask(question: "What has happened so far?", source: source, boundary: boundary) {}
        let received = try #require(await model.received.first)
        Self.expectNoIdentity(in: received.prompt, package: package)
    }

    /// No title line, no author's full name, no chapter heading line.
    /// The title may still occur inside prose, by design.
    static func expectNoIdentity(in prompt: String, package: EPUBPackage) {
        let lowered = prompt.lowercased().replacingOccurrences(of: "’", with: "'")
        let lines = Set(prompt.split(separator: "\n").map { BookIdentityScrubber.normalised(String($0)) })
        if let title = package.metadata.title {
            #expect(!lines.contains(BookIdentityScrubber.normalised(title)), "a title line reached the model")
        }
        for author in package.metadata.authors {
            let pieces = author.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let natural = pieces.count == 2 ? "\(pieces[1]) \(pieces[0])" : author
            guard natural.split(separator: " ").count >= 2 else { continue }
            #expect(!lowered.contains(natural.lowercased()), "an author's name reached the model")
        }
        for point in package.navigation {
            let heading = BookIdentityScrubber.normalised(point.title)
            guard heading.count >= BookIdentityScrubber.shortestHeading else { continue }
            #expect(!lines.contains(heading), "a chapter heading reached the model: \(point.title)")
            for part in BookIdentityScrubber.parts(of: heading) where part.count >= BookIdentityScrubber.shortestHeading {
                #expect(!lines.contains(part), "a chapter heading reached the model: \(part)")
            }
        }
    }

    @Test("everything read is built in one pass, oldest dropped first, on a very long book")
    func linearOnALongBook() {
        // About 250,000 words in 2,800 passages.
        let passages = (0..<2_800).map { index in
            Passage(
                spineIndex: index / 40, ordinal: index % 40, start: 0, end: 500, words: 90,
                text: String(repeating: "word ", count: 90),
            )
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let built = AskPromptBuilder.buildEverythingRead(
                question: "q", passages: passages, ceiling: 100_000, contextSize: 1_000_000,
                instructions: "rules", responseTokens: 8_000, finishedBefore: 70,
                render: { $0.text },
            )
            #expect(built.dropped > 0)
            #expect(built.passages.last == passages.last, "the newest passages are the ones kept")
            #expect(built.promptTokens <= 100_000 + 200)
            let prefix = try! #require(built.cacheablePrefix)
            let head = String(built.prompt.utf16.prefix(prefix))!
            #expect(head.hasSuffix(passages.filter { $0.spineIndex < 70 }.last!.text))
        }
        #expect(elapsed < .seconds(2))
    }
}
