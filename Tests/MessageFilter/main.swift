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
assert(strongest.action(for: "trusted sale") == .allow)
assert(strongest.action(for: "trusted") == .allow)
assert(strongest.action(for: "ordinary") == nil)
var reversed = original
reversed.groups.reverse()
assert(reversed.action(for: "trusted sale") == .dim)
assert(try! reversed.normalized().groups.map(\.id) == [1, 2])

// Every action, both strategies, equal-priority ordering, and album captions.
let actionPriority: [SGMessageFilterAction] = [.dim, .mask, .collapse, .hide, .allow]
for (priority, action) in actionPriority.enumerated() {
    let group = SGMessageFilterGroup(name: action.rawValue, action: action, keywords: ["match"])
    let configuration = SGMessageFilterConfiguration(groups: [group])
    assert(configuration.match(for: ["match"]) == SGMessageFilterMatch(action: action, groupName: action.rawValue))
    let encoded = try SGMessageFilterRuleFile.encode(configuration: configuration, format: .json)
    assert(try! SGMessageFilterRuleFile.decode(data: encoded, format: .json) == configuration)
    let text = try SGMessageFilterRuleFile.encode(configuration: configuration, format: .txt)
    assert(text == Data("match".utf8))
    assert(try! SGMessageFilterRuleFile.decode(data: text, format: .txt).groups[0].action == .dim)
    for (otherPriority, otherAction) in actionPriority.enumerated() {
        let other = SGMessageFilterGroup(id: 2, name: "Second", action: otherAction, keywords: ["match"])
        var pair = SGMessageFilterConfiguration(groups: [group, other])
        assert(pair.match(for: ["match"])?.groupName == group.name)
        pair.matchingMode = .strongest
        let expected = priority >= otherPriority ? group : other
        assert(pair.match(for: ["match"]) == SGMessageFilterMatch(action: expected.action, groupName: expected.name))
    }
}
let albumRules = SGMessageFilterConfiguration(matchingMode: .strongest, groups: [
    SGMessageFilterGroup(id: 1, name: "Hidden ads", action: .hide, keywords: ["广告📢", "跨行\n关键词"]),
    SGMessageFilterGroup(id: 2, name: "Trusted albums", action: .allow, keywords: ["trusted"])
])
assert(albumRules.match(for: ["ordinary", "广告📢"])?.action == .hide)
assert(albumRules.match(for: ["广告📢", "trusted"])?.action == .allow)
assert(albumRules.match(for: ["广告", "📢"]) == nil)
assert(albumRules.match(for: ["跨行", "关键词"]) == nil)
assert(albumRules.match(for: ["跨行\n关键词"])?.action == .hide)
assert(albumRules.match(for: []) == nil)
let combiningText = "e\u{301}"
let unicodeRules = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Unicode", action: .mask, keywords: [combiningText, "👨‍👩‍👧‍👦"])])
assert(unicodeRules.action(for: "prefix \(combiningText) suffix") == .mask)
assert(unicodeRules.action(for: "家庭👨‍👩‍👧‍👦") == .mask)
var orderedAlbumRules = albumRules
orderedAlbumRules.matchingMode = .firstMatch
assert(orderedAlbumRules.match(for: ["trusted", "广告📢"])?.groupName == "Hidden ads")

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

func testRegexMatching() {
    for (rule, text, expected) in [
        ("example.com", "exampleXcom", false),
        ("C++", "C++ guide", true),
        ("sale.*", "sale today", false),
        ("REGEX:sale.*", "sale today", false),
        ("REGEX:sale.*", "REGEX:sale.*", true),
        ("/sale/", "/sale/", true),
        (#"regex:\bsale\d+\b"#, "today sale123!", true),
        (#"regex:\bsale\d+\b"#, "wholesale123", false),
        (#"regex:\bsale\d+\b"#, "SALE123", false),
        ("regex:(?i)sale|promo", "PROMO", true),
        (#"regex:^📢广告\d+$"#, "📢广告42", true),
        (#"regex:^📢广告\d+$"#, "📢广告", false),
        ("regex:e\u{301}", "prefix e\u{301} suffix", true),
        ("regex:first.*second", "first\nsecond", false),
        ("regex:(?s)first.*second", "first\nsecond", true),
        ("regex:(?m)^sale$", "first\nsale\nlast", true),
        ("regex:^$", "", true),
        (#"regex:\d "#, "7 ", true),
        (#"regex:\d "#, "7", false),
        ("regex: ", " ", true),
        ("regex:[", "anything", false),
        ("regex:", "anything", false)
    ] {
        let configuration = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Rules", keywords: [rule])])
        assert((configuration.action(for: text) != nil) == expected, "Unexpected result for \(rule) in \(text)")
        assert(configuration.match(for: []) == nil)
    }
    let album = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Album", action: .hide, keywords: [#"regex:^📢广告\d+$"#, "literal.*"])])
    assert(album.match(for: ["ordinary", "📢广告42"])?.action == .hide)
    assert(album.match(for: ["📢广告", "42"]) == nil)
    assert(album.action(for: "literal.*") == .hide)
    assert(album.action(for: "literal text") == nil)
    for (priority, action) in actionPriority.enumerated() {
        for (otherPriority, otherAction) in actionPriority.enumerated() {
            let regex = SGMessageFilterGroup(name: "Regex", action: action, keywords: ["regex:^match$"])
            let literal = SGMessageFilterGroup(id: 2, name: "Literal", action: otherAction, keywords: ["match"])
            var configuration = SGMessageFilterConfiguration(groups: [regex, literal])
            assert(configuration.match(for: ["match"])?.groupName == "Regex")
            configuration.matchingMode = .strongest
            let expected = priority >= otherPriority ? regex : literal
            assert(configuration.match(for: ["match"]) == SGMessageFilterMatch(action: expected.action, groupName: expected.name))
        }
    }
    DispatchQueue.concurrentPerform(iterations: 40) { _ in
        let configuration = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Concurrent", keywords: ["regex:(?i)sale"])])
        assert(configuration.match(for: ["SALE"], deadline: .infinity)?.action == .dim)
    }
}

func testRegexFilesAndPersistence() throws {
    let rules = ["ordinary", #"regex:\d "#, "regex: lead ", "regex: ", #"regex:(?s)first\nsecond"#]
    let configuration = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Rules", keywords: rules)])
    assert(try! configuration.normalized().groups[0].keywords == rules)
    for format in [SGMessageFilterFileFormat.json, .txt] {
        let data = try SGMessageFilterRuleFile.encode(configuration: configuration, format: format)
        assert(try! SGMessageFilterRuleFile.decode(data: data, format: format, groupName: "Rules") == configuration)
    }
    let txt = Data("\u{feff} ordinary \r\nregex: lead \r\nregex: \r\n".utf8)
    assert(try! SGMessageFilterRuleFile.decode(data: txt, format: .txt).groups[0].keywords == ["ordinary", "regex: lead ", "regex: "])
    let multiline = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Multiline", keywords: ["regex:first\nsecond"])])
    let json = try SGMessageFilterRuleFile.encode(configuration: multiline, format: .json)
    assert(try! SGMessageFilterRuleFile.decode(data: json, format: .json) == multiline)
    expectError(.multilineKeyword) { _ = try SGMessageFilterRuleFile.encode(configuration: multiline, format: .txt) }
    let merged = configuration.merging(SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Rules", action: .allow, keywords: [rules[1], "regex:extra$"])]))
    assert(merged.groups[0].keywords == rules + ["regex:extra$"])
    assert(merged.groups[0].action == .dim)

    let suite = "MessageFilterRegexTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SGMessageFilterStore(userDefaults: defaults)
    try store.update(configuration)
    assert(SGMessageFilterStore(userDefaults: defaults).configuration == configuration)
    let saved = defaults.data(forKey: "messageFilterGroups")
    for rule in ["regex:", "regex:[", "regex:(", #"regex:\"#] {
        assert(SGMessageFilterRule.validationError(for: rule) == .invalidRegularExpression(rule))
        let invalid = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Invalid", keywords: [rule])])
        expectError(.invalidRegularExpression(rule)) { try store.update(invalid) }
        for format in [SGMessageFilterFileFormat.json, .txt] {
            let data = try SGMessageFilterRuleFile.encode(configuration: invalid, format: format)
            expectError(.invalidRegularExpression(rule)) { _ = try SGMessageFilterRuleFile.decode(data: data, format: format) }
        }
        assert(store.configuration == configuration)
        assert(defaults.data(forKey: "messageFilterGroups") == saved)
    }
    // Selected text must stay literal even if it looks like a prefixed expression.
    let selection = #"regex:a+b["#
    assert(try! store.appendKeywords([selection, selection], toGroupNamed: "Rules", defaultGroupName: "Default") == 1)
    assert(try! store.appendKeywords([selection], toGroupNamed: "Rules", defaultGroupName: "Default") == 0)
    let selectedRule = store.configuration.groups[0].keywords.last!
    assert(selectedRule == "regex:" + NSRegularExpression.escapedPattern(for: selection))
    let selected = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Selection", keywords: [selectedRule])])
    assert(selected.action(for: selection) == .dim)
    assert(selected.action(for: "regex:aaab[") == nil)
    assert(try! SGMessageFilterRuleFile.decode(data: SGMessageFilterRuleFile.encode(configuration: selected, format: .txt), format: .txt).action(for: selection) == .dim)

    // Old invalid expressions stay visible and individually removable; valid prefixes activate.
    let old = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Old", keywords: ["regex:[", "regex:(", "regex:^sale$"])])
    let oldData = try SGMessageFilterRuleFile.encode(configuration: old, format: .json)
    defaults.set(oldData, forKey: "messageFilterGroups")
    let loaded = SGMessageFilterStore(userDefaults: defaults)
    assert(loaded.loadError == nil)
    assert(loaded.configuration == old)
    assert(defaults.data(forKey: "messageFilterGroups") == oldData)
    assert(loaded.configuration.action(for: "sale") == .dim)
    assert(loaded.configuration.action(for: "regex:[") == nil)
    var edited = loaded.configuration
    edited.groups[0].name = "Renamed"
    try loaded.update(edited)
    edited.groups[0].keywords.removeFirst()
    try loaded.update(edited)
    assert(loaded.configuration.groups[0].keywords == ["regex:(", "regex:^sale$"])
    edited.groups[0].keywords[0] = "regex:repaired"
    try loaded.update(edited)
    assert(SGMessageFilterStore(userDefaults: defaults).configuration == edited)
    defaults.removeObject(forKey: "messageFilterGroups")
    defaults.set(["regex:[", "regex:^legacy$"], forKey: "messageFilterKeywords")
    let legacy = SGMessageFilterStore(userDefaults: defaults)
    assert(legacy.loadError == nil)
    assert(legacy.configuration.action(for: "legacy") == .dim)
    assert(legacy.configuration.groups[0].keywords.first == "regex:[")
}

func testRegexDeadline() {
    let expired = ProcessInfo.processInfo.systemUptime - 1.0
    var configuration = SGMessageFilterConfiguration(groups: [
        SGMessageFilterGroup(name: "Literal", action: .hide, keywords: ["match"]),
        SGMessageFilterGroup(id: 2, name: "Regex", action: .allow, keywords: ["regex:^match$"])
    ])
    assert(configuration.match(for: ["match"], deadline: expired) == nil)
    configuration.matchingMode = .strongest
    assert(configuration.match(for: ["match"], deadline: expired) == nil)
    assert(configuration.match(for: ["match"], deadline: .infinity)?.action == .allow)
    // A partial hide result must be discarded when a later expression times out.
    configuration.groups[0].keywords = ["!"]
    configuration.groups[1].keywords = ["regex:^(a+)+$"]
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + SGMessageFilterRule.matchingTimeLimit
    assert(configuration.match(for: [String(repeating: "a", count: 80) + "!"], deadline: deadline) == nil)
    assert(ProcessInfo.processInfo.systemUptime >= deadline)
    assert(ProcessInfo.processInfo.systemUptime - start < 2.0)
    assert(configuration.match(for: ["!"], deadline: deadline) == nil)
}

func testRegexUnicodeIdentity() throws {
    let composed = "regex:^\u{e9}$"
    let decomposed = "regex:^e\u{301}$"
    assert(composed == decomposed) // Swift equality alone must not deduplicate these ICU patterns.
    for (rule, matching, other) in [(composed, "\u{e9}", "e\u{301}"), (decomposed, "e\u{301}", "\u{e9}")] {
        let configuration = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Unicode", keywords: [rule])])
        assert(configuration.action(for: matching) == .dim)
        assert(configuration.action(for: other) == nil)
    }
    let first = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Unicode", keywords: [composed])])
    let second = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Unicode", keywords: [decomposed])])
    assert(first != second)
    let merged = first.merging(second)
    assert(merged.groups[0].keywords.count == 2)
    var duplicates = merged
    duplicates.groups[0].keywords += [composed, decomposed]
    assert(try! duplicates.normalized() == merged)
    for format in [SGMessageFilterFileFormat.json, .txt] {
        let encoded = try SGMessageFilterRuleFile.encode(configuration: duplicates, format: format)
        let decoded = try SGMessageFilterRuleFile.decode(data: encoded, format: format, groupName: "Unicode")
        assert(decoded == merged)
        assert(decoded.groups[0].keywords.map { Data($0.utf8) } == [Data(composed.utf8), Data(decomposed.utf8)])
    }
    let literal = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Literal", keywords: ["\u{e9}", "e\u{301}"])])
    assert(try! literal.normalized().groups[0].keywords.count == 1)

    let suite = "MessageFilterUnicodeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SGMessageFilterStore(userDefaults: defaults)
    try store.update(first)
    let counter = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(forName: SGMessageFilterStore.didChange, object: store, queue: nil) { _ in counter.increment() }
    defer { NotificationCenter.default.removeObserver(observer) }
    try store.update(second)
    assert(counter.value == 1)
    assert(SGMessageFilterStore(userDefaults: defaults).configuration == second)
    try store.update(merged)
    var removed = store.configuration
    let removedIDs = Set([SGMessageFilterRule.identity(composed)])
    removed.groups[0].keywords.removeAll { removedIDs.contains(SGMessageFilterRule.identity($0)) }
    try store.update(removed)
    assert(store.configuration == second)

    // A combining mark joins the prefix's colon into one grapheme, but remains part of the pattern.
    let combining = "regex:\u{301}"
    let configuration = SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: "Combining", keywords: [combining])])
    assert(configuration.hasRegularExpressions)
    assert(SGMessageFilterRule.validationError(for: combining) == nil)
    assert(configuration.action(for: "e\u{301}") == .dim)
    assert(configuration.action(for: "plain") == nil)
    let selected = combining + "[+"
    assert(try! store.appendKeywords([selected], toGroupNamed: "Unicode", defaultGroupName: "Default") == 1)
    let selectedRule = store.configuration.groups[0].keywords.last!
    assert(Data(selectedRule.utf8) == Data(("regex:" + NSRegularExpression.escapedPattern(for: selected)).utf8))
    assert(store.configuration.action(for: selected) == .dim)
}

testRegexMatching()
try testRegexFilesAndPersistence()
testRegexDeadline()
try testRegexUnicodeIdentity()

print("Message filter matching, regex deadlines, groups, JSON/TXT codecs, limits, merging, migration, persistence and keyword selection checks passed.")
