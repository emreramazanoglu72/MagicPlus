//
//  HLSPlaylistTests.swift
//  tabmenuTests
//

import Foundation
import Testing
@testable import tabmenu

@Suite("HLS playlists")
struct HLSPlaylistTests {
    private let base = URL(string: "https://example.com/videos/stream/master.m3u8")!

    // MARK: - Recognition

    @Test func recognisesWhatItIsLookingAt() {
        #expect(HLS.kind(of: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8") == .master)
        #expect(HLS.kind(of: "#EXTM3U\n#EXTINF:9.0,\na.ts") == .media)
        #expect(HLS.kind(of: "<html><body>not a playlist") == .notAPlaylist)
        // The page that got downloaded as HTML instead of media is the mistake this prevents.
        #expect(HLS.kind(of: "{\"json\": true}") == .notAPlaylist)
    }

    @Test func spotsAPlaylistByNameOrByType() {
        #expect(HLS.looksLikePlaylist(url: URL(string: "https://x.com/a/index.m3u8")!, contentType: nil))
        #expect(HLS.looksLikePlaylist(
            url: URL(string: "https://x.com/a/playlist")!,
            contentType: "application/vnd.apple.mpegurl"
        ))
        #expect(!HLS.looksLikePlaylist(url: URL(string: "https://x.com/a/v.mp4")!, contentType: "video/mp4"))
    }

    // MARK: - Attribute lists

    /// The bug this is here for: `CODECS` carries a comma inside its quotes, and splitting the
    /// line on commas throws away every attribute after it — which is how a manifest with a
    /// perfectly good RESOLUTION ends up looking like it has none.
    @Test func aCommaInsideQuotesDoesNotEatTheRest() {
        let attributes = HLS.attributes(
            in: #"BANDWIDTH=1927833,CODECS="mp4a.40.2, avc1.4d401f",RESOLUTION=1920x1080,AUDIO="aud1""#
        )
        #expect(attributes["BANDWIDTH"] == "1927833")
        #expect(attributes["RESOLUTION"] == "1920x1080")
        #expect(attributes["AUDIO"] == "aud1")
        #expect(attributes["CODECS"] == "mp4a.40.2, avc1.4d401f")
    }

    // MARK: - Master playlists

    /// Apple's own long-standing sample stream, verbatim. It declares no RESOLUTION at all, which
    /// is the case a height-based picker has to survive.
    @Test func readsAMasterThatOnlyDeclaresBandwidth() {
        let text = """
        #EXTM3U

        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=232370,CODECS="mp4a.40.2, avc1.4d4015"
        gear1/prog_index.m3u8

        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=649879,CODECS="mp4a.40.2, avc1.4d401e"
        gear2/prog_index.m3u8

        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1927833,CODECS="mp4a.40.2, avc1.4d401f"
        gear4/prog_index.m3u8
        """

        let master = HLS.parseMaster(text, baseURL: base)
        #expect(master.variants.count == 3)
        #expect(master.variants[0].url.absoluteString == "https://example.com/videos/stream/gear1/prog_index.m3u8")
        // Nothing to go on but bandwidth, so the best is the biggest.
        #expect(master.variant(preferredHeight: 720)?.bandwidth == 1927833)
    }

    @Test func picksTheTallestRenditionThatDoesNotExceedWhatWasAsked() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=16000000,RESOLUTION=3840x2160
        2160.m3u8
        """
        let master = HLS.parseMaster(text, baseURL: base)

        #expect(master.variant(preferredHeight: 1080)?.height == 1080)
        #expect(master.variant(preferredHeight: 720)?.height == 720)
        // Between two named heights, never round up: 900 must not fetch four times the bytes.
        #expect(master.variant(preferredHeight: 900)?.height == 720)
        // Asked for less than anything on offer, take the smallest rather than nothing.
        #expect(master.variant(preferredHeight: 144)?.height == 360)
        #expect(master.variant(preferredHeight: nil)?.height == 2160)
    }

    @Test func findsTheSoundThatBelongsToARendition() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-128",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac-128",NAME="Türkçe",DEFAULT=NO,URI="audio/tr.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="Wrong",DEFAULT=YES,URI="audio/wrong.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aac-128"
        video/720.m3u8
        """
        let master = HLS.parseMaster(text, baseURL: base)
        let variant = try! #require(master.variant(preferredHeight: 720))

        #expect(variant.audioGroup == "aac-128")
        let audio = try! #require(master.audio(for: variant))
        #expect(audio.name == "English", "the default rendition of the right group")
        #expect(audio.url?.absoluteString == "https://example.com/videos/stream/audio/en.m3u8")
    }

    @Test func aVariantWithNoAudioGroupNeedsNoJoining() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=854x480
        muxed.m3u8
        """
        let master = HLS.parseMaster(text, baseURL: base)
        let variant = try! #require(master.variants.first)
        #expect(variant.audioGroup == nil)
        #expect(master.audio(for: variant) == nil)
    }

    // MARK: - Media playlists

    @Test func readsSegmentsInOrderWithTheirDurations() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:9.97667,
        fileSequence0.ts
        #EXTINF:9.97667,
        fileSequence1.ts
        #EXTINF:4.0,
        https://cdn.example.com/absolute/fileSequence2.ts
        #EXT-X-ENDLIST
        """
        let media = HLS.parseMedia(text, baseURL: URL(string: "https://example.com/videos/stream/gear2/i.m3u8")!)

        #expect(media.isUsable)
        #expect(media.segments.count == 3)
        #expect(media.segments[0].url.absoluteString == "https://example.com/videos/stream/gear2/fileSequence0.ts")
        // An absolute URI in the list is used as it stands, not glued onto the base.
        #expect(media.segments[2].url.absoluteString == "https://cdn.example.com/absolute/fileSequence2.ts")
        #expect(abs(media.duration - 23.95) < 0.01)
    }

    @Test func carriesTheInitialisationSegmentForFragmentedMP4() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        seg1.m4s
        #EXT-X-ENDLIST
        """
        let media = HLS.parseMedia(text, baseURL: base)
        #expect(media.initSegment?.url.lastPathComponent == "init.mp4")
        #expect(media.segments.count == 1)
    }

    /// Many segments in one file, each taking a slice. A range that omits its offset continues
    /// from where the last one ended — get that wrong and every segment after the first is the
    /// wrong bytes.
    @Test func followsByteRangesIncludingTheOnesThatOmitTheirOffset() {
        let text = """
        #EXTM3U
        #EXT-X-BYTERANGE:1000@0
        #EXTINF:4.0,
        all.ts
        #EXT-X-BYTERANGE:2000
        #EXTINF:4.0,
        all.ts
        #EXT-X-BYTERANGE:500
        #EXTINF:4.0,
        all.ts
        #EXT-X-ENDLIST
        """
        let media = HLS.parseMedia(text, baseURL: base)
        #expect(media.segments.count == 3)
        #expect(media.segments[0].byteRange == HLS.ByteRange(offset: 0, length: 1000))
        #expect(media.segments[1].byteRange == HLS.ByteRange(offset: 1000, length: 2000))
        #expect(media.segments[2].byteRange == HLS.ByteRange(offset: 3000, length: 500))
        #expect(media.segments[1].byteRange?.headerValue == "bytes=1000-2999")
    }

    @Test func refusesAStreamWithNoEnd() {
        let text = """
        #EXTM3U
        #EXTINF:4.0,
        seg1.ts
        """
        let media = HLS.parseMedia(text, baseURL: base)
        #expect(media.obstacle == .live)
        #expect(!media.isUsable, "a live stream has no last segment to download to")
    }

    @Test func refusesEncryptionItCannotOpenAndIgnoresTheOneItCan() {
        let encrypted = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        #expect(HLS.parseMedia(encrypted, baseURL: base).obstacle == .encrypted("AES-128"))

        // METHOD=NONE turns encryption back off; treating it as an obstacle would refuse a
        // perfectly ordinary stream.
        let cleared = """
        #EXTM3U
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        #expect(HLS.parseMedia(cleared, baseURL: base).obstacle == nil)
    }

    @Test func anEmptyPlaylistIsNotAFailureWorthRetrying() {
        let media = HLS.parseMedia("#EXTM3U\n#EXT-X-ENDLIST", baseURL: base)
        #expect(media.obstacle == .empty)
    }
}
