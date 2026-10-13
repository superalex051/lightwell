import Foundation
import Testing
@testable import RulesKit

@Suite("rules.json")
struct RulesJSONTests {
    let rules = (try? RuleLoader.loadBundled()) ?? []

    /// One id per R3 B1 row (rows with several tools are split per tool), plus the extra
    /// browser-profile and core-dump rules.
    static let expectedIDs: [String: Risk] = [
        "caches.user": .safe, "caches.apple": .review, "caches.icloud": .review,
        "xcode.deriveddata": .safe, "xcode.archives": .review, "xcode.devicesupport": .safe,
        "simulator.unavailable": .safe, "simulator.devices": .review, "simulator.runtimes": .review,
        "simulator.caches": .safe, "xcode.previews": .safe, "xcode.caches": .safe,
        "npm.cache": .safe, "yarn.cache": .safe, "pnpm.store": .safe, "bun.cache": .safe,
        "homebrew.cache": .safe, "pip.cache": .safe, "uv.cache": .safe, "poetry.cache": .safe,
        "gradle.cache": .review, "maven.repository": .review, "cargo.registry": .review,
        "go.buildcache": .safe, "go.modcache": .review, "cocoapods.cache": .safe, "swiftpm.cache": .safe,
        "docker.disk": .review, "orbstack.data": .review, "ai.models": .review, "dev.artifacts": .review,
        "trash.items": .review, "downloads.items": .review, "downloads.installers": .review,
        "ios.backups": .dangerous, "mail.downloads": .safe, "messages.attachments": .never,
        "photos.library": .dangerous, "icloud.drive": .never, "cloud.providers": .never,
        "timemachine.snapshots": .review, "system.purgeable": .review, "logs.user": .safe,
        "logs.system": .review, "app.leftovers": .review, "app.languagefiles": .never,
        "apps.installed": .review, "apps.xcode": .review, "system.memoryfiles": .never,
        "system.tempitems": .never, "browser.profiles": .dangerous, "system.coredumps": .review,
    ]

    @Test func everyB1RowIsPresentWithItsRisk() {
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        for (id, risk) in Self.expectedIDs {
            #expect(byID[id]?.risk == risk, "rule \(id)")
        }
        #expect(Set(byID.keys) == Set(Self.expectedIDs.keys))
    }

    @Test func idsAreUniqueAndTextIsClean() {
        #expect(Set(rules.map(\.id)).count == rules.count)
        for rule in rules {
            #expect(!rule.title.isEmpty && !rule.explanation.isEmpty, "\(rule.id)")
            for text in [rule.title, rule.explanation, rule.commandHint ?? ""] {
                #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(rule.id) has a dash")
            }
        }
    }

    @Test func rawFileHasNoDashes() throws {
        let url = try #require(RuleLoader.bundledURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
    }

    @Test func schemaRoundTrips() throws {
        let data = try JSONEncoder().encode(RulesFile(version: 1, rules: rules))
        let back = try RuleLoader.decode(data)
        #expect(back == rules)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((json["rules"] as? [[String: Any]])?.first)
        #expect(first["category"] != nil)
        #expect((first["action"] as? [String: Any])?["type"] as? String == "trash")
    }

    @Test func detectorsAndGuides() {
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        #expect(byID["dev.artifacts"]?.detector == .devArtifacts)
        #expect(byID["downloads.installers"]?.detector == .oldInstallers)
        #expect(byID["downloads.installers"]?.minAgeDays == 30)
        #expect(byID["xcode.devicesupport"]?.keepNewest == 1)
        #expect(byID["xcode.deriveddata"]?.requiredQuitApps == ["com.apple.dt.Xcode"])
        for rule in rules where rule.risk >= .dangerous {
            #expect(rule.action == .guide, "\(rule.id)")
        }
    }

    // MARK: Validator

    func rule(_ id: String = "x.y", risk: Risk = .safe, title: String = "T", explanation: String = "E",
              match: [RuleMatch] = [RuleMatch(path: "~/x", kind: .subtree)], action: RuleAction = .trash,
              detector: RuleDetector? = nil, keepNewest: Int? = nil, minAgeDays: Int? = nil) -> Rule {
        Rule(id: id, categoryID: "c", risk: risk, title: title, explanation: explanation, match: match, action: action,
             minAgeDays: minAgeDays, keepNewest: keepNewest, detector: detector)
    }

    @Test func validatorCatchesProblems() {
        #expect(RuleValidator.validate([rule()]).isEmpty)
        let cases: [[Rule]] = [
            [rule(), rule()],                                           // duplicate id
            [rule(title: " ")],                                         // empty title
            [rule(explanation: "")],                                    // empty explanation
            [rule(title: "Caches \u{2014} all")],                       // em dash
            [rule(explanation: "a \u{2013} b")],                        // en dash
            [rule(match: [RuleMatch(path: "~/a/*", kind: .subtree)])],  // glob in subtree
            [rule(match: [RuleMatch(path: "~/a", kind: .glob)])],       // glob without *
            [rule(match: [RuleMatch(path: "a/b", kind: .exact)])],      // relative
            [rule(match: [RuleMatch(path: "~/a/../b", kind: .exact)])], // dot dot
            [rule(match: [])],                                          // trash without match
            [rule(risk: .never)],                                       // never must be guide
            [rule(risk: .dangerous)],                                   // dangerous must be guide
            [rule(detector: .devArtifacts)],                            // detector with match
            [rule(keepNewest: 0)],
            [rule(minAgeDays: 0)],
            [rule(match: [], detector: .oldInstallers)],                // oldInstallers needs minAgeDays
            [rule("Bad ID")],
            [Rule(id: "g.p", categoryID: "c", risk: .review, title: "T", explanation: "E",     // guide with a precondition
                  match: [RuleMatch(path: "~/x", kind: .exact)], action: .guide,
                  preconditions: [.appNotRunning(bundleID: "com.example")])],
        ]
        for rules in cases {
            #expect(!RuleValidator.validate(rules).isEmpty, "\(rules.map(\.id))")
        }
    }

    @Test func decodeRejectsUnknownVersionAndPrecondition() {
        let badVersion = Data(#"{"version": 2, "rules": []}"#.utf8)
        #expect(throws: RuleLoadError.self) { try RuleLoader.decode(badVersion) }
        let badPrecondition = Data(#"""
        {"version": 1, "rules": [{"id": "a.b", "category": "c", "risk": "safe", "title": "T", "explanation": "E",
          "match": [{"path": "~/x", "kind": "subtree"}], "action": {"type": "trash"},
          "preconditions": [{"type": "diskIsFast"}]}]}
        """#.utf8)
        #expect(throws: DecodingError.self) { try RuleLoader.decode(badPrecondition) }
        let invalid = Data(#"""
        {"version": 1, "rules": [{"id": "a.b", "category": "c", "risk": "never", "title": "T", "explanation": "E",
          "match": [{"path": "~/x", "kind": "subtree"}], "action": {"type": "trash"}}]}
        """#.utf8)
        #expect(throws: RuleLoadError.self) { try RuleLoader.decode(invalid) }
    }
}
