import Foundation
import Testing
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
}
