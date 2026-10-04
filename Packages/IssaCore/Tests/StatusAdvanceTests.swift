import Foundation
import Testing

@testable import IssaCore

/// The server's own status rule, applied where 3.x cannot apply it: a book with
/// no status at all.
@Suite("Advancing a book with no status after a position write")
struct StatusAdvanceTests {
    private let toRead = Status(uuid: "s-to-read", name: Status.toReadName)
    private let reading = Status(uuid: "s-reading", name: Status.readingName)
    /// Relabelled, as the v3 capture has it: the rule matches by name.
    private let read = Status(uuid: "s-read", name: Status.readName, label: "Finished")
    private let abandoned = Status(uuid: "s-abandoned", name: "Abandoned")

    private var statuses: [Status] { [toRead, reading, read, abandoned] }

    private func at(_ progression: Double?) -> ReadiumLocator {
        ReadiumLocator(
            href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: progression, totalProgression: progression))
    }

    @Test("below 98% a book with no status moves to Reading")
    func belowThresholdMovesToReading() {
        let next = StatusAdvance.statusToSet(
            after: at(0.5), current: nil, generation: .v3, statuses: statuses)
        #expect(next == reading)
    }

    @Test("at 98% or more it moves to Read, whatever the label says")
    func atThresholdMovesToRead() {
        #expect(StatusAdvance.statusToSet(
            after: at(0.99), current: nil, generation: .v3, statuses: statuses) == read)
        #expect(StatusAdvance.statusToSet(
            after: at(0.98), current: nil, generation: .v3, statuses: statuses) == read,
            "the server's comparison is inclusive")
        #expect(StatusAdvance.statusToSet(
            after: at(0.979_999), current: nil, generation: .v3, statuses: statuses) == reading)
    }

    /// The server reads a missing progression as zero; so does this.
    @Test("a locator with no progression counts as the start")
    func missingLocations() {
        let bare = ReadiumLocator(href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml")
        #expect(StatusAdvance.statusToSet(
            after: bare, current: nil, generation: .v3, statuses: statuses) == reading)
        #expect(StatusAdvance.statusToSet(
            after: at(nil), current: nil, generation: .v3, statuses: statuses) == reading)
    }

    /// The first launch after an upgrade can be offline, before detection has
    /// answered — and those are exactly the writes 3.x will not advance.
    @Test("an undetected server is advanced too")
    func unknownGenerationAdvances() {
        #expect(StatusAdvance.statusToSet(
            after: at(0.4), current: nil, generation: nil, statuses: statuses) == reading)
    }

    @Test("a known 2.x server is left to advance its own books")
    func v2NeverAdvances() {
        #expect(StatusAdvance.statusToSet(
            after: at(0.4), current: nil, generation: .v2, statuses: statuses) == nil)
        #expect(StatusAdvance.statusToSet(
            after: at(0.99), current: nil, generation: .v2, statuses: statuses) == nil)
    }

    /// A book with a status has a row, and the server moves To read and
    /// Reading along itself; anything else is the reader's own choice.
    @Test("a book that has any status is left alone")
    func existingStatusIsLeftAlone() {
        for current in [toRead, reading, read, abandoned] {
            #expect(StatusAdvance.statusToSet(
                after: at(0.5), current: current, generation: .v3, statuses: statuses) == nil,
                "\(current.name) at 50%")
            #expect(StatusAdvance.statusToSet(
                after: at(0.99), current: current, generation: .v3, statuses: statuses) == nil,
                "\(current.name) at 99%")
        }
    }

    @Test("with no status by the built-in name there is nothing to set")
    func missingBuiltInStatus() {
        #expect(StatusAdvance.statusToSet(
            after: at(0.5), current: nil, generation: .v3, statuses: [toRead, read]) == nil)
        #expect(StatusAdvance.statusToSet(
            after: at(0.99), current: nil, generation: .v3, statuses: [toRead, reading]) == nil)
        #expect(StatusAdvance.statusToSet(
            after: at(0.5), current: nil, generation: .v3, statuses: []) == nil,
            "statuses not loaded yet")
    }

    @Test("the captured 3.x statuses resolve by name, not label")
    func capturedStatuses() throws {
        let captured = try JSONDecoder().decode(
            [Status].self, from: BookDecodingTests.fixture("v3/statuses"))
        let next = try #require(StatusAdvance.statusToSet(
            after: at(1), current: nil, generation: .v3, statuses: captured))
        #expect(next.uuid == "030f4277-3fd4-4a09-a4cb-0a46812f529a")
        #expect(next.displayName == "Finished")
    }
}
