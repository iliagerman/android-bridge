import Foundation

/// Exports a meeting note into the local second brain (default ~/second_brain,
/// overridable via BRAIN_ROOT). Writes go through the second-brain skill's
/// brain.py CLI so every cluster index.md stays linked. Notes land under
/// work/meetings/<client-slug>/, with meeting photos stored as attachments.
/// Existing brains using work/sela/meetings keep that legacy location.
public struct SecondBrainExporter {
    public struct TransferError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let fm = FileManager.default
    private let scriptURL: URL
    private let brainRoot: String

    public init() {
        let home = fm.homeDirectoryForCurrentUser
        scriptURL = SecondBrainSkillManager.configuredURL().appendingPathComponent("scripts/brain.py")
        let configured = UserDefaults.standard.string(forKey: "secondBrain.root")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = ProcessInfo.processInfo.environment["BRAIN_ROOT"]?.trimmingCharacters(in: .whitespaces)
        brainRoot = (configured?.isEmpty == false ? configured! : (env?.isEmpty == false ? env! : home.appendingPathComponent("second_brain").path))
    }

    /// Company names are case-insensitive: clusters are keyed by slug (which
    /// lowercases), and if a cluster for this client already exists its stored
    /// title is the canonical spelling — "acme"/"ACME"/"Acme" all map to it.
    public func canonicalClientName(_ client: String) -> String {
        let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let index = "\(brainRoot)/\(meetingsParent)/\(slug(trimmed))/index.md"
        guard let text = try? String(contentsOfFile: index, encoding: .utf8) else { return trimmed }
        let title = text.components(separatedBy: .newlines)
            .first { $0.hasPrefix("# ") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespaces)
        return title?.isEmpty == false ? title! : trimmed
    }

    /// Returns the brain-relative path of the created note.
    public func transfer(meeting: MeetingRecord, client: String) throws -> String {
        guard fm.isReadableFile(atPath: scriptURL.path) else {
            throw TransferError(message: "brain.py not found at \(scriptURL.path)")
        }
        try SecondBrainSkillManager.initializeBrainIfNeeded(
            skillURL: scriptURL.deletingLastPathComponent().deletingLastPathComponent(),
            rootURL: URL(fileURLWithPath: brainRoot)
        )
        let clientName = canonicalClientName(client)
        guard !clientName.isEmpty else { throw TransferError(message: "Client name is empty") }

        var chain: [(slug: String, title: String, desc: String)] = [
            ("work", "Work", "Work-related subjects."),
        ]
        if meetingsParent == "work/sela/meetings" {
            chain.append(("sela", "Sela", "Sela consulting work."))
        }
        chain += [
            ("meetings", "Meetings", "Meeting notes captured with Android Bridge."),
            (slug(clientName), clientName, "Meetings with \(clientName)."),
        ]
        var parent = ""
        for cluster in chain {
            let rel = parent.isEmpty ? cluster.slug : "\(parent)/\(cluster.slug)"
            if !fm.fileExists(atPath: "\(brainRoot)/\(rel)/index.md") {
                try runBrain(["add-cluster", "--parent", parent, "--name", cluster.slug, "--title", cluster.title, "--desc", cluster.desc])
            }
            parent = rel
        }

        let stamp = DateFormatter.brainNoteStamp.string(from: meeting.date)
        let title = "\(meeting.title) (\(stamp))"
        let notePath = "\(parent)/\(slug(title)).md"
        // Re-transferring (e.g. after editing the company back and forth) must
        // update the note instead of failing on brain.py's "note already exists".
        if fm.fileExists(atPath: "\(brainRoot)/\(notePath)") {
            try runBrain(["delete-note", notePath])
        }
        var arguments = ["add-note", "--cluster", parent, "--title", title, "--summary", "Meeting with \(clientName) on \(stamp)", "--tags", "meeting, \(slug(clientName))"]
        for image in meeting.imageFiles {
            arguments += ["--attach", image.path]
        }
        try runBrain(arguments, stdin: noteBody(meeting, clientName: clientName))
        guard fm.fileExists(atPath: "\(brainRoot)/\(notePath)") else {
            throw TransferError(message: "brain.py did not create the note at \(notePath)")
        }
        return notePath
    }

    private var meetingsParent: String {
        fm.fileExists(atPath: "\(brainRoot)/work/sela/meetings") ? "work/sela/meetings" : "work/meetings"
    }

    private func noteBody(_ meeting: MeetingRecord, clientName: String) -> String {
        var body = "Meeting with \(clientName), captured with Android Bridge on \(meeting.date.formatted(date: .long, time: .shortened)).\n\n## Summary\n\n\(meeting.summary.isEmpty ? "(no summary was generated)" : meeting.summary)\n"
        if !meeting.transcript.isEmpty {
            body += "\n## Transcript\n\n\(meeting.transcript)\n"
        }
        if !meeting.questions.isEmpty {
            body += "\n## Q&A\n\n\(meeting.questions)\n"
        }
        return body
    }

    // Mirrors brain.py `_slug` so the paths we predict match what the CLI creates.
    private func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for character in text.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "untitled" : out
    }

    private func runBrain(_ arguments: [String], stdin: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BRAIN_ROOT"] = brainRoot
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let input = Pipe()
        process.standardInput = input
        try process.run()
        // Write on a background queue: if the script exits before draining stdin,
        // a synchronous write into a full pipe would deadlock waitUntilExit.
        let writer = input.fileHandleForWriting
        let body = Data((stdin ?? "").utf8)
        DispatchQueue.global(qos: .utility).async {
            writer.write(body)
            try? writer.close()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransferError(message: detail?.isEmpty == false ? detail! : "brain.py \(arguments.first ?? "") failed")
        }
    }
}

private extension DateFormatter {
    static let brainNoteStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
