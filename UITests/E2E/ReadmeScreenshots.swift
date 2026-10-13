import AppKit
import XCTest

/// Screenshots for README.md from the real stores in fixture mode (nothing from the preview data).
/// Gated: `TEST_RUNNER_LIGHTWELL_UI_SCREENSHOTS=1 xcodebuild ... test -only-testing:LightwellUITests/ReadmeScreenshots`,
/// then export the `readme-*` attachments with `xcrun xcresulttool export attachments`.
///
/// - The fixture is `<fixture area>/<uuid>/Demo-xxxx`, and the app runs with `CFFIXED_USER_HOME`
///   set to `<fixture area>/<uuid>`, so every path the app shows reads `~/Demo-xxxx/...`: no account
///   name, container path or UUID. Anything the app writes under that home stays in the uuid folder,
///   which teardown deletes.
/// - Each image is the main window only, with rounded corners masked. Other windows that sit above
///   it (for example a system permission prompt) are removed by taking the window at the left and
///   at the right edge of the screen and filling the covered parts of one shot from the other.
final class ReadmeScreenshots: E2ETestCase {
    private let home = E2ETestCase.fixtureArea.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let demoName = "Demo-" + UUID().uuidString.prefix(4).lowercased()

    override var fixtureFolderName: String { demoName }
    override var fixtureParent: URL { home }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LIGHTWELL_UI_SCREENSHOTS"] == "1" else {
            throw XCTSkip("README screenshots are taken on request")
        }
        try super.setUpWithError()
        for (path, size) in [
            ("home/Movies/summer-trip.mov", 14_000_000),
            ("home/Movies/drone-cut.mp4", 6_500_000),
            ("home/Music/Library.musiclibrary/library.db", 2_500_000),
            ("home/Library/Caches/com.example.browser/cache.bin", 4_500_000),
            ("home/Library/Developer/Xcode/DerivedData/Weather-app/build.o", 7_000_000),
            ("home/Pictures/scans/receipt-2025.pdf", 1_200_000),
        ] {
            try fixture.write(path, bytes: size)
        }
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if home.path.contains("/lightwell-fixtures/") {
            try? FileManager.default.removeItem(at: home)
        }
    }

    @MainActor
    func testCaptureScreens() throws {
        launch(fakeClaude: Self.fakeClaudePath, environment: ["CFFIXED_USER_HOME": home.path])
        scanFixture()

        // Assistant at the scan root: a suggestion queued unticked, a protected file refused.
        element("explore.assistantToggle").click()
        XCTAssertTrue(element("assistant.consent.open").waitForExistence(timeout: 15))
        element("assistant.consent.open").click()
        XCTAssertTrue(element("assistant.consent.accept").waitForExistence(timeout: 5))
        element("assistant.consent.accept").click()
        let input = element("assistant.input")
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.click()
        input.typeText("Can I remove ~/Movies/drone-cut.mp4 and ~/Library/Keychains/login.keychain-db")
        element("assistant.send").click()
        XCTAssertTrue(element("assistant.proposal.0").waitForExistence(timeout: 30))
        try capture("assistant")
        element("explore.assistantToggle").click()

        // Explore: the map and list of home, Movies selected.
        open("home")
        let movies = listRow("Movies")
        XCTAssertTrue(movies.waitForExistence(timeout: 5))
        movies.click()
        try capture("explore")

        element("sidebar.overview").click()
        XCTAssertTrue(element("overview.hero").waitForExistence(timeout: 10))
        try capture("overview")

        element("sidebar.reclaim").click()
        XCTAssertTrue(element("reclaim.addSafe").waitForExistence(timeout: 10))
        element("reclaim.addSafe").click()
        showQueue()
        XCTAssertTrue(element("queue.row.App-1").waitForExistence(timeout: 5))
        try capture("cleanup")
    }

    // MARK: Clean window capture

    private struct Shot {
        var image: CGImage
        /// Window frame in screen points (top-left origin, like XCUIElement frames).
        var frame: CGRect
        /// Parts covered by other windows, in window points, widened for their shadows.
        var covered: [CGRect]
        /// Owners of those windows (for failure messages).
        var owners: [String] = []
    }

    @MainActor
    private func capture(_ name: String) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let window = app.windows["main"]
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let start = window.frame
        let left = try shot(window, movedTo: screen.minX + 6)
        var result = left
        if !left.covered.isEmpty {
            let right = try shot(window, movedTo: screen.maxX - start.width - 6)
            let merged = try merge(left, right, size: start.size)
            XCTAssertEqual(merged.conflicts, 0, "\(name): a window draws over the same part in both shots: left \(left.owners) \(left.covered), right \(right.owners) \(right.covered)")
            print("README \(name): \(merged.patched) pixels taken from the second shot, \(merged.unexplained) other differing pixels kept from the first")
            result.image = merged.image
        }
        _ = try shot(window, movedTo: start.minX, capture: false)
        let attachment = XCTAttachment(image: NSImage(cgImage: try rounded(result.image, size: start.size), size: start.size))
        attachment.name = "readme-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Drags the window by an empty spot of its toolbar so its left edge lands on `x`, then shoots it.
    @MainActor
    private func shot(_ window: XCUIElement, movedTo x: CGFloat, capture: Bool = true) throws -> Shot {
        // A window drag can land a few points off (snapping), so drag again for the rest.
        for _ in 0..<4 {
            let frame = window.frame
            guard abs(frame.minX - x) > 6 else { break }
            let grip = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width * 0.55, dy: 14))
            grip.press(forDuration: 0.5, thenDragTo: grip.withOffset(CGVector(dx: x - frame.minX, dy: 0)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }
        XCTAssertTrue(abs(window.frame.minX - x) <= 6, "window moved to x \(x): \(window.frame)")
        let moved = window.frame
        if capture, let screen = NSScreen.main?.frame {
            XCTAssertTrue(moved.minX >= screen.minX && moved.maxX <= screen.maxX, "window fully on screen: \(moved)")
        }
        guard capture else { return Shot(image: try placeholder(), frame: moved, covered: []) }
        let image = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let covering = coveringWindows(over: moved)
        return Shot(image: image, frame: moved, covered: covering.map(\.rect), owners: covering.map(\.owner))
    }

    /// On-screen windows above Lightwell's main window that intersect it (owner and bounds only,
    /// no window contents or titles are read), as rectangles in window points.
    private func coveringWindows(over frame: CGRect) -> [(owner: String, rect: CGRect)] {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        func bounds(_ info: [String: Any]) -> CGRect {
            guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { return .null }
            return rect
        }
        // The list runs front to back; everything before our window is above it.
        guard let ours = all.firstIndex(where: {
            ($0[kCGWindowOwnerName as String] as? String) == "Lightwell" && bounds($0).insetBy(dx: -2, dy: -2).contains(frame.insetBy(dx: 2, dy: 2))
        }) else { return [] }
        // AutomationModeUI is the transparent overlay macOS shows while UI tests drive the Mac.
        let ignored: Set<String> = ["Dock", "Window Server", "Control Center", "SystemUIServer", "AutomationModeUI", "Lightwell"]
        return all[..<ours].compactMap { info in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let rect = bounds(info)
            guard !ignored.contains(owner), alpha > 0, rect.intersects(frame) else { return nil }
            let covered = rect.insetBy(dx: -48, dy: -48).offsetBy(dx: -frame.minX, dy: -frame.minY)
                .intersection(CGRect(origin: .zero, size: frame.size))
            return (owner, covered)
        }
    }

    /// The window without other windows: pixels under another window in the first shot come from
    /// the second shot when they are free there. `conflicts`: differing pixels covered in both shots
    /// (a transparent overlay that draws nothing causes no difference and is harmless).
    private func merge(_ first: Shot, _ second: Shot, size: CGSize) throws -> (image: CGImage, patched: Int, conflicts: Int, unexplained: Int) {
        let width = first.image.width, height = first.image.height
        XCTAssertEqual(width, second.image.width)
        XCTAssertEqual(height, second.image.height)
        let scale = CGFloat(width) / size.width
        func pixels(_ image: CGImage) throws -> [UInt8] {
            let context = try bitmap(width: width, height: height)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = try XCTUnwrap(context.data)
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * height))
        }
        let rowBytes = try bitmap(width: width, height: height).bytesPerRow
        var a = try pixels(first.image)
        let b = try pixels(second.image)
        // Covered rectangles in pixel rows (row 0 at the top of the window).
        func pixelRects(_ rects: [CGRect]) -> [(x0: Int, x1: Int, y0: Int, y1: Int)] {
            rects.map { (Int($0.minX * scale), Int($0.maxX * scale), Int($0.minY * scale), Int($0.maxY * scale)) }
        }
        let coveredA = pixelRects(first.covered), coveredB = pixelRects(second.covered)
        func inside(_ rects: [(x0: Int, x1: Int, y0: Int, y1: Int)], _ x: Int, _ y: Int) -> Bool {
            rects.contains { x >= $0.x0 && x < $0.x1 && y >= $0.y0 && y < $0.y1 }
        }
        var patched = 0, conflicts = 0, unexplained = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * rowBytes + x * 4
                let underA = inside(coveredA, x, y), underB = inside(coveredB, x, y)
                if underA && !underB {
                    // Under a window in the first shot only: take the second shot, faint shadows included.
                    a[i] = b[i]; a[i + 1] = b[i + 1]; a[i + 2] = b[i + 2]; a[i + 3] = b[i + 3]
                    patched += 1
                    continue
                }
                let difference = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                guard difference > 24 else { continue }
                if underA && underB {
                    conflicts += 1
                } else if !underB {
                    unexplained += 1
                }
            }
        }
        let context = try bitmap(width: width, height: height)
        let data = try XCTUnwrap(context.data)
        a.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, rowBytes * height)) }
        return (try XCTUnwrap(context.makeImage()), patched, conflicts, unexplained)
    }

    /// Masks the window's rounded corners, so nothing from behind the window shows there.
    private func rounded(_ image: CGImage, size: CGSize) throws -> CGImage {
        let scale = CGFloat(image.width) / size.width
        let context = try bitmap(width: image.width, height: image.height)
        let all = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: all, cornerWidth: 26 * scale, cornerHeight: 26 * scale, transform: nil))
        context.clip()
        context.draw(image, in: all)
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func placeholder() throws -> CGImage {
        try XCTUnwrap(bitmap(width: 1, height: 1).makeImage())
    }
}
