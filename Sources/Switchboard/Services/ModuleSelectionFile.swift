import Foundation

enum ModuleSelectionFile {
    static func load(from applicationSupportURL: URL) throws -> Set<String> {
        let url = applicationSupportURL.appending(path: "enabled-modules.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    static func save(_ moduleIDs: Set<String>, to applicationSupportURL: URL) throws {
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = applicationSupportURL.appending(path: "enabled-modules.json")
        try JSONEncoder().encode(moduleIDs.sorted()).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
