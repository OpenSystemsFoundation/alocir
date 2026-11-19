import Testing
@testable import AlocirCore

@Suite struct FormattingTests {
    @Test func sizes() {
        #expect(Formatting.size(0) == "0 B")
        #expect(Formatting.size(1023) == "1023 B")
        #expect(Formatting.size(1024) == "1.0 KB")
        #expect(Formatting.size(1536) == "1.5 KB")
        #expect(Formatting.size(1024 * 1023) == "1023.0 KB")
        #expect(Formatting.size(1024 * 1024 * 500) == "500.0 MB")
        #expect(Formatting.size(10 << 30) == "10.0 GB")
        #expect(Formatting.size(5 << 40) == "5.0 TB")
    }

    @Test func counts() {
        #expect(Formatting.count(0) == "0")
        #expect(Formatting.count(999) == "999")
        #expect(Formatting.count(1000) == "1,000")
        #expect(Formatting.count(1_234_567) == "1,234,567")
    }

    @Test func durations() {
        #expect(Formatting.duration(seconds: 0.45) == "0.5s")
        #expect(Formatting.duration(seconds: 12.34) == "12.3s")
        #expect(Formatting.duration(seconds: 125) == "2m 05s")
        #expect(Formatting.duration(seconds: 3725) == "1h 02m")
        #expect(Formatting.duration(.milliseconds(1500)) == "1.5s")
    }

    @Test func percents() {
        #expect(Formatting.percent(1, of: 4) == "25%")
        #expect(Formatting.percent(1, of: 1000) == "<1%")
        #expect(Formatting.percent(0, of: 10) == "0%")
        #expect(Formatting.percent(5, of: 0) == "0%")
    }

    @Test func truncation() {
        #expect(Formatting.truncateEnd("abc", maxCharacters: 10) == "abc")
        #expect(Formatting.truncateEnd("abcdefghijkl", maxCharacters: 10) == "abcdefghi…")
        #expect(Formatting.truncateStart("abcdefghijkl", maxCharacters: 10) == "…defghijkl")
        #expect(Formatting.truncateEnd("😀😀😀😀😀😀", maxCharacters: 5) == "😀😀😀😀…")
        #expect(Formatting.truncateStart("😀😀😀😀😀😀", maxCharacters: 5) == "…😀😀😀😀")
        // A flag is one Character made of two scalars; it is never split.
        #expect(Formatting.truncateEnd("🇳🇱🇳🇱🇳🇱", maxCharacters: 2) == "🇳🇱…")
        let name = "Ünïcödé 📁 föld€r — ünïcödé.txt"
        for max in 0..<40 {
            #expect(Formatting.truncateEnd(name, maxCharacters: max).count <= Swift.max(max, 1))
            #expect(Formatting.truncateStart(name, maxCharacters: max).count <= Swift.max(max, 1))
            #expect(Formatting.truncateMiddle(name, maxCharacters: max).count <= Swift.max(max, 1))
            #expect(Formatting.truncateMiddle(name, maxCharacters: max, keepingExtension: true).count <= Swift.max(max, 1))
        }
    }

    @Test func middleTruncationKeepsBothEnds() {
        #expect(Formatting.truncateMiddle("short.mov", maxCharacters: 20, keepingExtension: true) == "short.mov")
        #expect(Formatting.truncateMiddle("abcdefghijkl", maxCharacters: 7) == "abc…jkl")
        // The extension survives, with a couple of characters before it.
        #expect(Formatting.truncateMiddle("Device-7021.dmg", maxCharacters: 11, keepingExtension: true) == "Devi…21.dmg")
        #expect(Formatting.truncateMiddle("Concert recording.mkv", maxCharacters: 12, keepingExtension: true)
            == "Conce…ng.mkv")
        // Too tight for the extension: plain middle truncation.
        #expect(Formatting.truncateMiddle("a-long-name.extension", maxCharacters: 7, keepingExtension: true)
            == "a-l…ion")
        // A leading dot is a hidden file's name, not an extension.
        #expect(Formatting.truncateMiddle(".bash_history_long", maxCharacters: 9, keepingExtension: true)
            == ".bas…long")
        #expect(Formatting.truncateMiddle("🇳🇱🇳🇱🇳🇱🇳🇱", maxCharacters: 3) == "🇳🇱…🇳🇱")
    }
}

@Suite struct FileKindTests {
    @Test func extensions() {
        #expect(FileKind(fileName: "Photo.JPG") == .image)
        #expect(FileKind(fileName: "movie.mov") == .video)
        #expect(FileKind(fileName: "song.mp3") == .audio)
        #expect(FileKind(fileName: "report.final.pdf") == .document)
        #expect(FileKind(fileName: "backup.tar.gz") == .archive)
        #expect(FileKind(fileName: "main.swift") == .code)
        #expect(FileKind(fileName: ".zshrc") == .other)
        #expect(FileKind(fileName: "README") == .other)
        #expect(FileKind(fileName: "trailing.") == .other)
        #expect(FileKind(fileName: "x.averyveryverylongextension") == .other)
        #expect(FileKind(fileName: "Ünïcödé.PNG") == .image)
    }
}
