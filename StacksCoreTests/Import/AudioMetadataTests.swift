import Foundation
import Testing
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import StacksCore

@Suite
struct AudioMetadataTests {
    // MARK: - Tagged file (macOS: AVFoundation reads ID3/MP4 tags)

    #if canImport(AVFoundation)
    /// Writes a tiny silent m4a with common metadata (title, artist,
    /// description) through AVAssetWriter, then asserts the extractor maps
    /// them to the book fields. Exercises the real AVFoundation path end to
    /// end — a filename-only fallback would fail these assertions.
    @Test
    func m4aExtractsTagsAndArtwork() async throws {
        let url = try await makeTaggedM4A()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MetadataExtractor.extract(from: url, kind: .m4b)

        #expect(metadata.title == "Test Audiobook")
        #expect(metadata.authors == ["Test Narrator"])
        #expect(metadata.comments == "Test description")

        let cover = try MetadataExtractor.extractCover(from: url, kind: .m4b)
        #if canImport(ImageIO)
        #expect(cover != nil)
        #else
        #expect(cover == nil)
        #endif
    }

    private func makeTaggedM4A() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ]
        )
        writer.add(input)

        func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
        writer.metadata = [
            metadataItem(.commonIdentifierTitle, "Test Audiobook"),
            metadataItem(.commonIdentifierArtist, "Test Narrator"),
            metadataItem(.commonIdentifierDescription, "Test description"),
        ]
        // A 1x1 PNG so the artwork extraction path is exercised too.
        if let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==") {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = png as NSData
            writer.metadata.append(artwork)
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AudioMetadataTests", code: 1)
        }
        writer.startSession(atSourceTime: .zero)

        // 0.1 s of float32 silence to encode (a zero-length track would make
        // the writer fail to finalize).
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true
        )!
        let frameCount: AVAudioFrameCount = 4_410
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData?[0] {
            data.update(repeating: 0, count: Int(frameCount))
        }

        guard try input.append(makeSampleBuffer(from: buffer, format: format)) else {
            throw writer.error ?? NSError(domain: "AudioMetadataTests", code: 2)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "AudioMetadataTests", code: 3)
        }
        return url
    }

    /// Wraps a PCM buffer in a CMSampleBuffer so the writer's AAC encoder can
    /// consume it (the deprecated synchronous append is fine for tests).
    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, format: AVAudioFormat) throws -> CMSampleBuffer {
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let descStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard descStatus == noErr, let formatDescription else {
            throw NSError(domain: "AudioMetadataTests", code: 4)
        }
        let sampleRate = CMTimeScale(asbd.mSampleRate)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: Int(buffer.frameLength),
            presentationTimeStamp: timing.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "AudioMetadataTests", code: 5)
        }
        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.mutableAudioBufferList
        )
        guard attachStatus == noErr else {
            throw NSError(domain: "AudioMetadataTests", code: 6)
        }
        return sampleBuffer
    }
    #endif

    // MARK: - Fallback (all platforms)

    @Test
    func audioFallsBackToFilenameWhenUntagged() throws {
        let name = "My Audiobook \(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).m4b")
        try Data("not actually audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try MetadataExtractor.extract(from: url, kind: .m4b)

        // Filename-stem title, no authors — the degrade path for tag-less
        // files (and all files on Linux, where AVFoundation is unavailable).
        #expect(metadata.title == name)
        #expect(metadata.authors.isEmpty)
    }
}
