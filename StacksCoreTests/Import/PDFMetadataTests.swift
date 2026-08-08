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
    }
}
