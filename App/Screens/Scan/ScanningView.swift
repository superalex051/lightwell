import AppCore
import ScanKit
import SwiftUI

/// Scan in progress: light filling a bar, counts, the folder being read, Cancel.
struct ScanningView: View {
    @Environment(AppModel.self) private var model
    let session: ScanSessionModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reading \(session.target.displayName)", tableName: "UI")
                        .font(Theme.Fonts.summaryHeadline)
                        .foregroundStyle(Theme.ink)
                    Text("Counting names and sizes. Nothing is opened, moved or deleted.", tableName: "UI")
                        .font(Theme.Fonts.summaryBody)
                        .foregroundStyle(Theme.secondaryInk)
                }

                ScanProgressBar(fraction: session.progress?.fraction)
                    .frame(height: 14)
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Scan progress", table: "UI"))
                    .accessibilityValue(progressValue)
                    .accessibilityIdentifier("scan.progress")

                HStack(alignment: .firstTextBaseline, spacing: 36) {
                    figure(Format.count(session.progress?.itemsScanned ?? 0), caption: String(localized: "items", table: "UI"))
                    figure(Format.bytes(session.progress?.bytesScanned ?? 0), caption: String(localized: "counted so far", table: "UI"))
                    if let fraction = session.progress?.fraction {
                        figure(Format.percent(fraction), caption: String(localized: "of used space", table: "UI"))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Now reading", tableName: "UI")
                        .sectionLabelStyle()
                    Text(Format.abbreviatedPath(session.progress?.currentPath ?? session.target.url.path))
                        .font(Theme.Fonts.path)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("scan.currentPath")
                    if let stuck = session.progress?.unresponsiveFolders, stuck > 0 {
                        Label(String(localized: "\(stuck) folders are not responding. The scan goes on without them.", table: "UI"), systemImage: "hourglass")
                            .font(Theme.Fonts.callout)
                            .foregroundStyle(Theme.secondaryInk)
                            .accessibilityIdentifier("scan.unresponsive")
                    }
                }

                HStack {
                    Spacer()
                    Button(String(localized: "Cancel Scan", table: "UI")) {
                        session.cancel()
                        model.showStart()
                    }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("scan.cancel")
                }
            }
            .padding(32)
            .frame(width: 600)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .onAppear { DockProgress.show(fraction: session.progress?.fraction) }
        .onChange(of: session.progress?.fraction) { _, fraction in DockProgress.show(fraction: fraction) }
        .onDisappear { DockProgress.clear() }
    }

    private var progressValue: String {
        if let fraction = session.progress?.fraction { return Format.percent(fraction) }
        return String(localized: "In progress", table: "UI")
    }

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Fonts.figure)
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(caption)
                .font(Theme.Fonts.callout)
                .foregroundStyle(Theme.secondaryInk)
        }
    }
}

/// Determinate: light fills from the left. Indeterminate: a band of light sweeps across.
private struct ScanProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                if let fraction {
                    LightStripes()
                        .frame(width: max(proxy.size.width * fraction, proxy.size.height))
                        .clipShape(Capsule())
                        .animation(Theme.Motion.standard, value: fraction)
                } else {
                    TimelineView(.animation(paused: reduceMotion)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        LightStripes()
                            .frame(width: proxy.size.width * 0.3)
                            .clipShape(Capsule())
                            .offset(x: (proxy.size.width * 1.3) * phase - proxy.size.width * 0.3)
                    }
                    .clipShape(Capsule())
                }
            }
        }
    }
}
