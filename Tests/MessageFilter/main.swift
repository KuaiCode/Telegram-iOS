import Foundation

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

print("Message filter matching, groups, JSON/TXT codecs, limits, merging, migration and persistence checks passed.")
