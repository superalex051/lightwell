import AppCore
import SwiftUI

/// Single-window routing: Start, then Scanning, then the session (Overview, Explore, Reclaim, Cleanup).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let session = model.activeSession {
                switch session.state {
                case .idle, .scanning:
                    ScanningView(session: session)
                        .transition(.opacity)
                case .finished:
                    SessionView(session: session)
                        .id(session.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                case .failed, .cancelled:
                    StartView()
                }
            } else {
                StartView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.page, value: routeKey)
        .frame(minWidth: 940, minHeight: 620)
        .background(Theme.window)
        .tint(Theme.ink)
        .onChange(of: model.activeSession?.state) { _, state in
            guard state == .finished, let session = model.activeSession, let tree = session.tree else { return }
            ScanNotifications.scanFinished(name: session.target.displayName, bytes: tree.size(tree.root), model: model)
        }
    }

    private var routeKey: String {
        guard let session = model.activeSession else { return "start" }
        return "\(session.id)-\(session.state == .finished)"
    }
}
