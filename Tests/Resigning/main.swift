import Foundation

let bundle = "dev.kuaicode.airygram"
let shared = URL(fileURLWithPath: "/shared", isDirectory: true)
let documents = URL(fileURLWithPath: "/private/Documents", isDirectory: true)
let original = AppGroupLocation(baseBundleId: bundle, groups: ["group.other", "group.\(bundle)"], isExtension: false)
assert(original.identifier == "group.\(bundle)")
assert(original.containerURL(groupContainer: shared, privateContainer: documents) == shared)
assert(original.defaultsKey("status") == "status")

let groups = ["group.z", "group.a"]
let resigned = AppGroupLocation(baseBundleId: bundle, groups: groups, isExtension: false)
let extensionLocation = AppGroupLocation(baseBundleId: bundle, groups: Array(groups.reversed()), isExtension: true)
assert(resigned.identifier == extensionLocation.identifier)
assert(resigned.identifier == "group.a")
let isolated = shared.appendingPathComponent("Airygram.\(bundle)", isDirectory: true)
assert(resigned.containerURL(groupContainer: shared, privateContainer: nil) == isolated)
assert(extensionLocation.containerURL(groupContainer: shared, privateContainer: nil) == isolated)
assert(isolated != shared.appendingPathComponent("Swiftgram", isDirectory: true))
assert(resigned.defaultsKey("status") == "\(bundle).status")
assert(resigned.defaultsKey("status") == extensionLocation.defaultsKey("status"))

let otherApp = AppGroupLocation(baseBundleId: "app.swiftgram.ios", groups: groups, isExtension: false)
assert(otherApp.containerURL(groupContainer: shared, privateContainer: nil) != isolated)
assert(otherApp.defaultsKey("status") != resigned.defaultsKey("status"))
// A failed shared lookup must not silently open a second, empty private database.
assert(resigned.containerURL(groupContainer: nil, privateContainer: documents) == nil)
assert(original.containerURL(groupContainer: nil, privateContainer: documents) == nil)

let privateApp = AppGroupLocation(baseBundleId: bundle, groups: [], isExtension: false)
let privateExtension = AppGroupLocation(baseBundleId: bundle, groups: [], isExtension: true)
assert(privateApp.containerURL(groupContainer: nil, privateContainer: documents) == documents.appendingPathComponent("Airygram.\(bundle)", isDirectory: true))
assert(privateExtension.containerURL(groupContainer: nil, privateContainer: documents) == nil)
assert(privateApp.containerURL(groupContainer: nil, privateContainer: nil) == nil)
print("App Group selection, data isolation, preferences and failure-path checks passed.")
