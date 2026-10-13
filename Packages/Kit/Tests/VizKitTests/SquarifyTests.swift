import CoreGraphics
import Testing
import VizKit

@Suite("Squarify")
struct SquarifyTests {
    @Test(arguments: [UInt64(1), 2, 3, 4, 5])
    func areasProportionalAndTiled(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        let count = Int.random(in: 1...300, using: &random)
        let weights = (0..<count).map { _ in Double.random(in: 1...1_000_000, using: &random) }.sorted(by: >)
        let rect = CGRect(x: 13, y: 7, width: 911, height: 377)
        let rects = TreemapLayout.squarify(weights, in: rect)
        let total = weights.reduce(0, +)
        #expect(rects.count == weights.count)

        var covered = 0.0
        for (weight, r) in zip(weights, rects) {
            let expected = weight / total * Geometry.area(rect)
            #expect(abs(Geometry.area(r) - expected) <= expected * 0.01, "area off: \(Geometry.area(r)) vs \(expected)")
            #expect(Geometry.contains(rect, r))
            covered += Geometry.area(r)
        }
        #expect(abs(covered - Geometry.area(rect)) < Geometry.area(rect) * 1e-9)
        for i in rects.indices {
            for j in rects.indices where j > i {
                #expect(Geometry.overlap(rects[i], rects[j]) < 1e-6)
            }
        }
    }

    @Test func aspectRatiosNearOne() {
        var random = SeededRandom(seed: 42)
        let weights = (0..<60).map { _ in Double.random(in: 1...100, using: &random) }.sorted(by: >)
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let rects = TreemapLayout.squarify(weights, in: rect)
        let aspects = rects.map(Geometry.aspect)
        let mean = aspects.reduce(0, +) / Double(aspects.count)
        // A slice-and-dice layout of the same input averages far above 10.
        #expect(mean < 2.0, "mean aspect \(mean)")
        #expect(aspects.max()! < 5, "worst aspect \(aspects.max()!)")

        let equal = TreemapLayout.squarify(Array(repeating: 1, count: 16), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(equal.map(Geometry.aspect).max()! < 1.6)
    }

    @Test func nonPositiveWeightsGetEmptyRects() {
        let rects = TreemapLayout.squarify([5, 0, -1, 5], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rects[1].isEmpty && rects[2].isEmpty)
        #expect(abs(Geometry.area(rects[0]) - 5000) < 1e-6)
        #expect(abs(Geometry.area(rects[3]) - 5000) < 1e-6)
        #expect(TreemapLayout.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TreemapLayout.squarify([1, 2], in: .zero).allSatisfy { $0.isEmpty })
    }
}
