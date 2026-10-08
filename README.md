# Airygram

Telegram fork for iOS, based on Swiftgram.

Upstream Swiftgram links:

[<img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" height="50">](https://apps.apple.com/app/apple-store/id6471879502?pt=126511626&ct=gh&mt=8)

- Download: [App Store](https://apps.apple.com/app/apple-store/id6471879502?pt=126511626&ct=gh&mt=8)
- Telegram channel: https://t.me/swiftgram
- Telegram chat: https://t.me/swiftgramchat
- TestFlight beta, local chats, translations and other [@SwiftgramLinks](https://t.me/s/SwiftgramLinks)

Airygram's compilation steps follow the upstream app. The internal Bazel targets and module names remain unchanged.

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
