import Foundation

/// The chips under the question field.
///
/// They exist because the first thing a reader does with a blank field is not
/// type — it is wonder what the thing can do. Every suggestion is answerable
/// from the index by construction: the names come out of the book's own name
/// table bounded by the reading position, so no chip can name someone the
/// reader has not met, and the recap has its own retrieval path.
///
/// **Six, and six different questions.** There were two, and the second was
/// always the recap, so the whole set said "this answers who-is questions and
/// summarises". Six spellings of "Who is X?" would have been no better. These
/// take a different path each: two identity lookups, one ordinary question with
/// a subject, one kinship question, one search with no subject at all, and the
/// recap — which is every retrieval kind the engine has.
///
/// Six is the ceiling, not a quota. Only the second identity chip needs a
/// second name, so a book that has introduced one person offers five and a book
/// that has introduced nobody offers the two that need no name at all. An empty
/// capsule would be worse than a missing one.
///
/// Each one was checked against `QuestionReader.kind` rather than written by
/// eye, because the wording decides the path and the near misses are bad. "What
/// is Alice like?" reads as an identity question and classifies as one, with
/// `like` in the subject — so every passage would have to contain the word
/// "like". "What happened to Alice?" is a general question about Alice, which
/// is what was wanted.
public enum AskSuggestions {
    /// Shown when the book has introduced nobody yet — the opening pages of a
    /// novel that starts on landscape, or an index built at the very first page.
    public static let fallbackName = "Who are the main characters so far?"
    public static let recap = "What has happened so far?"

    /// How many names to ask the index for.
    ///
    /// Two are used. More are fetched because `isPresentable` throws some away,
    /// and because the cost is nothing: `topNames` is one indexed query whose
    /// other caller asks for two hundred.
    public static let namesWanted = 6

    /// - Parameter topNames: most-mentioned first, already bounded by the
    ///   reading position (`AskIndexStore.topNames(before:limit:)`).
    public static func chips(topNames: [String]) -> [String] {
        let names = topNames.filter(isPresentable)
        guard let first = names.first else { return [fallbackName, recap] }

        // The first two are what shipped, in the order they shipped in: a
        // reader who has used this before should not have to find the recap
        // again.
        var chips = ["Who is \(first)?", recap]
        if names.count > 1 { chips.append("Who is \(names[1])?") }
        chips.append("What happened to \(first)?")
        // The possessive is what makes this a kinship question rather than a
        // search for the word "family" — see `QuestionReader.kinship`.
        chips.append("Who is in \(first)'s family?")
        chips.append(fallbackName)
        return chips
    }

    /// Whether a name from the index is fit to print in a question.
    ///
    /// `NLTagger` sometimes runs a name into the words after it — *Alice*'s own
    /// index holds "Alice soon began" as a person, from "Alice soon began
    /// talking again" — and a chip offering "Who is Alice soon began?" makes
    /// the feature look broken before it has answered anything. The rule is the
    /// shape of a name as a book prints one: every word capitalised, and not
    /// more than three of them.
    ///
    /// Applied here rather than in `NameFinder`, deliberately. That table is
    /// also what promotes a token retrieval would otherwise miss, and there a
    /// generous list costs nothing while a strict one loses invented names. It
    /// is only the *printed* chip that has to be presentable.
    static func isPresentable(_ name: String) -> Bool {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 3, name.count > 1 else { return false }
        return words.allSatisfy { $0.first?.isUppercase == true }
    }
}
