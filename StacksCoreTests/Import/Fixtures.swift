import Foundation
import ZIPFoundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

enum Fixtures {
    /// A minimal EPUB 2.0 archive with one book and a cover PNG.
    static func makeEPUB(
        named name: String = "book.epub",
        extraEntries: [(name: String, data: Data)] = []
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "mimetype", type: .file, uncompressedSize: Int64(20),
            compressionMethod: .none,
            provider: { _, _ in Data("application/epub+zip".utf8) }
        )
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try archive.addEntry(
            with: "META-INF/container.xml", type: .file,
            uncompressedSize: Int64(container.utf8.count),
            provider: { _, _ in Data(container.utf8) }
        )
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="uid">
        <metadata>
          <dc:identifier id="uid" opf:scheme="ISBN">978-0-7352-2129-1</dc:identifier>
          <dc:title>Range: Why Generalists Triumph in a Specialized World</dc:title>
          <dc:creator opf:role="aut">David Epstein</dc:creator>
          <dc:language>eng</dc:language>
          <dc:date>2019-05-28</dc:date>
          <dc:subject>Science</dc:subject>
          <dc:description>Why generalists beat specialists.</dc:description>
          <meta name="calibre:series" content="Studies"/>
          <meta name="calibre:series_index" content="1.5"/>
          <meta name="cover" content="cover-image"/>
        </metadata>
        <manifest>
          <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        </package>
        """
        try archive.addEntry(
            with: "OEBPS/content.opf", type: .file,
            uncompressedSize: Int64(opf.utf8.count),
            provider: { _, _ in Data(opf.utf8) }
        )
        let coverPNG = Fixtures.png1x1()
        try archive.addEntry(
            with: "OEBPS/cover.png", type: .file,
            uncompressedSize: Int64(coverPNG.count),
            provider: { _, _ in coverPNG }
        )
        try archive.addEntry(
            with: "OEBPS/chapter.xhtml", type: .file,
            uncompressedSize: Int64(Data("<p/>".utf8).count),
            provider: { _, _ in Data("<p/>".utf8) }
        )
        for extra in extraEntries {
            try archive.addEntry(
                with: extra.name, type: .file,
                uncompressedSize: Int64(extra.data.count),
                provider: { _, _ in extra.data }
            )
        }
        return url
    }

    /// A one-page PDF with no embedded metadata. On Apple platforms it is
    /// rendered via a CoreGraphics PDF context; on Linux a minimal hand-built
    /// PDF (computed xref offsets) is written so the extractor's pdfinfo path
    /// has something parseable and falls back to the filename title.
    static func makePDF(named name: String = "plain.pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        #if canImport(CoreGraphics) && canImport(ImageIO)
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        #else
        // One blank page and no Info dictionary, so the filename fallback is
        // exercised on Linux (pdfinfo/PDFKit both read it fine).
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\nendstream",
        ]
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefStart = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n"
        body += "0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"
        try Data(body.utf8).write(to: url, options: .atomic)
        #endif
        return url
    }

    static func png1x1() -> Data {
        // 1x1 transparent PNG bytes.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64)!
    }

    static func jpeg1x1() throws -> Data {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
        #else
        // Minimal JFIF 1x1 JPEG (SOI + APP0 + EOI). No ImageIO decoder exists
        // on Linux, so the bytes are only carried through archives.
        let bytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00,
            0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9,
        ]
        return Data(bytes)
        #endif
    }
}
