import Foundation
import Testing
#if canImport(ImageIO)
import ImageIO
#endif
@testable import StacksCore

@Suite
struct CoverDecoderTests {
    /// 64x96 two-tone PNG (top half red, bottom half blue) — embedded as
    /// base64 so the SAME fixture drives both the macOS (ImageIO) and Linux
    /// (portable) decode branches. The Linux branch's PNG decoder is verified
    /// against the identical bytes.
    private static let coverPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABgCAIAAAAip+O/AAAApUlEQVR4nO3RwQnAQAzEQPffdFLGsJzAf+3g++6mzy8IMH5+QYDx8wsCjJ9fEGD8/IIA4+cXBBg/vyDA+PkFAcbPLwgwfn5BgPHzCwKMn18QYPz8ggDj5xcEGD+/IMD4+QXPA/SAfqDzAXQ+gM4H0PkAOh9A5wPofACdD6DzAXQ+gM4H0PkAOh9A5wPofACdD6DzAXQ+gM4H0PkAOh9A5wPo/POAH3vy6Vr3aTjRAAAAAElFTkSuQmCC")!

    /// 2x2 RGBA PNG with distinct alpha values per pixel.
    private static let tinyAlphaPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAGUlEQVR4nGP4z8DQwPCfwYGBgeH/gf9AAAA6JQh6TzTjegAAAABJRU5ErkJggg==")!

    /// 4x4 16-bit RGB PNG whose four scanlines use filter types 1, 2, 3, 4 —
    /// locks de-filtering of all four predictive filters AND 16-bit -> 8-bit
    /// sample scaling on both decode branches.
    private static let filter16PNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAEEAIAAAB2A9VqAAAAN0lEQVR4nGNkAANGRiDRDCIZmyFsJgYGAUYGdkySmYFBgomBm5GRg5HBFUQyHoWwWWCqgACFBADRmwO+gGQHOwAAAABJRU5ErkJggg==")!
    /// Reference 8-bit RGBA for `filter16PNG` (16-bit samples truncated to
    /// their high byte).
    private static let filter16Expected = Data(base64Encoded: "AAAA/wEAAP8CAAH/AwAB/wAQAP8BEAD/AhAB/wMQAf8AIAD/ASAA/wIgAf8DIAH/ADAA/wEwAP8CMAH/AzAB/w==")!

    /// 4x2 palette PNG with a 4-bit sample depth and tRNS alpha — locks
    /// sub-byte sample unpacking and palette transparency on both branches.
    private static let palette4PNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACBAMAAACNhmBQAAAADFBMVEXIHigK3FoeKMj6yBRaTNRfAAAABHRSTlP/AID/excXrQAAAA5JREFUeJxjYFRmMBIAAAELAGda5MC9AAAAAElFTkSuQmCC")!

    /// Reads width/height straight out of the PNG header (bytes 16-23) so the
    /// assertions need no platform image API and compile on Linux too.
    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(data[0..<8]) == signature else { return nil }
        func be32(_ start: Int) -> Int {
            Int(data[start]) << 24 | Int(data[start + 1]) << 16 | Int(data[start + 2]) << 8 | Int(data[start + 3])
        }
        return (be32(16), be32(20))
    }

#if canImport(ImageIO)
    /// Raw pixel bytes of a PNG decoded by ImageIO (macOS only) — a direct
    /// dataProvider read, no compositing, so alpha values are preserved.
    private static func decodePNGPixels(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let provider = image.dataProvider,
              let cfData = provider.data else { return nil }
        return Array(cfData as Data)
    }
#endif

    /// Extracts 8-bit RGB (plus opaque alpha) from ImageIO's little-endian
    /// 16-bit RGB pixels — 6 bytes per pixel, high byte at odd offsets.
    private static func highBytesRGB16(_ raw: [UInt8], pixelCount: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(pixelCount * 4)
        for p in 0..<pixelCount {
            let base = p * 6
            out.append(raw[base + 1]) // r
            out.append(raw[base + 3]) // g
            out.append(raw[base + 5]) // b
            out.append(255)
        }
        return out
    }

    @Test
    func decodeBoundsLongestSide() throws {
        let out = try #require(CoverDecoder.decode(data: Self.coverPNG, maxPixelSize: 64))
        let dims = try #require(Self.pngDimensions(out))
        #expect(dims.width > 0)
        #expect(dims.height > 0)
        // The longest side (96) is capped at maxPixelSize — never a full-size decode.
        #expect(max(dims.width, dims.height) <= 64)
        // Aspect ratio 64:96 is preserved.
        #expect(abs(Double(dims.width) / Double(dims.height) - 64.0 / 96.0) < 0.05)
    }

    @Test
    func decodeDoesNotUpscale() throws {
        let out = try #require(CoverDecoder.decode(data: Self.coverPNG, maxPixelSize: 500))
        let dims = try #require(Self.pngDimensions(out))
        #expect(dims.width <= 64)
        #expect(dims.height <= 96)
    }

    @Test
    func decodeAlphaPNG() throws {
        let out = try #require(CoverDecoder.decode(data: Self.tinyAlphaPNG, maxPixelSize: 64))
        let dims = try #require(Self.pngDimensions(out))
        #expect(dims.width == 2)
        #expect(dims.height == 2)
    }

    @Test
    func decodeInvalidInputReturnsNil() {
        #expect(CoverDecoder.decode(data: Data(), maxPixelSize: 64) == nil)
        #expect(CoverDecoder.decode(data: Data("not an image".utf8), maxPixelSize: 64) == nil)
        // Truncated PNG: signature plus a partial header.
        let truncated = Data(Self.coverPNG.prefix(14))
        #expect(CoverDecoder.decode(data: truncated, maxPixelSize: 64) == nil)
    }

    @Test
    func decodeRejectsOversizedDimensions() {
        // A valid PNG signature + IHDR claiming 20000x20000 (400MP) with no
        // IDAT. The portable decoder must reject it from the header alone —
        // nil, never a multi-gigabyte buffer allocation (OOM guard for
        // untrusted cover data on the headless server).
        func be32(_ value: Int) -> [UInt8] {
            [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ]
        }
        var ihdr = Data()
        ihdr.append(contentsOf: be32(20_000))
        ihdr.append(contentsOf: be32(20_000))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, adaptive, non-interlaced
        var png = Data()
        png.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10])
        png.append(contentsOf: be32(13))
        png.append(contentsOf: Array("IHDR".utf8))
        png.append(ihdr)
        png.append(contentsOf: be32(0)) // bogus CRC — never reached
        png.append(contentsOf: be32(0))
        png.append(contentsOf: Array("IEND".utf8))
        #expect(CoverDecoder.decode(data: png, maxPixelSize: 64) == nil)
    }

    @Test
    func decode16BitFilteredPNG() throws {
        let out = try #require(CoverDecoder.decode(data: Self.filter16PNG, maxPixelSize: 4096))
        let dims = try #require(Self.pngDimensions(out))
        #expect(dims.width == 4)
        #expect(dims.height == 4)
        #if canImport(ImageIO)
        // macOS: ImageIO preserves 16-bit in the re-encoded PNG, so probe the
        // high bytes of each 16-bit sample against the reference RGBA.
        let raw = try #require(Self.decodePNGPixels(out))
        #expect(Self.highBytesRGB16(raw, pixelCount: 16) == Array(Self.filter16Expected))
        #endif
    }

    @Test
    func decode4BitPalettePNG() throws {
        let out = try #require(CoverDecoder.decode(data: Self.palette4PNG, maxPixelSize: 4096))
        let dims = try #require(Self.pngDimensions(out))
        #expect(dims.width == 4)
        #expect(dims.height == 2)
        #if canImport(ImageIO)
        // macOS: ImageIO's thumbnail round-trip zeroes RGB where alpha is 0
        // and rounds semi-transparent channels, so assert the opaque pixels
        // exactly and the tRNS alphas exactly.
        let raw = try #require(Self.decodePNGPixels(out))
        #expect(Array(raw[0..<4]) == [200, 30, 40, 255])   // entry 0 (opaque)
        #expect(raw[7] == 0)                                // entry 1: tRNS alpha 0
        #expect(raw[11] == 128)                             // entry 2: tRNS alpha 128
        #expect(Array(raw[12..<16]) == [250, 200, 20, 255]) // entry 3 (opaque)
        #expect(Array(raw[28..<32]) == [200, 30, 40, 255])  // row 1 entry 0 — rows intact
        #endif
    }
}
