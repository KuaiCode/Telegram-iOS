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
assert "paidMedia = paidContent.extendedMedia" in local_policy
assert "as? TelegramMediaInvoice, let extendedMedia = invoice.extendedMedia" in local_policy
assert "paidMedia = [extendedMedia]" in local_policy
assert "if let paidMedia, !paidMedia.isEmpty" in local_policy
assert re.search(r"paidMediaIsUnlocked = paidMedia\.allSatisfy \{ media in\s+if case \.full = media \{\s+return true\s+\}\s+return false", local_policy)
paid_allows = expression(local_policy, "let allowsPaidMedia = ", {
    "SGSimpleSettings.shared.allowPaidMediaCopyingAndScreenshots": "paid_enabled",
    "paidMediaIsUnlocked": "unlocked",
    "paidMedia": "paid_media",
})
allows = expression(local_policy, "let allowsLocalCopy = ", {
    "self.id.peerId.allowsGroupCopyingAndScreenshots": "allows_group",
    "self.containsSecretMedia": "secret_media",
    "self.minAutoremoveOrClearTimeout": "timeout",
    "allowsPaidMedia": "allows_paid",
    "viewOnceTimeout": "view_once_timeout",
})
protected = expression(local_policy.split("let allowsLocalCopy = ", 1)[1], "return ", {
    "peerIsCopyProtected": "peer_protected",
    "self.isCopyProtected()": "message_protected",
    "allowsLocalCopy": "allows_local",
    "paidMedia": "paid_media",
})
# Cover both paid-media encodings, including empty and partially unlocked albums.
media_fixtures = (
    ("ordinary", None), ("invoice_without_media", None),
    ("paid_empty", ()), ("paid_preview", ("preview",)),
    ("paid_full", ("full",)), ("paid_album", ("full", "full")),
    ("paid_mixed", ("full", "preview")),
    ("invoice_preview", ("preview",)), ("invoice_full", ("full",)),
)
for enabled, paid_enabled, peer, secret, once, fixture, raw, peer_raw in product(
    (False, True), (False, True), ("user", "secret", "group", "channel"),
    (False, True), (False, True), media_fixtures, (False, True), (False, True),
):
    name, paid_media = fixture
    unlocked = bool(paid_media) and all(item == "full" for item in paid_media)
    allowed = allows(
        allows_group=scope(is_group=peer in ("group", "channel"), enabled=enabled),
        secret_media=secret, timeout=100 if once else None,
        view_once_timeout=100,
        allows_paid=paid_allows(paid_media=paid_media, paid_enabled=paid_enabled, unlocked=unlocked),
    )
    eligible_media = name in ("ordinary", "invoice_without_media") or (
        paid_enabled and name in ("paid_full", "paid_album", "invoice_full")
    )
    expected_bypass = enabled and peer in ("group", "channel") and not (secret or once) and eligible_media
    assert allowed == expected_bypass, (enabled, paid_enabled, peer, secret, once, name)
    assert protected(peer_protected=peer_raw, message_protected=raw, paid_media=paid_media, allows_local=allowed) == ((raw or peer_raw or paid_media is not None) and not expected_bypass)
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
for key in ("ignoreAppleTerms", "allowGroupCopyingAndScreenshots", "allowPaidMediaCopyingAndScreenshots"):
    assert f"Keys.{key}.rawValue: false" in settings
    property_body = body(settings, f"public var {key}: Bool {{")
    assert f"UserDefaults.standard.bool(forKey: Keys.{key}.rawValue)" in property_body
    assert f"UserDefaults.standard.set(newValue, forKey: Keys.{key}.rawValue)" in property_body
    assert f"settingName: .{key}" in advanced and f"SGSimpleSettings.shared.{key} = value" in advanced
assert "settingsUpdated.set(value)" in advanced and "settingsUpdated.get()" in advanced
paid_toggle = next(line for line in advanced.splitlines() if "settingName: .allowPaidMediaCopyingAndScreenshots" in line)
assert "enabled: SGSimpleSettings.shared.allowGroupCopyingAndScreenshots" in paid_toggle

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
context_menu = read(UI + "Sources/Chat/ChatControllerOpenMessageContextMenu.swift")
assert "let isSecret = message._asMessage().isCopyProtectedForLocalUse(peerIsCopyProtected: self.presentationInterfaceState.copyProtectionEnabled)" in context_menu

# Pinned paid thumbnails must not inherit only the peer's unprotected capture state.
pinned = read(UI + "Sources/ChatPinnedMessageTitlePanelNode.swift")
assert "interfaceState.pinnedMessage?.message.isCopyProtectedForLocalUse(peerIsCopyProtected: interfaceState.copyProtectionEnabled) ?? peerCaptureProtected" in pinned
assert "let imageCaptureProtected = message.isCopyProtectedForLocalUse()" in pinned
assert re.search(r'if updateImageSignal != nil && strongSelf\.imageNode\.captureProtected && !imageCaptureProtected \{\s+strongSelf\.imageNode\.layer\.removeAnimation\(forKey: "contents"\)\s+strongSelf\.imageNode\.reset\(\)\s+\}\s+strongSelf\.imageNode\.captureProtected = imageCaptureProtected', pinned)
assert "strongSelf.imageNode.setSignal(updateImageSignal, dispatchOnDisplayLink: false)" in pinned

# Capture and OCR use the shared policy, with no unconditional paid-media override.
for path in ("submodules/GalleryUI/Sources/GalleryController.swift", "submodules/GalleryUI/Sources/Items/ChatImageGalleryItem.swift", CHAT + "ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift"):
    source = read(path)
    for line in source.splitlines():
        if "isCopyProtectedForLocalUse(" in line:
            assert "paidContent" not in line and "isExtendedMedia" not in line, line
image_gallery = read("submodules/GalleryUI/Sources/Items/ChatImageGalleryItem.swift")
assert "guard let message = self.message, !message.isCopyProtectedForLocalUse() else" in image_gallery

# Trace protection all the way to HLS output, thumbnail reuse and scrubber frames.
capture_sources = {
    "gallery": read("submodules/GalleryUI/Sources/GalleryController.swift"),
    "inline": read(CHAT + "ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift"),
    "hls": read("submodules/TelegramUniversalVideoContent/Sources/HLSVideoContent.swift"),
    "hls_node": read("submodules/TelegramUniversalVideoContent/Sources/HLSVideoJSNativeContentNode.swift"),
    "image": image_gallery,
    "video": read("submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift"),
    "thumbnails": read("submodules/GalleryUI/Sources/GalleryThumbnailContainerNode.swift"),
    "footer": read("submodules/GalleryUI/Sources/ChatItemGalleryFooterContentNode.swift"),
}


def check_media_capture_wiring(sources):
    for key in ("gallery", "inline"):
        calls = re.findall(r"= HLSVideoContent\(([\s\S]*?)codecConfiguration:", sources[key])
        assert len(calls) == 1 and "captureProtected: captureProtected" in calls[0], key
    assert "self.captureProtected = captureProtected" in sources["hls"]
    assert "captureProtected: self.captureProtected" in sources["hls"]
    assert "self.imageNode.captureProtected = captureProtected" in sources["hls_node"]
    assert "MediaPlayerNode(captureProtected: captureProtected)" in sources["hls_node"]
    assert "var captureProtected: Bool { get }" in sources["thumbnails"]
    assert "self.imageNode.captureProtected = item.captureProtected" in sources["thumbnails"]
    assert "self.captureProtected = captureProtected" in sources["image"]
    assert "self.thumbnail == to.thumbnail && self.captureProtected == to.captureProtected" in sources["image"]
    thumbnail_calls = [line for key in ("image", "video") for line in sources[key].splitlines() if "= ChatMediaGalleryThumbnailItem(" in line]
    assert len(thumbnail_calls) == 7 and all("captureProtected:" in line for line in thumbnail_calls)
    assert "setFramePreviewImage(image: image, captureProtected: item.captureProtected)" in sources["video"]
    assert "setLayerDisableScreenshots(videoFramePreviewNode.layer, captureProtected)" in sources["footer"]


check_media_capture_wiring(capture_sources)
# Each removed connection must fail, even when the shared boolean policy is correct.
mutations = (
    ("gallery", "captureProtected: captureProtected, codecConfiguration:", "codecConfiguration:"),
    ("inline", "captureProtected: captureProtected,", "captureProtected: false,"),
    ("hls", "captureProtected: self.captureProtected", "captureProtected: false"),
    ("hls_node", "self.imageNode.captureProtected = captureProtected", "self.imageNode.captureProtected = false"),
    ("hls_node", "MediaPlayerNode(captureProtected: captureProtected)", "MediaPlayerNode()"),
    ("thumbnails", "self.imageNode.captureProtected = item.captureProtected", "self.imageNode.captureProtected = false"),
    ("image", " && self.captureProtected == to.captureProtected", ""),
    ("image", "mediaReference: mediaReference, captureProtected: captureProtected", "mediaReference: mediaReference"),
    ("video", "captureProtected: item.captureProtected", "captureProtected: item.isSecret"),
    ("footer", "setLayerDisableScreenshots(videoFramePreviewNode.layer, captureProtected)", "setLayerDisableScreenshots(videoFramePreviewNode.layer, false)"),
)
for key, old, new in mutations:
    assert old in capture_sources[key], (key, old)
    modified = dict(capture_sources)
    modified[key] = modified[key].replace(old, new)
    try:
        check_media_capture_wiring(modified)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"Missed capture regression: {key}: {old}")

video_policy = body(capture_sources["video"], "var captureProtected: Bool {")
assert "return self.isSecret" in video_policy
video_capture = expression(video_policy.split("\n        }", 1)[0], "return ", {
    "message.isCopyProtectedForLocalUse(peerIsCopyProtected: self.peerIsCopyProtected)": "local_protected",
    "self.isSecret": "is_secret",
    "message.id.peerId.namespace": "namespace",
    "Namespaces.Peer.SecretChat": '"secret"',
    "message.containsSecretMedia": "secret_media",
    "message.minAutoremoveOrClearTimeout": "timeout",
    "viewOnceTimeout": "view_once_timeout",
})
for local_protected, is_secret, secret_chat, secret_media, once in product(*((False, True),) * 5):
    assert video_capture(local_protected=local_protected, is_secret=is_secret,
                         namespace="secret" if secret_chat else "channel", secret_media=secret_media,
                         timeout=100 if once else None, view_once_timeout=100) == any((local_protected, is_secret, secret_chat, secret_media, once))
    cases += 1

thumbnail_equal = expression(body(image_gallery, "func isEqual(to: GalleryThumbnailItem)").split("\n        }", 1)[0], "return ", {
    "self.thumbnail == to.thumbnail": "same_media",
    "self.captureProtected": "old_protected",
    "to.captureProtected": "new_protected",
})
for same_media, old_protected, new_protected in product(*((False, True),) * 3):
    assert thumbnail_equal(same_media=same_media, old_protected=old_protected, new_protected=new_protected) == (same_media and old_protected == new_protected)
    cases += 1

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

print(f"Content restriction checks passed: {cases} synthetic boundary cases, {len(mutations)} capture regression controls, UI wiring and localization. No Swift compilation or device validation.")
