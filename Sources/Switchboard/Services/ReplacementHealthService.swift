import Darwin
import Foundation

struct ReplacementCapabilityHealth: Equatable {
    let ready: Bool
    let detail: String
    let checkedAt: Date
}

private struct HelperCapabilityHealthFile: Decodable {
    let schemaVersion: Int
    let bundleID: String
    let pid: Int32
    let executablePath: String
    let accessibilityTrusted: Bool
    let eventTapActive: Bool
    let ready: Bool
    let healthNonce: String
    let timestamp: String
}

enum ReplacementHealthService {
    private static let maximumHealthAge: TimeInterval = 45

    static func helperCapability(
        named name: String,
        expectedBundleID: String,
        expectedExecutableURL: URL,
        expectedNonce: String,
        now: Date = Date(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ReplacementCapabilityHealth {
        let healthURL = homeDirectory
            .appending(path: "Library/Application Support/Switchboard/Health", directoryHint: .isDirectory)
            .appending(path: "\(name).json")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: healthURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0 else {
                return .init(ready: false, detail: "Health evidence is not private and owner-controlled", checkedAt: now)
            }
            let values = try healthURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536 else {
                return .init(ready: false, detail: "Health evidence is unsafe", checkedAt: now)
            }
            let payload = try JSONDecoder().decode(
                HelperCapabilityHealthFile.self,
                from: Data(contentsOf: healthURL, options: [.mappedIfSafe])
            )
            guard payload.schemaVersion == 1,
                  payload.bundleID == expectedBundleID,
                  payload.executablePath == expectedExecutableURL.path,
                  payload.healthNonce == expectedNonce,
                  payload.pid > 0,
                  processExecutablePath(payload.pid) == expectedExecutableURL.path,
                  let timestamp = ISO8601DateFormatter().date(from: payload.timestamp),
                  now.timeIntervalSince(timestamp) >= -5,
                  now.timeIntervalSince(timestamp) <= maximumHealthAge else {
                return .init(ready: false, detail: "Health evidence does not match the installed helper", checkedAt: now)
            }
            guard payload.accessibilityTrusted else {
                return .init(ready: false, detail: "Accessibility is not enabled for this helper", checkedAt: timestamp)
            }
            guard payload.eventTapActive, payload.ready else {
                return .init(ready: false, detail: "The helper is running but its event monitor is not ready", checkedAt: timestamp)
            }
            return .init(ready: true, detail: "Accessibility and event monitoring are ready", checkedAt: timestamp)
        } catch {
            return .init(ready: false, detail: "No current capability check is available", checkedAt: now)
        }
    }

    static func continuousAgentJob(
        label: String,
        expectedExecutableURL: URL,
        expectedNonce: String,
        now: Date = Date(),
        applicationSupportURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Switchboard", directoryHint: .isDirectory)
    ) -> ReplacementCapabilityHealth {
        do {
            let stateURL = applicationSupportURL.appending(path: "agent-state.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
            let values = try stateURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077 == 0,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 1_048_576 else {
                return .init(ready: false, detail: "The agent health file is unsafe", checkedAt: now)
            }
            let state = try JSONDecoder().decode(AgentStateFile.self, from: Data(contentsOf: stateURL))
            guard let job = state.jobs[label],
                  job.lastFailure == nil,
                  let pid = job.runningPID,
                  let heartbeat = job.heartbeat,
                  let recordedPath = job.runningExecutablePath,
                  job.healthNonce == expectedNonce,
                  job.processStartedAt != nil,
                  recordedPath == expectedExecutableURL.path,
                  processExecutablePath(pid) == expectedExecutableURL.path,
                  now.timeIntervalSince(heartbeat) >= -5,
                  now.timeIntervalSince(heartbeat) <= maximumHealthAge else {
                return .init(ready: false, detail: "The background replacement has not published a current heartbeat", checkedAt: now)
            }
            return .init(ready: true, detail: "The background replacement is stable and reporting", checkedAt: heartbeat)
        } catch {
            return .init(ready: false, detail: "The background replacement has not published health yet", checkedAt: now)
        }
    }

    private static func processExecutablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return base.withMemoryRebound(to: UInt8.self, capacity: pointer.count) {
                String(decodingCString: $0, as: UTF8.self)
            }
        }
    }
}
