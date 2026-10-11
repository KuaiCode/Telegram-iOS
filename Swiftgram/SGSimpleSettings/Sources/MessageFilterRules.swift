import Foundation

public enum SGMessageFilterAction: String, Codable, CaseIterable {
    case dim
    case allow
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
    case unreadableStoredConfiguration
}

public enum SGMessageFilterKeywordError: Error, Equatable {
    case targetGroupMissing
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
}

public struct SGMessageFilterConfiguration: Codable, Equatable {
    public var matchingMode: SGMessageFilterMatchingMode
    public var groups: [SGMessageFilterGroup]

    public init(matchingMode: SGMessageFilterMatchingMode = .firstMatch, groups: [SGMessageFilterGroup] = []) {
        self.matchingMode = matchingMode
        self.groups = groups
    }

    public func action(for text: String) -> SGMessageFilterAction? {
        var result: SGMessageFilterAction?
        for group in groups where group.keywords.contains(where: { !$0.isEmpty && text.contains($0) }) {
            if matchingMode == .firstMatch || group.action == .dim {
                return group.action
            }
            result = group.action
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
            var seen = Set<String>()
            var keywords: [String] = []
            for keyword in result.groups[index].keywords {
                let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else { throw SGMessageFilterRuleFileError.emptyKeyword }
                if seen.insert(keyword).inserted {
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
                var seen = Set(result.groups[index].keywords)
                result.groups[index].keywords.append(contentsOf: group.keywords.filter { seen.insert($0).inserted })
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
        switch format {
        case .json:
            let configuration: SGMessageFilterConfiguration
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
            var result = configuration
            result.groups.sort { $0.id < $1.id }
            return try result.normalized()
        case .txt:
            guard var text = String(data: data, encoding: .utf8) else { throw SGMessageFilterRuleFileError.invalidFile }
            if text.hasPrefix("\u{feff}") {
                text.removeFirst()
            }
            let keywords = text.components(separatedBy: .newlines).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            return try SGMessageFilterConfiguration(groups: [SGMessageFilterGroup(name: groupName, keywords: keywords)]).normalized()
        }
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
            var seen = Set<String>()
            var keywords: [String] = []
            for group in configuration.groups {
                for keyword in group.keywords {
                    guard keyword.rangeOfCharacter(from: .newlines) == nil else { throw SGMessageFilterRuleFileError.multilineKeyword }
                    if seen.insert(keyword).inserted {
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
                self.cachedConfiguration = try SGMessageFilterRuleFile.decode(data: data, format: .json)
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
        let keywords = Self.normalizedKeywords(keywords)
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
            let existing = Set(updated.groups[index].keywords)
            let additions = keywords.filter { !existing.contains($0) }
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
        let changed = configuration != cachedConfiguration
        if changed {
            userDefaults.set(data, forKey: Self.configurationKey)
            cachedConfiguration = configuration
        }
        return changed
    }
}
