import Foundation
import BuildConfig

private let appGroupLocation: AppGroupLocation? = {
    guard let groups = BuildConfig.applicationGroupIdentifiers() else {
        NSLog("Airygram: unable to read App Group entitlements")
        return nil
    }
    return AppGroupLocation(baseBundleId: sgBaseBundleIdentifier(), groups: groups, isExtension: Bundle.main.bundlePath.hasSuffix(".appex"))
}()

public func sgResolvedAppGroupIdentifier() -> String? {
    return appGroupLocation?.identifier
}

public func sgAppGroupContainerURL() -> URL? {
    guard let location = appGroupLocation else { return nil }
    let manager = FileManager.default
    let groupContainer = location.identifier.flatMap { manager.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    let privateContainer = manager.urls(for: .documentDirectory, in: .userDomainMask).first
    guard let url = location.containerURL(groupContainer: groupContainer, privateContainer: privateContainer) else { return nil }
    do {
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    } catch {
        NSLog("Airygram: unable to prepare data container: %@", String(describing: error))
        return nil
    }
}

public func sgSharedUserDefaults() -> UserDefaults? {
    guard let location = appGroupLocation else { return nil }
    if let identifier = location.identifier {
        return UserDefaults(suiteName: identifier)
    }
    return location.isExtension ? nil : .standard
}

public func sgSharedDefaultsKey(_ key: String) -> String {
    return appGroupLocation?.defaultsKey(key) ?? "\(sgBaseBundleIdentifier()).\(key)"
}

public let FALLBACK_BASE_BUNDLE_ID: String = "dev.kuaicode.airygram"

public func sgBaseBundleIdentifier() -> String {
    let baseBundleId: String
    if let bundleId: String = Bundle.main.bundleIdentifier {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            if let lastDotRange: Range<String.Index> = bundleId.range(of: ".", options: [.backwards]) {
                baseBundleId = String(bundleId[..<lastDotRange.lowerBound])
            } else {
                baseBundleId = FALLBACK_BASE_BUNDLE_ID
            }
        } else {
            baseBundleId = bundleId
        }
    } else {
        baseBundleId = FALLBACK_BASE_BUNDLE_ID
    }
    return baseBundleId
}

public func sgAppGroupIdentifier() -> String {
    let result: String = "group.\(sgBaseBundleIdentifier())"
    
    #if DEBUG
    print("APP_GROUP_IDENTIFIER: \(result)")
    #endif
    
    return result
}
