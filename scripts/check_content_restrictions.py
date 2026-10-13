"""Check local restriction policy boundaries and UI wiring; not an iOS runtime test."""

import ast
from itertools import product
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CORE = "submodules/TelegramCore/Sources/"
UI = "submodules/TelegramUI/"
CHAT = UI + "Components/Chat/"


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def expression(source, marker, replacements):
    """Evaluate the actual Swift boolean expression over synthetic boundary inputs."""
    assert source.count(marker) == 1, marker
    value = source.split(marker, 1)[1].splitlines()[0].strip()
    for old, new in replacements.items():
        value = value.replace(old, new)
    value = value.replace("&&", " and ").replace("||", " or ")
    value = re.sub(r"!(?!=)", "not ", value).replace("nil", "None")
    value = re.sub(r"\btrue\b", "True", value)
    tree = ast.parse(value, mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp,
               ast.Not, ast.Compare, ast.Eq, ast.NotEq, ast.Name, ast.Load, ast.Constant)
    assert all(isinstance(node, allowed) for node in ast.walk(tree)), value
    code = compile(tree, "<Swift restriction expression>", "eval")
    return lambda **values: eval(code, {"__builtins__": {}}, values)


def body(source, declaration):
    assert source.count(declaration) == 1, declaration
    return source.split(declaration, 1)[1].split("\n    }", 1)[0]


content = read(CORE + "Settings/ContentSettings.swift")
ignores = expression(body(content, "public func ignoresPlatformRestriction("), "return ", {
    "self.ignoreContentRestrictionReasons.contains(reason)": "server_ignored",
    "self.ignoreAppleTerms": "enabled",
})
assert "public var ignoreAppleTerms: Bool = false" in content
assert "self.ignoreAppleTerms = SGSimpleSettings.shared.ignoreAppleTerms" in body(content, "init(appConfiguration: AppConfiguration)")
assert "SGSimpleSettings" not in body(content, "public init(ignoreContentRestrictionReasons:")
cases = 0
for enabled, server_ignored, reason, platform in product(
    (False, True), (False, True),
    ("appleterms", "terms", "sensitive", "AppleTerms", "appleterms-ios"),
    ("ios", "all", "android", "android-ios"),
):
    expected = server_ignored or (enabled and reason == "appleterms" and platform == "ios")
    assert ignores(enabled=enabled, server_ignored=server_ignored, reason=reason, platform=platform) == expected
    cases += 1

peers = read(CORE + "Utils/PeerUtils.swift")
scope = expression(body(peers, "var allowsGroupCopyingAndScreenshots:"), "return ", {
    "self.isGroupOrChannel": "is_group",
    "SGSimpleSettings.shared.allowGroupCopyingAndScreenshots": "enabled",
})
assert "case Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:" in body(peers, "var isGroupOrChannel:")
messages = read(CORE + "Utils/MessageUtils.swift")
local_policy = body(messages, "func isCopyProtectedForLocalUse(")
allows = expression(local_policy, "let allowsLocalCopy = ", {
    "self.id.peerId.allowsGroupCopyingAndScreenshots": "allows_group",
    "self.containsSecretMedia": "secret_media",
    "self.minAutoremoveOrClearTimeout": "timeout",
    "self.paidContent": "paid_content",
    "viewOnceTimeout": "view_once_timeout",
})
protected = expression(local_policy, "return ", {
    "peerIsCopyProtected": "peer_protected",
    "self.isCopyProtected()": "message_protected",
    "allowsLocalCopy": "allows_local",
})
for enabled, peer, secret, once, paid, raw, peer_raw in product(
    (False, True), ("user", "secret", "group", "channel"),
    *((False, True),) * 5,
):
    allowed = allows(
        allows_group=scope(is_group=peer in ("group", "channel"), enabled=enabled),
        secret_media=secret, timeout=100 if once else None,
        view_once_timeout=100, paid_content="paid" if paid else None,
    )
    expected_bypass = enabled and peer in ("group", "channel") and not (secret or once or paid)
    assert allowed == expected_bypass, (enabled, peer, secret, once, paid)
    assert protected(peer_protected=peer_raw, message_protected=raw, allows_local=allowed) == ((raw or peer_raw) and not expected_bypass)
    cases += 1

# Whole-chat capture must still protect secret chats and the verification-code chat.
chat_node = read(UI + "Sources/ChatControllerNode.swift")
capture = expression(chat_node, "        let isSecret = ", {
    "self.chatPresentationInterfaceState.copyProtectionEnabled": "peer_protected",
    "self.chatLocation.peerId?.allowsGroupCopyingAndScreenshots": "allows_group",
    "self.chatLocation.peerId?.namespace": "namespace",
    "Namespaces.Peer.SecretChat": '"secret"',
    "self.chatLocation.peerId?.isVerificationCodes": "verification",
})
for enabled, peer, raw, verification in product((False, True), ("user", "secret", "group", "channel", None), (False, True), (False, True)):
    allows_group = scope(is_group=peer in ("group", "channel"), enabled=enabled)
    assert capture(peer_protected=raw, allows_group=allows_group, namespace=peer, verification=verification) == ((raw and not allows_group) or peer == "secret" or verification)
    cases += 1

# Raw flags remain authoritative for forwarding, saving and service-side operations.
for source, declaration in ((messages, "func isCopyProtected()"), (peers, "var isCopyProtectionEnabled:")):
    raw_policy = body(source, declaration)
    assert "SGSimpleSettings" not in raw_policy and "LocalUse" not in raw_policy

settings = read("Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift")
advanced = read("Swiftgram/SGProUI/Sources/SGProUI.swift")
for key in ("ignoreAppleTerms", "allowGroupCopyingAndScreenshots"):
    assert f"Keys.{key}.rawValue: false" in settings
    property_body = body(settings, f"public var {key}: Bool {{")
    assert f"UserDefaults.standard.bool(forKey: Keys.{key}.rawValue)" in property_body
    assert f"UserDefaults.standard.set(newValue, forKey: Keys.{key}.rawValue)" in property_body
    assert f"settingName: .{key}" in advanced and f"SGSimpleSettings.shared.{key} = value" in advanced
assert "settingsUpdated.set(value)" in advanced and "settingsUpdated.get()" in advanced

for path in (CORE + "Utils/PeerUtils.swift", "submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift"):
    source = read(path)
    assert "ignoresPlatformRestriction(reason: rule.reason, platform: rule.platform)" in source
    assert "ignoreContentRestrictionReasons.contains(rule.reason)" not in source

for component in ("ChatMessageTextBubbleContentNode", "ChatMessageRichDataBubbleContentNode", "ChatMessageInteractiveFileNode", "ChatMessageInteractiveMediaNode", "ChatMessageInteractiveInstantVideoNode", "ChatMessageReplyInfoNode"):
    assert "isCopyProtectedForLocalUse(" in read(CHAT + component + "/Sources/" + component + ".swift"), component
for path in ("submodules/GalleryUI/Sources/GalleryController.swift", "submodules/GalleryUI/Sources/Items/ChatImageGalleryItem.swift", UI + "Sources/SharedMediaPlayer.swift"):
    assert "isCopyProtectedForLocalUse(" in read(path), path
for path in (UI + "Sources/ChatController.swift", UI + "Sources/ChatPinnedMessageTitlePanelNode.swift", UI + "Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"):
    assert "allowsGroupCopyingAndScreenshots" in read(path), path
assert "isCopyProtectedForLocalUse(peerIsCopyProtected: true)" in read(UI + "Sources/Chat/ChatControllerOpenMessageContextMenu.swift")

menus = read(UI + "Sources/ChatInterfaceStateContextMenus.swift")
# An ignored restriction returns nil: keep it nil so Copy falls back to message text.
copy_restriction_assignments = re.findall(r"restrictedText = attribute\.platformText\([^\n]+", menus)
assert len(copy_restriction_assignments) == 3
assert all("??" not in line for line in copy_restriction_assignments), "An ignored restriction must not replace copied text with an empty string"
assert "if !isLocalCopyProtected {" in menus
assert "let isCopyProtected = chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()" in menus
assert "if resourceAvailable, !message.containsSecretMedia && !isCopyProtected {" in menus
for component in ("ChatMessageTextBubbleContentNode", "ChatMessageRichDataBubbleContentNode"):
    source = read(CHAT + component + "/Sources/" + component + ".swift")
    assert "textSelectionNode.enableShare = enableOtherActions && enableCopy" in source
    assert "textSelectionNode.enableCopy = !" in source

keys = set(re.findall(r'"(Settings\.Advance\.[\w.]+)"', advanced))
for locale in ("en", "zh-hans", "zh-hant"):
    entries = re.findall(r'^"(Settings\.Advance\.[\w.]+)"\s*=\s*"((?:\\.|[^"\\])*)";', read(f"Swiftgram/SGStrings/Strings/{locale}.lproj/SGLocalizable.strings"), re.M)
    mapping = dict(entries)
    assert len(mapping) == len(entries) and keys <= mapping.keys(), locale
    assert "Settings.Advance.RestrictionsRestart" in mapping

print(f"Content restriction checks passed: {cases} synthetic boundary cases, UI wiring and localization. No Swift compilation or device validation.")
