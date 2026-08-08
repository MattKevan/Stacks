import Foundation
import Testing
@testable import StacksCore

@Suite
struct PDFMetadataTests {
    @Test
    func filenameFallbackWhenPDFUnreadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MetadataExtractor.extract(from: url, kind: .pdf)

        #expect(!metadata.title.isEmpty)
        // The title must be filename-derived, not the raw (unreadable) content.
        #expect(!metadata.title.contains("not a pdf"))
    }

    @Test
    func pdfinfoOutputMapsMetadata() {
        let url = URL(fileURLWithPath: "/tmp/My Book.pdf")
        let output = """
        Title:          The Book of Stacks
        Author:         Matt Kevan
        Subject:        A test document
        Keywords:       test, poppler
        """
        let metadata = MetadataExtractor.metadata(fromPdfinfoOutput: output, url: url)

        #expect(metadata.title == "The Book of Stacks")
        #expect(metadata.authors == ["Matt Kevan"])
        #expect(metadata.comments == "A test document")
        #expect(metadata.tags == ["test, poppler"])
    }
}
