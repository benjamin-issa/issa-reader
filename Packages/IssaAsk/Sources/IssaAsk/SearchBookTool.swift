#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import IssaCore

/// `BookSearchTool`, as a `FoundationModels.Tool` Apple's models can call.
///
/// Everything that bounds the search — the captured book and boundary, the two
/// calls, the token cap, the numbering — lives in `BookSearchTool`, so Apple's
/// models and a reader's own provider are held to exactly the same rules. This
/// type only adds the framework's argument type.
public final class SearchBookTool: AskTool, Tool {
    /// What the model may ask for. One string: a schema with fields for
    /// chapter or character invites the model to invent constraints, and the
    /// only thing retrieval can actually use is words.
    @Generable
    public struct Arguments {
        @Guide(description: "Words to look for, such as a character's name or a thing that happened.")
        public var query: String
    }

    public let name = "searchBook"
    public let description = BookSearchTool.description
    public var toolDescription: String { description }
    public let callLimit = 2

    public static let exhausted = BookSearchTool.exhausted
    static let noMatches = BookSearchTool.noMatches
    static let tokenCap = BookSearchTool.tokenCap
    static let passageLimit = BookSearchTool.passageLimit

    private let search: BookSearchTool

    /// How many times the model called this tool during the last generation.
    public func callsMade() async -> Int { await search.callsMade() }

    public init(
        store: AskIndexStore, bookUUID: String, boundary: ReadingBoundary,
        render: @escaping @Sendable (Passage) -> String = { $0.displayText },
    ) {
        search = BookSearchTool(store: store, bookUUID: bookUUID, boundary: boundary, render: render)
    }

    public func beginGeneration(numberingFrom firstOrdinal: Int) async {
        await search.beginGeneration(numberingFrom: firstOrdinal)
    }

    public func passagesShown() async -> [Int: Passage] {
        await search.passagesShown()
    }

    public func call(arguments: Arguments) async throws -> String {
        await search.call(query: arguments.query)
    }

    public var parametersJSONSchema: String? { BookSearchTool.parametersJSONSchema }

    public func call(query: String) async -> String {
        await search.call(query: query)
    }

    static func excerpts(
        _ passages: [Passage], numberingFrom firstOrdinal: Int,
    ) -> (text: String, shown: [Int: Passage]) {
        BookSearchTool.excerpts(passages, numberingFrom: firstOrdinal)
    }

    static func truncated(_ text: String, toTokens tokens: Int) -> String {
        BookSearchTool.truncated(text, toTokens: tokens)
    }
}
#endif
