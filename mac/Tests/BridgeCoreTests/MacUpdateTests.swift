import XCTest
import Crypto
@testable import BridgeCore

final class MacUpdateTests: XCTestCase {
    func testSemanticVersionIsStrictAndNumeric() throws {
        XCTAssertEqual(try SemanticVersion("1.10.0"), try SemanticVersion("1.10.0"))
        XCTAssertTrue(try SemanticVersion("1.10.0") > SemanticVersion("1.2.99"))
        for value in ["1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.-2.3", "1.1000.0", "0.0.0"] {
            XCTAssertThrowsError(try SemanticVersion(value))
        }
    }

    func testManifestAndTagMustBindExactStableAssets() throws {
        let version = try SemanticVersion("1.2.3")
        let release = fixtureRelease(version: version)
        let decoded = try ReleaseBundleDecoder.release(from: Data(release.utf8))
        let manifest = fixtureManifest(version: version)
        let bundle = try ReleaseBundleDecoder.bundle(release: decoded, manifestData: manifest)
        XCTAssertEqual(bundle.version, version)
        XCTAssertEqual(bundle.dmg.name, "AndroidBridge-1.2.3-macOS-arm64.dmg")

        let manifestText = String(data: fixtureManifest(version: version), encoding: .utf8)!
        let bad = manifestText.replacingOccurrences(of: "AndroidBridge-1.2.3-macOS-arm64.dmg", with: "other.dmg")
        XCTAssertThrowsError(try ReleaseBundleDecoder.bundle(release: decoded, manifestData: Data(bad.utf8)))

        let taggedLatest = release.replacingOccurrences(of: "\"tag_name\":\"v1.2.3\"", with: "\"tag_name\":\"latest-build\"")
        XCTAssertThrowsError(try ReleaseBundleDecoder.release(from: Data(taggedLatest.utf8)))
    }

    func testCheckOnlyReturnsStrictlyNewerRelease() async throws {
        let bundle = try fixtureBundle(version: "1.2.3")
        let service = MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads())
        let equal = try await service.check(currentVersion: "1.2.3")
        let older = try await service.check(currentVersion: "2.0.0")
        let newer = try await service.check(currentVersion: "1.2.2")
        XCTAssertNil(equal)
        XCTAssertNil(older)
        XCTAssertEqual(newer?.version, try SemanticVersion("1.2.3"))
    }

    func testChecksumSizeHashAndCleanup() async throws {
        let bytes = Data("verified dmg".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let initialBundle = try fixtureBundle(version: "1.2.3", size: Int64(bytes.count))
        let bundle = ReleaseBundle(version: initialBundle.version, pageURL: initialBundle.pageURL, dmg: initialBundle.dmg, checksum: initialBundle.checksum, sha256: digest)
        let update = MacUpdate(bundle: bundle)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = FakeDownloads(checksum: "\(digest)  \(update.dmg.name)\n", bytes: bytes)
        let service = MacUpdateService(releases: FakeReleases(bundle), downloads: downloader, dmgVerifier: AcceptingDMGVerifier(), temporaryDirectory: root)
        let verified = try await service.downloadAndVerify(update)
        XCTAssertEqual(try Data(contentsOf: verified.fileURL), bytes)
        try service.removeTemporaryUpdate(verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verified.fileURL.deletingLastPathComponent().path))

        let failing = MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads(checksum: "bad\n", bytes: bytes), dmgVerifier: AcceptingDMGVerifier(), temporaryDirectory: root)
        await XCTAssertThrowsErrorAsync(try await failing.downloadAndVerify(update))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    func testChecksumRequiresTheExactCanonicalLine() throws {
        XCTAssertEqual(try MacUpdateService.checksum(from: Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file.dmg\n".utf8), filename: "file.dmg"), String(repeating: "a", count: 64))
        XCTAssertThrowsError(try MacUpdateService.checksum(from: Data("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  file.dmg\n".utf8), filename: "file.dmg"))
        XCTAssertThrowsError(try MacUpdateService.checksum(from: Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa file.dmg\n".utf8), filename: "file.dmg"))
        XCTAssertThrowsError(try MacUpdateService.checksum(from: Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file.dmg\nextra".utf8), filename: "file.dmg"))
    }

    func testReleaseRejectsDraftPrereleaseAndDuplicateAssets() throws {
        let version = try SemanticVersion("1.2.3")
        let release = fixtureRelease(version: version)
        for flag in ["draft", "prerelease"] {
            let invalid = release.replacingOccurrences(of: "\"\(flag)\":false", with: "\"\(flag)\":true")
            XCTAssertThrowsError(try ReleaseBundleDecoder.release(from: Data(invalid.utf8)))
        }
        let base = "https://github.com/iliagerman/android-bridge/releases/download/v\(version)/"
        let duplicate = release.replacingOccurrences(of: "]}", with: ",{\"name\":\"release-manifest.json\",\"size\":100,\"browser_download_url\":\"\(base)release-manifest.json\"}]}")
        XCTAssertThrowsError(try ReleaseBundleDecoder.release(from: Data(duplicate.utf8)))
    }

    func testManifestRejectsExtraAndMismatchedValues() throws {
        let version = try SemanticVersion("1.2.3")
        let release = try ReleaseBundleDecoder.release(from: Data(fixtureRelease(version: version).utf8))
        let text = String(data: fixtureManifest(version: version), encoding: .utf8)!
        let hash = String(repeating: "a", count: 64)
        let name = "AndroidBridge-\(version)-macOS-arm64.dmg"
        let cases = [
            String(text.dropLast()) + ",\"extra\":true}",
            text.replacingOccurrences(of: "\"sha256\":\"\(hash)\"},\"android\"", with: "\"sha256\":\"\(hash)\",\"extra\":true},\"android\""),
            text.replacingOccurrences(of: "\"versionCode\":\(version.versionCode)", with: "\"versionCode\":1"),
            text.replacingOccurrences(of: "\"minimumMacOS\":\"13.0\"", with: "\"minimumMacOS\":\"14.0\""),
            text.replacingOccurrences(of: "\"name\":\"\(name)\"", with: "\"name\":\"other.dmg\""),
            text.replacingOccurrences(of: "\"size\":12", with: "\"size\":13"),
            text.replacingOccurrences(of: "\"sha256\":\"\(hash)\"", with: "\"sha256\":\"\(hash.uppercased())\"")
        ]
        for manifest in cases {
            XCTAssertThrowsError(try ReleaseBundleDecoder.bundle(release: release, manifestData: Data(manifest.utf8)))
        }
    }

    func testDownloadRejectsPathOutsideOwnedDirectory() async throws {
        let bytes = Data("verified dmg".utf8)
        let bundle = try verifiedBundle(bytes: bytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.dmg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checksum = "\(bundle.sha256)  \(bundle.dmg.name)\n"
        let service = MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads(checksum: checksum, bytes: bytes, returnedURL: outside), dmgVerifier: AcceptingDMGVerifier(), temporaryDirectory: root)
        await XCTAssertThrowsErrorAsync(try await service.downloadAndVerify(MacUpdate(bundle: bundle)))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    func testRemovalRefusesPrefixedDirectoryOutsideTemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.deletingLastPathComponent().appendingPathComponent("android-bridge-update-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let bundle = try fixtureBundle(version: "1.2.3")
        let update = VerifiedMacUpdate(update: MacUpdate(bundle: bundle), fileURL: outside.appendingPathComponent(bundle.dmg.name))
        XCTAssertThrowsError(try MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads(), temporaryDirectory: root).removeTemporaryUpdate(update))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFailedDigestAndSizeLeaveTemporaryRootEmpty() async throws {
        let bytes = Data("verified dmg".utf8)
        let bundle = try verifiedBundle(bytes: bytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checksum = "\(bundle.sha256)  \(bundle.dmg.name)\n"
        for downloaded in [Data(repeating: 0, count: bytes.count), Data(repeating: 1, count: bytes.count - 1)] {
            let service = MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads(checksum: checksum, bytes: downloaded), dmgVerifier: AcceptingDMGVerifier(), temporaryDirectory: root)
            await XCTAssertThrowsErrorAsync(try await service.downloadAndVerify(MacUpdate(bundle: bundle)))
            XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
        }
    }

    func testWrongDistributionSignatureIsRejectedAndCleaned() async throws {
        let bytes = Data("verified dmg".utf8)
        let bundle = try verifiedBundle(bytes: bytes)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checksum = "\(bundle.sha256)  \(bundle.dmg.name)\n"
        let service = MacUpdateService(releases: FakeReleases(bundle), downloads: FakeDownloads(checksum: checksum, bytes: bytes), dmgVerifier: RejectingDMGVerifier(), temporaryDirectory: root)

        await XCTAssertThrowsErrorAsync(try await service.downloadAndVerify(MacUpdate(bundle: bundle)))

        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    private func verifiedBundle(bytes: Data) throws -> ReleaseBundle {
        let initial = try fixtureBundle(version: "1.2.3", size: Int64(bytes.count))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ReleaseBundle(version: initial.version, pageURL: initial.pageURL, dmg: initial.dmg, checksum: initial.checksum, sha256: digest)
    }

    private func fixtureBundle(version: String, size: Int64 = 12) throws -> ReleaseBundle {
        let semantic = try SemanticVersion(version)
        let name = "AndroidBridge-\(version)-macOS-arm64.dmg"
        let base = "https://github.com/iliagerman/android-bridge/releases/download/v\(version)/"
        return ReleaseBundle(version: semantic, pageURL: URL(string: "https://github.com/iliagerman/android-bridge/releases/tag/v\(version)")!, dmg: ReleaseAsset(name: name, size: size, url: URL(string: base + name)!), checksum: ReleaseAsset(name: name + ".sha256", size: 80, url: URL(string: base + name + ".sha256")!), sha256: String(repeating: "a", count: 64))
    }

    private func fixtureRelease(version: SemanticVersion) -> String {
        let name = "AndroidBridge-\(version)-macOS-arm64.dmg"
        let base = "https://github.com/iliagerman/android-bridge/releases/download/v\(version)/"
        return "{\"tag_name\":\"v\(version)\",\"draft\":false,\"prerelease\":false,\"assets\":[{\"name\":\"release-manifest.json\",\"size\":100,\"browser_download_url\":\"\(base)release-manifest.json\"},{\"name\":\"\(name)\",\"size\":12,\"browser_download_url\":\"\(base)\(name)\"},{\"name\":\"\(name).sha256\",\"size\":80,\"browser_download_url\":\"\(base)\(name).sha256\"}]}"
    }

    private func fixtureManifest(version: SemanticVersion) -> Data {
        let name = "AndroidBridge-\(version)-macOS-arm64.dmg"
        let android = "AndroidBridge-\(version)-android.apk"
        let hash = String(repeating: "a", count: 64)
        return Data("{\"schemaVersion\":1,\"version\":\"\(version)\",\"versionCode\":\(version.versionCode),\"minimumMacOS\":\"13.0\",\"minimumAndroidSdk\":33,\"macos\":{\"name\":\"\(name)\",\"size\":12,\"sha256\":\"\(hash)\"},\"android\":{\"name\":\"\(android)\",\"size\":1,\"sha256\":\"\(hash)\",\"signerSha256\":\"\(hash)\"}}".utf8)
    }
}

private final class FakeReleases: ReleaseFetching {
    let bundle: ReleaseBundle
    init(_ bundle: ReleaseBundle) { self.bundle = bundle }
    func latestStableRelease() async throws -> ReleaseBundle { bundle }
}

private struct AcceptingDMGVerifier: DMGVerifying {
    func verify(_ dmg: URL) throws {}
}

private struct RejectingDMGVerifier: DMGVerifying {
    func verify(_ dmg: URL) throws { throw MacUpdateError.invalidSignature }
}

private final class FakeDownloads: ArtifactDownloading {
    let checksum: String
    let bytes: Data
    let returnedURL: URL?
    init(checksum: String = String(repeating: "a", count: 64) + "  file.dmg\n", bytes: Data = Data("fixture bytes".utf8), returnedURL: URL? = nil) {
        self.checksum = checksum
        self.bytes = bytes
        self.returnedURL = returnedURL
    }
    func data(from asset: ReleaseAsset, maximumBytes: Int) async throws -> Data { Data(checksum.utf8) }
    func download(_ asset: ReleaseAsset, to directory: URL, maximumBytes: Int64) async throws -> URL {
        let url = directory.appendingPathComponent(asset.name)
        try bytes.write(to: url)
        return returnedURL ?? url
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) }
    catch {}
}
