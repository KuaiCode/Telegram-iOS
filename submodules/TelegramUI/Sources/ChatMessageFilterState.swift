import Foundation
import Postbox
import TelegramCore
import ChatHistoryEntry
import SGSimpleSettings

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
    private var contents: [MessageId: Content] = [:]
    private var matches: [Key: SGMessageFilterMatch] = [:]
    private var generation = 0

    func configurationChanged() {
        self.configuration = SGSimpleSettings.shared.messageFilter.configuration
        self.generation += 1
        self.revealed.removeAll()
        self.pendingReveal.removeAll()
    }

    func setRevealed(_ id: MessageId, _ value: Bool) {
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
    }

    func toggleShowAll() {
        self.showAll.toggle()
    }

    func process(_ entries: [ChatHistoryEntry], accountPeerId: PeerId) -> [ChatHistoryEntry] {
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
        var results: [Key: (SGMessageFilterMatch?, Bool)] = [:]
        for (key, messages) in messagesByKey {
            for message in messages {
                if let previousKey = self.keys[message.id], previousKey != key {
                    self.revealed.remove(previousKey)
                    self.revealed.remove(key)
                }
                self.keys[message.id] = key
                if let previous = self.contents[message.id], !previous.matches(message) {
                    self.revealed.remove(key)
                }
                self.contents[message.id] = Content(text: message.text, media: message.media)
            }
            guard messages.allSatisfy({ message in
                message.effectivelyIncoming(accountPeerId) && message.adAttribute == nil
                    && !message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent })
            }) else {
                continue
            }
            var match: SGMessageFilterMatch?
            if !configuration.groups.isEmpty && (SGFeaturePolicy.isFreeEdition || SGSimpleSettings.shared.ephemeralStatus > 1) {
                match = self.configuration.match(for: messages.map(\.text))
            }
            if self.matches[key] != match {
                self.revealed.remove(key)
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
                updated.messageFilterGeneration = self.generation
                return .MessageEntry(message, presentationData, read, location, selection, updated)
            case let .MessageGroupEntry(groupId, messages, presentationData):
                let (match, revealed) = results[.album(messages.first?.0.groupingKey ?? groupId)] ?? (nil, false)
                if match?.action == .hide && !revealed {
                    self.hasHiddenMessages = true
                    return nil
                }
                let updated = messages.map { message, read, selection, originalAttributes, location in
                    var updated = originalAttributes
                    updated.messageFilterMatch = match
                    updated.messageFilterRevealed = revealed
                    updated.messageFilterGeneration = self.generation
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
