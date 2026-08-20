import Foundation
import CryptoKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The small part of URLSession used by update discovery and downloads.
/// Supplying a test implementation keeps the update path deterministic without
/// adding a networking dependency.
public protocol GitHubUpdateNetworking {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(from url: URL, to destinationURL: URL) async throws -> URL
}

public typealias UpdateNetworking = GitHubUpdateNetworking
public typealias URLSessionProtocol = GitHubUpdateNetworking

extension URLSession: GitHubUpdateNetworking {
    public func download(from url: URL, to destinationURL: URL) async throws -> URL {
        let (temporaryURL, _) = try await download(from: url)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}

public struct SwitchboardUpdateManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let minimumSystemVersion: String
    public let architectures: [String]
    public let dmgURL: URL
    public let dmgSHA256: String
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        schemaVersion: Int,
        version: String,
        minimumSystemVersion: String,
        architectures: [String],
        dmgURL: URL,
        dmgSHA256: String,
        bundleIdentifier: String,
        teamIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.dmgURL = dmgURL
        self.dmgSHA256 = dmgSHA256
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case version
        case minimumSystemVersion
        case architectures
        case dmgURL
        case dmgSHA256
        case bundleIdentifier
        case teamIdentifier
    }
}

public typealias UpdateManifest = SwitchboardUpdateManifest

public struct SwitchboardUpdate: Equatable, Sendable {
    public let releaseTag: String
    public let manifest: SwitchboardUpdateManifest
    public let manifestAssetURL: URL

    public init(releaseTag: String, manifest: SwitchboardUpdateManifest, manifestAssetURL: URL) {
        self.releaseTag = releaseTag
        self.manifest = manifest
        self.manifestAssetURL = manifestAssetURL
    }
}

public typealias GitHubUpdate = SwitchboardUpdate

public enum GitHubUpdateServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion
    case invalidMinimumSystemVersion
    case invalidReleaseResponse
    case invalidHTTPStatus(Int)
    case releaseIsNotPublished
    case draftOrPrerelease
    case missingManifestAsset
    case duplicateManifestAssets
    case malformedManifest
    case unsupportedSchema(Int)
    case updateIsNotNewer
    case unsupportedMinimumSystemVersion
    case missingArm64Architecture
    case bundleIdentifierMismatch
    case invalidDownloadURL
    case invalidSHA256
    case missingTeamIdentifier
    case destinationMissing
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: "The current app version is not valid semantic version text."
        case .invalidMinimumSystemVersion: "The update's minimum system version is not valid."
        case .invalidReleaseResponse: "GitHub returned an invalid release response."
        case .invalidHTTPStatus(let status): "GitHub returned HTTP status \(status)."
        case .releaseIsNotPublished: "The GitHub release has not been published."
        case .draftOrPrerelease: "Draft and prerelease updates are not accepted."
        case .missingManifestAsset: "The release does not contain Switchboard-update.json."
        case .duplicateManifestAssets: "The release contains more than one Switchboard-update.json asset."
        case .malformedManifest: "Switchboard-update.json does not match the supported schema."
        case .unsupportedSchema(let schema): "Manifest schema \(schema) is not supported."
        case .updateIsNotNewer: "The available update is not newer than the installed version."
        case .unsupportedMinimumSystemVersion: "The update requires a newer version of macOS."
        case .missingArm64Architecture: "The update does not contain an arm64 build."
        case .bundleIdentifierMismatch: "The update is not for com.ivogundlach.switchboard."
        case .invalidDownloadURL: "The update download URL is not an allowed HTTPS GitHub URL."
        case .invalidSHA256: "The update SHA-256 value is not lowercase 64-digit hexadecimal text."
        case .missingTeamIdentifier: "The update has no signing team identifier."
        case .destinationMissing: "The download did not produce the requested destination file."
        case .hashMismatch: "The downloaded update failed SHA-256 verification."
        }
    }
}

public final class GitHubUpdateService: @unchecked Sendable {
    public typealias Networking = GitHubUpdateNetworking
    public typealias Manifest = SwitchboardUpdateManifest
    public typealias Update = SwitchboardUpdate

    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/ivogundlach/Switchboard/releases/latest")!
    public static let manifestAssetName = "Switchboard-update.json"
    public static let expectedBundleIdentifier = "com.ivogundlach.switchboard"

    private let session: any GitHubUpdateNetworking
    private let currentSystemVersion: Version

    public init(
        session: any GitHubUpdateNetworking = URLSession.shared,
        currentSystemVersion: String? = nil
    ) {
        self.session = session
        let actual = currentSystemVersion ?? Self.detectCurrentSystemVersion()
        self.currentSystemVersion = Version(systemVersion: actual) ?? Version(major: 0, minor: 0, patch: 0)
    }

    public convenience init(
        session: any GitHubUpdateNetworking = URLSession.shared,
        currentOSVersion: String?
    ) {
        self.init(session: session, currentSystemVersion: currentOSVersion)
    }

    /// Discovers a newer, signed-update manifest from the fixed GitHub release endpoint.
    public func checkForUpdate(currentVersion: String) async throws -> SwitchboardUpdate? {
        guard let installedVersion = Version(semanticVersion: currentVersion) else {
            throw GitHubUpdateServiceError.invalidCurrentVersion
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Switchboard", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard response.url == Self.latestReleaseURL else {
            throw GitHubUpdateServiceError.invalidReleaseResponse
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw GitHubUpdateServiceError.invalidHTTPStatus(httpResponse.statusCode)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw GitHubUpdateServiceError.invalidReleaseResponse
        }
        guard let publishedAt = release.publishedAt,
              !publishedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isValidISO8601Timestamp(publishedAt) else {
            throw GitHubUpdateServiceError.releaseIsNotPublished
        }
        guard !release.draft, !release.prerelease else { throw GitHubUpdateServiceError.draftOrPrerelease }

        let manifestAssets = release.assets.filter { $0.name == Self.manifestAssetName }
        guard !manifestAssets.isEmpty else { throw GitHubUpdateServiceError.missingManifestAsset }
        guard manifestAssets.count == 1 else { throw GitHubUpdateServiceError.duplicateManifestAssets }
        let manifestAsset = manifestAssets[0]
        guard Self.isAllowedHTTPSGitHubURL(manifestAsset.browserDownloadURL) else {
            throw GitHubUpdateServiceError.invalidDownloadURL
        }

        let (manifestData, manifestResponse) = try await session.data(
            for: URLRequest(url: manifestAsset.browserDownloadURL)
        )
        if let httpResponse = manifestResponse as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw GitHubUpdateServiceError.invalidHTTPStatus(httpResponse.statusCode)
        }

        let manifest: SwitchboardUpdateManifest
        do {
            manifest = try JSONDecoder().decode(SwitchboardUpdateManifest.self, from: manifestData)
        } catch {
            throw GitHubUpdateServiceError.malformedManifest
        }
        guard try validate(manifest, installedVersion: installedVersion) else { return nil }
        return SwitchboardUpdate(
            releaseTag: release.tagName,
            manifest: manifest,
            manifestAssetURL: manifestAsset.browserDownloadURL
        )
    }

    /// Alias retained for callers that prefer the discovery verb.
    public func discoverUpdate(currentVersion: String) async throws -> SwitchboardUpdate? {
        try await checkForUpdate(currentVersion: currentVersion)
    }

    public func fetchLatestRelease(currentVersion: String) async throws -> SwitchboardUpdate? {
        try await checkForUpdate(currentVersion: currentVersion)
    }

    /// Downloads to the caller-owned temporary URL and verifies the exact bytes on disk.
    @discardableResult
    public func downloadAndVerify(
        _ update: SwitchboardUpdate,
        to destinationURL: URL
    ) async throws -> URL {
        guard Self.isAllowedHTTPSGitHubURL(update.manifest.dmgURL) else {
            throw GitHubUpdateServiceError.invalidDownloadURL
        }
        guard update.manifest.dmgSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw GitHubUpdateServiceError.invalidSHA256
        }
        _ = try await session.download(from: update.manifest.dmgURL, to: destinationURL)
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw GitHubUpdateServiceError.destinationMissing
        }
        let actualHash = try Self.sha256(of: destinationURL)
        guard actualHash == update.manifest.dmgSHA256 else {
            throw GitHubUpdateServiceError.hashMismatch(
                expected: update.manifest.dmgSHA256,
                actual: actualHash
            )
        }
        return destinationURL
    }

    @discardableResult
    public func downloadAndVerify(
        update: SwitchboardUpdate,
        to destinationURL: URL
    ) async throws -> URL {
        try await downloadAndVerify(update, to: destinationURL)
    }

    private func validate(_ manifest: SwitchboardUpdateManifest, installedVersion: Version) throws -> Bool {
        guard manifest.schemaVersion == 1 else {
            throw GitHubUpdateServiceError.unsupportedSchema(manifest.schemaVersion)
        }
        guard let updateVersion = Version(semanticVersion: manifest.version) else {
            throw GitHubUpdateServiceError.updateIsNotNewer
        }
        guard updateVersion > installedVersion else { return false }
        guard manifest.minimumSystemVersion == "26.0" else {
            throw GitHubUpdateServiceError.invalidMinimumSystemVersion
        }
        guard let minimumVersion = Version(systemVersion: manifest.minimumSystemVersion) else {
            throw GitHubUpdateServiceError.invalidMinimumSystemVersion
        }
        guard currentSystemVersion >= minimumVersion else {
            throw GitHubUpdateServiceError.unsupportedMinimumSystemVersion
        }
        guard manifest.architectures.contains("arm64") else {
            throw GitHubUpdateServiceError.missingArm64Architecture
        }
        guard manifest.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw GitHubUpdateServiceError.bundleIdentifierMismatch
        }
        guard Self.isAllowedHTTPSGitHubURL(manifest.dmgURL) else {
            throw GitHubUpdateServiceError.invalidDownloadURL
        }
        guard manifest.dmgSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw GitHubUpdateServiceError.invalidSHA256
        }
        guard !manifest.teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubUpdateServiceError.missingTeamIdentifier
        }
        return true
    }

    private static func isAllowedHTTPSGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "objects.githubusercontent.com"
    }

    private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidISO8601Timestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private static func detectCurrentSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

private struct Version: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    init(major: Int, minor: Int, patch: Int, prerelease: [Identifier] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(semanticVersion value: String) {
        self.init(value: value, allowOneOrTwoComponents: false)
    }

    init?(systemVersion value: String) {
        self.init(value: value, allowOneOrTwoComponents: true)
    }

    private init?(value: String, allowOneOrTwoComponents: Bool) {
        let mainAndBuild = value.split(separator: "+", omittingEmptySubsequences: false)
        guard mainAndBuild.count <= 2 else { return nil }
        if mainAndBuild.count == 2 {
            let buildIdentifiers = mainAndBuild[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !buildIdentifiers.isEmpty,
                  buildIdentifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isIdentifierCharacter) }) else {
                return nil
            }
        }
        let mainAndPrerelease = mainAndBuild[0].split(separator: "-", omittingEmptySubsequences: false)
        guard !mainAndPrerelease.isEmpty, mainAndPrerelease.count <= 2 else { return nil }
        let components = mainAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (allowOneOrTwoComponents ? (1...3).contains(components.count) : components.count == 3) else { return nil }
        let numbers = components.map(String.init)
        guard numbers.allSatisfy(Self.validNumber), let major = Int(numbers[0]),
              let minor = components.count > 1 ? Int(numbers[1]) : 0,
              let patch = components.count > 2 ? Int(numbers[2]) : 0 else { return nil }
        var identifiers: [Identifier] = []
        if mainAndPrerelease.count == 2 {
            let raw = mainAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !raw.isEmpty else { return nil }
            for item in raw {
                let string = String(item)
                guard !string.isEmpty, string.allSatisfy(Self.isIdentifierCharacter) else { return nil }
                if string.allSatisfy(\.isNumber) {
                    guard string == "0" || !string.hasPrefix("0"), let number = Int(string) else { return nil }
                    identifiers.append(.number(number))
                } else {
                    identifiers.append(.text(string))
                }
            }
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: identifiers)
    }

    private static func validNumber(_ value: String) -> Bool {
        value == "0" || (!value.hasPrefix("0") && !value.isEmpty && value.allSatisfy(\.isNumber))
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isNumber || character.isLetter || character == "-")
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    enum Identifier: Comparable, Equatable, Sendable {
        case number(Int)
        case text(String)

        static func < (lhs: Identifier, rhs: Identifier) -> Bool {
            switch (lhs, rhs) {
            case let (.number(a), .number(b)): return a < b
            case (.number, .text): return true
            case (.text, .number): return false
            case let (.text(a), .text(b)): return a < b
            }
        }
    }
}
