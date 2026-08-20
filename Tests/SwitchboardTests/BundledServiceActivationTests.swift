import Foundation
import Testing
@testable import Switchboard

struct BundledServiceActivationTests {
    private let canonical = BundledServiceActivation.canonicalAppURL
    private let serviceName = "Copy.workflow"
    private let servicesDirectory = URL(fileURLWithPath: "/fixture/home/Library/Services", isDirectory: true)
    private let recoveryRoot = URL(fileURLWithPath: "/fixture/home/Library/Application Support/Switchboard/Services", isDirectory: true)

    @Test
    func traversalAndSymlinkSourcesAreRejected() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)

        #expect(throws: BundledServiceActivationError.self) {
            try activation.enable(bundleURL: canonical, serviceNames: ["../escape.workflow"])
        }

        let source = sourceURL(serviceName)
        fileSystem.addSymbolicLink(at: source, pointingTo: URL(fileURLWithPath: "/tmp/foreign.workflow"))
        #expect(throws: BundledServiceActivationError.self) {
            try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        }

        fileSystem.removeNode(at: source)
        addSource(fileSystem, name: serviceName)
        fileSystem.addSymbolicLink(
            at: source.appendingPathComponent("Contents/Info.plist"),
            pointingTo: URL(fileURLWithPath: "/tmp/foreign.plist")
        )
        #expect(throws: BundledServiceActivationError.self) {
            try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        }
    }

    @Test
    func exactLegacyBackupAndIntentPrecedeReplacement() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)
        addSource(fileSystem, name: serviceName)
        let destination = servicesDirectory.appendingPathComponent(serviceName)
        let legacyMetadata = BundledServiceFileMetadata(
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false,
            posixPermissions: 0o754,
            modificationDate: Date(timeIntervalSince1970: 1234)
        )
        let legacyFile = destination.appendingPathComponent("Contents/legacy.txt")
        fileSystem.addDirectory(at: destination)
        fileSystem.addDirectory(at: destination.appendingPathComponent("Contents"))
        fileSystem.addFile(at: legacyFile, data: Data("legacy bytes".utf8), metadata: legacyMetadata)

        try activation.enable(bundleURL: canonical, serviceNames: [serviceName])

        #expect(fileSystem.atomicMoveCount == 1)
        #expect(try fileSystem.metadata(at: destination)?.isDirectory == true)
        let intentIndex = fileSystem.events.firstIndex { $0.contains(".intent.json") && $0.hasPrefix("write:") }
        let legacyMoveIndex = fileSystem.events.firstIndex { $0.hasPrefix("move:") && $0.contains(".legacy") }
        #expect(intentIndex != nil)
        #expect(legacyMoveIndex != nil)
        #expect(intentIndex! < legacyMoveIndex!)

        let backups = fileSystem.directories(under: recoveryRoot).filter { $0.lastPathComponent.hasSuffix(".legacy") }
        #expect(backups.count == 1)
        let backupFile = backups[0].appendingPathComponent("Contents/legacy.txt")
        #expect(fileSystem.data(at: backupFile) == Data("legacy bytes".utf8))
        #expect(try fileSystem.metadata(at: backupFile)?.posixPermissions == legacyMetadata.posixPermissions)
        #expect(try fileSystem.metadata(at: backupFile)?.modificationDate == legacyMetadata.modificationDate)

        try activation.disable(bundleURL: canonical, serviceNames: [serviceName])
        #expect(fileSystem.data(at: legacyFile) == Data("legacy bytes".utf8))
        #expect(try fileSystem.metadata(at: legacyFile)?.posixPermissions == legacyMetadata.posixPermissions)
        #expect(try fileSystem.metadata(at: legacyFile)?.modificationDate == legacyMetadata.modificationDate)
    }

    @Test
    func failedInstallRollsBackExactLegacyDirectory() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        fileSystem.failOnAtomicMoveNumber = 1
        let activation = makeActivation(fileSystem)
        addSource(fileSystem, name: serviceName)
        let destination = servicesDirectory.appendingPathComponent(serviceName)
        fileSystem.addDirectory(at: destination)
        fileSystem.addDirectory(at: destination.appendingPathComponent("Contents"))
        fileSystem.addFile(
            at: destination.appendingPathComponent("Contents/legacy.txt"),
            data: Data("legacy".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o640, modificationDate: nil)
        )

        #expect(throws: Error.self) {
            try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        }
        #expect(fileSystem.data(at: destination.appendingPathComponent("Contents/legacy.txt")) == Data("legacy".utf8))
        #expect(try fileSystem.metadata(at: destination)?.isDirectory == true)
        #expect(fileSystem.files(under: recoveryRoot).isEmpty)
    }

    @Test
    func failedSecondInstallRollsBackEveryService() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        fileSystem.failOnAtomicMoveNumber = 2
        let activation = makeActivation(fileSystem)
        let first = "One.workflow"
        let second = "Two.workflow"
        addSource(fileSystem, name: first)
        addSource(fileSystem, name: second)
        addLegacy(fileSystem, name: first, contents: "first legacy")
        addLegacy(fileSystem, name: second, contents: "second legacy")

        #expect(throws: Error.self) {
            try activation.enable(bundleURL: canonical, serviceNames: [first, second])
        }
        #expect(fileSystem.data(at: servicesDirectory.appendingPathComponent(first).appendingPathComponent("Contents/legacy.txt")) == Data("first legacy".utf8))
        #expect(fileSystem.data(at: servicesDirectory.appendingPathComponent(second).appendingPathComponent("Contents/legacy.txt")) == Data("second legacy".utf8))
        #expect(fileSystem.files(under: recoveryRoot).isEmpty)
    }

    @Test
    func disableRemovesSwitchboardCopyAndRestoresLegacy() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)
        addSource(fileSystem, name: serviceName)
        let destination = servicesDirectory.appendingPathComponent(serviceName)
        fileSystem.addDirectory(at: destination)
        fileSystem.addDirectory(at: destination.appendingPathComponent("Contents"))
        fileSystem.addFile(
            at: destination.appendingPathComponent("Contents/legacy.txt"),
            data: Data("legacy".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o600, modificationDate: nil)
        )

        try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        try activation.disable(bundleURL: canonical, serviceNames: [serviceName])

        #expect(fileSystem.data(at: destination.appendingPathComponent("Contents/legacy.txt")) == Data("legacy".utf8))
        #expect(fileSystem.files(under: recoveryRoot).isEmpty)
    }

    @Test
    func disablePreservesForeignModification() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)
        addSource(fileSystem, name: serviceName)
        let destination = servicesDirectory.appendingPathComponent(serviceName)
        try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        let foreignFile = destination.appendingPathComponent("Contents/foreign.txt")
        fileSystem.addFile(
            at: foreignFile,
            data: Data("changed by another app".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o600, modificationDate: nil)
        )

        try activation.disable(bundleURL: canonical, serviceNames: [serviceName])
        #expect(fileSystem.data(at: foreignFile) == Data("changed by another app".utf8))
        #expect(try fileSystem.metadata(at: destination)?.isDirectory == true)
        #expect(!fileSystem.files(under: recoveryRoot).isEmpty)
    }

    @Test
    func disablePersistsIntentBeforeRemovalAndLegacyRestore() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)
        addSource(fileSystem, name: serviceName)
        addLegacy(fileSystem, name: serviceName, contents: "legacy")

        try activation.enable(bundleURL: canonical, serviceNames: [serviceName])
        fileSystem.events.removeAll()
        try activation.disable(bundleURL: canonical, serviceNames: [serviceName])

        let stateWrites = fileSystem.events.enumerated().filter { $0.element.contains(".switchboard-state.json") && $0.element.hasPrefix("write:") }
        let removal = try #require(fileSystem.events.firstIndex { $0 == "remove:\(servicesDirectory.appendingPathComponent(serviceName).path)" })
        let restore = try #require(fileSystem.events.firstIndex { $0.hasPrefix("move:") && $0.contains(".legacy->\(servicesDirectory.path)") })
        #expect(stateWrites.contains { $0.offset < removal })
        #expect(stateWrites.contains { $0.offset < restore })
    }

    @Test
    func noncanonicalBundleIsRefusedBeforeFilesystemUse() throws {
        let fileSystem = MemoryBundledServiceFileSystem()
        let activation = makeActivation(fileSystem)
        #expect(throws: BundledServiceActivationError.self) {
            try activation.enable(bundleURL: URL(fileURLWithPath: "/tmp/Switchboard.app", isDirectory: true), serviceNames: [serviceName])
        }
        #expect(fileSystem.events.isEmpty)
        #expect(fileSystem.nodes.isEmpty)
    }

    private func makeActivation(_ fileSystem: MemoryBundledServiceFileSystem) -> BundledServiceActivation {
        BundledServiceActivation(
            fileSystem: fileSystem,
            servicesDirectoryURL: servicesDirectory,
            recoveryRootURL: recoveryRoot
        )
    }

    private func sourceURL(_ name: String) -> URL {
        canonical.appendingPathComponent("Contents/Resources/Services", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func addSource(_ fileSystem: MemoryBundledServiceFileSystem, name: String) {
        let source = sourceURL(name)
        fileSystem.addDirectory(at: source)
        fileSystem.addDirectory(at: source.appendingPathComponent("Contents"))
        fileSystem.addFile(
            at: source.appendingPathComponent("Contents/Info.plist"),
            data: Data("<?xml version=\"1.0\"?><plist/>".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o644, modificationDate: nil)
        )
        fileSystem.addFile(
            at: source.appendingPathComponent("Contents/document.wflow"),
            data: Data("workflow".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o644, modificationDate: nil)
        )
    }

    private func addLegacy(_ fileSystem: MemoryBundledServiceFileSystem, name: String, contents: String) {
        let destination = servicesDirectory.appendingPathComponent(name)
        fileSystem.addDirectory(at: destination)
        fileSystem.addDirectory(at: destination.appendingPathComponent("Contents"))
        fileSystem.addFile(
            at: destination.appendingPathComponent("Contents/legacy.txt"),
            data: Data(contents.utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o640, modificationDate: nil)
        )
    }
}

private final class MemoryBundledServiceFileSystem: BundledServiceActivationFileSystem {
    enum Node {
        case file(Data, BundledServiceFileMetadata)
        case directory(BundledServiceFileMetadata)
        case symbolicLink(URL, BundledServiceFileMetadata)
    }

    enum Failure: Error { case missing(URL); case injectedAtomicMoveFailure }

    var nodes: [String: Node] = [:]
    var events: [String] = []
    var atomicMoveCount = 0
    var failOnAtomicMoveNumber: Int?

    func addDirectory(at url: URL, permissions: UInt16 = 0o755) {
        nodes[key(url)] = .directory(.init(isRegularFile: false, isDirectory: true, isSymbolicLink: false, posixPermissions: permissions, modificationDate: nil))
    }

    func addFile(at url: URL, data: Data, metadata: BundledServiceFileMetadata) {
        nodes[key(url)] = .file(data, metadata)
    }

    func addSymbolicLink(at url: URL, pointingTo target: URL) {
        nodes[key(url)] = .symbolicLink(target, .init(isRegularFile: false, isDirectory: false, isSymbolicLink: true, posixPermissions: 0o777, modificationDate: nil))
    }

    func removeNode(at url: URL) { nodes.removeValue(forKey: key(url)) }

    func metadata(at url: URL) throws -> BundledServiceFileMetadata? { nodes[key(url)].flatMap { node in
        switch node {
        case let .file(_, metadata), let .directory(metadata), let .symbolicLink(_, metadata): metadata
        }
    } }

    func readData(at url: URL) throws -> Data {
        guard case let .file(data, _) = nodes[key(url)] else { throw Failure.missing(url) }
        return data
    }

    func createDirectory(at url: URL, permissions: UInt16) throws {
        events.append("mkdir:\(key(url))")
        addDirectory(at: url, permissions: permissions)
    }

    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
        events.append("write:\(key(url))")
        addFile(at: url, data: data, metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: permissions, modificationDate: nil))
    }

    func copyItem(at source: URL, to destination: URL) throws {
        events.append("copy:\(key(source))->\(key(destination))")
        try remap(source: source, destination: destination, removeSource: false)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        events.append("move:\(key(source))->\(key(destination))")
        try remap(source: source, destination: destination, removeSource: true)
    }

    func atomicallyMoveItem(at source: URL, to destination: URL) throws {
        atomicMoveCount += 1
        events.append("atomic:\(key(source))->\(key(destination))")
        if atomicMoveCount == failOnAtomicMoveNumber { throw Failure.injectedAtomicMoveFailure }
        try remap(source: source, destination: destination, removeSource: true)
    }

    func removeItem(at url: URL) throws {
        events.append("remove:\(key(url))")
        let path = key(url)
        nodes = nodes.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
    }

    func treeSnapshot(at url: URL) throws -> [BundledServiceTreeEntry] {
        var result: [BundledServiceTreeEntry] = []
        try appendSnapshot(at: url, relativePath: "", into: &result)
        return result
    }

    func data(at url: URL) -> Data? { try? readData(at: url) }

    func files(under root: URL) -> [URL] {
        let prefix = key(root) + "/"
        return nodes.keys.filter { $0.hasPrefix(prefix) }.compactMap(URL.init(fileURLWithPath:)).filter { (try? metadata(at: $0)?.isDirectory) == false }.sorted { $0.path < $1.path }
    }

    func directories(under root: URL) -> [URL] {
        let prefix = key(root) + "/"
        return nodes.keys.filter { $0.hasPrefix(prefix) }.compactMap(URL.init(fileURLWithPath:)).filter { (try? metadata(at: $0)?.isDirectory) == true }.sorted { $0.path < $1.path }
    }

    private func appendSnapshot(at url: URL, relativePath: String, into result: inout [BundledServiceTreeEntry]) throws {
        guard let metadata = try metadata(at: url) else { return }
        let data = metadata.isRegularFile ? try readData(at: url) : nil
        result.append(.init(relativePath: relativePath, metadata: metadata, data: data))
        guard metadata.isDirectory, !metadata.isSymbolicLink else { return }
        let prefix = key(url) + "/"
        let children = nodes.keys.filter { path in
            guard path.hasPrefix(prefix) else { return false }
            return !path.dropFirst(prefix.count).contains("/")
        }.sorted()
        for child in children {
            let childURL = URL(fileURLWithPath: child)
            let childRelative = relativePath.isEmpty ? childURL.lastPathComponent : relativePath + "/" + childURL.lastPathComponent
            try appendSnapshot(at: childURL, relativePath: childRelative, into: &result)
        }
    }

    private func remap(source: URL, destination: URL, removeSource: Bool) throws {
        let sourcePath = key(source)
        guard nodes[sourcePath] != nil else { throw Failure.missing(source) }
        let prefix = sourcePath + "/"
        let entries = nodes.filter { $0.key == sourcePath || $0.key.hasPrefix(prefix) }
        if nodes[key(destination)] != nil {
            let destinationPath = key(destination)
            nodes = nodes.filter { $0.key != destinationPath && !$0.key.hasPrefix(destinationPath + "/") }
        }
        for (path, node) in entries {
            let suffix = path == sourcePath ? "" : String(path.dropFirst(sourcePath.count))
            nodes[key(destination) + suffix] = node
        }
        if removeSource {
            nodes = nodes.filter { $0.key != sourcePath && !$0.key.hasPrefix(prefix) }
        }
    }

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
