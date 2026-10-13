import Foundation

public enum SGMessageFilterAction: String, Codable, CaseIterable {
    case dim
    case allow
    case collapse
    case hide
    case mask

    public var localizationKey: String {
        switch self {
        case .dim: return "MessageFilter.Action.Dim"
        case .allow: return "MessageFilter.Action.Allow"
        case .collapse: return "MessageFilter.Action.Collapse"
        case .hide: return "MessageFilter.Action.Hide"
        case .mask: return "MessageFilter.Action.Mask"
        }
    }

    private var priority: Int {
        switch self {
        case .allow: return 4
        case .hide: return 3
        case .collapse: return 2
        case .mask: return 1
        case .dim: return 0
        }
    }

    fileprivate func takesPriority(over other: SGMessageFilterAction) -> Bool {
        return self.priority > other.priority
    }
}

public struct SGMessageFilterMatch: Equatable {
    public let action: SGMessageFilterAction
    public let groupName: String

    public init(action: SGMessageFilterAction, groupName: String) {
        self.action = action
        self.groupName = groupName
    }
}

public enum SGMessageFilterMatchingMode: String, Codable, CaseIterable {
    case firstMatch
    case strongest
}

public enum SGMessageFilterFileFormat: String, CaseIterable {
    case json
    case txt
}

public enum SGMessageFilterRuleFileError: Error, Equatable {
    case invalidFile
    case unsupportedFormat
    case fileTooLarge
    case emptyGroupName
    case duplicateGroupName
    case invalidGroupID
    case duplicateGroupID
    case emptyKeyword
    case multilineKeyword
    case invalidRegularExpression(String)
    case unreadableStoredConfiguration
}

public enum SGMessageFilterKeywordError: Error, Equatable {
    case targetGroupMissing
}

public enum SGMessageFilterRule {
    public static let regularExpressionPrefix = "regex:"
    public static let matchingTimeLimit: TimeInterval = 0.05

    private final class CompiledExpression {
        let expression: NSRegularExpression?

        init(pattern: String) {
            self.expression = pattern.isEmpty ? nil : (try? NSRegularExpression(pattern: pattern))
        }
    }

    private static let expressions: NSCache<NSData, CompiledExpression> = {
        let cache = NSCache<NSData, CompiledExpression>()
        cache.countLimit = 256
        return cache
    }()

    public static func isRegularExpression(_ rule: String) -> Bool {
        return rule.utf8.starts(with: regularExpressionPrefix.utf8)
    }

    public static func identity(_ rule: String) -> Data {
        // ICU distinguishes canonically equivalent patterns; literal keywords keep Swift's equality.
        return Data((isRegularExpression(rule) ? rule : rule.precomposedStringWithCanonicalMapping).utf8)
    }

    public static func normalized(_ rule: String) -> String {
        return isRegularExpression(rule) ? rule : rule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expression(for rule: String) -> NSRegularExpression? {
        let key = identity(rule) as NSData
        if let cached = expressions.object(forKey: key) {
            return cached.expression
        }
        let pattern = String(decoding: rule.utf8.dropFirst(regularExpressionPrefix.utf8.count), as: UTF8.self)
        let cached = CompiledExpression(pattern: pattern)
        expressions.setObject(cached, forKey: key)
        return cached.expression
    }

    public static func validationError(for rule: String) -> SGMessageFilterRuleFileError? {
        if isRegularExpression(rule), expression(for: rule) == nil {
            return .invalidRegularExpression(rule)
        }
        return nil
    }

    // nil means evaluation could not finish; the entire message must remain visible.
    fileprivate static func matches(_ rule: String, texts: [String], deadline: TimeInterval) -> Bool? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        guard !rule.isEmpty else { return false }
        guard isRegularExpression(rule) else {
            return texts.contains(where: { $0.contains(rule) })
        }
        guard let expression = expression(for: rule) else { return false }
        for text in texts {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var matched = false
            var interrupted = false
            // shortcut: progress callbacks give an approximate deadline; strict isolation would require a different engine.
            expression.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex ..< text.endIndex, in: text)) { result, flags, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline || flags.contains(.internalError) {
                    interrupted = true
                    stop.pointee = true
                } else if result != nil {
                    matched = true
                    stop.pointee = true
                }
            }
            guard !interrupted, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            if matched { return true }
        }
        return false
    }
}

public struct SGMessageFilterGroup: Codable, Equatable {
    public var id: Int
    public var name: String
    public var action: SGMessageFilterAction
    public var keywords: [String]

    public init(id: Int = 1, name: String, action: SGMessageFilterAction = .dim, keywords: [String] = []) {
        self.id = id
        self.name = name
        self.action = action
        self.keywords = keywords
    }

    public static func == (lhs: SGMessageFilterGroup, rhs: SGMessageFilterGroup) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.action == rhs.action
            && lhs.keywords.map(SGMessageFilterRule.identity) == rhs.keywords.map(SGMessageFilterRule.identity)
    }
}

public struct SGMessageFilterConfiguration: Codable, Equatable {
    public var matchingMode: SGMessageFilterMatchingMode
    public var groups: [SGMessageFilterGroup]

    public init(matchingMode: SGMessageFilterMatchingMode = .firstMatch, groups: [SGMessageFilterGroup] = []) {
        self.matchingMode = matchingMode
        self.groups = groups
    }

    public func action(for text: String) -> SGMessageFilterAction? {
        return self.match(for: [text])?.action
    }

    public var hasRegularExpressions: Bool {
        return groups.contains(where: { $0.keywords.contains(where: SGMessageFilterRule.isRegularExpression) })
    }

    public func match(for texts: [String], deadline: TimeInterval? = nil) -> SGMessageFilterMatch? {
        let deadline = deadline ?? (hasRegularExpressions ? ProcessInfo.processInfo.systemUptime + SGMessageFilterRule.matchingTimeLimit : .infinity)
        var result: SGMessageFilterMatch?
        for group in groups {
            var matched = false
            for keyword in group.keywords {
                guard let matches = SGMessageFilterRule.matches(keyword, texts: texts, deadline: deadline) else { return nil }
                if matches {
                    matched = true
                    break
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            guard matched else { continue }
            let match = SGMessageFilterMatch(action: group.action, groupName: group.name)
            if matchingMode == .firstMatch {
                return match
            }
            if result == nil || group.action.takesPriority(over: result!.action) {
                result = match
            }
        }
        return result
    }

    public func normalized() throws -> SGMessageFilterConfiguration {
        var result = self
        var names = Set<String>()
        for index in result.groups.indices {
            let name = result.groups[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw SGMessageFilterRuleFileError.emptyGroupName }
            guard names.insert(name).inserted else { throw SGMessageFilterRuleFileError.duplicateGroupName }
            result.groups[index].id = index + 1
            result.groups[index].name = name
            var seen = Set<Data>()
            var keywords: [String] = []
            for keyword in result.groups[index].keywords {
                let keyword = SGMessageFilterRule.normalized(keyword)
                guard !keyword.isEmpty else { throw SGMessageFilterRuleFileError.emptyKeyword }
                if seen.insert(SGMessageFilterRule.identity(keyword)).inserted {
                    keywords.append(keyword)
                }
            }
            result.groups[index].keywords = keywords
        }
        return result
    }

    public func merging(_ imported: SGMessageFilterConfiguration) -> SGMessageFilterConfiguration {
        var result = self
        var indices: [String: Int] = [:]
        for (index, group) in result.groups.enumerated() {
            indices[group.name] = index
        }
        for group in imported.groups {
            if let index = indices[group.name] {
                var seen = Set(result.groups[index].keywords.map(SGMessageFilterRule.identity))
                result.groups[index].keywords.append(contentsOf: group.keywords.filter { seen.insert(SGMessageFilterRule.identity($0)).inserted })
            } else {
                indices[group.name] = result.groups.count
                result.groups.append(group)
            }
        }
        for index in result.groups.indices {
            result.groups[index].id = index + 1
        }
        return result
    }
}

public enum SGMessageFilterRuleFile {
    public static let maximumFileSize = 1024 * 1024

    public static func read(url: URL) throws -> Data {
        guard let stream = InputStream(url: url) else { throw SGMessageFilterRuleFileError.invalidFile }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumFileSize {
            let length = min(buffer.count, maximumFileSize + 1 - data.count)
            let count = stream.read(&buffer, maxLength: length)
            guard count >= 0 else { throw SGMessageFilterRuleFileError.invalidFile }
            if count == 0 {
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw SGMessageFilterRuleFileError.fileTooLarge
    }

    public static func decode(data: Data, format: SGMessageFilterFileFormat, groupName: String = "Imported") throws -> SGMessageFilterConfiguration {
        guard data.count <= maximumFileSize else { throw SGMessageFilterRuleFileError.fileTooLarge }
        let configuration: SGMessageFilterConfiguration
        switch format {
        case .json:
            configuration = try decodeStored(data: data)
        case .txt:
            guard var text = String(data: data, encoding: .utf8) else { throw SGMessageFilterRuleFileError.invalidFile }
            if text.hasPrefix("\u{feff}") {
                text.removeFirst()
            }
            let keywords = text.components(separatedBy: .newlines).map {
                SGMessageFilterRule.normalized($0)
            }.filter { !$0.isEmpty }
            configuration = try SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: groupName, keywords: keywords)]).normalized()
        }
        for group in configuration.groups {
            for rule in group.keywords {
                if let error = SGMessageFilterRule.validationError(for: rule) { throw error }
            }
        }
        return configuration
    }

    // Stored invalid expressions stay editable; imports must pass the stricter decode above.
    fileprivate static func decodeStored(data: Data) throws -> SGMessageFilterConfiguration {
        guard data.count <= maximumFileSize else { throw SGMessageFilterRuleFileError.fileTooLarge }
        var configuration: SGMessageFilterConfiguration
        do {
            configuration = try JSONDecoder().decode(SGMessageFilterConfiguration.self, from: data)
        } catch {
            throw SGMessageFilterRuleFileError.invalidFile
        }
        var ids = Set<Int>()
        for group in configuration.groups {
            guard group.id > 0 else { throw SGMessageFilterRuleFileError.invalidGroupID }
            guard ids.insert(group.id).inserted else { throw SGMessageFilterRuleFileError.duplicateGroupID }
        }
        configuration.groups.sort { $0.id < $1.id }
        return try configuration.normalized()
    }

    public static func encode(configuration: SGMessageFilterConfiguration, format: SGMessageFilterFileFormat) throws -> Data {
        let configuration = try configuration.normalized()
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(configuration)
        case .txt:
            var seen = Set<Data>()
            var keywords: [String] = []
            for group in configuration.groups {
                for keyword in group.keywords {
                    guard keyword.rangeOfCharacter(from: .newlines) == nil else { throw SGMessageFilterRuleFileError.multilineKeyword }
                    if seen.insert(SGMessageFilterRule.identity(keyword)).inserted {
                        keywords.append(keyword)
                    }
                }
            }
            data = Data(keywords.joined(separator: "\n").utf8)
        }
        guard data.count <= maximumFileSize else { throw SGMessageFilterRuleFileError.fileTooLarge }
        return data
    }
}

public final class SGMessageFilterStore: NSObject {
    public static let didChange = Notification.Name("SGMessageFilterStoreDidChange")
    private static let configurationKey = "messageFilterGroups"
    private static let lastUsedGroupKey = "messageFilterLastUsedGroupName"
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    private var cachedConfiguration: SGMessageFilterConfiguration
    public let loadError: SGMessageFilterRuleFileError?

    public init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        do {
            if let stored = userDefaults.object(forKey: Self.configurationKey) {
                guard let data = stored as? Data else { throw SGMessageFilterRuleFileError.invalidFile }
                self.cachedConfiguration = try SGMessageFilterRuleFile.decodeStored(data: data)
            } else {
                let keywords: [String]
                if let legacy = userDefaults.object(forKey: "messageFilterKeywords") {
                    guard let legacy = legacy as? [String] else { throw SGMessageFilterRuleFileError.invalidFile }
                    keywords = legacy
                } else {
                    keywords = []
                }
                let groups = keywords.isEmpty ? [] : [SGMessageFilterGroup(name: "Default", keywords: keywords)]
                let configuration = try SGMessageFilterConfiguration(groups: groups).normalized()
                let data = try SGMessageFilterRuleFile.encode(configuration: configuration, format: .json)
                userDefaults.set(data, forKey: Self.configurationKey)
                self.cachedConfiguration = configuration
            }
            self.loadError = nil
        } catch {
            self.cachedConfiguration = SGMessageFilterConfiguration()
            self.loadError = .unreadableStoredConfiguration
        }
        super.init()
    }

    public var configuration: SGMessageFilterConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return cachedConfiguration
    }

    public var lastUsedGroupName: String? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.string(forKey: Self.lastUsedGroupKey)
    }

    public var preferredKeywordGroup: SGMessageFilterGroup? {
        lock.lock()
        defer { lock.unlock() }
        let groups = cachedConfiguration.groups
        if let name = userDefaults.string(forKey: Self.lastUsedGroupKey), let group = groups.first(where: { $0.name == name }) {
            return group
        }
        return groups.first(where: { $0.action == .dim }) ?? groups.first
    }

    public static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords.compactMap { keyword in
            let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !keyword.isEmpty && seen.insert(keyword).inserted ? keyword : nil
        }
    }

    public func appendKeywords(_ keywords: [String], toGroupNamed groupName: String?, defaultGroupName: String) throws -> Int {
        let keywords = Self.normalizedKeywords(keywords).map { keyword in
            return SGMessageFilterRule.isRegularExpression(keyword)
                ? SGMessageFilterRule.regularExpressionPrefix + NSRegularExpression.escapedPattern(for: keyword)
                : keyword
        }
        guard !keywords.isEmpty else { return 0 }
        let addedCount: Int
        do {
            lock.lock()
            defer { lock.unlock() }
            if let loadError = loadError {
                throw loadError
            }
            var updated = cachedConfiguration
            let index: Int
            if let groupName = groupName, let existingIndex = updated.groups.firstIndex(where: { $0.name == groupName }) {
                index = existingIndex
            } else if groupName == nil && updated.groups.isEmpty {
                updated.groups.append(SGMessageFilterGroup(name: defaultGroupName))
                index = 0
            } else {
                throw SGMessageFilterKeywordError.targetGroupMissing
            }
            let existing = Set(updated.groups[index].keywords.map(SGMessageFilterRule.identity))
            let additions = keywords.filter { !existing.contains(SGMessageFilterRule.identity($0)) }
            guard !additions.isEmpty else { return 0 }
            updated.groups[index].keywords.append(contentsOf: additions)
            _ = try updateLocked(updated)
            userDefaults.set(cachedConfiguration.groups[index].name, forKey: Self.lastUsedGroupKey)
            addedCount = additions.count
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return addedCount
    }

    public func renameLastUsedGroup(from oldName: String, to newName: String) {
        lock.lock()
        defer { lock.unlock() }
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldName != newName, userDefaults.string(forKey: Self.lastUsedGroupKey) == oldName, cachedConfiguration.groups.contains(where: { $0.name == newName }) {
            userDefaults.set(newName, forKey: Self.lastUsedGroupKey)
        }
    }

    public func update(_ configuration: SGMessageFilterConfiguration) throws {
        let changed: Bool
        do {
            lock.lock()
            defer { lock.unlock() }
            changed = try updateLocked(configuration)
        }
        if changed {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private func updateLocked(_ configuration: SGMessageFilterConfiguration) throws -> Bool {
        if let loadError = loadError {
            throw loadError
        }
        let configuration = try configuration.normalized()
        let data = try SGMessageFilterRuleFile.encode(configuration: configuration, format: .json)
        let existing = Set(cachedConfiguration.groups.flatMap { $0.keywords }.map(SGMessageFilterRule.identity))
        for group in configuration.groups {
            for rule in group.keywords where !existing.contains(SGMessageFilterRule.identity(rule)) {
                if let error = SGMessageFilterRule.validationError(for: rule) { throw error }
            }
        }
        let changed = configuration != cachedConfiguration
        if changed {
            userDefaults.set(data, forKey: Self.configurationKey)
            cachedConfiguration = configuration
        }
        return changed
    }
}
