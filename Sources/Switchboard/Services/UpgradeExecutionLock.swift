import Darwin
import Foundation

final class UpgradeExecutionLock {
    private var descriptor: Int32 = -1

    init(
        supportURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard", directoryHint: .isDirectory)
    ) throws {
        try Self.ensureOwnerOnlyDirectory(supportURL, createIntermediates: true)
        let directory = supportURL.appending(path: "Upgrade", directoryHint: .isDirectory)
        try Self.ensureOwnerOnlyDirectory(directory, createIntermediates: false)
        let lockURL = directory.appending(path: "migration.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UpgradeExecutionLockError.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw UpgradeExecutionLockError.unavailable
        }
        let owner: [String: Any] = [
            "schemaVersion": 1,
            "pid": getpid(),
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys]) {
            _ = ftruncate(fd, 0)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            _ = fsync(fd)
        }
        descriptor = fd
    }

    private static func ensureOwnerOnlyDirectory(
        _ url: URL,
        createIntermediates: Bool
    ) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw UpgradeExecutionLockError.unsafeState
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    deinit {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum UpgradeExecutionLockError: LocalizedError {
    case unavailable
    case unsafeState

    var errorDescription: String? {
        switch self {
        case .unavailable: "Another Switchboard upgrade is already running."
        case .unsafeState: "Switchboard's private upgrade folder is not a safe owner-only directory."
        }
    }
}
