// Scan benchmark (PLAN 5.4). Read only: it scans and reports, it never changes anything.
//
//   scanbench <path> [--json] [--workers N] [--no-dedupe-clones] [--sweep] [--volume] [--exclude PATH]...
//   scanbench <path> --refresh-watch SECONDS [--inject-drop-at SECONDS]
//
// Reports nodes, wall seconds, peak phys_footprint, bytes per node and total bytes.
// --sweep runs the scan with 8, 16, 32 and 48 workers. --volume adds the space summary of the
// volume (scanned + hidden + other volumes versus used).
import Darwin
import Foundation
import ScanKit
import Synchronization

struct Arguments {
    var path = FileManager.default.currentDirectoryPath
    var json = false
    var workers: Int?
    var countClonesOnce = true
    var sweep = false
    var volume = false
    var excluded: [String] = []
    /// Seconds to wait before exiting (to inspect memory with vmmap or footprint).
    var pause: UInt32 = 0
    /// Seconds to keep a `TreeRefresher` running after the scan, logging every refresh decision.
    var refreshWatch: Int?
    /// Seconds after the refresher starts at which a dropped-events notice is fed to it.
    var injectDropAt: Double?

    init(_ raw: [String]) {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--json": json = true
            case "--no-dedupe-clones": countClonesOnce = false
            case "--sweep": sweep = true
            case "--volume": volume = true
            case "--refresh-watch":
                if let value = iterator.next(), let seconds = Int(value) { refreshWatch = seconds }
            case "--inject-drop-at":
                if let value = iterator.next(), let seconds = Double(value) { injectDropAt = seconds }
            case "--pause":
                if let value = iterator.next(), let seconds = UInt32(value) { pause = seconds }
            case "--exclude":
                if let value = iterator.next() { excluded.append((value as NSString).expandingTildeInPath) }
            case "--workers":
                if let value = iterator.next(), let count = Int(value) { workers = count }
            default:
                if !argument.hasPrefix("--") { path = (argument as NSString).expandingTildeInPath }
            }
        }
    }
}

func physFootprint() -> (current: UInt64, peak: UInt64) {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { return (0, 0) }
    return (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
}

struct RunResult {
    var workers: Int?
    var seconds: Double
    var tree: ScanTree?
    var error: ScanError?
}

func runScan(path: String, workers: Int?, countClonesOnce: Bool, excluded: [String]) async -> RunResult {
    let scanner = Scanner(ScanOptions(
        root: URL(fileURLWithPath: path), workers: workers, countClonesOnce: countClonesOnce, excludedPaths: excluded
    ))
    let clock = ContinuousClock()
    let started = clock.now
    var tree: ScanTree?
    var failure: ScanError?
    for await event in scanner.start() {
        switch event {
        case .finished(let finished): tree = finished
        case .failed(let error): failure = error
        case .progress: break
        }
    }
    let elapsed = clock.now - started
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return RunResult(workers: workers, seconds: seconds, tree: tree, error: failure)
}

func format(_ value: Double) -> String { String(format: "%.2f", value) }

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let baseline = physFootprint().current

/// Scans `path`, then keeps it current with a `TreeRefresher` for `seconds`, printing each refresh
/// decision with a timestamp and a summary at the end. Read only.
func refreshWatch(path: String, seconds: Int, injectDropAt: Double?) async {
    let result = await runScan(path: path, workers: nil, countClonesOnce: true, excluded: [])
    guard let tree = result.tree else {
        FileHandle.standardError.write(Data("scan failed: \(String(describing: result.error))\n".utf8))
        exit(1)
    }
    print("scan: \(tree.statistics().nodes) nodes in \(format(result.seconds)) s")
    let started = Date()
    let refresher = TreeRefresher(tree: tree, root: URL(fileURLWithPath: path))
    let plainEvents = Mutex(0)
    refresher.setTrace { line in
        // Plain directory events (no flags) are only counted; everything else is printed.
        if line.hasPrefix("event flags=0x0 ") {
            plainEvents.withLock { $0 += 1 }
            return
        }
        let plain = plainEvents.withLock { count in defer { count = 0 }; return count }
        let stamp = String(format: "%7.2f", Date().timeIntervalSince(started))
        if plain > 0 { print("[\(stamp)] (\(plain) plain directory events)") }
        print("[\(stamp)] \(line)")
    }
    let usageBefore = rusageCPU()
    refresher.start()
    if let injectDropAt {
        Task {
            try? await Task.sleep(for: .seconds(injectDropAt))
            print("[\(String(format: "%7.2f", Date().timeIntervalSince(started)))] injecting a dropped-events notice")
            refresher.injectDroppedEvents()
        }
    }
    let counter = Task {
        var updated = 0, restructured = 0, stale = 0
        for await event in refresher.events {
            switch event {
            case .updated(let generation, let paths):
                updated += 1
                print("[\(String(format: "%7.2f", Date().timeIntervalSince(started)))] updated generation=\(generation) paths=\(paths.count)")
            case .restructured(let epoch):
                restructured += 1
                print("[\(String(format: "%7.2f", Date().timeIntervalSince(started)))] restructured epoch=\(epoch)")
            case .fullRescanPending(let at):
                print("[\(String(format: "%7.2f", Date().timeIntervalSince(started)))] full rescan pending at=\(at.map { String(format: "+%.0f s", $0.timeIntervalSinceNow) } ?? "none")")
            case .stale(let reason):
                stale += 1
                print("[\(String(format: "%7.2f", Date().timeIntervalSince(started)))] stale \(reason)")
            }
        }
        return (updated, restructured, stale)
    }
    try? await Task.sleep(for: .seconds(seconds))
    refresher.stop()
    let (updated, restructured, stale) = await counter.value
    let cpu = rusageCPU() - usageBefore
    print("summary: seconds=\(seconds) updated=\(updated) restructured=\(restructured) stale=\(stale) cpuSeconds=\(format(cpu)) nodes=\(tree.statistics().nodes) peakFootprintMB=\(physFootprint().peak / 1_048_576)")
}

func rusageCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

if let seconds = arguments.refreshWatch {
    await refreshWatch(path: arguments.path, seconds: seconds, injectDropAt: arguments.injectDropAt)
    exit(0)
}

if arguments.sweep {
    var rows: [[String: Any]] = []
    for workers in [8, 16, 32, 48] {
        let result = await runScan(path: arguments.path, workers: workers, countClonesOnce: arguments.countClonesOnce, excluded: arguments.excluded)
        let nodes = result.tree?.statistics().nodes ?? 0
        rows.append(["workers": workers, "seconds": result.seconds, "nodes": nodes])
        if !arguments.json {
            print("workers \(workers): \(format(result.seconds)) s, \(nodes) nodes")
        }
    }
    if arguments.json, let data = try? JSONSerialization.data(withJSONObject: ["sweep": rows], options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

let result = await runScan(path: arguments.path, workers: arguments.workers, countClonesOnce: arguments.countClonesOnce, excluded: arguments.excluded)
guard let tree = result.tree else {
    FileHandle.standardError.write(Data("scan failed: \(String(describing: result.error))\n".utf8))
    exit(1)
}
let footprint = physFootprint()
let stats = tree.statistics()
let total = tree.size(tree.root)
let peakDelta = footprint.peak > baseline ? footprint.peak - baseline : 0
var report: [String: Any] = [
    "path": tree.rootPath,
    "nodes": stats.nodes,
    "directories": stats.directories,
    "files": stats.files,
    "symlinks": stats.symlinks,
    "restricted": stats.restricted,
    "mountPoints": stats.mountPoints,
    "hardLinkGroups": stats.hardLinkGroups,
    "cloneFamilies": stats.cloneFamilies,
    "seconds": result.seconds,
    "totalBytes": total,
    "treeBytes": stats.storageBytes,
    "treeBytesPerNode": Double(stats.storageBytes) / Double(max(stats.nodes, 1)),
    "peakFootprintBytes": footprint.peak,
    "currentFootprintBytes": footprint.current,
    "baselineFootprintBytes": baseline,
    "peakFootprintBytesPerNode": Double(peakDelta) / Double(max(stats.nodes, 1)),
    "footprintBudgetBytes": 100 * 1_048_576 + 64 * stats.nodes,
    "countClonesOnce": arguments.countClonesOnce,
    "excluded": arguments.excluded,
]
if arguments.volume, let volume = VolumeCatalog.volume(containing: URL(fileURLWithPath: arguments.path)) {
    let summary = SpaceSummary.compute(volume, scanned: total)
    let accounted = summary.scanned + summary.hidden + summary.otherVolumes
    report["volume"] = [
        "capacity": summary.capacity, "used": summary.used, "free": summary.free, "purgeable": summary.purgeable,
        "otherVolumes": summary.otherVolumes, "scanned": summary.scanned, "hidden": summary.hidden,
        "accountedMinusUsed": Int64(bitPattern: accounted &- summary.used),
    ]
}

if arguments.json {
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else {
    print("path: \(tree.rootPath)")
    print("nodes: \(stats.nodes) (\(stats.directories) dirs, \(stats.files) files, \(stats.symlinks) symlinks, \(stats.restricted) restricted)")
    print("seconds: \(format(result.seconds))")
    print("total bytes: \(total)")
    print("tree bytes: \(stats.storageBytes) (\(format(Double(stats.storageBytes) / Double(max(stats.nodes, 1)))) B/node)")
    print("peak phys_footprint: \(footprint.peak) bytes (\(format(Double(peakDelta) / Double(max(stats.nodes, 1)))) B/node over baseline)")
    var zones = malloc_statistics_t()
    malloc_zone_statistics(nil, &zones)
    print("current phys_footprint: \(footprint.current) bytes (malloc in use \(zones.size_in_use), allocated \(zones.size_allocated))")
    print("budget (100 MB + 64 B/node): \(100 * 1_048_576 + 64 * stats.nodes) bytes")
    print("hard-link groups: \(stats.hardLinkGroups), clone families: \(stats.cloneFamilies)")
    if let volume = report["volume"] { print("volume: \(volume)") }
}

if arguments.pause > 0 {
    print("pid \(getpid()) pausing \(arguments.pause) s")
    sleep(arguments.pause)
}
