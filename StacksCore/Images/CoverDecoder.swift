import Foundation

#if canImport(ImageIO)
import ImageIO
#else
import Clibz
#endif

/// Portable cover decoding.
///
/// On macOS the decode routes through ImageIO's thumbnail API —
/// `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`
/// decodes the image AT the target size instead of materializing a
/// full-resolution bitmap (WWDC 2018 "Image and Graphics Best Practices") —
/// and the downsampled result is re-encoded as PNG.
///
/// Linux has no ImageIO, so the same function runs a self-contained PNG
/// decoder: chunk parsing, zlib inflate of the IDAT stream, scanline
/// de-filtering (filter types 0-4), expansion to RGBA, a nearest-neighbour
/// downscale, and a PNG re-encode. PNG is the format both branches agree on;
/// JPEG covers on Linux fall back to `nil` (v1 scope, see
/// `decodePNGPortable`).
public enum CoverDecoder {
    /// Decodes `data` and returns PNG-encoded image data whose longest side is
    /// capped at `maxPixelSize` (aspect ratio preserved). Never upscales.
    /// Returns nil when the data isn't a decodable image, on decode failure,
    /// or (Linux branch) when the image isn't a PNG.
    public static func decode(data: Data, maxPixelSize: Int) -> Data? {
        #if canImport(ImageIO)
        return decodeWithImageIO(data: data, maxPixelSize: maxPixelSize)
        #else
        return decodePNGPortable(data: data, maxPixelSize: maxPixelSize)
        #endif
    }

#if canImport(ImageIO)
    // MARK: - macOS: ImageIO thumbnail decode

    /// ImageIO downsample + PNG re-encode. The thumbnail options match
    /// `CoverThumbnailer.downsample(url:maxPixelSize:)` exactly (the value
    /// passed as `kCGImageSourceThumbnailMaxPixelSize` is the same number,
    /// just carried as an `Int`).
    private static func decodeWithImageIO(data: Data, maxPixelSize: Int) -> Data? {
        // Don't let the source cache the full-resolution image.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return png as Data
    }

#else
    // MARK: - Linux: self-contained PNG decoder

    /// Decodes a non-interlaced PNG to RGBA, downscales it so the longest side
    /// is at most `maxPixelSize`, and re-encodes the result as a PNG — the
    /// same return format as the ImageIO branch. JPEG and interlaced (Adam7)
    /// PNG covers fall back to `nil` in this v1; both are rare among EPUB
    /// covers (JPEG covers are handled on macOS by ImageIO).
    private static func decodePNGPortable(data: Data, maxPixelSize: Int) -> Data? {
        guard maxPixelSize > 0, let parsed = parsePNG(data) else { return nil }
        guard let scanlines = inflateScanlines(parsed.idat, expectedSize: parsed.expectedSize) else {
            return nil
        }
        guard let rgba = unfilterAndExpand(scanlines, info: parsed) else { return nil }
        let scaled = downscale(rgba.pixels, width: rgba.width, height: rgba.height, maxPixelSize: maxPixelSize)
        return encodePNG(rgba: scaled.pixels, width: scaled.width, height: scaled.height)
    }

    // MARK: PNG parsing

    private struct PNGInfo {
        let width: Int
        let height: Int
        let bitDepth: Int
        let colorType: Int
        let channels: Int        // raw samples per pixel (before expansion)
        let bytesPerSample: Int  // 1 or 2
        let stride: Int          // bytes per scanline
        let expectedSize: Int    // (filter byte + scanline) * height
        let idat: Data
        let palette: [UInt8]?    // PLTE payload
        let transparency: [UInt8]? // tRNS payload
    }

    /// Validates the signature, walks the chunks (IHDR/PLTE/tRNS/IDAT/IEND),
    /// and returns everything the later stages need. Returns nil for anything
    /// that isn't a well-formed, non-interlaced PNG.
    private static func parsePNG(_ data: Data) -> PNGInfo? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 8, Array(data[0..<8]) == signature else { return nil }

        var width = 0
        var height = 0
        var bitDepth = 0
        var colorType = 0
        var palette: [UInt8]?
        var transparency: [UInt8]?
        var idatParts: [Data] = []
        var sawIHDR = false
        var offset = 8

        while offset + 12 <= data.count {
            let length = be32(data, offset)
            let chunkStart = offset + 8
            guard length <= data.count - chunkStart else { return nil }
            let type = data[offset + 4..<offset + 8]
            let payload = data[chunkStart..<chunkStart + length]
            switch String(bytes: type, encoding: .ascii) {
            case "IHDR":
                guard length == 13, !sawIHDR else { return nil }
                sawIHDR = true
                // Data slices keep absolute indices; rebase before Int indexing.
                let p = Data(payload)
                width = be32(p, 0)
                height = be32(p, 4)
                bitDepth = Int(p[8])
                colorType = Int(p[9])
                let compression = Int(p[10])
                let filterMethod = Int(p[11])
                let interlace = Int(p[12])
                // Only method-0 deflate/filter and non-interlaced (Adam7 not
                // supported in this v1).
                guard compression == 0, filterMethod == 0, interlace == 0 else { return nil }
            case "PLTE":
                guard palette == nil, length % 3 == 0 else { return nil }
                palette = Array(payload)
            case "tRNS":
                transparency = Array(payload)
            case "IDAT":
                idatParts.append(Data(payload))
            case "IEND":
                guard sawIHDR, let (channels, bytesPerSample) = layout(colorType: colorType, bitDepth: bitDepth),
                      width > 0, height > 0, width < 1 << 24, height < 1 << 24 else { return nil }
                // Scanline size in bytes — ceil() handles sub-byte bit depths
                // (e.g. 8 1-bit gray pixels = 1 byte per row).
                let stride = (width * channels * bitDepth + 7) / 8
                let expectedSize = (stride + 1) * height
                guard expectedSize > 0 else { return nil }
                let idat = idatParts.reduce(into: Data()) { $0.append($1) }
                guard !idat.isEmpty else { return nil }
                return PNGInfo(
                    width: width, height: height, bitDepth: bitDepth, colorType: colorType,
                    channels: channels, bytesPerSample: bytesPerSample, stride: stride,
                    expectedSize: expectedSize, idat: idat,
                    palette: palette, transparency: transparency
                )
            default:
                break // ancillary chunks (e.g. tEXt, gAMA) are skipped
            }
            offset = chunkStart + length + 4 // skip the CRC
        }
        return nil
    }

    /// Maps (colorType, bitDepth) to raw samples per pixel and bytes per
    /// sample, rejecting unsupported combinations.
    private static func layout(colorType: Int, bitDepth: Int) -> (channels: Int, bytesPerSample: Int)? {
        switch (colorType, bitDepth) {
        case (0, 1), (0, 2), (0, 4), (0, 8), (0, 16): return (1, bitDepth > 8 ? 2 : 1)
        case (2, 8), (2, 16): return (3, bitDepth > 8 ? 2 : 1)
        case (3, 1), (3, 2), (3, 4), (3, 8): return (1, 1)
        case (4, 8), (4, 16): return (2, bitDepth > 8 ? 2 : 1)
        case (6, 8), (6, 16): return (4, bitDepth > 8 ? 2 : 1)
        default: return nil
        }
    }

    private static func be32(_ data: Data, _ start: Int) -> Int {
        Int(data[start]) << 24 | Int(data[start + 1]) << 16 | Int(data[start + 2]) << 8 | Int(data[start + 3])
    }

    // MARK: zlib inflate / deflate

    /// Inflates the concatenated IDAT stream (zlib-wrapped deflate, RFC 1950)
    /// into exactly `expectedSize` raw scanline bytes.
    private static func inflateScanlines(_ idat: Data, expectedSize: Int) -> [UInt8]? {
        guard !idat.isEmpty, expectedSize > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: expectedSize)
        let outCapacity = expectedSize
        let inCount = idat.count
        var produced = 0
        let status: Int32 = out.withUnsafeMutableBytes { outPtr in
            idat.withUnsafeBytes { inPtr in
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(inCount)
                stream.next_out = outPtr.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(outCapacity)
                let rc = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard rc == Z_OK else { return rc }
                let result = inflate(&stream, Z_FINISH)
                produced = Int(stream.total_out)
                inflateEnd(&stream)
                return result
            }
        }
        guard status == Z_STREAM_END, produced == expectedSize else { return nil }
        return out
    }

    /// Deflates raw scanline bytes into a zlib-wrapped stream for IDAT.
    private static func zlibDeflate(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let inCount = input.count
        // deflateBound upper bound (zlib.h) + safety margin.
        let capacity = inCount + (inCount >> 12) + (inCount >> 14) + (inCount >> 25) + 64
        var out = [UInt8](repeating: 0, count: capacity)
        let outCapacity = out.count
        var produced = 0
        let status: Int32 = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(inCount)
                stream.next_out = outPtr.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(outCapacity)
                let rc = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard rc == Z_OK else { return rc }
                let result = deflate(&stream, Z_FINISH)
                produced = Int(stream.total_out)
                deflateEnd(&stream)
                return result
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return Array(out[0..<produced])
    }

    // MARK: De-filtering and expansion to RGBA

    private static func unfilterAndExpand(_ scanlines: [UInt8], info: PNGInfo) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard scanlines.count == info.expectedSize else { return nil }
        let stride = info.stride
        let bpp = max(1, info.channels * info.bytesPerSample)
        var raw = [UInt8](repeating: 0, count: scanlines.count)

        for y in 0..<info.height {
            let filter = Int(scanlines[y * (stride + 1)])
            guard filter <= 4 else { return nil }
            let rowStart = y * (stride + 1) + 1
            let outStart = y * stride
            for x in 0..<stride {
                let byte = scanlines[rowStart + x]
                let left = x >= bpp ? raw[outStart + x - bpp] : 0
                let up = y > 0 ? raw[outStart + x - stride] : 0
                let upLeft = (y > 0 && x >= bpp) ? raw[outStart + x - stride - bpp] : 0
                switch filter {
                case 0: raw[outStart + x] = byte
                case 1: raw[outStart + x] = byte &+ left
                case 2: raw[outStart + x] = byte &+ up
                case 3: raw[outStart + x] = byte &+ UInt8((Int(left) + Int(up)) >> 1)
                default: // 4 Paeth
                    let p = Int(left) + Int(up) - Int(upLeft)
                    let pa = abs(p - Int(left))
                    let pb = abs(p - Int(up))
                    let pc = abs(p - Int(upLeft))
                    let predictor: UInt8 = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft)
                    raw[outStart + x] = byte &+ predictor
                }
            }
        }
        return expandToRGBA(raw, info: info)
    }

    /// Expands every supported color type to 8-bit RGBA. Palette tRNS alpha is
    /// honored; gray/RGB key transparency (rare among covers) is not.
    private static func expandToRGBA(_ scanlines: [UInt8], info: PNGInfo) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = info.width
        let h = info.height
        guard info.colorType != 3 || info.palette != nil else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        for y in 0..<h {
            let rowStart = y * info.stride
            for x in 0..<w {
                let o = (y * w + x) * 4
                switch info.colorType {
                case 0: // grayscale -> RGB, alpha 255
                    let s = readSample(scanlines, rowStart: rowStart, x: x, channel: 0, info: info)
                    let v = expandSample(s, bitDepth: info.bitDepth)
                    rgba[o] = v
                    rgba[o + 1] = v
                    rgba[o + 2] = v
                    rgba[o + 3] = 255
                case 2: // RGB -> RGBA, alpha 255
                    let r = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 0, info: info), bitDepth: info.bitDepth)
                    let g = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 1, info: info), bitDepth: info.bitDepth)
                    let b = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 2, info: info), bitDepth: info.bitDepth)
                    rgba[o] = r
                    rgba[o + 1] = g
                    rgba[o + 2] = b
                    rgba[o + 3] = 255
                case 3: // palette -> RGBA via PLTE (+ tRNS alpha)
                    let index = readSample(scanlines, rowStart: rowStart, x: x, channel: 0, info: info)
                    guard let palette = info.palette, index * 3 + 2 < palette.count else { return nil }
                    rgba[o] = palette[index * 3]
                    rgba[o + 1] = palette[index * 3 + 1]
                    rgba[o + 2] = palette[index * 3 + 2]
                    if let trns = info.transparency, index < trns.count {
                        rgba[o + 3] = trns[index]
                    } else {
                        rgba[o + 3] = 255
                    }
                case 4: // grayscale + alpha
                    let s = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 0, info: info), bitDepth: info.bitDepth)
                    let a = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 1, info: info), bitDepth: info.bitDepth)
                    rgba[o] = s
                    rgba[o + 1] = s
                    rgba[o + 2] = s
                    rgba[o + 3] = a
                default: // 6 RGBA
                    let r = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 0, info: info), bitDepth: info.bitDepth)
                    let g = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 1, info: info), bitDepth: info.bitDepth)
                    let b = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 2, info: info), bitDepth: info.bitDepth)
                    let a = expandSample(readSample(scanlines, rowStart: rowStart, x: x, channel: 3, info: info), bitDepth: info.bitDepth)
                    rgba[o] = r
                    rgba[o + 1] = g
                    rgba[o + 2] = b
                    rgba[o + 3] = a
                }
            }
        }
        return (rgba, w, h)
    }

    /// Reads one sample for pixel `x` (channel `channel`) from a scanline,
    /// handling packed sub-byte samples (bit depths 1/2/4) and 16-bit samples.
    private static func readSample(_ scanlines: [UInt8], rowStart: Int, x: Int, channel: Int, info: PNGInfo) -> Int {
        if info.bitDepth < 8 {
            let pixelsPerByte = 8 / info.bitDepth
            let byte = Int(scanlines[rowStart + x / pixelsPerByte])
            let shift = 8 - info.bitDepth * (x % pixelsPerByte + 1)
            return (byte >> shift) & ((1 << info.bitDepth) - 1)
        }
        let offset = (x * info.channels + channel) * info.bytesPerSample
        if info.bytesPerSample == 2 {
            return Int(scanlines[rowStart + offset]) << 8 | Int(scanlines[rowStart + offset + 1])
        }
        return Int(scanlines[rowStart + offset])
    }

    /// Expands a sample to 8 bits: 16-bit takes the high byte, sub-byte
    /// samples are scaled into the full 0-255 range (PNG spec).
    private static func expandSample(_ sample: Int, bitDepth: Int) -> UInt8 {
        if bitDepth >= 8 { return UInt8(sample >> (bitDepth - 8)) }
        let max = (1 << bitDepth) - 1
        return UInt8((sample * 255 + max / 2) / max)
    }

    // MARK: Downscale + PNG re-encode

    /// Nearest-neighbour downscale preserving aspect ratio; never upscales.
    private static func downscale(_ rgba: [UInt8], width: Int, height: Int, maxPixelSize: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxPixelSize else { return (rgba, width, height) }
        let newWidth = max(1, Int((Double(width) * Double(maxPixelSize) / Double(longest)).rounded()))
        let newHeight = max(1, Int((Double(height) * Double(maxPixelSize) / Double(longest)).rounded()))
        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            let srcY = min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let srcX = min(width - 1, x * width / newWidth)
                let si = (srcY * width + srcX) * 4
                let di = (y * newWidth + x) * 4
                out[di] = rgba[si]
                out[di + 1] = rgba[si + 1]
                out[di + 2] = rgba[si + 2]
                out[di + 3] = rgba[si + 3]
            }
        }
        return (out, newWidth, newHeight)
    }

    /// Writes an 8-bit RGBA PNG (non-interlaced, filter type 0 per row).
    private static func encodePNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var scanlines = [UInt8]()
        scanlines.reserveCapacity(height * (width * 4 + 1))
        for y in 0..<height {
            scanlines.append(0) // filter type 0 (None)
            let rowStart = y * width * 4
            scanlines.append(contentsOf: rgba[rowStart..<rowStart + width * 4])
        }
        guard let idat = zlibDeflate(scanlines) else { return nil }

        var out = Data()
        out.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10]) // PNG signature
        var ihdr = Data()
        ihdr.append(contentsOf: be32Bytes(width))
        ihdr.append(contentsOf: be32Bytes(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit, color type 6 (RGBA), deflate, adaptive, non-interlaced
        appendChunk(&out, type: "IHDR", payload: ihdr)
        appendChunk(&out, type: "IDAT", payload: Data(idat))
        appendChunk(&out, type: "IEND", payload: Data())
        return out
    }

    private static func appendChunk(_ out: inout Data, type: String, payload: Data) {
        out.append(contentsOf: be32Bytes(payload.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(payload)
        var crcInput = Data(typeBytes)
        crcInput.append(payload)
        out.append(contentsOf: be32Bytes(Int(pngCRC32(of: crcInput))))
    }

    private static func be32Bytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func pngCRC32(of data: Data) -> UInt32 {
        guard data.count > 0 else { return 0 }
        var result: uLong = 0
        data.withUnsafeBytes { buf in
            result = crc32(0, buf.bindMemory(to: UInt8.self).baseAddress!, uInt(data.count))
        }
        return UInt32(result)
    }
#endif
}
