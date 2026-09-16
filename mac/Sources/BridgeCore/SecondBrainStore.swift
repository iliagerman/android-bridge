import DeviceLinkProtocol
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SecondBrainSyncFile: Equatable {
    public let path: String
    public let data: Data
    public let digest: String
    public let mediaType: String
}

public enum SecondBrainStoreError: Error, Equatable {
    case invalidPath
    case unsupportedContent
}

public struct SecondBrainApplyResult: Equatable {
    public let outcome: ConflictOutcome
    public let conflictPath: String?
}

public struct BrainNode: Identifiable, Equatable {
    public let id: String
    public let path: String
    public let label: String
    public let isDirectory: Bool
    public let depth: Int
}

public struct BrainSearchResult: Identifiable, Equatable {
    public let id: String
    public let path: String
    public let title: String
    public let snippet: String
}

public struct BrainEdge: Identifiable, Equatable {
    public let id: String
    public let from: String
    public let to: String
    public let label: String
}

public final class SecondBrainStore {
    private let fm = FileManager.default
    private let explicitRoot: URL?

    public init(rootURL: URL? = nil) {
        self.explicitRoot = rootURL
    }

    private var scriptURL: URL {
        SecondBrainSkillManager.configuredURL().appendingPathComponent("scripts/brain.py")
    }

    public var rootURL: URL {
        if let explicitRoot { return explicitRoot }
        let home = fm.homeDirectoryForCurrentUser
        let configured = UserDefaults.standard.string(forKey: "secondBrain.root")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = ProcessInfo.processInfo.environment["BRAIN_ROOT"]?.trimmingCharacters(in: .whitespaces)
        let path = configured?.isEmpty == false ? configured! : (env?.isEmpty == false ? env! : home.appendingPathComponent("second_brain").path)
        return URL(fileURLWithPath: path)
    }

    public func revision() -> String {
        let files = (try? syncFiles()) ?? []
        return ([rootURL.path] + files.map { "\($0.path)|\($0.digest)" }.sorted()).joined(separator: "\n")
    }

    public func syncFiles() throws -> [SecondBrainSyncFile] {
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let urls = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let path = relativePath(for: url)
            guard Self.isSyncablePath(path) else { return nil }
            let data = try Data(contentsOf: url)
            guard let mediaType = Self.mediaType(path: path, data: data) else { return nil }
            return SecondBrainSyncFile(path: path, data: data, digest: ContentHash.sha256(data), mediaType: mediaType)
        }.sorted { $0.path < $1.path }
    }

    public func syncData(path: String) throws -> Data? {
        let url = try safeURL(for: path)
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func writeSyncData(path: String, data: Data, mediaType: String) throws {
        guard Self.mediaType(path: path, data: data) == mediaType else { throw SecondBrainStoreError.unsupportedContent }
        let url = try safeURL(for: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func removeSyncData(path: String) throws {
        let url = try safeURL(for: path)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    public func conflictPath(for operation: SyncOperation, deleted: Bool = false) throws -> String {
        guard Self.isValidRelativePath(operation.target) else { throw SecondBrainStoreError.invalidPath }
        let target = operation.target as NSString
        let ext = deleted ? "md" : target.pathExtension
        let stem = (target.lastPathComponent as NSString).deletingPathExtension
        let actor = operation.actorId.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let suffix = deleted ? ".deleted" : ""
        let name = "\(stem).conflict-\(String(actor))-\(String(format: "%010lld", operation.sequence))\(suffix)"
        let file = ext.isEmpty ? name : "\(name).\(ext)"
        let directory = target.deletingLastPathComponent
        return directory.isEmpty ? file : "\(directory)/\(file)"
    }

    public static func isSyncablePath(_ path: String) -> Bool {
        guard isValidRelativePath(path) else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "md" { return true }
        return ["jpg", "jpeg", "png"].contains(ext) && path.hasPrefix("meetings/android-bridge/photos/")
    }

    public static func mediaType(path: String, data: Data) -> String? {
        guard isSyncablePath(path) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "md" { return String(data: data, encoding: .utf8) == nil ? nil : "text/markdown" }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let type = CGImageSourceGetType(source), let imageType = UTType(type as String) else { return nil }
        if ["jpg", "jpeg"].contains(ext), imageType.conforms(to: .jpeg) { return "image/jpeg" }
        if ext == "png", imageType.conforms(to: .png) { return "image/png" }
        return nil
    }

    public static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public func tree() throws -> [BrainNode] {
        let output = try run(["tree"])
        var stack = [String]()
        return output.components(separatedBy: .newlines).compactMap { parseTreeLine($0, stack: &stack) }
    }

    public func show(_ path: String) throws -> String {
        try run(["show", path.isEmpty ? "index.md" : path])
    }

    public func edges() -> [BrainEdge] {
        let files = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "md" }.flatMap { url in
            let rel = String(url.path.dropFirst(rootURL.path.count + 1))
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return links(in: text).map { link in
                let target = resolve(link.target, from: rel)
                return BrainEdge(id: "\(rel)->\(target)->\(link.title)", from: rel, to: target, label: link.title)
            }
        }
    }

    public func search(_ query: String) throws -> [BrainSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = LLMConfig.config(for: .secondBrainSearch)
        if config.usePi {
            let prompt = "Search my second brain for: \(clean). Return concise matching note paths and snippets."
            let answer = LLMService(feature: .secondBrainSearch).run(prompt, feature: .secondBrainSearch) ?? "No search results returned."
            return [BrainSearchResult(id: "pi", path: "index.md", title: "pi results", snippet: answer)]
        }
        return try localSearch(clean)
    }

    public func addCluster(parent: String, name: String, title: String, desc: String) throws {
        _ = try run(["add-cluster", "--parent", parent, "--name", name, "--title", title, "--desc", desc])
        _ = try run(["check"])
    }

    public func addNote(cluster: String, title: String, summary: String, tags: String, body: String) throws {
        _ = try run(["add-note", "--cluster", cluster, "--title", title, "--summary", summary, "--tags", tags], stdin: body)
        _ = try run(["check"])
    }

    public func save(path: String, content: String, modifiedAtMs: Int? = nil) throws {
        guard Self.isMarkdownPath(path) else { throw NSError(domain: "SecondBrain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only Markdown notes are supported"]) }
        if let modifiedAtMs, self.modifiedAtMs(path: path) > modifiedAtMs { return }
        let url = rootURL.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _ = try run(["check"])
    }

    public func deleteNote(path: String, modifiedAtMs: Int? = nil) throws {
        guard Self.isMarkdownPath(path) else { throw NSError(domain: "SecondBrain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only Markdown notes are supported"]) }
        if let modifiedAtMs, self.modifiedAtMs(path: path) > modifiedAtMs { return }
        _ = try run(["delete-note", path])
        _ = try run(["check"])
    }

    public func modifiedAtMs(path: String) -> Int {
        let url = rootURL.appendingPathComponent(path)
        let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        return Int(date.timeIntervalSince1970 * 1000)
    }

    public static func isMarkdownPath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".md") && isValidRelativePath(path)
    }

    public func answer(path: String, question: String) throws -> String {
        let content = try show(path)
        let prompt = "Answer the question using only this second-brain node. If the answer is not present, say so briefly.\n\nNode path: \(path)\n\nNode content:\n\(content)\n\nQuestion: \(question)"
        return LLMService(feature: .secondBrainQA).run(prompt, feature: .secondBrainQA) ?? "No answer returned."
    }

    private func safeURL(for path: String) throws -> URL {
        guard Self.isValidRelativePath(path) else { throw SecondBrainStoreError.invalidPath }
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootURL.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { throw SecondBrainStoreError.invalidPath }
        return candidate
    }

    private func relativePath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
    }

    private func localSearch(_ query: String) throws -> [BrainSearchResult] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        let files = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lower = text.lowercased()
            guard terms.allSatisfy({ lower.contains($0) }) else { return nil }
            let rel = String(url.path.dropFirst(rootURL.path.count + 1))
            return BrainSearchResult(id: rel, path: rel, title: title(from: text, fallback: url.deletingPathExtension().lastPathComponent), snippet: snippet(from: text, terms: terms))
        }.prefix(12).map { $0 }
    }

    private func title(from text: String, fallback: String) -> String {
        text.components(separatedBy: .newlines).first { $0.hasPrefix("# ") }?.replacingOccurrences(of: "# ", with: "") ?? fallback
    }

    private func snippet(from text: String, terms: [String]) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("tags:") }
        let matches = lines.filter { line in terms.contains { line.lowercased().contains($0) } }.prefix(3)
        let picked = matches.isEmpty ? lines.prefix(3) : matches
        return picked.map { compact($0) }.joined(separator: "\n")
    }

    private func compact(_ line: String) -> String {
        line.count > 260 ? String(line.prefix(260)) + "…" : line
    }

    private func links(in text: String) -> [(title: String, target: String)] {
        let pattern = #"\[([^\]]+)\]\(([^\)]+\.md)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges == 3 else { return nil }
            return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
        }
    }

    private func resolve(_ target: String, from source: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        let base = (source as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: base).appendingPathComponent(target).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func run(_ arguments: [String], stdin: String? = nil) throws -> String {
        try SecondBrainSkillManager.initializeBrainIfNeeded(
            skillURL: scriptURL.deletingLastPathComponent().deletingLastPathComponent(),
            rootURL: rootURL
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BRAIN_ROOT"] = rootURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = Pipe()
        process.standardInput = input
        try process.run()
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            writer.write(Data((stdin ?? "").utf8))
            try? writer.close()
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 { return String(data: data, encoding: .utf8) ?? "" }
        let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "brain.py failed"
        throw NSError(domain: "SecondBrain", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
    }

    private func parseTreeLine(_ line: String, stack: inout [String]) -> BrainNode? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "second_brain/" else { return nil }
        let marker = line.range(of: "├── ") ?? line.range(of: "└── ")
        guard let marker else { return nil }
        let label = String(line[marker.upperBound...])
        let depth = line.distance(from: line.startIndex, to: marker.lowerBound) / 4
        while stack.count > depth { stack.removeLast() }
        let isDirectory = label.hasSuffix("/")
        let name = isDirectory ? String(label.dropLast()) : label
        let path = (stack + [name]).joined(separator: "/") + (isDirectory ? "/index.md" : "")
        if isDirectory { stack.append(name) }
        return BrainNode(id: path, path: path, label: label, isDirectory: isDirectory, depth: depth)
    }
}
