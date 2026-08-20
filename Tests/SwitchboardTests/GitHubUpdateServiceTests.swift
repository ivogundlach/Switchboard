import Foundation
import CryptoKit
import Testing
@testable import Switchboard

struct GitHubUpdateServiceTests {
    @Test
    func discoversValidNewerUpdate() async throws {
        let payload = Data("valid update bytes".utf8)
        let mock = MockNetworking(release: releaseJSON(), manifest: manifestJSON(for: payload), downloadBytes: payload)
        let service = GitHubUpdateService(session: mock, currentSystemVersion: "26.0.0")

        let update = try await service.checkForUpdate(currentVersion: "1.0.0")
        #expect(update?.manifest.version == "1.1.0")
        #expect(mock.requestURLs.first == GitHubUpdateService.latestReleaseURL)
    }

    @Test
    func returnsNilWhenReleaseIsNotNewer() async throws {
        let mock = MockNetworking(release: releaseJSON(), manifest: manifestJSON(for: Data("x".utf8)))
        let service = GitHubUpdateService(session: mock, currentSystemVersion: "26.0.0")
        #expect(try await service.checkForUpdate(currentVersion: "1.1.0") == nil)
    }

    @Test
    func rejectsWrongDownloadHost() async throws {
        let manifest = manifestJSON(for: Data("x".utf8), dmgURL: "https://evil.example/update.dmg")
        let mock = MockNetworking(release: releaseJSON(), manifest: manifest)
        let service = GitHubUpdateService(session: mock, currentSystemVersion: "26.0.0")
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await service.checkForUpdate(currentVersion: "1.0.0")
        }
    }

    @Test
    func rejectsMissingAndDuplicateManifestAssets() async throws {
        let missing = MockNetworking(
            release: releaseJSON(assetNames: ["Other.json"]),
            manifest: Data()
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: missing, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }

        let duplicate = MockNetworking(
            release: releaseJSON(assetNames: [GitHubUpdateService.manifestAssetName, GitHubUpdateService.manifestAssetName]),
            manifest: Data()
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: duplicate, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }
    }

    @Test
    func rejectsWrongBundleIDAndMalformedSHA() async throws {
        let wrongBundle = MockNetworking(
            release: releaseJSON(),
            manifest: manifestJSON(for: Data(), bundleIdentifier: "com.example.other")
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: wrongBundle, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }

        let wrongSHA = MockNetworking(
            release: releaseJSON(),
            manifest: manifestJSON(for: Data(), sha256: String(repeating: "A", count: 64))
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: wrongSHA, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }
    }

    @Test
    func rejectsDraftAndPrereleaseReleases() async throws {
        for flags in [(true, false), (false, true)] {
            let mock = MockNetworking(
                release: releaseJSON(draft: flags.0, prerelease: flags.1),
                manifest: manifestJSON(for: Data())
            )
            await #expect(throws: GitHubUpdateServiceError.self) {
                _ = try await GitHubUpdateService(session: mock, currentSystemVersion: "26.0.0")
                    .checkForUpdate(currentVersion: "1.0.0")
            }
        }
    }

    @Test
    func rejectsUnsupportedMinimumSystemAndArchitecture() async throws {
        let tooNew = MockNetworking(
            release: releaseJSON(),
            manifest: manifestJSON(for: Data(), minimumSystemVersion: "27.0.0")
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: tooNew, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }

        let wrongArchitecture = MockNetworking(
            release: releaseJSON(),
            manifest: manifestJSON(for: Data(), architectures: ["x86_64"])
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: wrongArchitecture, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }
    }

    @Test
    func rejectsNonExactMinimumSystemVersionAndInvalidPublicationDate() async throws {
        for value in ["26.0.0", "25.0", "26"] {
            let mock = MockNetworking(
                release: releaseJSON(),
                manifest: manifestJSON(for: Data(), minimumSystemVersion: value)
            )
            await #expect(throws: GitHubUpdateServiceError.self) {
                _ = try await GitHubUpdateService(session: mock, currentSystemVersion: "26.0.0")
                    .checkForUpdate(currentVersion: "1.0.0")
            }
        }

        let invalidDate = MockNetworking(
            release: releaseJSON(publishedAt: "not-an-iso8601-date"),
            manifest: manifestJSON(for: Data())
        )
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: invalidDate, currentSystemVersion: "26.0.0")
                .checkForUpdate(currentVersion: "1.0.0")
        }
    }

    @Test
    func verifiesMatchingAndMismatchingDownloadHashes() async throws {
        let payload = Data("downloaded bytes".utf8)
        let matching = MockNetworking(release: releaseJSON(), manifest: manifestJSON(for: payload), downloadBytes: payload)
        let matchingURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: matchingURL) }
        let update = try await GitHubUpdateService(session: matching, currentSystemVersion: "26.0.0")
            .checkForUpdate(currentVersion: "1.0.0")!
        #expect(try await GitHubUpdateService(session: matching, currentSystemVersion: "26.0.0")
            .downloadAndVerify(update, to: matchingURL) == matchingURL)

        let mismatching = MockNetworking(release: releaseJSON(), manifest: manifestJSON(for: Data("expected".utf8)), downloadBytes: payload)
        let mismatchURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: mismatchURL) }
        let mismatchUpdate = try await GitHubUpdateService(session: mismatching, currentSystemVersion: "26.0.0")
            .checkForUpdate(currentVersion: "1.0.0")!
        await #expect(throws: GitHubUpdateServiceError.self) {
            _ = try await GitHubUpdateService(session: mismatching, currentSystemVersion: "26.0.0")
                .downloadAndVerify(mismatchUpdate, to: mismatchURL)
        }
    }

    private func releaseJSON(
        assetNames: [String] = [GitHubUpdateService.manifestAssetName],
        draft: Bool = false,
        prerelease: Bool = false,
        publishedAt: String = "2026-08-20T00:00:00Z"
    ) -> Data {
        let assets = assetNames.map {
            ["name": $0, "browser_download_url": "https://github.com/ivogundlach/Switchboard/releases/download/v1.1.0/\($0)"]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0",
            "draft": draft,
            "prerelease": prerelease,
            "published_at": publishedAt,
            "assets": assets,
        ])
    }

    private func manifestJSON(
        for payload: Data,
        dmgURL: String = "https://objects.githubusercontent.com/update.dmg",
        bundleIdentifier: String = GitHubUpdateService.expectedBundleIdentifier,
        sha256: String? = nil,
        minimumSystemVersion: String = "26.0",
        architectures: [String] = ["arm64"]
    ) -> Data {
        let digest = sha256 ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return try! JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "version": "1.1.0",
            "minimumSystemVersion": minimumSystemVersion,
            "architectures": architectures,
            "dmgURL": dmgURL,
            "dmgSHA256": digest,
            "bundleIdentifier": bundleIdentifier,
            "teamIdentifier": "TEAM123",
        ])
    }
}

private final class MockNetworking: GitHubUpdateNetworking, @unchecked Sendable {
    let release: Data
    let manifest: Data
    let downloadBytes: Data
    var requestURLs: [URL] = []

    init(release: Data, manifest: Data, downloadBytes: Data = Data()) {
        self.release = release
        self.manifest = manifest
        self.downloadBytes = downloadBytes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestURLs.append(request.url!)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (requestURLs.count == 1 ? release : manifest, response)
    }

    func download(from url: URL, to destinationURL: URL) async throws -> URL {
        try downloadBytes.write(to: destinationURL)
        return destinationURL
    }
}
