"""Read-only integration checks for message filtering. Does not run a Swift compiler."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CHAT = "submodules/TelegramUI/Components/Chat/"


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


rules = read("Swiftgram/SGSimpleSettings/Sources/MessageFilterRules.swift")
action_enum = rules.split("public enum SGMessageFilterAction", 1)[1].split("public var localizationKey", 1)[0]
assert set(re.findall(r"case (\w+)", action_enum)) == {"dim", "allow", "collapse", "hide", "mask"}
assert "public func action(for text: String)" in rules
assert "public struct SGMessageFilterMatch: Equatable" in rules

sources = [
    rules,
    read("Swiftgram/SGProUI/Sources/MessageFilterController.swift"),
    read("Swiftgram/SGProUI/Sources/MessageFilterKeywordSelectionController.swift"),
    read(CHAT + "ChatMessageItemImpl/Sources/ChatMessageFilterItemNode.swift"),
    read(CHAT + "ChatMessageItemView/Sources/ChatMessageItemView.swift"),
    read("submodules/TelegramUI/Sources/ChatHistoryListNode.swift"),
    read("submodules/TelegramUI/Sources/Chat/ChatControllerMessageFilter.swift"),
]
keys = set(re.findall(r'"(MessageFilter\.[\w.]+)"', "\n".join(sources)))
for locale in ("en", "zh-hans", "zh-hant"):
    strings = read(f"Swiftgram/SGStrings/Strings/{locale}.lproj/SGLocalizable.strings")
    entries = re.findall(r'^"(MessageFilter\.[\w.]+)"\s*=\s*"((?:\\.|[^"\\])*)";', strings, re.M)
    mapping = dict(entries)
    assert len(mapping) == len(entries), f"Duplicate filter localization: {locale}"
    assert keys <= mapping.keys(), f"Missing localization in {locale}: {keys - mapping.keys()}"
    assert mapping["MessageFilter.Collapsed"].count("%@") == 1

for module, dependencies in {
    "ChatHistoryEntry": ["//Swiftgram/SGSimpleSettings:SGSimpleSettings"],
    "ChatMessageItemView": ["//Swiftgram/SGStrings:SGStrings", "//submodules/InvisibleInkDustNode"],
    "ChatMessageItemImpl": ["//Swiftgram/SGStrings:SGStrings", "//submodules/TelegramPresentationData"],
}.items():
    build = read(CHAT + module + "/BUILD")
    for dependency in dependencies:
        assert f'"{dependency}"' in build, f"Missing dependency in {module}: {dependency}"

base = sources[4]
assert "import TelegramPresentationData" in sources[3], "The compact row uses the baseDisplaySize extension"
assert "import AppBundle" in sources[6], "The menu icon uses UIImage(bundleImageName:)"
assert "withAlphaComponent(1.0)" in base, "Dust must have an opaque backing"
assert "self.view.accessibilityElements = [cover.view]" in base
assert "recognizer.isEnabled = false" in base
assert "self.filterDust === dust" in base, "A stale reveal animation must not reveal a reused node"
assert "SGSimpleSettings.shared.messageFilter.configuration" not in base
assert "NotificationCenter.default.addObserver" not in base
for renderer in ("ChatMessageBubbleItemNode", "ChatMessageStickerItemNode", "ChatMessageAnimatedStickerItemNode"):
    source = read(CHAT + renderer + "/Sources/" + renderer + ".swift")
    assert source.count("override public func messageFilterContentFrame()") == 1
    hit_test = source.split("override public func hitTest(_ point:", 1)[1]
    assert hit_test.index("messageFilterHitTest") < hit_test.index("super.hitTest")
    assert "strongSelf.messageFilterHitTest(point, with: nil) != nil" in source
    assert "self.actionButtonsNode" in source.split("override public func messageFilterContentFrame()", 1)[1].split("return frame", 1)[0]

item = read(CHAT + "ChatMessageItemImpl/Sources/ChatMessageItemImpl.swift")
assert "viewClassName = ChatMessageFilterItemNode.self" in item
assert item.count("updateMessageFilterPresentation(contentSize: layout.contentSize)") == 2
assert base.count("updateMessageFilterPresentation(contentSize: layout.contentSize)") == 1
attributes = read(CHAT + "ChatHistoryEntry/Sources/ChatHistoryEntry.swift")
assert "public var messageFilterGeneration: Int = 0" in attributes
assert attributes.count("isMessageFilterCollapsed") == 3

state = read("submodules/TelegramUI/Sources/ChatMessageFilterState.swift")
assert "messages.map(\\.text)" in state and ".joined(" not in state
assert "message.effectivelyIncoming(accountPeerId) && message.adAttribute == nil" in state
assert "TelegramMediaAction || $0 is TelegramMediaExpiredContent" in state
assert "zip(self.media, message.media)" in state and "message.stableVersion" not in state
assert not any(call in state for call in ("deleteMessages", "applyMaxReadIndex", "markAsRead"))
assert "messagesByKey[key, default: []]" in state
history = sources[5]
assert "combineLatest(self.allAdMessagesPromise.get(), self.messageFilterRevision.get())" in history
assert "self.messageFilterState.configurationChanged()" in history
assert "historyView.originalView.entries.first?.message.index ?? firstEntry.index" in history
assert "historyView.originalView.entries.last?.message.index ?? lastEntry.index" in history
assert "self.loadFilteredHistory(at: self.historyView?.originalView.entries.first?.message.index)" in history
assert "self.loadFilteredHistory(at: self.historyView?.originalView.entries.last?.message.index)" in history
assert history.count("hasHiddenMessages &&") == 2
assert "self.messageFilterState.setRevealed(id, true)" in history
assert "private let messageFilterState = ChatMessageFilterState()" in history
assert "controllerInteraction.setMessageFilterRevealed =" not in history
assert "self?.historyNode.setMessageFilterRevealed(id, value, expectedGeneration: generation)" in read("submodules/TelegramUI/Sources/ChatControllerNode.swift")


def section(source, start, end):
    assert source.count(start) == 1, f"Review changed section: {start}"
    tail = source.split(start, 1)[1]
    assert end in tail, f"Missing section boundary: {end}"
    return tail.split(end, 1)[0]


def check_history_boundaries(state, history, base):
    """Source contracts for the reviewed bugs, not Swift execution tests."""
    anchor = section(history, "public func anchorMessageInCurrentHistoryView()", "return nil")
    album = section(state, "func chatMessageFilterAlbums(", "final class ChatMessageFilterState")
    processing = section(state, "func process(", "let result: [ChatHistoryEntry]")
    setup = section(base, "open func setupItem(", "public static func messageFilterLayout(")
    invalidate = section(base, "private func invalidateMessageFilterDust()", "private func removeMessageFilterCover()")
    paging = section(history, "// A sparse page can touch both edges.", "if mathesFirst && historyView.originalView.laterId")
    revision = section(state, "if contentChanged ||", "self.matches[key] = match")
    reveal = section(state, "func setRevealed(", "func toggleShowAll()")
    callback = section(base, "dust.revealed = {", "cover.addSubnode(dust)")
    content = section(state, "private struct Content {", "var configuration")
    scroll = section(history, "self.listView.visibleContentOffsetChanged =", "strongSelf.messageReadMetricsTracker?.reportUserActivity()")
    range_callback = section(history, "private func processDisplayedItemRangeChanged(", "private func updateHistoryPagination(")
    pagination = section(history, "private func updateHistoryPagination(", "private func updateMessageReadTracker()")
    return {
        "shared regex deadline": (
            processing.count("let matchingDeadline:") == 1
            and "configuration.hasRegularExpressions" in processing
            and "ProcessInfo.processInfo.systemUptime + SGMessageFilterRule.matchingTimeLimit : nil" in processing
            and processing.index("let matchingDeadline:") < processing.index("for (key, messages) in messagesByKey")
            and r"self.configuration.match(for: messages.map(\.text), deadline: matchingDeadline)" in processing
        ),
        "hidden-page navigation": (
            "historyView.hasHiddenMessages, historyView.filteredEntries.isEmpty" in anchor
            and "historyView.originalView.entries.last?.message" in anchor
            and "return EngineMessage(message)" in anchor
            and anchor.count(".MessageGroupEntry(_, messages, _)") == 2
        ),
        "complete boundary albums": (
            "PostboxViewKey.messageGroup(id: $0)" in album
            and "postbox.combinedView(keys: Array(groupKeys.values))" in album
            and "result[key] = group.messages" in album
            and "take(1)" not in album
            and "messagesByKey[.album(groupId)] = messages" in processing
            and "messageFilterAlbums: filterAlbums" in history
            and "historyViewUpdateUntilStopped |> debug_measureTimeToFirstEvent" in history
        ),
        "opaque cover during asynchronous reuse": (
            "self.invalidateMessageFilterDust()" in setup
            and "self.removeMessageFilterCover()" not in setup
            and setup.index("self.invalidateMessageFilterDust()") < setup.index("self.item = item")
            and "self.filterDust?.revealed = {}" in invalidate
            and "self.filterDust?.removeFromSupernode()" in invalidate
            and "self.filterCover?.view.mask = nil" in invalidate
            and "self.filterCover?.layer.removeAllAnimations()" in invalidate
            and "self.filterCover?.alpha = 1.0" in invalidate
            and "self.filterCover?.removeFromSupernode()" not in invalidate
        ),
        "sparse-page paging direction": (
            "if mathesFirst && mathesLast" in paging
            and "mathesFirst = self.messageFilterLoadDirection == .later" in paging
            and "mathesLast = self.messageFilterLoadDirection == .earlier" in paging
            and "self.messageFilterLoadDirection = .earlier" in section(history, "@objc private func loadMoreFilteredHistory()", "@objc private func loadNewerFilteredHistory()")
            and "self.messageFilterLoadDirection = .later" in section(history, "@objc private func loadNewerFilteredHistory()", "private func loadFilteredHistory(")
            and "self.messageFilterLoadDirection = nil" in section(history, "func revealFilteredMessage(", "func setMessageFilterRevealed(")
            and "strongSelf.listView.trackingOffset > 0.0 ? .later : .earlier" in scroll
        ),
        "album membership invalidation": (
            "previousContents?.count != messages.count" in processing
            and "previousContents?[message.id]?.matches(message) != true" in processing
            and "updatedContents[message.id] = Content(text: message.text, entities: message.textEntitiesAttribute?.entities ?? [], media: message.media)" in processing
            and "self.contents[key] = updatedContents" in processing
            and "self.revealed.remove(key)" in revision
            and "self.generations[key] = self.generation" in revision
            and processing.index("if contentChanged ||") < processing.index("self.pendingReveal.contains($0.id)")
        ),
        "stale album reveal rejection": (
            "self.generations[key] == expectedGeneration else { return false }" in reveal
            and reveal.index("self.generations[key] == expectedGeneration") < reveal.index("self.revealed.insert(key)")
            and "self.generations.removeAll()" in state
            and state.count("updated.messageFilterGeneration = self.generations[key] ?? 0") == 2
            and "messageFilterGeneration != item.content.firstMessageAttributes.messageFilterGeneration" in setup
            and "self.filterDust === dust, self.isMessageFilterMasked" in callback
            and "item.content.firstMessageAttributes.messageFilterGeneration == generation else { return }" in callback
            and "setMessageFilterRevealed?(item.message.id, true, generation)" in callback
        ),
        "entity-only content updates": (
            "let entities: [MessageTextEntity]" in content
            and "self.entities == (message.textEntitiesAttribute?.entities ?? [])" in content
            and "entities: message.textEntitiesAttribute?.entities ?? []" in processing
            and "previousContents?[message.id]?.matches(message) != true" in processing
            and "stableVersion" not in content
            and "message.attributes" not in content
        ),
        "scrolling without visible-range changes": (
            "if strongSelf.canToggleMessageFilter," in scroll
            and "strongSelf.listView.opaqueTransactionState as? ChatHistoryTransactionOpaqueState" in scroll
            and "historyView.hasHiddenMessages, strongSelf.listView.isTracking, abs(strongSelf.listView.trackingOffset) > 14.0" in scroll
            and "strongSelf.updateHistoryPagination(displayedRange: strongSelf.listView.displayedItemRange, historyView: historyView)" in scroll
            and scroll.index("strongSelf.messageFilterLoadDirection =") < scroll.index("strongSelf.updateHistoryPagination(")
            and "if strongSelf.messageFilterLoadDirection" not in scroll
            and "self.updateHistoryPagination(displayedRange: displayedRange, historyView: historyView)" in range_callback
            and "self.chatHistoryLocationValue?.content != locationInput" in pagination
            and "historyView.originalView.entries.first?.message.index ?? firstEntry.index" in pagination
            and "historyView.originalView.entries.last?.message.index ?? lastEntry.index" in pagination
            and "trackingOffset" not in range_callback
            and "trackingOffset" not in pagination
        ),
    }


boundaries = check_history_boundaries(state, history, base)
assert all(boundaries.values()), f"Boundary regression: {[name for name, passed in boundaries.items() if not passed]}"
assert "anchorMessageInCurrentHistoryView()" in read("submodules/TelegramUI/Sources/Chat/ChatControllerNavigateToMessage.swift")
assert "albums: messageFilterAlbums" in read("submodules/TelegramUI/Sources/ChatHistoryEntriesForView.swift")
assert '"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit"' in read("submodules/TelegramUI/BUILD")
assert "((EngineMessage.Id, Bool, Int) -> Void)?" in read("submodules/TelegramUI/Components/ChatControllerInteraction/Sources/ChatControllerInteraction.swift")
assert "setMessageFilterRevealed?(item.message.id, true, item.content.firstMessageAttributes.messageFilterGeneration)" in sources[3]
assert "setMessageFilterRevealed?(item.message.id, false, item.content.firstMessageAttributes.messageFilterGeneration)" in base

# Verify that actual scrolling delivers the offset callback independently of range changes.
list_view = read("submodules/Display/Source/ListView.swift")
scroll_dispatch = section(list_view, "self.didScrollWithOffset?(deltaY, .immediate, nil, self.isTrackingOrDecelerating)", "private func calculateAdditionalTopInverseInset()")
assert "self.updateVisibleContentOffset(transition: .immediate)\n        self.updateVisibleItemRange()" in scroll_dispatch
assert "self.visibleContentOffsetChanged(self.visibleContentOffset(), transition)" in list_view
entity_type = read("submodules/TelegramCore/Sources/SyncCore/SyncCore_TextEntitiesMessageAttribute.swift")
assert "public enum MessageTextEntityType: Equatable" in entity_type and "case TextUrl(url: String)" in entity_type
assert "public struct MessageTextEntity: PostboxCoding, Codable, Equatable" in entity_type
assert "return lhs.range == rhs.range && lhs.type == rhs.type" in entity_type

# Negative controls ensure each boundary check detects removal of its protection.
mutations = [
    (0, "deadline: matchingDeadline", "deadline: nil", "shared regex deadline"),
    (1, "historyView.originalView.entries.last?.message {", "historyView.filteredEntries.last?.message {", "hidden-page navigation"),
    (0, "messagesByKey[.album(groupId)] = messages", "messagesByKey[.album(groupId)] = []", "complete boundary albums"),
    (2, "self.invalidateMessageFilterDust()", "self.removeMessageFilterCover()", "opaque cover during asynchronous reuse"),
    (1, "mathesFirst = self.messageFilterLoadDirection == .later", "mathesFirst = true", "sparse-page paging direction"),
    (0, "previousContents?.count != messages.count", "false", "album membership invalidation"),
    (0, "previousContents?[message.id]?.matches(message) != true", "false", "album membership invalidation"),
    (0, "self.generations[key] == expectedGeneration", "true", "stale album reveal rejection"),
    (2, "item.content.firstMessageAttributes.messageFilterGeneration == generation else { return }", "true else { return }", "stale album reveal rejection"),
    (0, "self.entities == (message.textEntitiesAttribute?.entities ?? [])", "true", "entity-only content updates"),
    (0, "entities: message.textEntitiesAttribute?.entities ?? []", "entities: []", "entity-only content updates"),
    (1, "strongSelf.updateHistoryPagination(displayedRange: strongSelf.listView.displayedItemRange, historyView: historyView)", "", "scrolling without visible-range changes"),
    (1, "strongSelf.updateHistoryPagination(displayedRange: strongSelf.listView.displayedItemRange, historyView: historyView)", "if strongSelf.messageFilterLoadDirection != .earlier { strongSelf.updateHistoryPagination(displayedRange: strongSelf.listView.displayedItemRange, historyView: historyView) }", "scrolling without visible-range changes"),
    (1, "historyView.hasHiddenMessages, strongSelf.listView.isTracking, abs", "historyView.hasHiddenMessages, abs", "scrolling without visible-range changes"),
    (1, "self.updateHistoryPagination(displayedRange: displayedRange, historyView: historyView)", "", "scrolling without visible-range changes"),
]
for index, before, after, boundary in mutations:
    mutated = [state, history, base]
    assert before in mutated[index], f"Stale negative control: {before}"
    mutated[index] = mutated[index].replace(before, after, 1)
    assert not check_history_boundaries(*mutated)[boundary], f"Missed negative control: {boundary}"

def check_ui_boundaries(controller, selection):
    """UI source contracts only; gestures and input methods still need device tests."""
    name_changes = section(controller, "func nameChanged(", "func saveName()")
    save_name = section(controller, "func saveName()", "func finishEditing(")
    update = section(controller, "func update(_ change:", "private struct MessageFilterGroupNameField:")
    detail = section(controller, "private struct MessageFilterGroupView:", "public func sgMessageFilterController(")
    add_rule = section(detail, "private func addKeyword()", "newKeyword = \"\"")
    layout = section(selection, "override func updateLayout(constrainedSize:", "return size")
    pending = section(selection, "private func updatePending()", "private func updateGroupTitle()")
    return {
        "regex entry validates and resets only on success": (
            "@State private var isRegularExpression = false" in detail
            and 'Toggle("MessageFilter.Regex.Use"' in detail
            and "isRegularExpression ? SGMessageFilterRule.regularExpressionPrefix + newKeyword : SGMessageFilterRule.normalized(newKeyword)" in add_rule
            and "SGMessageFilterRule.validationError(for: keyword)" in add_rule
            and add_rule.index("SGMessageFilterRule.validationError(for: keyword)") < add_rule.index("if editor.update(")
            and "onError(error)\n            return" in add_rule
            and 'newKeyword = ""\n            isRegularExpression = false\n        } else if let error = editor.error' in detail
            and "if let error = SGMessageFilterRule.validationError(for: keyword) {\n                            Text(messageFilterErrorText(error, language: lang))" in detail
        ),
        "fixed controls and independent scroll regions": (
            "textScrollNode.addSubnode(textNode)" in selection
            and "textScrollNode.insertSubnode(selection.highlightAreaNode, belowSubnode: textNode)" in selection
            and "textScrollNode.addSubnode(selection)" in selection
            and "keywordsScrollNode.view.addSubview(button)" in pending
            and "keywordsScrollNode.canCancelAllTouchesInViews = true" in selection
            and "constrainedSize.height - fixedHeight - helpSectionHeight" in layout
            and "height: min(constrainedSize.height, y)" in layout
            and "height: textViewportHeight" in layout
            and "height: keywordsViewportHeight" in layout
            and "require(toFail: textScrollNode.view.panGestureRecognizer)" in selection
            and "require(toFail: keywordsScrollNode.view.panGestureRecognizer)" in selection
        ),
        "selection and scroll-position preservation": (
            "let offset = node.view.contentOffset" in selection
            and "min(max(0.0, offset.y), max(0.0, contentSize.height - frame.height))" in selection
            and "textNode" not in pending and "selectionNode" not in pending
            and "if textLayoutWidth != textWidth" in layout
            and selection.count("private let textNode = ImmediateTextNode()") == 1
            and "CGRect(x: 12.0, y: 12.0, width: textWidth" in layout
        ),
        "nested navigation owns edge swipes": (
            "tag: group.id, selection: $selectedGroupId" in controller
            and "disablesInteractiveTransitionGestureRecognizerNow = { selectedGroupId != nil }" in controller
            and "disablesInteractiveTransitionGestureRecognizerNow = nil" in controller
            and r"ForEach(configuration.groups, id: \.id)" in controller
        ),
        "debounced committed-text rename": (
            "pendingRename?.cancel()" in name_changes
            and "guard !isComposing else { return }" in name_changes
            and "DispatchWorkItem { [weak self]" in name_changes
            and ".now() + 0.5, execute: work" in name_changes
            and "pendingRename?.cancel()" in save_name
            and "guard !isComposing else { return false }" in save_name
            and "isComposing: field.markedTextRange != nil" in controller
            and "field.markedTextRange == nil, field.text != editor.name" in controller
            and "guard textField.markedTextRange == nil else { return }" in controller
            and "editor.finishEditing(textField.text ?? \"\")" in controller
            and "@StateObject private var editor: MessageFilterGroupEditor" in detail
            and "MessageFilter.SaveName" not in detail
            and "initialGroup" not in detail
            and "onError(error)" in detail
        ),
        "rename merges into latest configuration": (
            "var latest = store.configuration" in update
            and "latest.groups.firstIndex(where: { $0.name == group.name })" in update
            and "change(&latest.groups[index])" in update
            and "try store.update(latest)" in update
            and update.index("try store.update(latest)") < update.index("group = store.configuration.groups[index]")
            and "self.error = error" in update
            and "guard !newName.isEmpty" in save_name
            and "guard update({ $0.name = newName }) else { return false }" in save_name
            and "renameLastUsedGroup(from: oldName, to: group.name)" in save_name
        ),
        "detail ordering and flush before export": (
            detail.index('Picker("MessageFilter.Action"') < detail.index('Button("MessageFilter.ExportGroup"') < detail.index('Section(header: Text("MessageFilter.Keywords.Title"')
            and detail.index("MessageFilterKeywordInputView(") < detail.index("ForEach(editor.group.keywords.reversed()")
            and "wrapperController?.view.endEditing(true)\n                    if editor.saveName() {\n                        onExport(editor.group)" in detail
            and "wrapperController?.view.endEditing(true)\n            if !editor.saveName(), let error = editor.error" in detail
            and r"ForEach(editor.group.keywords.reversed(), id: \.messageFilterRuleIdentity)" in detail
            and "let removed = Set(offsets.map { SGMessageFilterRule.identity(keywords[keywords.count - 1 - $0]) })" in detail
            and "removed.contains(SGMessageFilterRule.identity($0))" in detail
        ),
    }


ui_boundaries = check_ui_boundaries(sources[1], sources[2])
assert all(ui_boundaries.values()), f"UI boundary regression: {[name for name, passed in ui_boundaries.items() if not passed]}"
assert "import UIKitRuntimeUtils" in sources[1]
assert '"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils"' in read("Swiftgram/SGProUI/BUILD")
gesture_source = read("submodules/Display/Source/InteractiveTransitionGestureRecognizer.swift")
assert "disablesInteractiveTransitionGestureRecognizerNow() {\n        return .strict" in gesture_source
selection_source = read("submodules/TextSelectionNode/Sources/TextSelectionNode.swift")
assert "if let scrollView = findScrollView(view: strongSelf.view)" in selection_source
assert "scrollView.scrollRectToVisible(" in selection_source
assert "guard names.insert(name).inserted else { throw SGMessageFilterRuleFileError.duplicateGroupName }" in rules
ui_mutations = [
    (0, 'newKeyword = ""\n            isRegularExpression = false', 'newKeyword = ""\n            isRegularExpression = true', "regex entry validates and resets only on success"),
    (0, "onError(error)\n            return", "onError(error)", "regex entry validates and resets only on success"),
    (1, "textScrollNode.addSubnode(textNode)", "self.addSubnode(textNode)", "fixed controls and independent scroll regions"),
    (1, "keywordsScrollNode.canCancelAllTouchesInViews = true", "keywordsScrollNode.canCancelAllTouchesInViews = false", "fixed controls and independent scroll regions"),
    (1, "height: min(constrainedSize.height, y)", "height: y", "fixed controls and independent scroll regions"),
    (1, "require(toFail: textScrollNode.view.panGestureRecognizer)", "require(toFail: keywordsScrollNode.view.panGestureRecognizer)", "fixed controls and independent scroll regions"),
    (1, "let offset = node.view.contentOffset", "let offset = CGPoint.zero", "selection and scroll-position preservation"),
    (0, "disablesInteractiveTransitionGestureRecognizerNow = { selectedGroupId != nil }", "disablesInteractiveTransitionGestureRecognizerNow = { false }", "nested navigation owns edge swipes"),
    (0, "guard !isComposing else { return }", "", "debounced committed-text rename"),
    (0, "guard textField.markedTextRange == nil else { return }", "", "debounced committed-text rename"),
    (0, "pendingRename?.cancel()\n        pendingRename = nil\n        error = nil", "pendingRename = nil\n        error = nil", "debounced committed-text rename"),
    (0, "var latest = store.configuration", "var latest = SGMessageFilterConfiguration(groups: [group])", "rename merges into latest configuration"),
    (0, "change(&latest.groups[index])", "latest.groups[index] = group", "rename merges into latest configuration"),
    (0, "renameLastUsedGroup(from: oldName, to: group.name)", "renameLastUsedGroup(from: group.name, to: group.name)", "rename merges into latest configuration"),
    (0, "if editor.saveName() {", "if true {", "detail ordering and flush before export"),
]
for index, before, after, boundary in ui_mutations:
    mutated = [sources[1], sources[2]]
    assert before in mutated[index], f"Stale UI negative control: {before}"
    mutated[index] = mutated[index].replace(before, after, 1)
    assert not check_ui_boundaries(*mutated)[boundary], f"Missed UI negative control: {boundary}"

print(f"All {len(ui_boundaries)} UI source contracts passed; all {len(ui_mutations)} UI negative controls detected.")
print("Message-filter source checks passed: five actions, three locales, dependencies, renderer hooks, raw album captions, pagination and reveal guards.")
print(f"All {len(boundaries)} history boundary contracts passed; all {len(mutations)} negative controls detected.")
print("Static checks only; Swift assertions, compilation, gestures and VoiceOver were not run.")
