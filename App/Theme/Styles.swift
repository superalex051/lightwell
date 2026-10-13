import SwiftUI

/// Primary action: ink capsule (design A), with press feedback.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodyStrong)
            .foregroundStyle(Theme.inkButtonLabel)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isDestructive ? Theme.danger : Theme.inkButton, in: Capsule())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressScale : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Secondary action: quiet capsule on the well color.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.bodyStrong)
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.well, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressScale : 1)
            .animation(Theme.Motion.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Small rounded chip, used for assistant suggestions and tool activity.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.callout)
            .foregroundStyle(Theme.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.well, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressScale : 1)
            .contentShape(Capsule())
    }
}

extension View {
    /// Raised card: white (or warm dark) surface with a hairline border.
    func cardSurface(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Floating glass bar (inspector strip, cleanup totals). Liquid Glass on macOS 26.
    func glassBar() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Theme.glassShape)
    }

    /// Small uppercase-free section label in tertiary ink.
    func sectionLabelStyle() -> some View {
        self
            .font(Theme.Fonts.labelStrong)
            .foregroundStyle(Theme.tertiaryInk)
    }
}
