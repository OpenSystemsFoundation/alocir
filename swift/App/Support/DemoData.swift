import AlocirCore
import Foundation

/// A made-up home folder for screenshots and previews. Deterministic, so
/// every CI run draws the same picture. Never touches the disk.
enum DemoData {
    static let path = "/Users/demo"

    static func homeFolder() -> FileNode {
        var rng = SeededGenerator(seed: 2026)
        let gb: UInt64 = 1 << 30
        let mb: UInt64 = 1 << 20

        func files(_ prefix: String, _ ext: [String], count: Int, from low: UInt64, to high: UInt64) -> [FileNode] {
            (0..<count).map { i in
                let size = UInt64.random(in: low...high, using: &rng)
                let name = "\(prefix)\(1000 + Int.random(in: 0..<9000, using: &rng)).\(ext[i % ext.count])"
                return FileNode(name: name, size: size, isDirectory: false)
            }
        }
        func dir(_ name: String, _ children: [FileNode]) -> FileNode {
            FileNode(name: name, isDirectory: true, children: children)
        }
        func file(_ name: String, _ size: UInt64) -> FileNode {
            FileNode(name: name, size: size, isDirectory: false)
        }

        /// Folders 22 levels deep, with long and short names, the way package
        /// managers and build tools nest them.
        func deepChain() -> FileNode {
            let names = [
                "monorepo", "packages", "design-system-components", "node_modules", "@scope", "react-native-reanimated",
                "node_modules", "@babel", "plugin-transform-modules-commonjs", "lib", "build", "Intermediates.noindex",
                "ArchiveIntermediates", "Release-iphoneos", "PackageFrameworks", "SharedModuleCache.noindex",
                "5K2PX0QO8OZFD", "Platform", "61", "cache", "Artifacts", "Products",
            ]
            var node = dir(names.last!, files("artifact-", ["o"], count: 3, from: 40 * 1024, to: 200 * 1024))
            for name in names.dropLast().reversed() {
                node = dir(name, [node])
            }
            return node
        }
        let movies = dir("Movies", [
            dir("Holiday 2025", files("Clip ", ["mov", "mp4"], count: 14, from: 300 * mb, to: 2 * gb)),
            dir("Final Cut Projects", [
                dir("Wedding", files("Render ", ["mov"], count: 6, from: 800 * mb, to: 3 * gb)),
                dir("Cache", files("Proxy ", ["mov"], count: 20, from: 50 * mb, to: 300 * mb)),
            ]),
            file("Concert recording.mkv", 4 * gb + 300 * mb),
            file("Lecture.mp4", 1 * gb + 200 * mb),
        ])
        let library = dir("Library", [
            dir("Caches", [
                dir("com.example.browser", files("cache-", ["db", "tmp"], count: 30, from: 5 * mb, to: 120 * mb)),
                dir("Developer", files("build-", ["o", "a"], count: 40, from: 10 * mb, to: 200 * mb)),
            ]),
            dir("Application Support", [
                dir("Music Studio", files("Sample ", ["wav", "aif"], count: 40, from: 20 * mb, to: 150 * mb)),
                dir("Mail", files("Message ", ["db", "plist"], count: 30, from: 1 * mb, to: 90 * mb)),
                dir("Games", [file("Assets.pak", 6 * gb), file("Shaders.cache", 900 * mb)]),
            ]),
            dir("Containers", files("Container ", ["db", "sqlite"], count: 18, from: 40 * mb, to: 600 * mb)),
            dir("Developer", [
                dir("Xcode", [dir("DerivedData", files("Index-", ["db", "o"], count: 25, from: 30 * mb, to: 400 * mb))]),
                dir("CoreSimulator", files("Device-", ["img", "dmg"], count: 6, from: 1 * gb, to: 3 * gb)),
            ]),
        ])
        let pictures = dir("Pictures", [
            dir("Photos Library.photoslibrary", [
                dir("originals", files("IMG_", ["heic", "jpg", "dng"], count: 120, from: 2 * mb, to: 60 * mb)),
                dir("resources", files("derivative-", ["jpg"], count: 40, from: 1 * mb, to: 8 * mb)),
            ]),
            dir("2025", files("IMG_", ["jpg", "heic", "dng", "raw"], count: 55, from: 5 * mb, to: 60 * mb)),
            dir("Screenshots", files("Screenshot ", ["png"], count: 30, from: 500 * 1024, to: 6 * mb)),
        ])
        let downloads = dir("Downloads", files("", ["dmg", "zip", "pdf", "pkg", "mp4", "iso"], count: 26, from: 2 * mb, to: 2 * gb))
        let music = dir("Music", [
            dir("Library", files("Track ", ["m4a", "mp3", "flac"], count: 90, from: 3 * mb, to: 40 * mb)),
        ])
        let projects = dir("Projects", [
            dir("website", [dir("node_modules", files("module-", ["js", "json"], count: 60, from: 100 * 1024, to: 20 * mb)), dir("src", files("page-", ["ts", "tsx", "css"], count: 25, from: 4 * 1024, to: 200 * 1024))]),
            // A very deep path, for the breadcrumb (small, so it doesn't show on the map).
            deepChain(),
            dir("app", [dir("build", files("obj-", ["o", "a"], count: 40, from: 1 * mb, to: 60 * mb)), dir("Sources", files("File", ["swift"], count: 40, from: 4 * 1024, to: 80 * 1024))]),
            dir("datasets", files("export-", ["csv", "json", "parquet"], count: 12, from: 50 * mb, to: 900 * mb)),
        ])
        let documents = dir("Documents", [
            dir("Taxes", files("Return ", ["pdf"], count: 12, from: 200 * 1024, to: 4 * mb)),
            dir("Papers", files("Draft ", ["pages", "docx", "pdf"], count: 30, from: 300 * 1024, to: 30 * mb)),
            dir("Archive", files("Backup ", ["zip", "tar"], count: 8, from: 200 * mb, to: 1 * gb)),
        ])
        return FileNode(name: path, isDirectory: true, children: [
            movies, library, pictures, downloads, music, projects, documents,
            file(".zsh_history", 400 * 1024), file("notes.txt", 12 * 1024),
        ])
    }

    static func recents() -> [RecentFolders.Entry] {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        return [
            .init(bookmark: Data(), path: "/Users/demo", lastSize: 71_800_000_000, lastScan: now.addingTimeInterval(-3600)),
            .init(bookmark: Data(), path: "/Users/demo/Pictures", lastSize: 9_100_000_000, lastScan: now.addingTimeInterval(-86_400 * 2)),
            .init(bookmark: Data(), path: "/Volumes/Backup", lastSize: 812_000_000_000, lastScan: now.addingTimeInterval(-86_400 * 9)),
            .init(bookmark: Data(), path: "/", lastSize: 402_000_000_000, lastScan: now.addingTimeInterval(-86_400 * 30)),
        ]
    }
}

/// A small, fast, seeded random generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
