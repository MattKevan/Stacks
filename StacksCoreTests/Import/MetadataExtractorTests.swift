import Foundation
import Testing
@testable import StacksCore

@Suite
struct MetadataExtractorTests {
    @Test
    func kindIsDetectedFromExtension() {
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.epub")) == .epub)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.pdf")) == .pdf)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.djvu")) == .djvu)
        #expect(MetadataExtractor.kind(for: URL(fileURLWithPath: "/tmp/x.txt")) == nil)
    }

    @Test
    func epubExtractsMetadataAndCover() throws {
        let url = try Fixtures.makeEPUB()
        let metadata = try MetadataExtractor.extract(from: url, kind: .epub)

        #expect(metadata.title == "Range: Why Generalists Triumph in a Specialized World")
        #expect(metadata.authors == ["David Epstein"])
        #expect(metadata.series == "Studies")
        #expect(metadata.seriesIndex == 1.5)
        #expect(metadata.tags.contains("Science"))
        #expect(metadata.languages == ["eng"])
        #expect(metadata.identifiers["isbn"] == "978-0-7352-2129-1")
        #expect(metadata.comments == "Why generalists beat specialists.")
        #expect(metadata.publicationDate != nil)

        #if canImport(ImageIO)
        let cover = try MetadataExtractor.extractCover(from: url, kind: .epub)
        #expect(cover != nil)
        #else
        // Linux has no ImageIO cover pipeline yet: cover extraction returns
        // nil (a later task replaces it with a portable decoder), while the
        // metadata assertions above still hold.
        let cover = try MetadataExtractor.extractCover(from: url, kind: .epub)
        #expect(cover == nil)
        #endif
    }

    @Test
    func pdfFallsBackToFilenameWhenNoMetadata() throws {
        let url = try Fixtures.makePDF()
        let metadata = try MetadataExtractor.extract(from: url, kind: .pdf)

        #expect(metadata.title == "plain")
        #expect(metadata.authors.isEmpty)

        #if canImport(PDFKit)
        let cover = try MetadataExtractor.extractCover(from: url, kind: .pdf)
        #expect(cover != nil)
        #else
        // PDF first-page rendering needs PDFKit (macOS-only); Linux returns nil.
        let cover = try MetadataExtractor.extractCover(from: url, kind: .pdf)
        #expect(cover == nil)
        #endif
    }

    @Test
    func djvuUsesFilenameMetadata() {
        let url = URL(fileURLWithPath: "/tmp/My Book.djvu")
        let metadata = try? MetadataExtractor.extract(from: url, kind: .djvu)
        #expect(metadata?.title == "My Book")
    }

    #if !canImport(CoreGraphics) || !canImport(ImageIO)
    /// The hand-built Linux PDF fixture must stay a parseable PDF: a broken
    /// xref would silently turn the pdfinfo path into an untested filename
    /// fallback (pdfFallsBackToFilenameWhenNoMetadata passes either way).
    @Test
    func linuxPdfFixtureIsStructurallyParseable() throws {
        let url = try Fixtures.makePDF(named: "fixture-structure.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
        #expect(text?.hasPrefix("%PDF-") == true)
        #expect(text?.contains("startxref") == true)
    }
    #endif
}
