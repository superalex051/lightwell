import Foundation
import Testing
@testable import IPCProtocol

@Suite("Tool catalog")
struct ToolCatalogTests {
    @Test func catalogMatchesPlanOrderAndNames() {
        #expect(ToolCatalog.all.map(\.name) == ToolName.allCases.map(\.rawValue))
        #expect(ToolCatalog.all.map(\.name) == [
            "get_disk_overview", "get_largest_items", "list_children", "get_category_summary",
            "inspect_path", "search_items", "get_cleanup_queue", "propose_deletion",
        ])
        #expect(Set(ToolCatalog.all.map(\.name)).count == 8)
    }

    @Test func allowedToolsArgumentIsExactPlanValue() {
        #expect(ToolCatalog.allowedToolsArgument == "mcp__disk__get_disk_overview mcp__disk__get_largest_items mcp__disk__list_children mcp__disk__get_category_summary mcp__disk__inspect_path mcp__disk__search_items mcp__disk__get_cleanup_queue mcp__disk__propose_deletion")
    }

    @Test func schemasDeclareTypesAndRequiredFields() {
        let required: [String: [String]] = [
            "list_children": ["path"],
            "inspect_path": ["path"],
            "propose_deletion": ["items", "summary"],
        ]
        for tool in ToolCatalog.all {
            #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
            #expect(tool.inputSchema["properties"]?.objectValue != nil, "\(tool.name)")
            let declared = tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(declared == (required[tool.name] ?? []), "\(tool.name)")
            #expect(!tool.description.isEmpty)
        }
        let largest = ToolCatalog.definition(named: "get_largest_items")!.inputSchema["properties"]!
        #expect(largest["limit"]?["minimum"] == 1)
        #expect(largest["limit"]?["maximum"] == 100)
        #expect(largest["limit"]?["default"] == 20)
        #expect(largest["kind"]?["enum"] == ["file", "directory", "any"])
        #expect(largest["scope"]?["default"] == "descendants")
        let children = ToolCatalog.definition(named: "list_children")!.inputSchema["properties"]!
        #expect(children["limit"]?["maximum"] == 200)
        #expect(children["limit"]?["default"] == 50)
        let search = ToolCatalog.definition(named: "search_items")!.inputSchema["properties"]!
        #expect(search["limit"]?["default"] == 30)
        #expect(Set(search.objectValue!.keys) == ["under", "name_glob", "extension", "min_bytes", "older_than_days", "limit", "cursor"])
        let items = ToolCatalog.definition(named: "propose_deletion")!.inputSchema["properties"]!["items"]!
        #expect(items["minItems"] == 1)
        #expect(items["maxItems"] == 50)
    }

    @Test func annotations() {
        for tool in ToolCatalog.all where tool.name != "propose_deletion" {
            #expect(tool.annotations["readOnlyHint"] == true, "\(tool.name)")
        }
        let propose = ToolCatalog.definition(named: "propose_deletion")!.annotations
        #expect(propose["readOnlyHint"] == false)
        #expect(propose["destructiveHint"] == false)
        #expect(propose["idempotentHint"] == true)
    }

    @Test func noDashesInModelFacingText() {
        let dashes: Set<Character> = ["\u{2013}", "\u{2014}"]
        var texts = ToolCatalog.all.map(\.description) + [ToolCatalog.proposalNote, ToolCatalog.appUnavailableText]
        for tool in ToolCatalog.all {
            let data = try! JSONEncoder().encode(tool.inputSchema)
            texts.append(String(decoding: data, as: UTF8.self))
        }
        for text in texts { #expect(!text.contains(where: dashes.contains), "\(text)") }
    }

    @Test func listEntryShape() {
        let entry = ToolCatalog.all[0].mcpListEntry
        #expect(Set(entry.objectValue!.keys) == ["name", "description", "inputSchema", "annotations"])
        #expect(ToolCatalog.all[0].qualifiedName == "mcp__disk__get_disk_overview")
    }
}

@Suite("Tool arguments")
struct ToolArgumentTests {
    @Test func defaultsAndClamping() throws {
        let empty = try ToolArguments.decode(GetLargestItemsArguments.self, from: .null)
        #expect(empty.limit == 20)
        #expect(empty.kind == .any)
        #expect(empty.scope == .descendants)
        let big = try ToolArguments.decode(GetLargestItemsArguments.self, from: ["limit": 5000, "min_bytes": 1024, "kind": "file", "path": "~/Library"])
        #expect(big.limit == 100)
        #expect(big.minBytes == 1024)
        #expect(big.kind == .file)
        #expect(big.path == "~/Library")
        let small = try ToolArguments.decode(ListChildrenArguments.self, from: ["path": "/", "limit": 0])
        #expect(small.limit == 1)
        #expect(small.sort == .size)
        let search = try ToolArguments.decode(SearchItemsArguments.self, from: ["extension": ".dmg", "older_than_days": 30, "name_glob": "*.dmg"])
        #expect(search.extension == "dmg")
        #expect(search.limit == 30)
        #expect(search.nameGlob == "*.dmg")
        #expect(search.olderThanDays == 30)
    }

    @Test func errorsAreReadable() {
        #expect(throws: ToolArgumentError("missing required argument path")) {
            try ToolArguments.decode(InspectPathArguments.self, from: [:])
        }
        #expect(throws: ToolArgumentError("wrong type for limit")) {
            try ToolArguments.decode(ListChildrenArguments.self, from: ["path": "/", "limit": "many"])
        }
        #expect(throws: ToolArgumentError("invalid value for kind")) {
            try ToolArguments.decode(GetLargestItemsArguments.self, from: ["kind": "socks"])
        }
        #expect(throws: ToolArgumentError("arguments must be a JSON object")) {
            try ToolArguments.decode(GetDiskOverviewArguments.self, from: [1, 2])
        }
        #expect(throws: ToolArgumentError("items must contain at least one path")) {
            try ToolArguments.decode(ProposeDeletionArguments.self, from: ["items": [], "summary": "x"])
        }
        let many: JSONValue = .array((0..<51).map { ["path": .string("/tmp/\($0)"), "reason": "r"] })
        #expect(throws: ToolArgumentError("items holds 51 paths, the limit is 50 per call")) {
            try ToolArguments.decode(ProposeDeletionArguments.self, from: ["items": many, "summary": "x"])
        }
    }

    @Test func proposeDecodes() throws {
        let args = try ToolArguments.decode(ProposeDeletionArguments.self, from: [
            "items": [["path": "~/Library/Caches/x", "reason": "cache"]],
            "summary": "One cache.",
        ])
        #expect(args.items == [ProposedPath(path: "~/Library/Caches/x", reason: "cache")])
        #expect(args.summary == "One cache.")
    }
}

@Suite("Tool output")
struct ToolOutputTests {
    @Test func resultsUseSnakeCaseKeys() {
        let item = ToolItem(path: "~/a", bytes: 10, freesBytes: 8, kind: "file", items: 0, ruleID: "caches", risk: "safe")
        #expect(ToolOutput.encode(item) == #"{"bytes":10,"frees_bytes":8,"items":0,"kind":"file","path":"~/a","risk":"safe","rule_id":"caches"}"#)
        let list = ToolItemList(items: [], nextCursor: "abc")
        #expect(ToolOutput.encode(list) == #"{"items":[],"next_cursor":"abc"}"#)
        let proposal = ProposeDeletionResult(queued: [QueuedProposal(path: "~/x", bytes: 1, risk: "safe")], rejected: [RejectedProposalEntry(path: "~/Library/Keychains", code: "protected", message: "no")])
        #expect(ToolOutput.encode(proposal) == #"{"note":"Nothing was deleted. The user reviews and confirms in the app.","queued":[{"bytes":1,"path":"~/x","risk":"safe"}],"rejected":[{"code":"protected","message":"no","path":"~/Library/Keychains"}]}"#)
        let overview = DiskOverviewResult(volume: "Macintosh HD", capacity: 1, used: 1, free: 0, purgeable: 0, otherVolumes: 0, hidden: 0, scannedRoot: "/", scanAgeSeconds: 5, fda: "granted", snapshotsCount: 2)
        let keys = try! JSONDecoder().decode(JSONValue.self, from: Data(ToolOutput.encode(overview).utf8)).objectValue!.keys
        #expect(Set(keys) == ["volume", "capacity", "used", "free", "purgeable", "other_volumes", "hidden", "scanned_root", "scan_age_s", "fda", "snapshots_count"])
    }

    @Test func pagingRespectsLimitBudgetAndCursor() throws {
        let items = (0..<500).map { ToolItem(path: "~/folder/item-\($0)-" + String(repeating: "x", count: 80), bytes: UInt64($0), freesBytes: 0, kind: "file", items: 0) }
        let first = try ToolOutput.page(items, cursor: nil, limit: 20, generation: 7)
        #expect(first.items.count == 20)
        let next = try #require(first.nextCursor)
        let second = try ToolOutput.page(items, cursor: next, limit: 20, generation: 7)
        #expect(second.items.first == items[20])

        let huge = try ToolOutput.page(items, cursor: nil, limit: 500, generation: 7)
        #expect(huge.items.count < 500)
        #expect(ToolOutput.encode(ToolItemList(items: huge.items, nextCursor: huge.nextCursor)).utf8.count <= ToolCatalog.maxResultBytes)

        #expect(throws: ToolArgumentError.self) { try ToolOutput.page(items, cursor: next, limit: 20, generation: 8) }
        #expect(throws: ToolArgumentError.self) { try ToolOutput.page(items, cursor: "garbage!", limit: 20, generation: 7) }

        let last = try ToolOutput.page(items, cursor: ToolCursor(offset: 495, generation: 7).token, limit: 20, generation: 7)
        #expect(last.items.count == 5)
        #expect(last.nextCursor == nil)
    }

    @Test func sizeLimitBackstop() {
        let small = ToolCallResult(text: String(repeating: "a", count: ToolCatalog.maxResultBytes), isError: false)
        #expect(ToolOutput.enforceSizeLimit(small) == small)
        let big = ToolOutput.enforceSizeLimit(ToolCallResult(text: String(repeating: "b", count: ToolCatalog.maxResultBytes + 1), isError: false))
        #expect(big.isError)
        #expect(big.text == "The result was too large to return (24577 bytes, the limit is 24576). Narrow the query: use a smaller limit, a more specific path or filter, or fetch the next page with cursor.")
        // Multi-byte text is measured in UTF-8 bytes.
        #expect(ToolOutput.enforceSizeLimit(ToolCallResult(text: String(repeating: "\u{00E9}", count: 13_000))).isError)
    }

    @Test func oversizedItemIsNotLetThrough() throws {
        let huge = ToolItem(path: "~/" + String(repeating: "deep/", count: 6000), bytes: 1, freesBytes: 1, kind: "directory", items: 0)
        let normal = ToolItem(path: "~/ok", bytes: 1, freesBytes: 1, kind: "file", items: 0)
        do {
            _ = try ToolOutput.page([huge, normal], cursor: nil, limit: 20, generation: 1)
            Issue.record("oversized first item was returned")
        } catch {
            #expect(error.message.hasPrefix("The item at position 0 is larger than the 24576 byte result limit"))
            let skip = ToolCursor(offset: 1, generation: 1).token
            #expect(error.message.contains(skip))
            let next = try ToolOutput.page([huge, normal], cursor: skip, limit: 20, generation: 1)
            #expect(next.items == [normal])
        }
        // An oversized item later in the list ends the page before it.
        let first = try ToolOutput.page([normal, huge], cursor: nil, limit: 20, generation: 1)
        #expect(first.items == [normal])
        #expect(first.nextCursor == ToolCursor(offset: 1, generation: 1).token)
    }

    @Test func cursorRoundTrip() {
        let cursor = ToolCursor(offset: 1234, generation: 99)
        #expect(ToolCursor(token: cursor.token) == cursor)
        #expect(!cursor.token.contains("="))
        #expect(ToolCursor(token: "") == nil)
    }

    @Test func pathConventions() {
        let home = "/Users/test"
        #expect(ToolPaths.expand("~", home: home) == "/Users/test")
        #expect(ToolPaths.expand("~/Library/Caches/", home: home) == "/Users/test/Library/Caches")
        #expect(ToolPaths.expand("/private/var/../tmp", home: home) == "/private/tmp")
        #expect(ToolPaths.expand("relative/path", home: home) == nil)
        #expect(ToolPaths.abbreviate("/Users/test/Downloads/a.dmg", home: home) == "~/Downloads/a.dmg")
        #expect(ToolPaths.abbreviate("/Users/test", home: home) == "~")
        #expect(ToolPaths.abbreviate("/Users/testing/x", home: home) == "/Users/testing/x")
        #expect(ToolPaths.abbreviate("/Applications", home: home + "/") == "/Applications")
    }
}
