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
assert "self?.historyNode.setMessageFilterRevealed(id, value)" in read("submodules/TelegramUI/Sources/ChatControllerNode.swift")

print("Message-filter source checks passed: five actions, three locales, dependencies, renderer hooks, raw album captions, pagination and reveal guards.")
print("Static checks only; Swift assertions, compilation, gestures and VoiceOver were not run.")
