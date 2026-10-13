import AppKit
import SwiftUI
import Testing
import VizKit

/// A home folder shaped like a real one, for the rendered sample.
func makeHomeTree() -> TestTree {
    let gb: UInt64 = 1_000_000_000
    let mb: UInt64 = 1_000_000
    let tree = TestTree()
    func folder(_ name: String, _ category: String, under parent: MapNodeID = 0, _ files: [(String, UInt64)]) -> MapNodeID {
        let id = tree.add(name, under: parent, category: category)
        for (file, size) in files { tree.add(file, size: size, under: id, category: category) }
        return id
    }
    let library = tree.add("Library", category: "system")
    _ = folder("Application Support", "appdata", under: library, [("Slack", 9 * gb), ("Adobe", 31 * gb), ("Steam", 24 * gb), ("Spotify", 7 * gb)])
    _ = folder("Developer", "developer", under: library, [("DerivedData", 19 * gb), ("CoreSimulator", 11 * gb), ("Archives", 3 * gb)])
    _ = folder("Caches", "caches", under: library, [("com.apple.Safari", 6 * gb), ("Homebrew", 5 * gb), ("Yarn", 4 * gb)])
    _ = folder("Containers", "appdata", under: library, [("Mail", 8 * gb), ("Notes", 5 * gb)])
    _ = folder("Logs", "other", under: library, [("DiagnosticReports", 2 * gb)])
    for i in 0..<40 { tree.add("pref-\(i).plist", size: 120 * mb + UInt64(i) * mb, under: library, category: "other") }

    let projects = tree.add("Projects", category: "projects")
    _ = folder("lumen-site", "projects", under: projects, [("node_modules", 14 * gb), ("dist", 6 * gb), ("src", 4 * gb)])
    _ = folder("field-notes-ios", "projects", under: projects, [("build", 7 * gb), ("Sources", 3 * gb)])
    tree.add("sketches", size: 4 * gb, under: projects, category: "projects")
    tree.add("scratch", size: 2 * gb, under: projects, category: "projects")

    let pictures = tree.add("Pictures", category: "media")
    tree.add("Photos Library", size: 21 * gb, under: pictures, category: "media")
    tree.add("Exports", size: 11 * gb, under: pictures, category: "media")

    _ = folder("Documents", "other", [("Taxes", 5 * gb), ("Writing", 4 * gb), ("Scans", 3 * gb), ("Letters", 2 * gb)])
    _ = folder("Downloads", "downloads", [("Xcode.xip", 7 * gb), ("Installer.dmg", 3 * gb), ("Footage.zip", 2 * gb)])
    _ = folder(".cache", "caches", [("huggingface", 6 * gb), ("pip", 2 * gb), ("uv", 2 * gb)])
    tree.add("Movies", size: 10 * gb, category: "media")
    tree.add("Applications", size: 8 * gb, category: "apps")
    tree.add("Music", size: 6 * gb, category: "media")
    let locked = tree.add("Locked data", size: 5 * gb, category: "system")
    tree.locked = [locked]
    for i in 0..<30 { tree.add(".dotfile\(i)", size: 20 * mb, category: "other") }
    return tree.seal()
}

/// Category colors of design direction A (light), for the sample only. The app theme owns the real palette.
func daylightSamplePalette() -> CategoryMapPalette {
    func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    return CategoryMapPalette(
        colors: [
            "projects": hex(0xA9C2EC), "developer": hex(0x93CDB8), "apps": hex(0xEDBE94),
            "appdata": hex(0xE9D592), "media": hex(0xEDA9A6), "caches": hex(0xBEDB95),
            "downloads": hex(0x97D3E2), "system": hex(0xCFCAC0), "other": hex(0xE3DFD7),
        ],
        fallback: hex(0xE3DFD7),
        smallItems: hex(0xEAE6DF),
        background: hex(0xF7F5F0),
        label: hex(0x1D1C19)
    )
}

@Suite("Rendering")
@MainActor
struct RenderTests {
    @Test func rendersSamplePNG() throws {
        let tree = makeHomeTree()
        let view = SpaceMapView(source: tree, root: 0, palette: daylightSamplePalette())
            .frame(width: 900, height: 420)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 1800 && image.height == 840)

        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 20_000, "a blank render would compress to almost nothing")

        // Pixels inside the biggest tile are not the background color.
        let tiles = TreemapLayout().layout(root: 0, in: CGRect(x: 0, y: 0, width: 900, height: 420), source: tree, options: MapLayoutOptions())
        let biggest = try #require(tiles.first { $0.depth == 1 })
        let probe = rep.colorAt(x: Int(biggest.rect.maxX * 2) - 12, y: Int(biggest.rect.maxY * 2) - 12)
        let background = rep.colorAt(x: 1, y: 1)
        #expect(probe != background)

        // Opt-in: LIGHTWELL_VIZ_SAMPLE_OUT names a file to keep the sample. Otherwise it goes to a
        // fixture directory under $TMPDIR that is deleted right away. The path is never printed.
        if let requested = ProcessInfo.processInfo.environment["LIGHTWELL_VIZ_SAMPLE_OUT"], !requested.isEmpty {
            let output = URL(fileURLWithPath: requested)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: output)
            print("VizKit sample written to the requested file (\(png.count) bytes, \(tiles.count) tiles)")
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lightwell-fixtures", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("vizkit-sample.png")
            try png.write(to: output)
            #expect(FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func rendersWithNeutralPaletteAndEmptyTree() throws {
        let empty = TestTree()
        let renderer = ImageRenderer(content: SpaceMapView(source: empty, root: 0).frame(width: 200, height: 100))
        #expect(renderer.cgImage != nil)
        let neutral = ImageRenderer(content: SpaceMapView(source: makeHomeTree(), root: 0).frame(width: 300, height: 200))
        #expect(neutral.cgImage != nil)
    }
}
