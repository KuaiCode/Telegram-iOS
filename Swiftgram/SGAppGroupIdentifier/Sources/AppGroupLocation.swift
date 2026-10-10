import Foundation

struct AppGroupLocation {
    let identifier: String?
    let baseBundleId: String
    let isExtension: Bool

    init(baseBundleId: String, groups: [String], isExtension: Bool) {
        self.baseBundleId = baseBundleId
        self.isExtension = isExtension
        let expected = "group.\(baseBundleId)"
        self.identifier = groups.contains(expected) ? expected : groups.sorted().first
    }

    var usesOriginalGroup: Bool {
        return self.identifier == "group.\(self.baseBundleId)"
    }

    func defaultsKey(_ key: String) -> String {
        return self.usesOriginalGroup ? key : "\(self.baseBundleId).\(key)"
    }

    func containerURL(groupContainer: URL?, privateContainer: URL?) -> URL? {
        if self.identifier != nil {
            // Never switch an existing shared database to private storage on an access error.
            guard let groupContainer = groupContainer else { return nil }
            return self.usesOriginalGroup ? groupContainer : groupContainer.appendingPathComponent("Airygram.\(self.baseBundleId)", isDirectory: true)
        }
        guard !self.isExtension, let privateContainer = privateContainer else { return nil }
        return privateContainer.appendingPathComponent("Airygram.\(self.baseBundleId)", isDirectory: true)
    }
}
