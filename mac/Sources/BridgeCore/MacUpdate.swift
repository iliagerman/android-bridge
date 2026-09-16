import Foundation
import Crypto

public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw MacUpdateError.invalidVersion }
        let numbers = try parts.map(Self.parseComponent)
        guard numbers[0] <= 2_100, numbers[1] <= 999, numbers[2] <= 999 else { throw MacUpdateError.invalidVersion }
        let code = numbers[0] * 1_000_000 + numbers[1] * 1_000 + numbers[2]
        guard code >= 1, code <= 2_100_000_000 else { throw MacUpdateError.invalidVersion }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    private static func parseComponent(_ value: Substring) throws -> Int {
        guard !value.isEmpty, value.allSatisfy(\ .isNumber), value == "0" || !value.hasPrefix("0"), let number = Int(value) else {
            throw MacUpdateError.invalidVersion
        }
        return number
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var versionCode: Int { major * 1_000_000 + minor * 1_000 + patch }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct ReleaseAsset: Sendable, Equatable {
    public let name: String
    public let size: Int64
    public let url: URL

    public init(name: String, size: Int64, url: URL) {
        self.name = name
        self.size = size
        self.url = url
    }
}

public struct ReleaseBundle: Sendable {
    public let version: SemanticVersion
    public let pageURL: URL
    public let dmg: ReleaseAsset
    public let checksum: ReleaseAsset
    public let sha256: String

    public init(version: SemanticVersion, pageURL: URL, dmg: ReleaseAsset, checksum: ReleaseAsset, sha256: String) {
        self.version = version
        self.pageURL = pageURL
        self.dmg = dmg
        self.checksum = checksum
        self.sha256 = sha256
    }
}

public struct MacUpdate: Sendable {
    public let version: SemanticVersion
    public let pageURL: URL
    public let dmg: ReleaseAsset
    public let checksum: ReleaseAsset
    public let sha256: String

    public init(bundle: ReleaseBundle) {
        version = bundle.version
        pageURL = bundle.pageURL
        dmg = bundle.dmg
        checksum = bundle.checksum
        sha256 = bundle.sha256
    }
}

public struct VerifiedMacUpdate: Sendable {
    public let update: MacUpdate
    public let fileURL: URL

    public init(update: MacUpdate, fileURL: URL) {
        self.update = update
        self.fileURL = fileURL
    }
}

public enum MacUpdateError: Error, Equatable, LocalizedError {
    case invalidVersion
    case invalidRelease
    case invalidManifest
    case invalidAsset
    case invalidURL
    case invalidResponse
    case responseTooLarge
    case checksumMismatch
    case sizeMismatch
    case hashMismatch
    case invalidSignature
    case filesystem
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidVersion: return "The update version is invalid."
        case .invalidRelease: return "The release metadata is invalid."
        case .invalidManifest: return "The release manifest is invalid."
        case .invalidAsset: return "The release assets are invalid."
        case .invalidURL: return "The release download address is invalid."
        case .invalidResponse: return "The update server returned an invalid response."
        case .responseTooLarge: return "The update response was too large."
        case .checksumMismatch: return "The downloaded checksum did not match the release."
        case .sizeMismatch: return "The downloaded update size did not match the release."
        case .hashMismatch: return "The downloaded update hash did not match the release."
        case .invalidSignature: return "The downloaded update was not signed by Android Bridge."
        case .filesystem: return "The update could not be stored safely."
        case .cancelled: return "The update download was cancelled."
        }
    }
}

public protocol ReleaseFetching {
    func latestStableRelease() async throws -> ReleaseBundle
}

public protocol ArtifactDownloading {
    func data(from asset: ReleaseAsset, maximumBytes: Int) async throws -> Data
    func download(_ asset: ReleaseAsset, to directory: URL, maximumBytes: Int64) async throws -> URL
}

public protocol DMGVerifying {
    func verify(_ dmg: URL) throws
}

public final class CodeSignatureDMGVerifier: DMGVerifying {
    private static let requirement = "identifier \"com.androidbridge.mac\" and certificate leaf = H\"ef2fb966bb80189b6e12ef4a9111601f4d8466ec\""

    public init() {}

    public func verify(_ dmg: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("android-bridge-mount-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false) }
        catch { throw MacUpdateError.filesystem }
        var failure: Error?
        var attached = false
        do {
            try Self.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path])
            attached = true
            let app = mount.appendingPathComponent("AndroidBridge.app")
            guard FileManager.default.fileExists(atPath: app.path) else { throw MacUpdateError.invalidSignature }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(Self.requirement)", app.path])
        } catch { failure = error }
        if attached { do { try Self.run("/usr/bin/hdiutil", ["detach", mount.path]) } catch { failure = failure ?? error } }
        do { try FileManager.default.removeItem(at: mount) } catch { failure = failure ?? MacUpdateError.filesystem }
        if let failure { throw failure }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw MacUpdateError.invalidSignature }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MacUpdateError.invalidSignature }
    }
}

private func boundedData(_ bytes: URLSession.AsyncBytes, maximumBytes: Int) async throws -> Data {
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 65_536))
    for try await byte in bytes {
        guard data.count < maximumBytes else { throw MacUpdateError.responseTooLarge }
        data.append(byte)
    }
    return data
}

private enum GitHubUpdateSession {
    static let hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]

    static func make() -> URLSession {
        URLSession(configuration: .default, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    static func isClean(_ url: URL, allowsQuery: Bool) -> Bool {
        guard url.scheme == "https", let host = url.host, hosts.contains(host), url.user == nil,
              url.password == nil, url.fragment == nil, allowsQuery || url.query == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.flatMap { isClean($0, allowsQuery: true) ? request : nil })
        }
    }
}

public final class GitHubReleaseClient: ReleaseFetching {
    public static let endpoint = URL(string: "https://api.github.com/repos/iliagerman/android-bridge/releases/latest")!
    private let session: URLSession

    public init(session: URLSession? = nil) { self.session = session ?? GitHubUpdateSession.make() }

    public func latestStableRelease() async throws -> ReleaseBundle {
        let releaseData = try await responseData(at: Self.endpoint, maximumBytes: 1_048_576, api: true)
        let release = try ReleaseBundleDecoder.release(from: releaseData)
        let manifestAsset = try release.asset(named: "release-manifest.json")
        let manifestData = try await responseData(at: manifestAsset.url, maximumBytes: 65_536, api: false)
        return try ReleaseBundleDecoder.bundle(release: release, manifestData: manifestData)
    }

    private func responseData(at url: URL, maximumBytes: Int, api: Bool) async throws -> Data {
        guard Self.isAllowed(url, api: api) else { throw MacUpdateError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let finalURL = response.url,
              Self.isAllowedFinalURL(finalURL, api: api) else { throw MacUpdateError.invalidResponse }
        return try await boundedData(bytes, maximumBytes: maximumBytes)
    }

    static func isAllowed(_ url: URL, api: Bool) -> Bool {
        guard GitHubUpdateSession.isClean(url, allowsQuery: false), let host = url.host else { return false }
        if api { return host == "api.github.com" && url == endpoint }
        return host == "github.com" && url.path.hasPrefix("/iliagerman/android-bridge/releases/download/")
    }

    static func isAllowedFinalURL(_ url: URL, api: Bool) -> Bool {
        guard GitHubUpdateSession.isClean(url, allowsQuery: !api), let host = url.host else { return false }
        return api ? host == "api.github.com" : GitHubUpdateSession.hosts.contains(host)
    }
}

public final class URLSessionArtifactDownloader: ArtifactDownloading {
    private let session: URLSession

    public init(session: URLSession? = nil) { self.session = session ?? GitHubUpdateSession.make() }

    public func data(from asset: ReleaseAsset, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, GitHubReleaseClient.isAllowed(asset.url, api: false) else { throw MacUpdateError.invalidURL }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: asset.url))
        try validate(response: response, count: 0, maximumBytes: Int64(maximumBytes))
        return try await boundedData(bytes, maximumBytes: maximumBytes)
    }

    public func download(_ asset: ReleaseAsset, to directory: URL, maximumBytes: Int64) async throws -> URL {
        guard maximumBytes > 0, GitHubReleaseClient.isAllowed(asset.url, api: false) else { throw MacUpdateError.invalidURL }
        let destination = directory.appendingPathComponent(asset.name)
        let handle: FileHandle
        do { try Data().write(to: destination); handle = try FileHandle(forWritingTo: destination) }
        catch { throw MacUpdateError.filesystem }
        defer { try? handle.close() }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: asset.url))
            try validate(response: response, count: 0, maximumBytes: maximumBytes)
            try await write(bytes: bytes, to: handle, maximumBytes: maximumBytes)
            return destination
        } catch is CancellationError {
            throw MacUpdateError.cancelled
        } catch let error as MacUpdateError {
            throw error
        } catch {
            throw MacUpdateError.invalidResponse
        }
    }

    private func write(bytes: URLSession.AsyncBytes, to handle: FileHandle, maximumBytes: Int64) async throws {
        var count: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(65_536)
        for try await byte in bytes {
            guard count < maximumBytes else { throw MacUpdateError.responseTooLarge }
            count += 1
            chunk.append(byte)
            if chunk.count == 65_536 { try write(chunk, to: handle); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try write(chunk, to: handle) }
    }

    private func write(_ chunk: Data, to handle: FileHandle) throws {
        do { try handle.write(contentsOf: chunk) }
        catch { throw MacUpdateError.filesystem }
    }

    private func validate(response: URLResponse, count: Int, maximumBytes: Int64) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = response.url,
              GitHubReleaseClient.isAllowedFinalURL(url, api: false) else { throw MacUpdateError.invalidResponse }
        guard Int64(count) <= maximumBytes else { throw MacUpdateError.responseTooLarge }
    }
}

public final class MacUpdateService {
    private let releases: ReleaseFetching
    private let downloads: ArtifactDownloading
    private let dmgVerifier: DMGVerifying
    private let temporaryDirectory: URL

    public init(releases: ReleaseFetching = GitHubReleaseClient(), downloads: ArtifactDownloading = URLSessionArtifactDownloader(), dmgVerifier: DMGVerifying = CodeSignatureDMGVerifier(), temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.releases = releases
        self.downloads = downloads
        self.dmgVerifier = dmgVerifier
        self.temporaryDirectory = temporaryDirectory
    }

    public func check(currentVersion: String) async throws -> MacUpdate? {
        let current = try SemanticVersion(currentVersion)
        let release = try await releases.latestStableRelease()
        return release.version > current ? MacUpdate(bundle: release) : nil
    }

    public func downloadAndVerify(_ update: MacUpdate) async throws -> VerifiedMacUpdate {
        let directory = temporaryDirectory.appendingPathComponent("android-bridge-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let checksum = try await downloads.data(from: update.checksum, maximumBytes: 65_536)
            let expected = try Self.checksum(from: checksum, filename: update.dmg.name)
            guard expected == update.sha256 else { throw MacUpdateError.checksumMismatch }
            let fileURL = try await downloads.download(update.dmg, to: directory, maximumBytes: update.dmg.size)
            let standardizedFileURL = fileURL.standardizedFileURL
            guard standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
                  standardizedFileURL.lastPathComponent == update.dmg.name else { throw MacUpdateError.filesystem }
            try Self.verify(fileURL: standardizedFileURL, expectedSize: update.dmg.size, expectedHash: expected)
            try dmgVerifier.verify(standardizedFileURL)
            return VerifiedMacUpdate(update: update, fileURL: standardizedFileURL)
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { throw MacUpdateError.filesystem }
            }
            throw error
        }
    }

    public func removeTemporaryUpdate(_ update: VerifiedMacUpdate) throws {
        let directory = update.fileURL.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent() == temporaryDirectory.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("android-bridge-update-") else { throw MacUpdateError.filesystem }
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw MacUpdateError.filesystem }
    }

    static func checksum(from data: Data, filename: String) throws -> String {
        guard let line = String(data: data, encoding: .utf8), line.hasSuffix("\n"), !line.dropLast().contains("\n") else { throw MacUpdateError.checksumMismatch }
        let expected = "  \(filename)\n"
        guard line.hasSuffix(expected) else { throw MacUpdateError.checksumMismatch }
        let digest = String(line.dropLast(expected.count))
        guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MacUpdateError.checksumMismatch
        }
        return digest
    }

    static func verify(fileURL: URL, expectedSize: Int64, expectedHash: String) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch { throw MacUpdateError.filesystem }
        guard let size = attributes[.size] as? NSNumber, size.int64Value == expectedSize else { throw MacUpdateError.sizeMismatch }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: fileURL) }
        catch { throw MacUpdateError.filesystem }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch {
            throw MacUpdateError.filesystem
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHash else { throw MacUpdateError.hashMismatch }
    }
}

internal enum ReleaseBundleDecoder {
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let size: Int64
        let browser_download_url: URL
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let version: String
        let versionCode: Int
        let minimumMacOS: String
        let minimumAndroidSdk: Int
        let macos: Descriptor
        let android: AndroidDescriptor
    }
    private struct Descriptor: Decodable { let name: String; let size: Int64; let sha256: String }
    private struct AndroidDescriptor: Decodable { let name: String; let size: Int64; let sha256: String; let signerSha256: String }

    static func release(from data: Data) throws -> DecodedRelease {
        try exactObject(data, keys: ["tag_name", "draft", "prerelease", "assets"], error: .invalidRelease, allowExtra: true)
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) }
        catch { throw MacUpdateError.invalidRelease }
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else { throw MacUpdateError.invalidRelease }
        let version = try SemanticVersion(String(release.tag_name.dropFirst()))
        let pairs = try release.assets.map { asset -> (String, ReleaseAsset) in
            guard asset.size > 0, GitHubReleaseClient.isAllowed(asset.browser_download_url, api: false),
                  asset.browser_download_url.path == "/iliagerman/android-bridge/releases/download/v\(version)/\(asset.name)" else { throw MacUpdateError.invalidAsset }
            return (asset.name, ReleaseAsset(name: asset.name, size: asset.size, url: asset.browser_download_url))
        }
        var assets: [String: ReleaseAsset] = [:]
        for (name, asset) in pairs {
            guard assets[name] == nil else { throw MacUpdateError.invalidAsset }
            assets[name] = asset
        }
        return DecodedRelease(version: version, assets: assets)
    }

    static func bundle(release: DecodedRelease, manifestData: Data) throws -> ReleaseBundle {
        try exactObject(manifestData, keys: ["schemaVersion", "version", "versionCode", "minimumMacOS", "minimumAndroidSdk", "macos", "android"], error: .invalidManifest, allowExtra: false)
        try exactDescriptor(manifestData, key: "macos", keys: ["name", "size", "sha256"])
        try exactDescriptor(manifestData, key: "android", keys: ["name", "size", "sha256", "signerSha256"])
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) }
        catch { throw MacUpdateError.invalidManifest }
        let version = try SemanticVersion(manifest.version)
        let dmgName = "AndroidBridge-\(version)-macOS-arm64.dmg"
        guard manifest.schemaVersion == 1, version == release.version, manifest.versionCode == version.versionCode,
              manifest.minimumMacOS == "13.0", manifest.minimumAndroidSdk == 33,
              valid(manifest.macos, name: dmgName), valid(manifest.android, name: "AndroidBridge-\(version)-android.apk"),
              validHash(manifest.android.signerSha256), let dmg = release.assets[dmgName], dmg.size == manifest.macos.size,
              let checksum = release.assets["\(dmgName).sha256"] else { throw MacUpdateError.invalidManifest }
        let page = URL(string: "https://github.com/iliagerman/android-bridge/releases/tag/v\(version)")!
        return ReleaseBundle(version: version, pageURL: page, dmg: dmg, checksum: checksum, sha256: manifest.macos.sha256)
    }

    private static func valid(_ descriptor: Descriptor, name: String) -> Bool { descriptor.name == name && descriptor.size > 0 && validHash(descriptor.sha256) }
    private static func valid(_ descriptor: AndroidDescriptor, name: String) -> Bool { descriptor.name == name && descriptor.size > 0 && validHash(descriptor.sha256) }
    private static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy(\ .isHexDigit) && hash == hash.lowercased() }

    private static func exactObject(_ data: Data, keys: Set<String>, error: MacUpdateError, allowExtra: Bool) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], keys.isSubset(of: Set(object.keys)),
              allowExtra || Set(object.keys) == keys else { throw error }
    }

    private static func exactDescriptor(_ data: Data, key: String, keys: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let descriptor = object[key] as? [String: Any], Set(descriptor.keys) == keys else { throw MacUpdateError.invalidManifest }
    }
}

struct DecodedRelease {
    let version: SemanticVersion
    let assets: [String: ReleaseAsset]

    func asset(named name: String) throws -> ReleaseAsset {
        guard let asset = assets[name] else { throw MacUpdateError.invalidAsset }
        return asset
    }
}
