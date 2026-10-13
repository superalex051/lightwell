import Foundation
import Synchronization

/// Options for one scan. Frozen contract (PLAN 4.3).
public struct ScanOptions: Sendable {
    public var root: URL
    /// Worker thread count; `nil` picks the default for the volume (32 SSD, 4 rotational or network).
    public var workers: Int?
    /// `nil` picks allocated for local volumes and logical for network volumes.
    public var sizeMode: SizeMode?
    public var countClonesOnce: Bool
    public var excludedPaths: [String]

    public init(
        root: URL,
        workers: Int? = nil,
        sizeMode: SizeMode? = nil,
        countClonesOnce: Bool = true,
        excludedPaths: [String] = []
    ) {
        self.root = root
        self.workers = workers
        self.sizeMode = sizeMode
        self.countClonesOnce = countClonesOnce
        self.excludedPaths = excludedPaths
    }
}

/// Progress snapshot, published at most 10 times per second.
public struct ScanProgress: Sendable, Hashable {
    /// 0...1 when known, `nil` while indeterminate.
    public var fraction: Double?
    public var itemsScanned: UInt64
    public var bytesScanned: UInt64
    public var currentPath: String
    /// Folders the watchdog gave up on so far ("some folders did not respond"). Added by WS1.
    public var unresponsiveFolders: Int

    public init(fraction: Double?, itemsScanned: UInt64, bytesScanned: UInt64, currentPath: String, unresponsiveFolders: Int = 0) {
        self.fraction = fraction
        self.itemsScanned = itemsScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
        self.unresponsiveFolders = unresponsiveFolders
    }
}

public enum ScanError: Error, Sendable, Hashable {
    case rootNotFound(path: String)
    case rootNotReadable(path: String, errno: Int32)
    /// No progress for 30 s and nothing scanned at all (watchdog). When part of the tree was
    /// scanned, stuck folders are flagged `notResponding` instead and the scan finishes.
    case notResponding(path: String)
    case cancelled
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanTree)
    case failed(ScanError)
}

/// Multi-threaded `getattrlistbulk` scanner. Frozen contract (PLAN 4.3).
///
/// `start()` runs the scan on dedicated threads (never the cooperative pool) and yields progress
/// at most 10 times per second, then `.finished(tree)` or `.failed(error)`. `cancel()` stops the
/// scan within about 100 ms; stopping iteration of the stream cancels too.
public final class Scanner: Sendable {
    public let options: ScanOptions
    private let state = Mutex<State>(State())

    private struct State: ~Copyable {
        var cancelled = false
        /// Every running engine (`start()` may be called more than once); `cancel()` stops all.
        var engines: [ObjectIdentifier: ScanEngine] = [:]
    }

    public init(_ o: ScanOptions) {
        options = o
    }

    public func start() -> AsyncStream<ScanEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ScanEvent.self)
        let alreadyCancelled = state.withLock { $0.cancelled }
        if alreadyCancelled {
            continuation.yield(.failed(.cancelled))
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [self] reason in
            if case .cancelled = reason { cancel() }
        }
        let thread = Thread { [self] in
            let result = run { continuation.yield(.progress($0)) }
            switch result {
            case .success(let tree):
                continuation.yield(.progress(ScanProgress(
                    fraction: 1,
                    itemsScanned: UInt64(tree.descendantCount(tree.root)),
                    bytesScanned: tree.size(tree.root),
                    currentPath: tree.rootPath,
                    unresponsiveFolders: tree.unresponsiveNodes.count
                )))
                continuation.yield(.finished(tree))
            case .failure(let error):
                continuation.yield(.failed(error))
            }
            continuation.finish()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        return stream
    }

    /// Runs the scan on the calling thread (blocking). Used by `start()` and by refreshes.
    func run(progress: ((ScanProgress) -> Void)? = nil) -> Result<ScanTree, ScanError> {
        let config: EngineConfig
        switch EngineConfig.resolve(options) {
        case .success(let resolved): config = resolved
        case .failure(let error): return .failure(error)
        }
        return run(config: config, progress: progress)
    }

    func run(config: EngineConfig, progress: ((ScanProgress) -> Void)? = nil) -> Result<ScanTree, ScanError> {
        let engine = ScanEngine(config: config)
        let key = ObjectIdentifier(engine)
        let cancelled = state.withLock { state -> Bool in
            state.engines[key] = engine
            return state.cancelled
        }
        defer { state.withLock { _ = $0.engines.removeValue(forKey: key) } }
        if cancelled { return .failure(.cancelled) }
        return engine.run(progress: progress)
    }

    public func cancel() {
        let engines = state.withLock { state -> [ScanEngine] in
            state.cancelled = true
            return Array(state.engines.values)
        }
        for engine in engines { engine.cancel() }
    }
}
