import Darwin
import XCTest

/// PLAN 5.4 UI numbers on a large synthetic fixture. Gated: run with `scripts/perf.sh ui`, which sets
/// `TEST_RUNNER_LIGHTWELL_UI_PERF=1` and attaches Instruments' Hangs instrument to the app.
///
/// Every accessibility query from the runner is answered on the app's main thread and shows up as
/// a hang of its own, so the test stays quiet in the windows the script measures and prints their
/// times as `PERF phase ...` lines (Unix seconds):
/// - `scan start` / `scan end`: 45 quiet seconds from the click on the fixture (the scan takes about 20 s);
/// - `drill <n>`: the Return that opens the 1M-node folder, followed by 3 quiet seconds.
final class PerfTests: E2ETestCase {
    /// home/big/d0000...d0999, 1000 empty files each, plus one 64 KB file per folder: 1,002,001 nodes.
    private static let folders = 1000
    private static let filesPerFolder = 1000

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LIGHTWELL_UI_PERF"] == "1" else {
            throw XCTSkip("UI perf tests run with scripts/perf.sh ui")
        }
        try super.setUpWithError()
        let big = fixture.home.appendingPathComponent("big", isDirectory: true)
        let block = Data(repeating: 0x5A, count: 65_536)
        for folder in 0..<Self.folders {
            let directory = big.appendingPathComponent(String(format: "d%04d", folder), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try block.write(to: directory.appendingPathComponent("payload.bin"))
            for file in 0..<Self.filesPerFolder {
                let path = directory.appendingPathComponent(String(format: "f%04d", file)).path
                let descriptor = Darwin.open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                Darwin.close(descriptor)
            }
        }
    }

    private func report(_ line: String) {
        print("PERF " + line)
        let note = XCTAttachment(string: line)
        note.lifetime = .keepAlways
        add(note)
    }

    private func phase(_ name: String) {
        report(String(format: "phase %@ %.3f", name, Date().timeIntervalSince1970))
    }

    @MainActor
    func testScanResponsivenessAndDrillIn() {
        launch()
        let row = element("start.recent.\(fixture.name)")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        let button = row.buttons.firstMatch.exists ? row.buttons.firstMatch : row
        // Give scripts/perf.sh time to attach Instruments before the scan starts.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        button.click()

        phase("scan start")
        RunLoop.current.run(until: Date().addingTimeInterval(45))
        phase("scan end")
        let finishedInWindow = element("explore.map").exists
        XCTAssertTrue(element("explore.map").waitForExistence(timeout: 120), "the 1M-item scan finished")
        report("scan of \(Self.folders * (Self.filesPerFolder + 2) + 1) items " + (finishedInWindow ? "finished inside the quiet window" : "was still running when the quiet window ended"))

        XCTAssertTrue(listRow("home").waitForExistence(timeout: 10))
        open("home")
        let big = listRow("big")
        XCTAssertTrue(big.waitForExistence(timeout: 10))
        for round in 1...3 {
            big.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            phase("drill \(round)")
            app.typeKey(.return, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertTrue(element("explore.list.smallerItems").waitForExistence(timeout: 30), "drill-in shows the 1000 folders (grouped as small items)")
            goBack(expecting: "big")
        }
    }
}
