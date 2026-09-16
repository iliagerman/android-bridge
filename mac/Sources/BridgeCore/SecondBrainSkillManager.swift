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
        if defaults.string(forKey: defaultsKey) != nil {
            return configuredURL(defaults: defaults, fileManager: fileManager)
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
