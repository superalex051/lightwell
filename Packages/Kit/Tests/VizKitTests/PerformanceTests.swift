import CoreGraphics
import Foundation
import Testing
import VizKit

@Suite("Layout performance")
struct PerformanceTests {
    /// PLAN acceptance: layout of 5k tiles under 8 ms (release). Debug builds get a looser bound;
    /// run `swift test -c release --filter VizKitTests` for the real figure.
    @Test func fiveThousandTilesLayoutQuickly() {
        let tree = makeWideTree(folders: 100, filesPerFolder: 50, seed: 77)
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let options = MapLayoutOptions(minTileFraction: 0, minFrameSize: .zero)
        let layout = TreemapLayout()

        var tiles = layout.layout(root: 0, in: bounds, source: tree, options: options) // warm up
        #expect(tiles.count >= 5_000)
        #expect(tiles.filter { $0.depth == 2 }.count >= 4_900)

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<25 {
            let elapsed = clock.measure {
                tiles = layout.layout(root: 0, in: bounds, source: tree, options: options)
            }
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        // The acceptance limit (8 ms) applies to optimized code only. Debug builds (what
        // `make test` runs) are about 7x slower, so they only get a sanity bound that catches
        // an accidental O(n²) without flaking.
        let releaseAcceptanceLimitMs = 8.0
        let debugSanityLimitMs = 80.0
        #if DEBUG
        let limit = debugSanityLimitMs
        let configuration = "debug, sanity bound"
        #else
        let limit = releaseAcceptanceLimitMs
        let configuration = "release, acceptance limit"
        #endif
        print("VizKit layout (\(configuration) \(limit) ms): \(tiles.count) tiles, median \(String(format: "%.3f", median)) ms, best \(String(format: "%.3f", samples[0])) ms")
        #expect(median < limit, "median \(median) ms over \(limit) ms")
    }

    @Test func hitTestOnFiveThousandTilesIsCheap() {
        let tree = makeWideTree(folders: 100, filesPerFolder: 50, seed: 78)
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let tiles = TreemapLayout().layout(root: 0, in: bounds, source: tree, options: MapLayoutOptions(minTileFraction: 0, minFrameSize: .zero))
        var random = SeededRandom(seed: 9)
        let points = (0..<1_000).map { _ in
            CGPoint(x: Double.random(in: 0..<1600, using: &random), y: Double.random(in: 0..<1000, using: &random))
        }
        let clock = ContinuousClock()
        var found = 0
        let elapsed = clock.measure {
            for point in points where TreemapLayout.hitTest(tiles, at: point) != nil { found += 1 }
        }
        let perPointMicroseconds = (Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6) / 1_000
        print("VizKit hit test: \(tiles.count) tiles, \(String(format: "%.2f", perPointMicroseconds)) us per point")
        #expect(found > 900)
        // One pointer move must stay far below a 16 ms frame even in debug.
        #expect(perPointMicroseconds < 2_000)
    }
}
