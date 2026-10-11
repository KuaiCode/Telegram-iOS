import Foundation
import Dispatch

func expectError(_ expected: SGMessageFilterRuleFileError, _ body: () throws -> Void) {
    do {
        try body()
        assertionFailure("Expected \(expected)")
    } catch let error as SGMessageFilterRuleFileError {
        assert(error == expected, "Expected \(expected), got \(error)")
    } catch {
        assertionFailure("Unexpected error: \(error)")
    }
}

final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class ConcurrentKeywordAppends: @unchecked Sendable {
    let store: SGMessageFilterStore

    init(store: SGMessageFilterStore) {
        self.store = store
    }

    func append(_ index: Int) {
        do {
            let count = try store.appendKeywords(["concurrent-\(index)"], toGroupNamed: "Ads", defaultGroupName: "Default")
            assert(count == 1)
        } catch {
            assertionFailure("Concurrent append failed: \(error)")
        }
    }
}

func expectMissingKeywordGroup(_ body: () throws -> Void) {
    do {
        try body()
        assertionFailure("Expected missing keyword group")
    } catch let error as SGMessageFilterKeywordError {
        assert(error == .targetGroupMissing)
    } catch {
        assertionFailure("Unexpected error: \(error)")
    }
}

let allow = SGMessageFilterGroup(id: 1, name: "Trusted", action: .allow, keywords: ["trusted"])
let dim = SGMessageFilterGroup(id: 2, name: "Ads", keywords: ["sale", "Sale", "推广"])
let original = SGMessageFilterConfiguration(groups: [allow, dim])
assert(original.action(for: "trusted sale") == .allow)
assert(original.action(for: "sale") == .dim)
assert(original.action(for: "SALE") == nil)
assert(original.action(for: "这是推广消息") == .dim)
assert(original.action(for: "") == nil)
var strongest = original
strongest.matchingMode = .strongest
assert(strongest.action(for: "trusted sale") == .dim)
assert(strongest.action(for: "trusted") == .allow)
assert(strongest.action(for: "ordinary") == nil)
var reversed = original
reversed.groups.reverse()
assert(reversed.action(for: "trusted sale") == .dim)
assert(try! reversed.normalized().groups.map(\.id) == [1, 2])

let json = try SGMessageFilterRuleFile.encode(configuration: original, format: .json)
assert(try! SGMessageFilterRuleFile.decode(data: json, format: .json) == original)
let jsonText = String(data: json, encoding: .utf8)!
assert(!jsonText.contains("version"))
let escaped = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "中文规则", keywords: ["广告📢", "\"quoted\"", "https://example.test/path", "a\\b"])])
for format in [SGMessageFilterFileFormat.json, .txt] {
    let encoded = try SGMessageFilterRuleFile.encode(configuration: escaped, format: format)
    assert(try! SGMessageFilterRuleFile.decode(data: encoded, format: format, groupName: "中文规则") == escaped)
}
let outOfOrder = Data(#"{"matchingMode":"firstMatch","groups":[{"id":9,"name":"Later","action":"dim","keywords":[" b ","b","B"]},{"id":2,"name":" Earlier ","action":"allow","keywords":["a"]}]}"#.utf8)
let ordered = try SGMessageFilterRuleFile.decode(data: outOfOrder, format: .json)
assert(ordered.groups.map(\.id) == [1, 2])
assert(ordered.groups.map(\.name) == ["Earlier", "Later"])
assert(ordered.groups[1].keywords == ["b", "B"])
let singleGroup = try SGMessageFilterRuleFile.decode(data: SGMessageFilterRuleFile.encode(configuration: SGMessageFilterConfiguration(groups: [dim]), format: .json), format: .json)
assert(singleGroup.groups[0].id == 1)

let txt = Data("\u{feff} sale\r\nsale\rSale\n\n 推广 \r\n".utf8)
let importedText = try SGMessageFilterRuleFile.decode(data: txt, format: .txt, groupName: " Rules ")
assert(importedText.matchingMode == .firstMatch)
assert(importedText.groups == [SGMessageFilterGroup(name: "Rules", keywords: ["sale", "Sale", "推广"])])
assert(try! SGMessageFilterRuleFile.encode(configuration: importedText, format: .txt) == Data("sale\nSale\n推广".utf8))
let acrossGroups = SGMessageFilterConfiguration(groups: [dim, SGMessageFilterGroup(id: 2, name: "Other", action: .allow, keywords: ["sale", "extra"])])
assert(try! acrossGroups.normalized().groups[1].keywords == ["sale", "extra"])
assert(try! SGMessageFilterRuleFile.encode(configuration: acrossGroups, format: .txt) == Data("sale\nSale\n推广\nextra".utf8))
let empty = SGMessageFilterConfiguration()
assert(try! SGMessageFilterRuleFile.decode(data: SGMessageFilterRuleFile.encode(configuration: empty, format: .json), format: .json) == empty)
assert(try! SGMessageFilterRuleFile.encode(configuration: empty, format: .txt).isEmpty)
assert(try! SGMessageFilterRuleFile.decode(data: Data(), format: .txt).groups[0].keywords.isEmpty)

let imported = SGMessageFilterConfiguration(matchingMode: .strongest, groups: [
    SGMessageFilterGroup(id: 1, name: "Ads", action: .allow, keywords: ["sale", "extra"]),
    SGMessageFilterGroup(id: 2, name: "New", action: .allow, keywords: ["new"])
])
let merged = original.merging(imported)
assert(merged.matchingMode == .firstMatch)
assert(merged.groups.map(\.name) == ["Trusted", "Ads", "New"])
assert(merged.groups.map(\.id) == [1, 2, 3])
assert(merged.groups[1].action == .dim)
assert(merged.groups[1].keywords == ["sale", "Sale", "推广", "extra"])
assert(merged.groups[2].action == .allow)

expectError(.invalidFile) { _ = try SGMessageFilterRuleFile.decode(data: Data("{".utf8), format: .json) }
expectError(.invalidFile) { _ = try SGMessageFilterRuleFile.decode(data: Data("[]".utf8), format: .json) }
expectError(.invalidFile) { _ = try SGMessageFilterRuleFile.decode(data: Data([0xff]), format: .txt) }
for invalid in [jsonText.replacingOccurrences(of: "firstMatch", with: "unknown"), jsonText.replacingOccurrences(of: "dim", with: "unknown")] {
    expectError(.invalidFile) { _ = try SGMessageFilterRuleFile.decode(data: Data(invalid.utf8), format: .json) }
}
expectError(.emptyGroupName) { _ = try SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: " \n")]).normalized() }
expectError(.duplicateGroupName) { _ = try SGMessageFilterConfiguration(groups: [dim, SGMessageFilterGroup(name: " Ads ")]).normalized() }
expectError(.emptyKeyword) { _ = try SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Empty", keywords: [" \n"])]).normalized() }
let duplicateIDs = Data(#"{"matchingMode":"firstMatch","groups":[{"id":1,"name":"A","action":"dim","keywords":[]},{"id":1,"name":"B","action":"dim","keywords":[]}]}"#.utf8)
expectError(.duplicateGroupID) { _ = try SGMessageFilterRuleFile.decode(data: duplicateIDs, format: .json) }
let invalidID = Data(#"{"matchingMode":"firstMatch","groups":[{"id":0,"name":"A","action":"dim","keywords":[]}]}"#.utf8)
expectError(.invalidGroupID) { _ = try SGMessageFilterRuleFile.decode(data: invalidID, format: .json) }
let multiline = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Multiline", keywords: ["first\nsecond"])])
assert(try! SGMessageFilterRuleFile.decode(data: SGMessageFilterRuleFile.encode(configuration: multiline, format: .json), format: .json) == multiline)
expectError(.multilineKeyword) { _ = try SGMessageFilterRuleFile.encode(configuration: multiline, format: .txt) }

let maximum = SGMessageFilterRuleFile.maximumFileSize
let boundaryData = Data(repeating: 0x61, count: maximum)
let tooLarge = Data(repeating: 0x61, count: maximum + 1)
assert(try! SGMessageFilterRuleFile.decode(data: boundaryData, format: .txt).groups[0].keywords[0].utf8.count == maximum)
expectError(.fileTooLarge) { _ = try SGMessageFilterRuleFile.decode(data: tooLarge, format: .txt) }
expectError(.fileTooLarge) { _ = try SGMessageFilterRuleFile.encode(configuration: SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Large", keywords: [String(repeating: "a", count: maximum + 1)])]), format: .txt) }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MessageFilterTests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("rules.txt")
try boundaryData.write(to: file)
assert(try! SGMessageFilterRuleFile.read(url: file) == boundaryData)
try tooLarge.write(to: file)
expectError(.fileTooLarge) { _ = try SGMessageFilterRuleFile.read(url: file) }
expectError(.invalidFile) { _ = try SGMessageFilterRuleFile.read(url: directory.appendingPathComponent("missing")) }

let suiteName = "MessageFilterTests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
defaults.set(["sale", "Sale"], forKey: "messageFilterKeywords")
let store = SGMessageFilterStore(userDefaults: defaults)
assert(store.loadError == nil)
assert(store.configuration.groups == [SGMessageFilterGroup(name: "Default", keywords: ["sale", "Sale"])])
assert(defaults.stringArray(forKey: "messageFilterKeywords") == ["sale", "Sale"])
let notifications = NotificationCounter()
let observer = NotificationCenter.default.addObserver(forName: SGMessageFilterStore.didChange, object: store, queue: nil) { notification in
    if let changedStore = notification.object as? SGMessageFilterStore {
        notifications.increment()
        assert(changedStore.configuration.groups.first?.name == "Trusted")
    }
}
try store.update(original)
try store.update(original)
NotificationCenter.default.post(name: SGMessageFilterStore.didChange, object: NSObject())
NotificationCenter.default.removeObserver(observer)
assert(notifications.value == 1)
assert(SGMessageFilterStore(userDefaults: defaults).configuration == original)
expectError(.emptyGroupName) { try store.update(SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: " ")])) }
assert(store.configuration == original)
try store.update(empty)
assert(SGMessageFilterStore(userDefaults: defaults).configuration == empty)
let corruptData = Data("not json".utf8)
defaults.set(corruptData, forKey: "messageFilterGroups")
let corrupt = SGMessageFilterStore(userDefaults: defaults)
assert(corrupt.loadError == .unreadableStoredConfiguration)
assert(corrupt.configuration == empty)
expectError(.unreadableStoredConfiguration) { try corrupt.update(original) }
assert(defaults.data(forKey: "messageFilterGroups") == corruptData)
expectError(.unreadableStoredConfiguration) { _ = try corrupt.appendKeywords(["new"], toGroupNamed: nil, defaultGroupName: "Default") }
assert(defaults.data(forKey: "messageFilterGroups") == corruptData)
assert(corrupt.lastUsedGroupName == nil)

func testKeywordSelection() throws {
    let suite = "MessageFilterKeywordTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SGMessageFilterStore(userDefaults: defaults)
    let initialData = defaults.data(forKey: "messageFilterGroups")
    assert(store.preferredKeywordGroup == nil)
    assert(store.lastUsedGroupName == nil)
    assert(try! store.appendKeywords([" \n", ""], toGroupNamed: nil, defaultGroupName: "默认") == 0)
    assert(store.configuration.groups.isEmpty)
    assert(defaults.data(forKey: "messageFilterGroups") == initialData)
    assert(store.lastUsedGroupName == nil)
    expectMissingKeywordGroup { _ = try store.appendKeywords(["new"], toGroupNamed: "Deleted", defaultGroupName: "Default") }
    expectError(.emptyGroupName) { _ = try store.appendKeywords(["new"], toGroupNamed: nil, defaultGroupName: " ") }
    assert(defaults.data(forKey: "messageFilterGroups") == initialData)
    let selected = [" 汉字 ", "📢", "e\u{301}", "first\nsecond", "SALE", "sale", "汉字", " \n"]
    assert(try! store.appendKeywords(selected, toGroupNamed: nil, defaultGroupName: " 默认 ") == 6)
    assert(store.configuration.groups == [SGMessageFilterGroup(name: "默认", keywords: ["汉字", "📢", "e\u{301}", "first\nsecond", "SALE", "sale"])])
    assert(store.configuration.groups[0].keywords[2].utf8.elementsEqual("e\u{301}".utf8))
    assert(store.lastUsedGroupName == "默认")
    assert(SGMessageFilterStore(userDefaults: defaults).lastUsedGroupName == "默认")
    assert(store.preferredKeywordGroup?.name == "默认")
    assert(SGMessageFilterStore.normalizedKeywords(selected) == store.configuration.groups[0].keywords)

    defaults.set("Other", forKey: "messageFilterLastUsedGroupName")
    let noOpData = defaults.data(forKey: "messageFilterGroups")
    let changes = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(forName: SGMessageFilterStore.didChange, object: store, queue: nil) { _ in
        changes.increment()
    }
    assert(try! store.appendKeywords([" 汉字 ", "📢", "é", "\n"], toGroupNamed: "默认", defaultGroupName: "Default") == 0)
    assert(try! store.appendKeywords([" "], toGroupNamed: nil, defaultGroupName: "Default") == 0)
    NotificationCenter.default.removeObserver(observer)
    assert(changes.value == 0)
    assert(defaults.data(forKey: "messageFilterGroups") == noOpData)
    assert(store.lastUsedGroupName == "Other")
    assert(store.preferredKeywordGroup?.name == "默认")

    let initial = SGMessageFilterConfiguration(groups: [
        SGMessageFilterGroup(name: "Trusted", action: .allow, keywords: ["trusted"]),
        SGMessageFilterGroup(name: "Ads", keywords: ["sale"])
    ])
    try store.update(initial)
    assert(store.preferredKeywordGroup?.name == "Ads")
    defaults.set("Trusted", forKey: "messageFilterLastUsedGroupName")
    assert(store.preferredKeywordGroup?.name == "Trusted")
    var latest = store.configuration
    latest.matchingMode = .strongest
    latest.groups.append(SGMessageFilterGroup(name: "AddedWhileOpen", keywords: ["current"]))
    try store.update(latest)
    assert(try! store.appendKeywords(["new", "new"], toGroupNamed: "Ads", defaultGroupName: "Default") == 1)
    assert(store.configuration.matchingMode == .strongest)
    assert(store.configuration.groups.map(\.name) == ["Trusted", "Ads", "AddedWhileOpen"])
    assert(store.configuration.groups[1].keywords == ["sale", "new"])
    assert(store.configuration.groups[2].keywords == ["current"])
    assert(store.lastUsedGroupName == "Ads")

    let concurrent = ConcurrentKeywordAppends(store: store)
    DispatchQueue.concurrentPerform(iterations: 16) { index in
        concurrent.append(index)
    }
    assert(Set(store.configuration.groups[1].keywords) == Set(["sale", "new"] + (0..<16).map { "concurrent-\($0)" }))
    let beforeFailure = store.configuration
    let dataBeforeFailure = defaults.data(forKey: "messageFilterGroups")
    expectError(.fileTooLarge) {
        _ = try store.appendKeywords([String(repeating: "x", count: SGMessageFilterRuleFile.maximumFileSize + 1)], toGroupNamed: "Trusted", defaultGroupName: "Default")
    }
    assert(store.configuration == beforeFailure)
    assert(defaults.data(forKey: "messageFilterGroups") == dataBeforeFailure)
    assert(store.lastUsedGroupName == "Ads")

    var renamed = store.configuration
    renamed.groups[1].name = " Promotions "
    try store.update(renamed)
    store.renameLastUsedGroup(from: "Ads", to: " Promotions ")
    assert(store.lastUsedGroupName == "Promotions")
    assert(store.preferredKeywordGroup?.name == "Promotions")
    store.renameLastUsedGroup(from: "Promotions", to: "Missing")
    assert(store.lastUsedGroupName == "Promotions")
    var invalidRename = store.configuration
    invalidRename.groups[1].name = "Trusted"
    expectError(.duplicateGroupName) { try store.update(invalidRename) }
    assert(store.lastUsedGroupName == "Promotions")
    try store.update(SGMessageFilterConfiguration(groups: [initial.groups[0]]))
    assert(store.preferredKeywordGroup?.name == "Trusted")
    let afterDelete = defaults.data(forKey: "messageFilterGroups")
    expectMissingKeywordGroup { _ = try store.appendKeywords(["stale"], toGroupNamed: "Promotions", defaultGroupName: "Default") }
    expectMissingKeywordGroup { _ = try store.appendKeywords(["stale"], toGroupNamed: nil, defaultGroupName: "Default") }
    assert(defaults.data(forKey: "messageFilterGroups") == afterDelete)
    assert(store.lastUsedGroupName == "Promotions")
    defaults.removeObject(forKey: "messageFilterLastUsedGroupName")
    assert(store.lastUsedGroupName == nil)
    assert(store.preferredKeywordGroup?.name == "Trusted")
}

try testKeywordSelection()

print("Message filter matching, groups, JSON/TXT codecs, limits, merging, migration, persistence and keyword selection checks passed.")
