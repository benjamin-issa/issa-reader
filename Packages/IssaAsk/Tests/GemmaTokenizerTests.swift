import Foundation
import Testing

@testable import IssaAsk

@Suite("GemmaTokenizerTests")
struct GemmaTokenizerTests {
    private static func makeSyntheticTokenizerData() throws -> Data {
        // Built as raw JSON text rather than a Swift `[String: Int]` literal
        // because Swift `String` treats U+03A9 (Greek Omega) and U+2126 (Ohm)
        // as duplicate keys — the exact bug `GemmaTokenizer` must avoid.
        var entries: [String] = [
            "\"<pad>\": 0", "\"<eos>\": 1", "\"<bos>\": 2", "\"<unk>\": 3", "\"<mask>\": 4",
            "\"\\u2581\": 10", "\"a\": 11", "\"b\": 12", "\"c\": 13",
            "\"ab\": 14", "\"\\u2581ab\": 15", "\"\\u2581abc\": 16",
            "\"<|custom|>\": 20",
            "\"\\u03A9\": 30",
            "\"\\u2126\": 31",
        ]
        let hex = Array("0123456789ABCDEF")
        for byte in 0..<256 {
            entries.append("\"<0x\(hex[byte >> 4])\(hex[byte & 0x0F])>\": \(238 + byte)")
        }
        let jsonString = """
        {
          "added_tokens": [
            {"id": 0, "content": "<pad>", "normalized": false, "special": true},
            {"id": 1, "content": "<eos>", "normalized": false, "special": true},
            {"id": 2, "content": "<bos>", "normalized": false, "special": true},
            {"id": 3, "content": "<unk>", "normalized": false, "special": true},
            {"id": 20, "content": "<|custom|>", "normalized": false, "special": true}
          ],
          "model": {
            "type": "BPE",
            "vocab": {\(entries.joined(separator: ", "))},
            "merges": [["a", "b"], ["\\u2581", "ab"], ["\\u2581ab", "c"]]
          }
        }
        """
        return Data(jsonString.utf8)
    }

    @Test("encodes BPE merges, metaspace normalisation, byte fallback, added tokens, and truncation")
    func coreEncoding() throws {
        let tokeniser = try GemmaTokenizer(data: try Self.makeSyntheticTokenizerData())

        #expect(tokeniser.encode(" abc") == [2, 16, 1])
        #expect(tokeniser.encode(" ab<|custom|>ab") == [2, 15, 20, 14, 1])
        // UTF-8 byte fallback for unseen 'z' (0x7A = 122 -> 238 + 122 = 360).
        #expect(tokeniser.encode("z") == [2, 360, 1])

        // Truncation preserves trailing <eos>, and maxLength < 2 never ignores the cap.
        let truncated = tokeniser.encode(" ab ab ab ab", maxLength: 4)
        #expect(truncated == [2, 15, 15, 1])
        #expect(tokeniser.encode(" abc", maxLength: 1) == [2])
        #expect(tokeniser.encode(" abc", maxLength: 0).isEmpty)
    }

    /// Swift `String` equality merges U+03A9 (Greek Omega) and U+2126 (Ohm sign);
    /// UTF-8 byte keying during parse and scalar-value lookup during encode must
    /// keep both vocabulary entries distinct.
    @Test("keeps canonically equivalent Unicode scalars distinct")
    func canonicalEquivalenceDoesNotCollide() throws {
        let tokeniser = try GemmaTokenizer(data: try Self.makeSyntheticTokenizerData())
        #expect(tokeniser.encode("\u{03A9}") == [2, 30, 1])
        #expect(tokeniser.encode("\u{2126}") == [2, 31, 1])
    }
}

@Suite("GemmaTokenizerParityTests")
struct GemmaTokenizerParityTests {
    @Test(
        "matches Hugging Face EmbeddingGemma-2 token IDs bit-for-bit",
        .enabled(if: GemmaTokenizerParityTests.shouldRunHuggingFaceParity),
    )
    func huggingFaceParity() throws {
        guard let path = ProcessInfo.processInfo.environment["ISSA_GEMMA_TOKENIZER_JSON"],
              FileManager.default.fileExists(atPath: path)
        else {
            Issue.record("ISSA_GEMMA_TOKENIZER_JSON is required when running parity tests.")
            return
        }

        let tokeniser = try GemmaTokenizer(contentsOf: URL(fileURLWithPath: path))
        // Verifies `NSDictionary` + UTF-8 byte keying avoids Swift `Dictionary`'s
        // 434 NFC canonical-equivalence collapses across the 262,144-token vocab.
        #expect(tokeniser.vocabSize >= 262_140)

        let vectors: [(String, [Int32])] = [
            ("", [2, 1]),
            (" ", [2, 236743, 1]),
            ("   ", [2, 139, 1]),
            ("title: none | text: ", [2, 3250, 236787, 7293, 1109, 1816, 236787, 236743, 1]),
            (
                "title: none | text: Hello, world!",
                [2, 3250, 236787, 7293, 1109, 1816, 236787, 26352, 236764, 1902, 236888, 1],
            ),
            (
                "task: search result | query: Who is Mollie again?",
                [2, 8071, 236787, 3927, 1354, 1109, 7609, 236787, 11063, 563, 101021, 703, 1570, 236881, 1],
            ),
            (
                "title: none | text: “Gee up, comrade!” — Boxer’s hoof wasn’t healed… 100% café naïve 日本語 🚀",
                [
                    2, 3250, 236787, 7293, 1109, 1816, 236787, 999, 228004, 872, 236764,
                    168827, 13348, 2192, 184576, 236858, 236751, 59328, 7289, 236858,
                    236745, 78030, 237064, 236743, 236770, 236771, 236771, 236908,
                    33443, 120362, 33375, 238582, 236743, 242015, 1,
                ],
            ),
            (
                "title: none | text:   multiple   spaces\n\nand\ttabs\r\nend",
                [2, 3250, 236787, 7293, 1109, 1816, 236787, 139, 43819, 139, 35220, 108, 624, 255968, 39218, 251, 107, 643, 1],
            ),
            ("foo<eos>bar", [2, 26537, 1, 2230, 1]),
        ]
        for (input, expected) in vectors {
            #expect(tokeniser.encode(input) == expected)
        }
    }

    private static var shouldRunHuggingFaceParity: Bool {
        guard let path = ProcessInfo.processInfo.environment["ISSA_GEMMA_TOKENIZER_JSON"] else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }
}
