import Foundation
import Testing
@testable import Switchboard

struct BundledCommandActivationTests {
    private let canonical = BundledCommandActivation.canonicalAppURL
    private let moduleID = "demo.module"
    private let localBin = URL(fileURLWithPath: "/fixture/home/.local/bin", isDirectory: true)
    private let recovery = URL(fileURLWithPath: "/fixture/home/Library/Application Support/Switchboard/Activation", isDirectory: true)

    @Test
    func localFilesystemTreatsARealMissingPathAsAbsent() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("switchboard-missing-command-\(UUID().uuidString)")
        #expect(try LocalBundledCommandActivationFileSystem().metadata(at: missing) == nil)
    }

    @Test
    func localFilesystemAtomicallyReplacesExistingFilesAndState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("switchboard-real-command-fs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileSystem = LocalBundledCommandActivationFileSystem()
        let destination = root.appendingPathComponent("command")
        let target = root.appendingPathComponent("bundled-command")
        try Data("legacy".utf8).write(to: destination)
        try Data("bundled".utf8).write(to: target)
        try fileSystem.atomicallyReplaceItem(at: destination, withSymbolicLinkTo: target)
        #expect(try fileSystem.metadata(at: destination)?.isSymbolicLink == true)
        #expect(try fileSystem.readSymbolicLink(at: destination) == target)

        let state = root.appendingPathComponent("state.json")
        try Data("old".utf8).write(to: state)
        try fileSystem.writeDataAtomically(Data("new".utf8), to: state, permissions: 0o600)
        #expect(try Data(contentsOf: state) == Data("new".utf8))
    }

    @Test
    func ownedLegacySymlinkWithinHomeIsRestoredAfterDisable() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "memory-search")
        let destination = localBin.appendingPathComponent("memory-search")
        let legacyTarget = URL(fileURLWithPath: "/fixture/home/.memory/tools/memory-search")
        fileSystem.addFile(
            at: legacyTarget,
            data: Data("#!/bin/sh\n".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o755, modificationDate: nil)
        )
        fileSystem.addSymbolicLink(at: destination, pointingTo: legacyTarget)

        try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["memory-search"])
        #expect(fileSystem.symbolicLinkTarget(at: destination) == sourceURL("memory-search"))
        try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["memory-search"])
        #expect(fileSystem.symbolicLinkTarget(at: destination) == legacyTarget)
    }

    @Test
    func legacySymlinkOutsideHomeIsRejected() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "foreign")
        let destination = localBin.appendingPathComponent("foreign")
        let foreignTarget = URL(fileURLWithPath: "/opt/homebrew/bin/foreign")
        fileSystem.addFile(
            at: foreignTarget,
            data: Data("binary".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o755, modificationDate: nil)
        )
        fileSystem.addSymbolicLink(at: destination, pointingTo: foreignTarget)
        #expect(throws: BundledCommandActivationError.self) {
            try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["foreign"])
        }
    }

    @Test
    func traversalAndSourceSymlinkAreRejected() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        #expect(throws: BundledCommandActivationError.self) {
            try service.enable(bundleURL: canonical, moduleID: "../escape", commandNames: ["safe"])
        }
        #expect(throws: BundledCommandActivationError.self) {
            try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["../escape"])
        }

        let source = sourceURL("safe")
        fileSystem.addSymbolicLink(at: source, pointingTo: URL(fileURLWithPath: "/tmp/not-the-payload"))
        #expect(throws: BundledCommandActivationError.self) {
            try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["safe"])
        }
    }

    @Test
    func exactLegacyBackupAndAtomicActivationAreReversible() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "hello")
        let destination = localBin.appendingPathComponent("hello")
        let legacyMetadata = BundledCommandFileMetadata(
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false,
            posixPermissions: 0o754,
            modificationDate: Date(timeIntervalSince1970: 1234)
        )
        fileSystem.addFile(at: destination, data: Data("legacy bytes".utf8), metadata: legacyMetadata)

        try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])
        #expect(fileSystem.atomicInstallCount == 1)
        #expect(fileSystem.symbolicLinkTarget(at: destination) == sourceURL("hello"))
        let backups = fileSystem.files(under: recovery).filter { $0.lastPathComponent.hasSuffix(".legacy") }
        #expect(backups.count == 1)
        #expect(fileSystem.data(at: backups[0]) == Data("legacy bytes".utf8))

        try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])
        #expect(fileSystem.data(at: destination) == Data("legacy bytes".utf8))
        #expect(try fileSystem.metadata(at: destination)?.posixPermissions == 0o754)
        #expect(try fileSystem.metadata(at: destination)?.modificationDate == legacyMetadata.modificationDate)
    }

    @Test
    func failedSecondInstallRollsBackEveryCommand() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        fileSystem.failOnAtomicInstallNumber = 2
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "first")
        addExecutable(fileSystem, name: "second")
        fileSystem.addFile(
            at: localBin.appendingPathComponent("first"),
            data: Data("first legacy".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o711, modificationDate: nil)
        )
        fileSystem.addFile(
            at: localBin.appendingPathComponent("second"),
            data: Data("second legacy".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o744, modificationDate: nil)
        )

        #expect(throws: Error.self) {
            try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["first", "second"])
        }
        #expect(fileSystem.data(at: localBin.appendingPathComponent("first")) == Data("first legacy".utf8))
        #expect(fileSystem.data(at: localBin.appendingPathComponent("second")) == Data("second legacy".utf8))
        #expect(fileSystem.atomicInstallCount == 2)
        #expect(!fileSystem.isSymbolicLink(at: localBin.appendingPathComponent("first")))
        #expect(!fileSystem.isSymbolicLink(at: localBin.appendingPathComponent("second")))
        #expect(try fileSystem.metadata(at: recovery.appendingPathComponent(moduleID).appendingPathComponent("state.json")) == nil)
    }

    @Test
    func disableLeavesForeignSymlinkUntouched() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        let destination = localBin.appendingPathComponent("foreign")
        let foreignTarget = URL(fileURLWithPath: "/tmp/foreign-command")
        fileSystem.addSymbolicLink(at: destination, pointingTo: foreignTarget)

        try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["foreign"])
        #expect(fileSystem.symbolicLinkTarget(at: destination) == foreignTarget)
    }

    @Test
    func disablePersistsIntentBeforeRemovalAndLegacyRestore() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "hello")
        let destination = localBin.appendingPathComponent("hello")
        fileSystem.addFile(
            at: destination,
            data: Data("legacy bytes".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o644, modificationDate: nil)
        )

        try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])
        fileSystem.events.removeAll()
        try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])

        let stateWrites = fileSystem.events.enumerated().filter { $0.element.contains("state.json") && $0.element.hasPrefix("write:") }
        let removal = try #require(fileSystem.events.firstIndex { $0 == "remove:\(destination.path)" })
        let restore = try #require(fileSystem.events.firstIndex { $0 == "write:\(destination.path)" })
        #expect(stateWrites.contains { $0.offset < removal })
        #expect(stateWrites.contains { $0.offset < restore })
    }

    @Test
    func disableResumesAfterCrashBetweenLegacyRestoreAndStateCleanup() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        addExecutable(fileSystem, name: "hello")
        let destination = localBin.appendingPathComponent("hello")
        let legacy = Data("legacy bytes".utf8)
        fileSystem.addFile(
            at: destination,
            data: legacy,
            metadata: .init(
                isRegularFile: true,
                isDirectory: false,
                isSymbolicLink: false,
                posixPermissions: 0o640,
                modificationDate: Date(timeIntervalSince1970: 321)
            )
        )
        try service.enable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])

        fileSystem.failRemoveSuffixOnce = "/state.json"
        #expect(throws: Error.self) {
            try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])
        }
        #expect(fileSystem.data(at: destination) == legacy)

        try service.disable(bundleURL: canonical, moduleID: moduleID, commandNames: ["hello"])
        #expect(fileSystem.data(at: destination) == legacy)
        #expect(try fileSystem.metadata(at: recovery.appendingPathComponent(moduleID).appendingPathComponent("state.json")) == nil)
    }

    @Test
    func noncanonicalBundleIsRefusedBeforeAnyFilesystemOperation() throws {
        let fileSystem = MemoryBundledCommandFileSystem()
        let service = makeService(fileSystem)
        #expect(throws: BundledCommandActivationError.self) {
            try service.enable(
                bundleURL: URL(fileURLWithPath: "/tmp/Switchboard.app", isDirectory: true),
                moduleID: moduleID,
                commandNames: ["hello"]
            )
        }
        #expect(fileSystem.atomicInstallCount == 0)
        #expect(fileSystem.allPaths.isEmpty)
    }

    private func makeService(_ fileSystem: MemoryBundledCommandFileSystem) -> BundledCommandActivation {
        BundledCommandActivation(fileSystem: fileSystem, localBinURL: localBin, recoveryRootURL: recovery)
    }

    private func sourceURL(_ name: String) -> URL {
        canonical.appendingPathComponent("Contents/Resources/Modules", isDirectory: true)
            .appendingPathComponent(moduleID, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func addExecutable(_ fileSystem: MemoryBundledCommandFileSystem, name: String) {
        fileSystem.addFile(
            at: sourceURL(name),
            data: Data("#!/bin/sh\n".utf8),
            metadata: .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: 0o755, modificationDate: nil)
        )
    }
}

private final class MemoryBundledCommandFileSystem: BundledCommandActivationFileSystem {
    enum Node {
        case file(Data, BundledCommandFileMetadata)
        case directory(BundledCommandFileMetadata)
        case symbolicLink(URL, BundledCommandFileMetadata)
    }

    enum Failure: Error { case missing(URL), notAFile(URL), notALink(URL), injectedInstallFailure, injectedRemovalFailure }

    var nodes: [String: Node] = [:]
    var events: [String] = []
    var atomicInstallCount = 0
    var failOnAtomicInstallNumber: Int?
    var failRemoveSuffixOnce: String?

    var allPaths: [String] { nodes.keys.sorted() }

    func addFile(at url: URL, data: Data, metadata: BundledCommandFileMetadata) {
        nodes[key(url)] = .file(data, metadata)
    }

    func addSymbolicLink(at url: URL, pointingTo target: URL) {
        nodes[key(url)] = .symbolicLink(
            target,
            .init(isRegularFile: false, isDirectory: false, isSymbolicLink: true, posixPermissions: 0o777, modificationDate: nil)
        )
    }

    func metadata(at url: URL) throws -> BundledCommandFileMetadata? {
        guard let node = nodes[key(url)] else { return nil }
        switch node {
        case let .file(_, metadata), let .directory(metadata), let .symbolicLink(_, metadata): return metadata
        }
    }

    func readData(at url: URL) throws -> Data {
        guard case let .file(data, _) = nodes[key(url)] else { throw Failure.notAFile(url) }
        return data
    }

    func readSymbolicLink(at url: URL) throws -> URL {
        guard case let .symbolicLink(target, _) = nodes[key(url)] else { throw Failure.notALink(url) }
        return target
    }

    func readSymbolicLinkDestination(at url: URL) throws -> String {
        try readSymbolicLink(at: url).path
    }

    func createDirectory(at url: URL, permissions: UInt16) throws {
        nodes[key(url)] = .directory(.init(isRegularFile: false, isDirectory: true, isSymbolicLink: false, posixPermissions: permissions, modificationDate: nil))
    }

    func writeData(_ data: Data, to url: URL, permissions: UInt16) throws {
        events.append("write:\(key(url))")
        nodes[key(url)] = .file(data, .init(isRegularFile: true, isDirectory: false, isSymbolicLink: false, posixPermissions: permissions, modificationDate: nil))
    }

    func writeDataAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
        events.append("write:\(key(url))")
        try writeData(data, to: url, permissions: permissions)
    }

    func setMetadata(_ metadata: BundledCommandFileMetadata, at url: URL) throws {
        switch nodes[key(url)] {
        case let .file(data, _): nodes[key(url)] = .file(data, metadata)
        case .directory: nodes[key(url)] = .directory(metadata)
        case let .symbolicLink(target, _): nodes[key(url)] = .symbolicLink(target, metadata)
        case nil: throw Failure.missing(url)
        }
    }

    func removeItem(at url: URL) throws {
        events.append("remove:\(key(url))")
        if let suffix = failRemoveSuffixOnce, key(url).hasSuffix(suffix) {
            failRemoveSuffixOnce = nil
            throw Failure.injectedRemovalFailure
        }
        let prefix = key(url) + "/"
        nodes = nodes.filter { $0.key != key(url) && !$0.key.hasPrefix(prefix) }
    }

    func createSymbolicLink(at url: URL, pointingTo target: URL) throws {
        addSymbolicLink(at: url, pointingTo: target)
    }

    func createSymbolicLink(at url: URL, pointingToPath target: String) throws {
        addSymbolicLink(at: url, pointingTo: URL(fileURLWithPath: target))
    }

    func atomicallyReplaceItem(at url: URL, withSymbolicLinkTo target: URL) throws {
        atomicInstallCount += 1
        if atomicInstallCount == failOnAtomicInstallNumber { throw Failure.injectedInstallFailure }
        addSymbolicLink(at: url, pointingTo: target)
    }

    func data(at url: URL) -> Data? {
        try? readData(at: url)
    }

    func isSymbolicLink(at url: URL) -> Bool {
        (try? metadata(at: url)?.isSymbolicLink) ?? false
    }

    func symbolicLinkTarget(at url: URL) -> URL? {
        try? readSymbolicLink(at: url)
    }

    func files(under root: URL) -> [URL] {
        let prefix = key(root) + "/"
        return nodes.keys.filter { $0.hasPrefix(prefix) }.compactMap(URL.init(fileURLWithPath:)).filter { (try? metadata(at: $0)?.isDirectory) == false }
    }

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
