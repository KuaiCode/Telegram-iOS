# Airygram

Telegram fork for iOS, based on Swiftgram.

Upstream Swiftgram links:

[<img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" height="50">](https://apps.apple.com/app/apple-store/id6471879502?pt=126511626&ct=gh&mt=8)

- Download: [App Store](https://apps.apple.com/app/apple-store/id6471879502?pt=126511626&ct=gh&mt=8)
- Telegram channel: https://t.me/swiftgram
- Telegram chat: https://t.me/swiftgramchat
- TestFlight beta, local chats, translations and other [@SwiftgramLinks](https://t.me/s/SwiftgramLinks)

Airygram's compilation steps follow the upstream app. The internal Bazel targets and module names remain unchanged.

## 使用 GitHub Actions 编译（无需本地 macOS）

工作流 `.github/workflows/build.yml` 手动构建 **iPhone ARM64 未签名 IPA**，不需要 Apple 开发者证书；不包含 Watch app，也不自动发布 Release。

1. 将本次配置推送到你自己的 GitHub 仓库默认分支。在仓库 **Actions** 页面启用工作流（fork 首次使用可能需要手动启用）。
2. 在 [my.telegram.org/apps](https://my.telegram.org/apps) 获取自己的 Telegram API 凭据。进入仓库 **Settings → Secrets and variables → Actions → New repository secret**，添加 `TELEGRAM_API_ID`（数字）和 `TELEGRAM_API_HASH`（32 位十六进制字符串）。缺少或格式错误会在编译前报错；不要使用上游示例凭据。
3. 进入 **Actions → Build Airygram unsigned IPA → Run workflow**，选择包含配置的分支并运行。
4. 成功后，在该次运行的 **Artifacts** 下载 `Airygram-unsigned-运行编号`，解压得到 `Airygram-unsigned.ipa` 和调试符号压缩包。失败时查看步骤日志；进入编译阶段后还会上传 `Airygram-build-log-运行编号`。产物保留 14 天。

工作流使用 macOS 26 ARM runner，严格按 `versions.json` 选择 Xcode（当前为 26.2）和 Bazel，并递归拉取 Git 子模块。GitHub 镜像若移除所需 Xcode，会明确失败，不会自动换版本。首次完整构建可能耗时较长；私有仓库注意账户的 Actions 用量和预算。

CI 会应用 `build-system/patches/rules-apple-unsigned-profiles.patch`，让锁定版本的 `rules_apple` 在禁用签名时不再要求嵌入描述文件，覆盖主 App 和 iOS 扩展。补丁仅应用到 runner 的临时子模块副本，并检查签名/未签名及设备/模拟器组合；升级子模块后若补丁不适用，工作流会报错。

Bundle ID 保持 `dev.kuaicode.airygram`。`AAAAAAAAAA` 仅用于未签名构建的 Team ID 占位，**不是有效 Apple Team ID**。IPA 不能直接安装或提交 App Store，需要自行签名；签名时应使用自己的 Team ID、描述文件，并处理主 App 和扩展的 App Group、钥匙串等 entitlement。推送等功能仍依赖有效签名及相应服务配置。

API 凭据只写入 CI 的 `build-input/`（已被 Git 忽略），但会编译进应用；不要把 IPA 当作隐藏这些凭据的方式。工作流仅上传 IPA、调试符号和构建日志，不上传生成的配置文件。

本地可运行 `python scripts/test_ci_unsigned_configuration.py` 检查配置生成与无效输入处理；真正的编译结果以 GitHub Actions 运行为准。

# Telegram iOS Source Code Compilation Guide

We welcome all developers to use our API and source code to create applications on our platform.
There are several things we require from **all developers** for the moment.

# Creating your Telegram Application

1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use our standard logo (white paper plane in a blue circle) as your app's logo.
3. Please study our [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
4. Please remember to publish **your** code too in order to comply with the licences.

# Quick Compilation Guide

## Get the Code

```
git clone --recursive -j8 https://github.com/Swiftgram/Telegram-iOS.git
```

## Setup Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

## Adjust Configuration

1. Use `dev.kuaicode.airygram` as the app's Bundle Identifier and register `group.dev.kuaicode.airygram` as its App Group in your Apple Developer account.
2. Create a new Xcode project. Use `Airygram` as the Product Name and `dev.kuaicode` as the Organization Identifier, then set the Bundle Identifier to `dev.kuaicode.airygram` exactly.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Keep `bundle_id` as `dev.kuaicode.airygram` and supply your own Telegram `api_id` / `api_hash` and Apple `team_id`.

The extensions derive their identifiers from this Bundle Identifier. Provision the matching extension IDs and App Group; an embedded Watch app uses `dev.kuaicode.airygram.watchkitapp`. If enabled, iCloud uses `iCloud.dev.kuaicode.airygram`. Existing example certificates, provisioning profiles, API credentials, and upstream service configuration are not Airygram credentials and must be configured for your own build. A different Bundle Identifier installs as a separate app and does not automatically inherit another installation's local data or login state.

Airygram has one app icon with ordinary and dark appearances. iOS selects the appearance using the Home Screen icon setting, independently of the in-app chat theme. Earlier iOS versions use the ordinary icon. The app no longer offers alternate icons; Watch uses the ordinary artwork.

Run `python3 Tests/Branding/check_airygram_branding.py` to check branding, icon files, and build references without Xcode. This does not replace a macOS build or testing the icon appearances on a device.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

# Advanced Compilation Guide

## Xcode

1. Copy and edit `build-system/appstore-configuration.json`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

## IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## Telegram_xcodeproj: no such package 

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```
