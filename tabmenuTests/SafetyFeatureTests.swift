//
//  SafetyFeatureTests.swift
//  tabmenuTests
//

import Testing
import CoreGraphics
import Foundation
@testable import tabmenu

@Suite("Sensitive content")
struct SensitiveContentDetectorTests {
    @Test(arguments: [
        "4111 1111 1111 1111",     // Visa test number, spaced
        "4111-1111-1111-1111",     // dashed
        "5500005555555559"         // Mastercard test number
    ])
    func detectsPaymentCards(text: String) {
        #expect(SensitiveContentDetector.looksSensitive(text))
    }

    /// Same shape, failing checksum — a phone number or order ID must not be swallowed.
    @Test func ignoresNumbersThatFailLuhn() {
        #expect(!SensitiveContentDetector.looksSensitive("4111 1111 1111 1112"))
        #expect(!SensitiveContentDetector.looksSensitive("05321234567"))
    }

    @Test(arguments: [
        "sk-abc123def456ghi789jkl012",
        "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
        "AKIAIOSFODNN7EXAMPLE",
        "xoxb-1234-5678-abcdefg",
        // Assembled at runtime: a literal matching the real token pattern would trip
        // GitHub's push protection even though this fixture is fake.
        "glpat-" + "XXyyZZ11223344556677"
    ])
    func detectsKnownKeyPrefixes(text: String) {
        #expect(SensitiveContentDetector.looksSensitive(text))
    }

    @Test func detectsPrivateKeyBlocks() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----"
        #expect(SensitiveContentDetector.looksSensitive(pem))
    }

    @Test func detectsJSONWebTokens() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(SensitiveContentDetector.looksSensitive(jwt))
    }

    /// Ordinary text mentioning a key prefix mid-sentence is prose, not a secret.
    @Test(arguments: [
        "meeting notes from today",
        "the sk- prefix is used by several vendors",
        "https://example.com/some/long/path?with=query",
        "Toplantı 14:30'da başlıyor",
        ""
    ])
    func leavesOrdinaryTextAlone(text: String) {
        #expect(!SensitiveContentDetector.looksSensitive(text))
    }

    /// A multi-kilobyte private key must not slip past on size alone.
    @Test func detectsOversizedPrivateKeyBlocks() {
        let body = String(repeating: "MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8m2H1x0\n", count: 120)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + body + "-----END RSA PRIVATE KEY-----"
        #expect(pem.count > 4096)
        #expect(SensitiveContentDetector.looksSensitive(pem))
    }

    /// A key pasted as an env assignment is still a key.
    @Test func detectsEnvAssignmentSecrets() {
        #expect(SensitiveContentDetector.looksSensitive("OPENAI_API_KEY=sk-Fh3kL9mQx7Tz2Wv8Yb4Nc6Rd1Sg5Jp0A"))
    }

    /// A bearer token inside a copied header line is still a token.
    @Test func detectsBearerTokenHeaders() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(SensitiveContentDetector.looksSensitive("Authorization: Bearer \(jwt)"))
    }

    /// A long article stays a long article.
    @Test func leavesLongOrdinaryProseAlone() {
        let prose = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 120)
        #expect(prose.count > 4096)
        #expect(!SensitiveContentDetector.looksSensitive(prose))
    }
}

@Suite("Window rescue")
struct WindowRescuerTests {
    private let mainScreen = CGRect(x: 0, y: 25, width: 1512, height: 920)

    /// A window comfortably on screen needs nothing.
    @Test func visibleWindowsAreLeftAlone() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowRescuer.rescuedFrame(for: frame, visibleAreas: [mainScreen], fallback: mainScreen) == nil)
    }

    /// Stranded on a display that no longer exists: pulled fully inside the fallback.
    @Test func strandedWindowsComeBack() {
        let stranded = CGRect(x: 2000, y: 100, width: 800, height: 600)
        let rescued = WindowRescuer.rescuedFrame(for: stranded, visibleAreas: [mainScreen], fallback: mainScreen)
        let unwrapped = try! #require(rescued)
        #expect(mainScreen.contains(unwrapped))
        #expect(unwrapped.size == stranded.size)
    }

    /// Showing a sliver too thin to grab counts as stranded.
    @Test func slimSliversCountAsStranded() {
        let sliver = CGRect(x: 1512 - 20, y: 100, width: 800, height: 600)
        #expect(WindowRescuer.rescuedFrame(for: sliver, visibleAreas: [mainScreen], fallback: mainScreen) != nil)
    }

    /// A grabbable strip on *any* screen means reachable.
    @Test func windowOnSecondScreenIsFine() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let frame = CGRect(x: 1600, y: 200, width: 800, height: 600)
        #expect(WindowRescuer.rescuedFrame(for: frame, visibleAreas: [mainScreen, second], fallback: mainScreen) == nil)
    }

    /// A window bigger than the fallback screen is shrunk to fit rather than left hanging off.
    @Test func oversizedWindowsAreShrunk() {
        let huge = CGRect(x: 5000, y: 5000, width: 3000, height: 2000)
        let rescued = try! #require(
            WindowRescuer.rescuedFrame(for: huge, visibleAreas: [mainScreen], fallback: mainScreen)
        )
        #expect(rescued.width <= mainScreen.width)
        #expect(rescued.height <= mainScreen.height)
        #expect(mainScreen.contains(rescued))
    }
}

@Suite("Menu palette scoring")
struct MenuPaletteScoringTests {
    @Test func prefixBeatsWordBeatsSubstring() {
        let prefix = MenuTreeReader.score(query: "exp", title: "Export…", path: "File")!
        let word = MenuTreeReader.score(query: "exp", title: "Quick Export", path: "File")!
        let substring = MenuTreeReader.score(query: "exp", title: "Reexport All", path: "File")!
        #expect(prefix > word)
        #expect(word > substring)
    }

    @Test func pathMatchesRankLowest() {
        let title = MenuTreeReader.score(query: "file", title: "New File", path: "File")!
        let pathOnly = MenuTreeReader.score(query: "file", title: "Open Recent", path: "File")!
        #expect(title > pathOnly)
    }

    @Test func noMatchMeansNil() {
        #expect(MenuTreeReader.score(query: "zzz", title: "Export…", path: "File") == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(MenuTreeReader.score(query: "EXPORT", title: "export as png", path: "File") != nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(MenuTreeReader.score(query: "", title: "Anything", path: "File") == 0)
    }
}

@Suite("Clipboard transforms")
struct ClipboardTransformTests {
    @Test func trimStripsSurroundingWhitespace() {
        #expect(ClipboardTransform.trimWhitespace.apply(to: "  hello \n") == "hello")
    }

    @Test func singleLineCollapsesBreaks() {
        #expect(ClipboardTransform.singleLine.apply(to: "a\n  b\n\nc") == "a b c")
    }

    @Test func jsonIsPrettyPrinted() {
        let result = ClipboardTransform.formatJSON.apply(to: #"{"b":1,"a":2}"#)
        let unwrapped = try! #require(result)
        #expect(unwrapped.contains("\n"))
        #expect(unwrapped.range(of: "\"a\"")!.lowerBound < unwrapped.range(of: "\"b\"")!.lowerBound)
    }

    @Test func invalidJSONOffersNothing() {
        #expect(ClipboardTransform.formatJSON.apply(to: "not json") == nil)
    }

    @Test func urlDecodingOnlyWhenItChangesSomething() {
        #expect(ClipboardTransform.decodeURL.apply(to: "a%20b") == "a b")
        #expect(ClipboardTransform.decodeURL.apply(to: "plain") == nil)
    }

    /// A transform that would return the input unchanged must not be offered.
    @Test func noOpTransformsAreFiltered() {
        let applicable = ClipboardTransform.applicable(to: "hello")
        #expect(!applicable.contains(.trimWhitespace))
        #expect(!applicable.contains(.lowerCase))
        #expect(applicable.contains(.upperCase))
    }
}

@Suite("Audio mixer rules")
struct AudioMixerRuleTests {
    @Test func volumeIsClamped() {
        #expect(AudioMixerService.clampVolume(1.7) == 1)
        #expect(AudioMixerService.clampVolume(-0.3) == 0)
        #expect(AudioMixerService.clampVolume(0.42) == 0.42)
    }

    /// Chrome's audio lives in helper processes; the user should see one Chrome slider.
    @Test func helperBundlesCollapseIntoTheParent() {
        #expect(AudioMixerService.groupKey(forBundleID: "com.google.Chrome.helper", pid: 1) == "com.google.Chrome")
        #expect(AudioMixerService.groupKey(forBundleID: "com.spotify.client", pid: 2) == "com.spotify.client")
        #expect(AudioMixerService.groupKey(forBundleID: nil, pid: 42) == "pid:42")
        #expect(AudioMixerService.groupKey(forBundleID: "", pid: 7) == "pid:7")
    }

    @Test func playingAppsSortFirst() {
        let silent = MixerApp(id: "b", name: "Alpha", icon: nil, isPlaying: false, volume: 1, processObjects: [])
        let playing = MixerApp(id: "a", name: "Zeta", icon: nil, isPlaying: true, volume: 1, processObjects: [])
        #expect(AudioMixerService.rowOrder(playing, silent))
        #expect(!AudioMixerService.rowOrder(silent, playing))
    }
}

@Suite("Microphone indicator policy")
struct MicrophoneIndicatorTests {
    /// Siri's wake listener and other Apple daemons hold the mic around the clock; the
    /// system's own orange dot ignores them and so must ours.
    @Test func appleDaemonsDoNotCount() {
        #expect(!NotchModel.countsAsMicrophoneUser(bundleID: "com.apple.CoreSpeech", isRegularApp: false))
        #expect(!NotchModel.countsAsMicrophoneUser(bundleID: "com.apple.assistantd", isRegularApp: false))
    }

    @Test func appleForegroundAppsCount() {
        #expect(NotchModel.countsAsMicrophoneUser(bundleID: "com.apple.FaceTime", isRegularApp: true))
        #expect(NotchModel.countsAsMicrophoneUser(bundleID: "com.apple.QuickTimePlayerX", isRegularApp: true))
    }

    /// Browser audio capture happens in helper processes that are not regular apps.
    @Test func thirdPartyProcessesAlwaysCount() {
        #expect(NotchModel.countsAsMicrophoneUser(bundleID: "com.google.Chrome.helper", isRegularApp: false))
        #expect(NotchModel.countsAsMicrophoneUser(bundleID: "us.zoom.xos", isRegularApp: true))
        #expect(NotchModel.countsAsMicrophoneUser(bundleID: nil, isRegularApp: false))
    }
}


@Suite("DDC packets")
struct DDCPacketTests {
    /// Checksum seeds from the wire-protocol address pair (0x6E ^ 0x51) per DDC/CI.
    @Test func brightnessWritePacketIsWellFormed() {
        let packet = DDC.brightnessWritePacket(percent: 100)
        #expect(packet == [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
    }

    @Test func percentIsClampedIntoVCPRange() {
        #expect(DDC.brightnessWritePacket(percent: 150)[4] == 100)
        #expect(DDC.brightnessWritePacket(percent: -5)[4] == 0)
    }

    @Test func readReplyParsesCurrentAgainstMax() {
        // op 0x02, vcp 0x10, max 100, current 37
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x25, 0x00, 0x00]
        #expect(DDC.parseBrightnessReply(reply) == 37)
    }

    @Test func malformedRepliesAreRejected() {
        #expect(DDC.parseBrightnessReply([]) == nil)
        #expect(DDC.parseBrightnessReply([0x6E, 0x88, 0x05, 0, 0, 0, 0, 0, 0, 0]) == nil)   // wrong opcode
        #expect(DDC.parseBrightnessReply([0x6E, 0x88, 0x02, 0, 0, 0, 0x00, 0x00, 0, 0]) == nil) // max 0
    }
}

@Suite("Language override")
struct AppLanguageTests {
    @Test func mapsStoredLanguagesToChoices() {
        #expect(AppLanguage.current(fromStored: nil) == .system)
        #expect(AppLanguage.current(fromStored: []) == .system)
        #expect(AppLanguage.current(fromStored: ["tr"]) == .turkish)
        #expect(AppLanguage.current(fromStored: ["tr-TR", "en"]) == .turkish)
        #expect(AppLanguage.current(fromStored: ["en-US"]) == .english)
        #expect(AppLanguage.current(fromStored: ["de-DE"]) == .system)
    }
}
