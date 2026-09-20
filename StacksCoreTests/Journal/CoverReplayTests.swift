import Foundation
import Testing
@testable import StacksKit

/// Does an `addBook` command's cover survive replay into an `IndexedBook`?
///
/// This pins the assumption behind remote cover loading: the sync stream
/// carries the cover, so a remote client can know a book has one. If it ever
/// regresses, every remote cover silently disappears even though the grid
/// still shows a stale cached copy.
struct CoverReplayTests {
    private func addBookCommand(bookID: UUID, cover: JournalCommand.StagedCover?) -> JournalCommand {
        JournalCommand(
            id: UUID(), seq: 1, ts: .now,
            op: .addBook(.init(
                bookID: bookID, title: "T", authors: ["A"],
                series: nil, seriesIndex: nil, tags: [], rating: nil,
                publisher: nil, publicationDate: nil, addedDate: .now,
                languages: [], identifiers: [:], comments: nil,
                formats: [.init(
                    kind: "EPUB", filename: "f.epub",
                    contentHash: "h", size: 1, stagedName: "stage"
                )],
                cover: cover
            ))
        )
    }

    @Test
    func addBookCoverHashSurvivesReplay() throws {
        let bookID = UUID()
        var state: [UUID: IndexedBook] = [:]
        try CommandReplay.apply(
            addBookCommand(bookID: bookID, cover: .init(
                filename: "cover.jpg", contentHash: "COVERHASH", stagedName: "cover"
            )),
            to: &state
        )
        #expect(state[bookID]?.coverHash == "COVERHASH")
    }

    @Test
    func addBookWithoutACoverHasNoHash() throws {
        let bookID = UUID()
        var state: [UUID: IndexedBook] = [:]
        try CommandReplay.apply(addBookCommand(bookID: bookID, cover: nil), to: &state)
        #expect(state[bookID]?.coverHash == nil)
    }
}
