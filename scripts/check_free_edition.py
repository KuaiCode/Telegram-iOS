"""Read-only source regression checks; run from any directory with Python 3.

These checks guard the reviewed free-edition integration, not Swift compilation
or runtime behavior. New gates/call sites intentionally require review.
"""

import ast
from itertools import product
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
POLICY = "SGFeaturePolicy.isFreeEdition"
UI = "submodules/TelegramUI/"
APP = UI + "Sources/AppDelegate.swift"
SHARED = UI + "Sources/SharedAccountContext.swift"
URLS = UI + "Sources/OpenUrl.swift"
NOTIFICATIONS = "Telegram/NotificationService/Sources/NotificationService.swift"
FILTER = UI + "Components/Chat/ChatMessageItemView/Sources/ChatMessageItemView.swift"
TOOLBARS = (
    "submodules/AttachmentTextInputPanelNode/Sources/AttachmentTextInputPanelNode.swift",
    UI + "Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift",
    UI + "Components/MessageInputPanelComponent/Sources/MessageInputPanelComponent.swift",
)
GATES = {
    NOTIFICATIONS: 2,
    FILTER: 1,
    "Swiftgram/SGProUI/Sources/AppBadgeSelectorController.swift": 1,
    "submodules/Display/Source/WindowContent.swift": 1,
    URLS: 1,
    UI + "Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift": 1,
    UI + "Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift": 1,
    **dict.fromkeys(TOOLBARS, 1),
}
STATUS_FIELD = (
    r"(?:\b(?:immediateSGStatus|sgStatus)\s*\.\s*status"
    r"|SGSimpleSettings\s*\.\s*shared\s*\.\s*(?:status|ephemeralStatus))"
)
COMPARISON = re.compile(
    rf"{STATUS_FIELD}\s*(?:[<>]=?|[!=]=)\s*\d+"
    rf"|\d+\s*(?:[<>]=?|[!=]=)\s*{STATUS_FIELD}"
)
GUARD = re.compile(rf"guard\s+!{re.escape(POLICY)}\s+else\s*{{\s*return\s*}}")


def source_only(source):
    # shortcut: this is a source-shape check, use Swift tooling for semantic analysis.
    return re.sub(r"(?m)^\s*//[^\n]*", "", source)


def check_sources(sources):
    failures = []

    def require(condition, message):
        if not condition:
            failures.append(message)

    def read(path):
        require(path in sources, f"Missing source: {path}")
        return source_only(sources.get(path, ""))

    def prefix(path, start, before):
        text = read(path)
        require(text.count(start) == 1, f"Review function/section: {path}: {start}")
        tail = text.partition(start)[2]
        require(before in tail, f"Missing boundary: {path}: {before}")
        return tail.partition(before)[0].strip()

    policy = read("Swiftgram/SGSimpleSettings/Sources/SGFeaturePolicy.swift")
    require(re.search(r"public\s+static\s+let\s+isFreeEdition\s*=\s*true\b", policy),
            "Free-edition policy must remain a fixed public true constant")

    counts = {}
    for path, raw in sources.items():
        if not path.endswith(".swift"):
            continue
        if not any(token in raw for token in ("SGFeaturePolicy", "immediateSGStatus", "sgStatus", "SGSimpleSettings")):
            continue
        text = source_only(raw)
        for match in COMPARISON.finditer(text):
            counts[path] = counts.get(path, 0) + 1
            line_start = text.rfind("\n", 0, match.start()) + 1
            condition = text[line_start:match.start()]
            require(POLICY + " || " in condition,
                    f"Unreviewed SG membership gate: {path}: {match.group()}")
        if "SGFeaturePolicy" in text and "/SGSimpleSettings/" not in path:
            require("import SGSimpleSettings" in text, f"Missing policy import: {path}")
            directory = Path(path).parent
            while directory != Path(".") and str(directory / "BUILD").replace("\\", "/") not in sources:
                directory = directory.parent
            build = str(directory / "BUILD").replace("\\", "/")
            require("//Swiftgram/SGSimpleSettings:SGSimpleSettings" in sources.get(build, ""),
                    f"Missing policy module dependency: {path} ({build})")
    require(counts == GATES, f"Review changed SG gate inventory (expected 11): {counts}")

    # Preserve feature choices and notification guards around the free entitlement.
    for path in TOOLBARS:
        text = read(path)
        require(re.search(r"guard SGSimpleSettings\.shared\.inputToolbar else \{ return \}\s*"
                          rf"guard {re.escape(POLICY)} \|\|", text),
                f"Input toolbar user switch must precede entitlement: {path}")
    filtered = read(FILTER)
    require("!self.wasFilteredKeywordTested && !SGSimpleSettings.shared.messageFilterKeywords.isEmpty && ("
            + POLICY + " || SGSimpleSettings.shared.ephemeralStatus > 1)" in filtered,
            "Message keyword filter guards/grouping changed")
    notifications = read(NOTIFICATIONS)
    for flag in ("isEmpty", "silent"):
        require(f"({POLICY} || self.sgStatus.status > 1) && !self.{flag}" in notifications,
                f"Notification !{flag} guard/grouping changed")
    require("let image = UIImage(bundleImageName: SGSimpleSettings.shared.customAppBadge)" in
            read("submodules/Display/Source/WindowContent.swift"), "Badge selection/image fallback changed")

    initialization = prefix(SHARED, "func initSGIAP(isMainApp: Bool) {", "public func makeSGProController")
    require(re.search(rf"if isMainApp && !{re.escape(POLICY)}\s*{{\s*"
                      r"self\.SGIAP = SGIAPManager\(\)\s*}\s*else\s*{\s*self\.SGIAP = nil", initialization),
            "SG StoreKit manager must not initialize in the free edition")
    for declaration in ("func setupIAP() {", "func sendReceiptForVerification(primaryContext: AccountContext) async {",
                        "func fetchSGStatus(primaryContext: AccountContext) async {"):
        tail = read(APP).partition(declaration)[2].lstrip()
        require(bool(tail) and GUARD.match(tail), f"Missing first-line free-edition guard: {declaration}")
    require(re.search(rf"if #available\(iOS 13\.0, \*\), !{re.escape(POLICY)}\s*{{\s*"
                      r"let _ = Task \{\s*let primaryContext = await self\.getPrimaryContext", read(APP)),
            "Startup must not schedule the SG membership task")

    factory = prefix(SHARED, "public func makeSGPayWallController(context: AccountContext) -> ViewController? {",
                     "guard #available")
    require(re.fullmatch(rf"if {re.escape(POLICY)}\s*{{\s*"
                         r"return self\.makeSGProController\(context: context\)\s*}", factory),
            "Legacy paywall factory must return Pro settings before availability/nil checks")
    restore = prefix(URLS, 'case "restore_purchases", "pro_restore", "validate", "restore":',
                     "let presentationData")
    require(re.fullmatch(rf"if {re.escape(POLICY)}\s*{{\s*navigationController\?\.pushViewController\("
                         r"context\.sharedContext\.makeSGProController\(context: context\)\)\s*return\s*}", restore),
            "Restore links must route to Pro settings and return before the restoring overlay")

    for path, actions in (("Swiftgram/SGDebugUI/Sources/SGDebugUI.swift", ("restorePurchases", "resetIAP")),
                          ("Swiftgram/SGProUI/Sources/SGProUI.swift", ("resetIAP",))):
        text = read(path)
        hidden = re.findall(rf"if !{re.escape(POLICY)}\s*{{([^{{}}]*)}}", text, re.S)
        for action in actions:
            require(any(f"actionType: .{action}," in group for group in hidden),
                    f"Paid debug/settings entry visible: {path}: {action}")
            require(GUARD.match(text.partition(f"case .{action}:")[2].lstrip()),
                    f"Paid debug/settings action unguarded: {path}: {action}")

    # New direct constructors/API calls can bypass the protected entry points.
    for symbol, expected in (
        ("SGIAPManager", {SHARED: 1}),
        ("sgPayWallController", {SHARED: 1}),
        ("postSGReceipt", {APP: 1}),
        ("sgIqtpQuery", {APP: 1}),
    ):
        calls = {}
        pattern = re.compile(rf"\b{symbol}\s*\(")
        for path, text in sources.items():
            if not path.endswith(".swift") or symbol not in text:
                continue
            text = source_only(text)
            text = re.sub(rf"\bfunc\s+{symbol}\s*\(", "func declaration(", text)
            count = len(pattern.findall(text))
            if count:
                calls[path] = count
        require(calls == expected, f"Review new/moved {symbol} call sites: {calls}")

    status = read("Swiftgram/SGStatus/Sources/SGStatus.swift")
    for fragment in ("return SGStatus(status: 1)", "self.status = status",
                     'decodeIfPresent(Int64.self, forKey: "status") ?? 1',
                     'encodeIfPresent(self.status, forKey: "status")'):
        require(fragment in status, f"SGStatus persisted semantics changed: {fragment}")
    settings = read("Swiftgram/SGSimpleSettings/Sources/SimpleSettings.swift")
    require("public var ephemeralStatus: Int64 = 1" in settings, "Do not fabricate cached membership")
    require("SGSimpleSettings.shared.ephemeralStatus = settings.status" in read(SHARED),
            "Existing status synchronization must remain intact")
    for path in (
        "Swiftgram/SGAPI/Sources/SGAPI.swift", "Swiftgram/SGAPIWebSettings/Sources/File.swift",
        "Swiftgram/SGAPIToken/Sources/SGAPIToken.swift", "Swiftgram/SGIQTP/Sources/SGIQTP.swift",
        "Swiftgram/SGRegDate/Sources/SGRegDate.swift", "Swiftgram/SGGHSettings/Sources/SGGHSettings.swift",
        "Swiftgram/SGStrings/Sources/LocalizationManager.swift",
        "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramUser.swift",
        "submodules/TelegramCore/Sources/TelegramEngine/Messages/Transcription.swift",
    ):
        require("SGFeaturePolicy" not in read(path), f"Free policy leaked into a retained service/data model: {path}")
    return failures


def check_feature_boundaries(sources):
    """Evaluate the actual three compound Swift conditions over 80 input cases."""
    cases = (
        (NOTIFICATIONS, "&& !self.isEmpty", {"self.isEmpty": "blocked"}),
        (NOTIFICATIONS, "&& !self.silent", {"self.silent": "blocked"}),
        (FILTER, "if !self.wasFilteredKeywordTested", {
            "self.wasFilteredKeywordTested": "tested",
            "SGSimpleSettings.shared.messageFilterKeywords.isEmpty": "empty",
        }),
    )
    for path, marker, replacements in cases:
        line = next(line.strip() for line in sources[path].splitlines() if marker in line)
        expression = line.removeprefix("if ").removesuffix(" {")
        for old, new in {POLICY: "free", "self.sgStatus.status": "status",
                         "SGSimpleSettings.shared.ephemeralStatus": "status", **replacements}.items():
            expression = expression.replace(old, new)
        expression = expression.replace("&&", " and ").replace("||", " or ").replace("!", "not ").strip()
        tree = ast.parse(expression, mode="eval")
        for node in ast.walk(tree):
            assert isinstance(node, (ast.Expression, ast.BoolOp, ast.UnaryOp, ast.Compare,
                                     ast.Name, ast.Load, ast.Constant, ast.And, ast.Or, ast.Not, ast.Gt)), marker
            if isinstance(node, ast.Name):
                assert node.id in {"free", "status", "blocked", "tested", "empty"}, marker
        code = compile(tree, "<Swift free-edition condition>", "eval")
        for free, status in product((False, True), (-1, 0, 1, 2, 3)):
            flags = product((False, True), repeat=len(replacements))
            for values in flags:
                inputs = dict(zip(replacements.values(), values), free=free, status=status)
                expected = not any(values) and (free or status > 1)
                assert eval(code, {"__builtins__": {}}, inputs) == expected, (marker, inputs)


def check_detector(sources):
    """Mutate in memory so a permanently passing source check cannot pass itself."""
    mutations = (
        (NOTIFICATIONS, POLICY + " || ", "", "Unreviewed SG membership gate"),
        (APP, "guard !" + POLICY + " else { return }", "", "Missing first-line"),
        (SHARED, "return self.makeSGProController(context: context)", "return nil", "Legacy paywall factory"),
        (NOTIFICATIONS, "&& !self.silent", "", "Notification !silent"),
    )
    for path, old, new, expected in mutations:
        assert old in sources[path], f"Mutation fixture moved: {path}: {old}"
        changed = dict(sources)
        changed[path] = changed[path].replace(old, new, 1)
        assert any(expected in failure for failure in check_sources(changed)), expected
    changed = dict(sources)
    changed["Swiftgram/NewGate.swift"] = "if context.sharedContext.immediateSGStatus.status >= 2 {}"
    assert any("Unreviewed SG membership gate" in failure for failure in check_sources(changed))
    changed = dict(sources)
    changed["Swiftgram/NewPurchase.swift"] = "let manager = SGIAPManager()"
    assert any("SGIAPManager call sites" in failure for failure in check_sources(changed))


if __name__ == "__main__":
    sources = {}
    for directory in ("Swiftgram", "submodules", "Telegram"):
        for path in (ROOT / directory).rglob("*"):
            if path.is_file() and (path.suffix == ".swift" or path.name == "BUILD"):
                sources[path.relative_to(ROOT).as_posix()] = path.read_text(encoding="utf-8-sig")
    failures = check_sources(sources)
    if failures:
        print("Free-edition source checks failed:")
        for failure in failures:
            print("- " + failure)
    else:
        check_feature_boundaries(sources)
        check_detector(sources)
        print("Free-edition source checks passed (11 gates; 80 boundary cases; 6 in-memory mutations).")
    print("Static checks only; macOS/iOS compilation and real-device tests remain required.")
    sys.exit(bool(failures))
