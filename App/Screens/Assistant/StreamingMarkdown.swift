import SwiftUI

/// Assistant reply rendered as inline markdown, cheap enough to update every frame while
/// streaming: the text is split into paragraphs, finished paragraphs are parsed once and
/// cached, and only the paragraph still growing is drawn as plain text.
struct StreamingMarkdown: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        let paragraphs = Self.paragraphs(of: text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paragraphs.indices, id: \.self) { index in
                let isTail = isStreaming && index == paragraphs.count - 1
                Text(isTail ? Self.tail(paragraphs[index]) : MarkdownCache.render(paragraphs[index]))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if paragraphs.isEmpty, isStreaming {
                Text(Self.tail(""))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    static func paragraphs(of text: String) -> [Substring] {
        text.split(separator: "\n\n", omittingEmptySubsequences: true)
    }

    /// Longest growing paragraph that is parsed as markdown on every update; longer ones are drawn
    /// as plain text until they finish (then they are parsed once and cached).
    static let tailParseLimit = 2_000

    /// The growing paragraph plus a soft "light" cursor.
    private static func tail(_ paragraph: Substring) -> AttributedString {
        var result = paragraph.count > tailParseLimit ? AttributedString(paragraph) : MarkdownCache.parse(paragraph)
        var cursor = AttributedString(" \u{25CF}")
        cursor.foregroundColor = Theme.lightDeep
        result.append(cursor)
        return result
    }
}

/// Parsed paragraphs, keyed by their text. Bounded so long sessions do not grow it forever.
@MainActor
enum MarkdownCache {
    private static var storage: [String: AttributedString] = [:]
    private static let limit = 600

    static func render(_ paragraph: Substring) -> AttributedString {
        let key = String(paragraph)
        if let cached = storage[key] { return cached }
        let parsed = parse(paragraph)
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = parsed
        return parsed
    }

    /// Inline markdown only (bold, italic, code, links); block syntax stays as typed.
    static func parse(_ paragraph: Substring) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: String(paragraph), options: options)) ?? AttributedString(paragraph)
    }
}
