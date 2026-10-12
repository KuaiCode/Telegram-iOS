import Foundation
import Postbox
import TelegramCore
import ChatHistoryEntry
import SGSimpleSettings
import SwiftSignalKit

// Observe complete albums, including captions outside the paged history window.
func chatMessageFilterAlbums(postbox: Postbox, messages: [Message]) -> Signal<[Int64: [Message]], NoError> {
    var representatives: [Int64: MessageId] = [:]
    for message in messages {
        if let key = message.groupingKey, representatives[key] == nil {
            representatives[key] = message.id
        }
    }
    if representatives.isEmpty {
        return .single([:])
    }
    let groupKeys = representatives.mapValues { PostboxViewKey.messageGroup(id: $0) }
    return postbox.combinedView(keys: Array(groupKeys.values))
    |> map { view in
        var result: [Int64: [Message]] = [:]
        for (key, viewKey) in groupKeys {
            if let group = view.views[viewKey] as? MessageGroupView, !group.messages.isEmpty {
                result[key] = group.messages
            }
        }
        return result
    }
}

// Owned by one chat history node and accessed on its main-queue history pipeline.
final class ChatMessageFilterState {
    private enum Key: Hashable {
        case message(MessageId)
        case album(Int64)
    }

    private struct Content {
        let text: String
        let media: [Media]

        func matches(_ message: Message) -> Bool {
            return self.text == message.text && self.media.count == message.media.count
                && zip(self.media, message.media).allSatisfy { $0.isEqual(to: $1) }
        }
    }

    var configuration = SGSimpleSettings.shared.messageFilter.configuration
    var showAll = false
    private(set) var hasHiddenMessages = false
    private var revealed = Set<Key>()
    private var pendingReveal = Set<MessageId>()
    private var keys: [MessageId: Key] = [:]
    private var contents: [Key: [MessageId: Content]] = [:]
    private var matches: [Key: SGMessageFilterMatch] = [:]
    private var generations: [Key: Int] = [:]
    private var generation = 0

    func configurationChanged() {
        self.configuration = SGSimpleSettings.shared.messageFilter.configuration
        self.generation += 1
        self.generations.removeAll()
        self.revealed.removeAll()
        self.pendingReveal.removeAll()
    }

    @discardableResult
    func setRevealed(_ id: MessageId, _ value: Bool, expectedGeneration: Int? = nil) -> Bool {
        if let expectedGeneration {
            guard let key = self.keys[id], self.generations[key] == expectedGeneration else { return false }
        }
        if value {
            self.pendingReveal.insert(id)
        } else {
            self.pendingReveal.remove(id)
        }
        if let key = self.keys[id] {
            if value {
                self.revealed.insert(key)
            } else {
                self.revealed.remove(key)
            }
        }
        return true
    }

    func toggleShowAll() {
        self.showAll.toggle()
    }

    func process(_ entries: [ChatHistoryEntry], accountPeerId: PeerId, albums: [Int64: [Message]] = [:]) -> [ChatHistoryEntry] {
        self.hasHiddenMessages = false
        var messagesByKey: [Key: [Message]] = [:]
        for entry in entries {
            switch entry {
            case let .MessageEntry(message, _, _, _, _, _):
                let key: Key = message.groupingKey.map(Key.album) ?? .message(message.id)
                messagesByKey[key, default: []].append(message)
            case let .MessageGroupEntry(groupId, messages, _):
                let key: Key = .album(messages.first?.0.groupingKey ?? groupId)
                messagesByKey[key, default: []].append(contentsOf: messages.map { $0.0 })
            default:
                break
            }
        }
        for (groupId, messages) in albums where messagesByKey[.album(groupId)] != nil {
            messagesByKey[.album(groupId)] = messages
        }
        var results: [Key: (SGMessageFilterMatch?, Bool)] = [:]
        for (key, messages) in messagesByKey {
            let previousContents = self.contents[key]
            var contentChanged = previousContents?.count != messages.count
            var updatedContents: [MessageId: Content] = [:]
            for message in messages {
                if let previousKey = self.keys[message.id], previousKey != key {
                    self.revealed.remove(previousKey)
                    self.revealed.remove(key)
                    contentChanged = true
                }
                self.keys[message.id] = key
                if previousContents?[message.id]?.matches(message) != true {
                    contentChanged = true
                }
                updatedContents[message.id] = Content(text: message.text, media: message.media)
            }
            self.contents[key] = updatedContents
            let canFilter = messages.allSatisfy { message in
                message.effectivelyIncoming(accountPeerId) && message.adAttribute == nil
                    && !message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent })
            }
            var match: SGMessageFilterMatch?
            if canFilter && !configuration.groups.isEmpty && (SGFeaturePolicy.isFreeEdition || SGSimpleSettings.shared.ephemeralStatus > 1) {
                match = self.configuration.match(for: messages.map(\.text))
            }
            if contentChanged || self.matches[key] != match || self.generations[key] == nil {
                self.revealed.remove(key)
                self.generation += 1
                self.generations[key] = self.generation
            }
            self.matches[key] = match
            if messages.contains(where: { self.pendingReveal.contains($0.id) }) {
                self.revealed.insert(key)
                for message in messages {
                    self.pendingReveal.remove(message.id)
                }
            }
            results[key] = (self.showAll ? nil : match, self.revealed.contains(key))
        }

        let result: [ChatHistoryEntry] = entries.compactMap { entry in
            switch entry {
            case let .MessageEntry(message, presentationData, read, location, selection, originalAttributes):
                let key: Key = message.groupingKey.map(Key.album) ?? .message(message.id)
                let (match, revealed) = results[key] ?? (nil, false)
                if match?.action == .hide && !revealed {
                    self.hasHiddenMessages = true
                    return nil
                }
                var updated = originalAttributes
                updated.messageFilterMatch = match
                updated.messageFilterRevealed = revealed
                updated.messageFilterGeneration = self.generations[key] ?? 0
                return .MessageEntry(message, presentationData, read, location, selection, updated)
            case let .MessageGroupEntry(groupId, messages, presentationData):
                let key = Key.album(messages.first?.0.groupingKey ?? groupId)
                let (match, revealed) = results[key] ?? (nil, false)
                if match?.action == .hide && !revealed {
                    self.hasHiddenMessages = true
                    return nil
                }
                let updated = messages.map { message, read, selection, originalAttributes, location in
                    var updated = originalAttributes
                    updated.messageFilterMatch = match
                    updated.messageFilterRevealed = revealed
                    updated.messageFilterGeneration = self.generations[key] ?? 0
                    return (message, read, selection, updated, location)
                }
                return .MessageGroupEntry(groupId, updated, presentationData)
            default:
                return entry
            }
        }
        if self.hasHiddenMessages && !result.contains(where: { entry in
            switch entry {
            case .MessageEntry, .MessageGroupEntry: return true
            default: return false
            }
        }) {
            return []
        }
        return result
    }
}
