import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import ZIPFoundation
@testable import StacksCore

@Suite
struct MobiToEpubConverterTests {
    private func content(
        title: String = "Test Book",
        authors: [String] = ["Alice", "Bob"],
        subjects: [String] = [],
        cover: Data? = nil,
        chapters: [MobiChapter] = [
            MobiChapter(id: "chap1", title: "One", html: "<h1>One</h1><p>First chapter.</p>"),
            MobiChapter(id: "chap2", title: "Two", html: "<h2>Two</h2><p>Second chapter.</p>"),
        ]
    ) -> MobiContent {
        MobiContent(title: title, authors: authors, subjects: subjects, cover: cover, chapters: chapters)
    }

    private func archive(from data: Data) throws -> Archive {
        try Archive(data: data, accessMode: .read)
    }

    private func entryData(_ archive: Archive, _ path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { chunk in data.append(chunk) }
        return data
    }

    @Test
    func producesValidEpubWithExpectedStructure() throws {
        let data = try MobiToEpubConverter.convert(content(cover: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let archive = try archive(from: data)

        let mimetype = entryData(archive, "mimetype").flatMap { String(data: $0, encoding: .utf8) }
        #expect(mimetype == "application/epub+zip")

        let container = entryData(archive, "META-INF/container.xml").flatMap { String(data: $0, encoding: .utf8) }
        #expect(container?.contains("content.opf") == true)

        let opf = entryData(archive, "content.opf").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // The OPF must be XML-well-formed (epubcheck/strict parsers reject an
        // unbound `opf:` prefix) — parse it and assert no error.
#if canImport(FoundationXML)
        #expect(throws: Never.self) { try XMLDocument(xmlString: opf) }
#else
        // Linux: FoundationXML is unavailable, so the XMLDocument parse is
        // skipped; the content assertions below still validate the OPF.
#endif
        #expect(opf.contains("Test Book"))
        #expect(opf.contains("Alice"))
        #expect(opf.contains("Bob"))
        // Spine order: chap1 before chap2.
        let first = opf.range(of: "idref=\"chap1\"")?.lowerBound
        let second = opf.range(of: "idref=\"chap2\"")?.lowerBound
        #expect(first != nil && second != nil && first! < second!)
        // Manifest includes chapters, cover, and ncx.
        #expect(opf.contains("chap1.xhtml"))
        #expect(opf.contains("chap2.xhtml"))
        #expect(opf.contains("cover.jpg"))
        #expect(opf.contains("toc.ncx"))

        // Chapter files exist and contain the expected text.
        let chapter1 = entryData(archive, "chap1.xhtml").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(chapter1.contains("First chapter."))
        let chapter2 = entryData(archive, "chap2.xhtml").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(chapter2.contains("Second chapter."))

        // Cover entry present; NCX has nav points.
        #expect(entryData(archive, "cover.jpg") != nil)
        let ncx = entryData(archive, "toc.ncx").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(ncx.contains("navPoint"))
    }

    @Test
    func subjectsBecomeDcSubjectElements() throws {
        let data = try MobiToEpubConverter.convert(content(subjects: ["Sci-Fi", "Dystopian"]))
        let archive = try archive(from: data)
        let opf = entryData(archive, "content.opf").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(opf.contains("<dc:subject>Sci-Fi</dc:subject>"))
        #expect(opf.contains("<dc:subject>Dystopian</dc:subject>"))
    }

    @Test
    func outputIsDeterministic() throws {
        let content = content()
        let first = try MobiToEpubConverter.convert(content)
        let second = try MobiToEpubConverter.convert(content)
        #expect(first == second)
    }

    @Test
    func minimalContentProducesOpenableEpub() throws {
        let data = try MobiToEpubConverter.convert(
            MobiContent(
                title: "",
                authors: [],
                cover: nil,
                chapters: [MobiChapter(id: "chap1", title: nil, html: "")]
            )
        )
        let archive = try archive(from: data)
        #expect(entryData(archive, "mimetype") != nil)
        #expect(entryData(archive, "chap1.xhtml") != nil)
    }

    @Test
    func repairHTMLFixesAmpersandsUnquotedAndStrayQuotes() {
        // Raw & in text — the single most common MOBI breakage.
        #expect(MobiToEpubConverter.repairHTML("<p>AT&T and R&D</p>")
            == "<p>AT&amp;T and R&amp;D</p>")
        // Existing entities are preserved, not double-escaped.
        #expect(MobiToEpubConverter.repairHTML("<p>A &amp; B &#169;</p>")
            == "<p>A &amp; B &#169;</p>")
        // Unquoted attribute values get quoted.
        #expect(MobiToEpubConverter.repairHTML(#"<img src=cover.jpg width=640 height=480>"#)
            == #"<img src="cover.jpg" width="640" height="480">"#)
        // Stray quote inside a quoted attribute value: re-quoted to double
        // quotes — the apostrophe is legal inside a "..." value.
        #expect(MobiToEpubConverter.repairHTML(#"<a href="x" alt='It's a test'>"#)
            == #"<a href="x" alt="It's a test">"#)
        // Well-formed markup passes through unchanged.
        let clean = #"<p class="body">Hello <b>world</b></p>"#
        #expect(MobiToEpubConverter.repairHTML(clean) == clean)
    }

    @Test
    func assembledChapterXHTMLIsWellFormed() throws {
        // The exact failure the user reported: a MOBI chapter whose raw HTML
        // breaks the EPUB (line-N "AttValue expected"). After repair the
        // assembled XHTML must parse as XML.
        let broken = #"<p>AT&T <img src=cover.png alt='It's a test' width=200></p>"#
        let content = MobiContent(
            title: "Broken & Book",
            authors: ["Author & Son"],
            cover: nil,
            chapters: [MobiChapter(id: "chap1", title: "Chapter & One", html: broken)]
        )
        let archive = try archive(from: MobiToEpubConverter.convert(content))
        guard let xhtml = entryData(archive, "chap1.xhtml"),
              let text = String(data: xhtml, encoding: .utf8) else {
            Issue.record("chap1.xhtml missing")
            return
        }
        // Must not contain the raw breakers.
        #expect(!text.contains("AT&T"))
        #expect(!text.contains("alt='It's"))
        // And must parse as XML (FoundationXML is imported at file scope
        // under the same canImport guard below).
        #if canImport(FoundationXML)
        #expect(throws: Never.self) {
            _ = try XMLDocument(xmlString: text)
        }
        #endif
    }

    @Test
    func normalizedContentStripsWrapper() {
        let wrapped = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body><h1>One</h1><p>Body text.</p></body></html>
        """
        let normalized = MobiToEpubConverter.normalizedContent(wrapped)
        #expect(normalized.contains("<h1>One</h1>"))
        #expect(normalized.contains("Body text."))
        #expect(!normalized.contains("<?xml"))
        #expect(!normalized.contains("<html"))
        #expect(!normalized.contains("<head>"))
        #expect(!normalized.contains("</html>"))

        // Already-clean content is returned trimmed and otherwise untouched.
        let clean = "<p>Hello</p>"
        #expect(MobiToEpubConverter.normalizedContent(clean) == clean)
    }
}
