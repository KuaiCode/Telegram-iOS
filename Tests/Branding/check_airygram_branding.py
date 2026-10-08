"""Static branding checks; run from any directory with Python 3."""

import ast
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct


ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "dev.kuaicode.airygram"


def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")


def check_branding():
    for path in (
        "build-system/appcenter-configuration.json",
        "build-system/appstore-configuration.json",
        "build-system/template_minimal_development_configuration.json",
    ):
        assert json.loads(read(path))["bundle_id"] == BUNDLE_ID, path
    assert f'telegram_bundle_id = "{BUNDLE_ID}"' in read(
        "build-system/example-configuration/variables.bzl"
    )
    assert f'FALLBACK_BASE_BUNDLE_ID: String = "{BUNDLE_ID}"' in read(
        "Swiftgram/SGAppGroupIdentifier/Sources/SGAppGroupIdentifier.swift"
    )
    for path in ("Config-AppStoreLLC.xcconfig", "Config-Fork.xcconfig"):
        config = read(f"Telegram/Telegram-iOS/{path}")
        assert "APP_NAME=Airygram" in config, path
        assert f"APP_BUNDLE_ID={BUNDLE_ID}" in config, path

    manager = read("Swiftgram/SGStrings/Sources/LocalizationManager.swift")
    brand_cases = manager.split("switch key {", 1)[1].split("default:", 1)[0]
    branded_keys = set(re.findall(r'"([A-Za-z]+(?:\.[A-Za-z]+)+)"', brand_cases))
    upstream_keys = {
        "PayWall.About.Notice",
        "PayWall.Notice.Markdown",
        "PayWall.Notice.Raw",
    }
    assert branded_keys.isdisjoint(upstream_keys)
    # Every existing branded translation must be app-owned or explicitly upstream.
    seen = set()
    strings_pattern = re.compile(r'^"([^"\n]+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
    for path in (ROOT / "Swiftgram/SGStrings/Strings").glob("*.lproj/SGLocalizable.strings"):
        for key, value in strings_pattern.findall(path.read_text(encoding="utf-8-sig")):
            if "Swiftgram" in value:
                assert key in branded_keys | upstream_keys, (path, key)
                seen.add(key)
    assert branded_keys <= seen
    assert upstream_keys <= seen
    assert '"SwiftgramBot"' in read("Swiftgram/SGConfig/Sources/File.swift")
    assert "https://raw.githubusercontent.com/Swiftgram/Telegram-iOS/" in manager
    english = read("Swiftgram/SGStrings/Strings/en.lproj/SGLocalizable.strings")
    assert '"PayWall.TermsURL" = "https://swiftgram.app/terms";' in english
    assert '"PayWall.About.Signature" = "@Kylmakalle";' in english

    korean = read("Telegram/Telegram-iOS/ko.lproj/InfoPlist.strings")
    assert '"CFBundleDisplayName" = "Airygram";' in korean
    app_strings = read("Telegram/Telegram-iOS/en.lproj/Localizable.strings")
    assert '"Tour.Title1" = "Airygram";' in app_strings
    assert '"Application.Name" = "Airygram";' in app_strings
    assert "Swiftgram" not in app_strings
    assert "Telegram's heavily encrypted cloud servers" in read(
        "Telegram/Telegram-iOS/en.lproj/InfoPlist.strings"
    )
    assert 'localizedName: "Airygram"' in read(
        "submodules/TelegramCallsUI/Sources/CallKitIntegration.swift"
    )
    print("Airygram branding checks passed.")


def check_icons():
    app = ROOT / "Telegram/Telegram-iOS"
    catalog = app / "DefaultAppIcon.xcassets"
    icon_sets = list(catalog.glob("*.appiconset"))
    assert len(icon_sets) == 1, icon_sets
    icon_set = icon_sets[0]
    preview = app / "Icons.xcassets/AirygramIcon.imageset"
    for directory, size in ((icon_set, 1024), (preview, 180)):
        images = json.loads((directory / "Contents.json").read_text())["images"]
        assert len(images) == 2, directory
        assert [image.get("appearances", []) for image in images] == [
            [], [{"appearance": "luminosity", "value": "dark"}]
        ], directory
        hashes = set()
        for image in images:
            png = (directory / image["filename"]).read_bytes()
            assert png[:8] == b"\x89PNG\r\n\x1a\n"
            assert png[12:16] == b"IHDR"
            width, height, depth, color_type = struct.unpack(">IIBB", png[16:26])
            assert (width, height, depth, color_type) == (size, size, 8, 2), image
            hashes.add(hashlib.sha256(png).digest())
            if directory == icon_set:
                assert image["platform"] == "ios" and image["size"] == "1024x1024"
        assert len(hashes) == 2, "Light and dark assets must differ"
        assert {p.name for p in directory.glob("*.png")} == {i["filename"] for i in images}

    for watch in ("Telegram/Watch/App", "Telegram/WatchApp/tgwatch Watch App"):
        watch_path = ROOT / watch
        watch_icon = watch_path / "Assets.xcassets/AppIcon.appiconset"
        images = json.loads((watch_icon / "Contents.json").read_text())["images"]
        assert len(images) == 1 and images[0]["platform"] == "watchos"
        assert (watch_icon / images[0]["filename"]).read_bytes() == (icon_set / "Airygram.png").read_bytes()
        assert not (watch_icon / "Swiftgram.png").exists()
        info = plistlib.loads((watch_path / "Info.plist").read_bytes())
        assert info["CFBundleDisplayName"] == info["CFBundleName"] == "Airygram"

    # Verify the build selects this catalog, and UIKit's preview resolves to a real imageset.
    build = read("Telegram/BUILD")
    tree = ast.parse(build)
    targets = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            arguments = {keyword.arg: keyword.value for keyword in node.keywords}
            name = arguments.get("name")
            if isinstance(name, ast.Constant):
                targets[name.value] = arguments
    assert ast.literal_eval(targets["Swiftgram"]["app_icons"]) == [":DefaultAppIcon"]
    assert "alternate_icons" not in targets["Swiftgram"]
    patterns = ast.literal_eval(targets["DefaultAppIcon"]["srcs"].args[0])
    assert any(icon_set / "Contents.json" in (ROOT / "Telegram").glob(p) for p in patterns)
    app_delegate = read("submodules/TelegramUI/Sources/AppDelegate.swift")
    image_names = re.findall(r'PresentationAppIcon\([^\n]+imageName: "([^"]+)"', app_delegate)
    assert image_names == [preview.stem]
    assert "setAlternateIconName(" not in app_delegate
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert "CFBundleIcons" not in info and "CFBundleIcons~ipad" not in info
    assert info["CFBundleDisplayName"] == info["CFBundleName"] == "Airygram"
    main_info = ast.literal_eval(targets["TelegramInfoPlist"]["template"].func.value)
    assert '<key>CFBundleDisplayName</key>\n    <string>Airygram</string>' in main_info

    assert not list(app.glob("*.alticon")) and not list(app.glob("*.icon"))
    for path in (
        "Telegram/Telegram-iOS/AlternateIcons.plist",
        "Telegram/Telegram-iOS/AlternateIcons-iPad.plist",
        "Telegram/Telegram-iOS/AddAlternateIcons.sh",
        "Telegram/Telegram-iOS/Icons.xcassets/Shortcuts/AppIcon.imageset",
        "submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift",
        "submodules/TelegramUI/Images.xcassets/Premium/Icons",
        "Swiftgram/SGPayWall/Images.xcassets/ProDetailsIcons.imageset",
    ):
        assert not (ROOT / path).exists(), path
    watch_project = read("Telegram/WatchApp/project.yml")
    assert "WKCompanionAppBundleIdentifier: $(PRODUCT_BUNDLE_IDENTIFIER:base)" in watch_project
    assert f"PRODUCT_BUNDLE_IDENTIFIER: {BUNDLE_ID}.watchkitapp" in watch_project
    print("Airygram icon assets and build wiring checks passed.")


if __name__ == "__main__":
    check_branding()
    check_icons()
