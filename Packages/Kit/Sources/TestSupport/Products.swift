import Foundation

/// Package executables (`mcp-helper`, `fake-claude`, `scanbench`) for tests that spawn them.
///
/// Lookup order: `LIGHTWELL_PRODUCTS_DIR` (override), then the folder holding the running test bundle
/// (SwiftPM and Xcode put executables next to it, for any configuration or scratch path), then
/// `Packages/Kit/.build/debug` as a last resort.
public enum Products {
    private final class BundleToken {}

    public static func url(_ name: String) -> URL {
        for directory in candidateDirectories() {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return fallbackDirectory().appendingPathComponent(name)
    }

    static func candidateDirectories() -> [URL] {
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["LIGHTWELL_PRODUCTS_DIR"], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override))
        }
        let bundle = Bundle(for: BundleToken.self).bundleURL
        directories.append(bundle.deletingLastPathComponent())
        directories += Bundle.allBundles.map(\.bundleURL).filter { $0.pathExtension == "xctest" }.map { $0.deletingLastPathComponent() }
        directories.append(fallbackDirectory())
        return directories
    }

    private static func fallbackDirectory(file: StaticString = #filePath) -> URL {
        // Sources/TestSupport/Products.swift -> Packages/Kit
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug")
    }
}
