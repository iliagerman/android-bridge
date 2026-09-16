import Foundation

public enum SecondBrainSkillManager {
    public static let defaultsKey = "pi.secondBrainSkill"

    public static func installedURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidBridge/second-brain-skill", isDirectory: true)
    }

    public static func configuredURL(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        let configured = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false
            ? URL(fileURLWithPath: configured!)
            : installedURL(fileManager: fileManager)
    }

    @discardableResult
    public static func installBundledSkillIfNeeded(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> URL {
        let legacy = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills/second-brain", isDirectory: true)
        if let configured = defaults.string(forKey: defaultsKey) {
            let configuredURL = URL(fileURLWithPath: configured)
            if fileManager.fileExists(atPath: configuredURL.appendingPathComponent("SKILL.md").path) {
                return configuredURL
            }
            if configuredURL.standardizedFileURL != legacy.standardizedFileURL {
                return configuredURL
            }
        }

        if fileManager.fileExists(atPath: legacy.appendingPathComponent("SKILL.md").path) {
            defaults.set(legacy.path, forKey: defaultsKey)
            return legacy
        }

        let destination = installedURL(fileManager: fileManager)
        if !fileManager.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path) {
            let source = try bundledURL(bundle: bundle)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }
        defaults.set(destination.path, forKey: defaultsKey)
        return destination
    }

    public static func bundledSkillText(bundle: Bundle = .main) throws -> String {
        try String(contentsOf: bundledURL(bundle: bundle).appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    public static func initializeBrainIfNeeded(skillURL: URL, rootURL: URL) throws {
        let index = rootURL.appendingPathComponent("index.md")
        guard !FileManager.default.fileExists(atPath: index.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", skillURL.appendingPathComponent("scripts/brain.py").path, "init"]
        var environment = setupProcessEnvironment()
        environment["BRAIN_ROOT"] = rootURL.path
        process.environment = environment
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Second Brain initialization failed."
            throw NSError(domain: "SecondBrainSkill", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private static func bundledURL(bundle: Bundle) throws -> URL {
        guard let url = bundle.resourceURL?.appendingPathComponent("Tools/second_brain", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
            throw NSError(
                domain: "SecondBrainSkill",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The embedded Second Brain skill is missing from the app bundle."]
            )
        }
        return url
    }
}
