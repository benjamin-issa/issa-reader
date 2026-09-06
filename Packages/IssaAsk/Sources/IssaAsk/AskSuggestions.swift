import Foundation

/// The two chips under the question field.
///
/// They exist because the first thing a reader does with a blank field is not
/// type — it is wonder what the thing can do. Both suggestions are answerable
/// from the index by construction: the name comes out of the book's own name
/// table bounded by the reading position, so "Who is …?" can never name someone
/// the reader has not met, and the recap has its own retrieval path.
public enum AskSuggestions {
    /// Shown when the book has introduced nobody yet — the opening pages of a
    /// novel that starts on landscape, or an index built at the very first page.
    public static let fallbackName = "Who are the main characters so far?"
    public static let recap = "What has happened so far?"

    /// - Parameter topNames: most-mentioned first, already bounded by the
    ///   reading position (`AskIndexStore.topNames(before:limit:)`).
    public static func chips(topNames: [String]) -> [String] {
        guard let first = topNames.first, !first.isEmpty else {
            return [fallbackName, recap]
        }
        return ["Who is \(first)?", recap]
    }
}
