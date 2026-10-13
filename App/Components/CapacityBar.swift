import SwiftUI

/// One segment of a capacity bar.
struct CapacitySegment: Identifiable, Hashable {
    enum Kind: Hashable {
        case category(SpaceCategory)
        /// Used space the scan could not read: hatched, never drawn as free.
        case hidden
        /// Free space, drawn as striped light (the design A signature).
        case free
        /// Plain used space when no breakdown is known.
        case used
    }

    var kind: Kind
    var bytes: UInt64
    var id: Kind { kind }

    var title: String {
        switch kind {
        case .category(let category): category.title
        case .hidden: String(localized: "Space Lightwell can't see", table: "UI")
        case .free: String(localized: "Free", table: "UI")
        case .used: String(localized: "Used", table: "UI")
        }
    }
}

/// Horizontal stacked bar: categories, hidden space, then free space as light.
struct CapacityBar: View {
    let segments: [CapacitySegment]
    var height: CGFloat = Theme.Metrics.barHeight
    var spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(UInt64(0)) { $0 + $1.bytes }, 1)
            let visible = segments.filter { $0.bytes > 0 }
            let usable = max(proxy.size.width - spacing * CGFloat(max(visible.count - 1, 0)), 0)
            HStack(spacing: spacing) {
                ForEach(visible) { segment in
                    SegmentFill(kind: segment.kind)
                        .frame(width: max(usable * CGFloat(Double(segment.bytes) / Double(total)), 2))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 3, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        segments.filter { $0.bytes > 0 }
            .map { String(localized: "\($0.title) \(Format.bytes($0.bytes))", table: "UI") }
            .joined(separator: ", ")
    }
}

private struct SegmentFill: View {
    let kind: CapacitySegment.Kind

    var body: some View {
        switch kind {
        case .category(let category):
            Rectangle().fill(category.color)
        case .used:
            Rectangle().fill(Theme.secondaryInk)
        case .hidden:
            Hatching(color: Theme.tertiaryInk, background: Theme.well)
        case .free:
            LightStripes()
        }
    }
}

/// Free space as light: warm yellow with soft diagonal stripes and a glow.
struct LightStripes: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(Theme.light))
            var stripes = Path()
            let step: CGFloat = 7
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(stripes, with: .color(Theme.lightDeep.opacity(0.45)), lineWidth: 2)
        }
        .shadow(color: Theme.light.opacity(0.6), radius: 6)
    }
}

/// Diagonal hatching for space the scan could not see.
struct Hatching: View {
    var color: Color
    var background: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            var lines = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += 5
            }
            context.stroke(lines, with: .color(color.opacity(0.5)), lineWidth: 1)
        }
    }
}

/// Legend under a capacity bar: dot, name, size.
struct CapacityLegend: View {
    let segments: [CapacitySegment]

    var body: some View {
        FlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(segments.filter { $0.bytes > 0 }) { segment in
                HStack(spacing: 5) {
                    LegendSwatch(kind: segment.kind)
                    Text(segment.title)
                        .foregroundStyle(Theme.secondaryInk)
                    Text(Format.bytes(segment.bytes))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                }
                .font(Theme.Fonts.callout)
                .fixedSize()
            }
        }
    }
}

private struct LegendSwatch: View {
    let kind: CapacitySegment.Kind

    var body: some View {
        SegmentFill(kind: kind)
            .frame(width: 9, height: 9)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
    }
}

/// Left-to-right wrapping layout for legends and chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + lineSpacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
