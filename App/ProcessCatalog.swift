import AppKit
import Foundation

struct RunningAppChoice: Identifiable {
    let url: URL
    let name: String
    var id: String { url.path }
}
enum ProcessCatalog {
    @MainActor static func runningApps() -> [RunningAppChoice] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, url.pathExtension == "app", seen.insert(url.path).inserted else { return nil }
            return RunningAppChoice(url: url, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func executables(in bundle: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [String] = []; var visited = 0
        for case let url as URL in enumerator {
            visited += 1; if visited > 40_000 || found.count >= 200 { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true && values.isExecutable == true {
                found.append(String(url.path.dropFirst(bundle.path.count + 1)))
            }
        }
        return found.sorted()
    }
    static func rulePath(_ url: URL) -> String { "^" + NSRegularExpression.escapedPattern(for: url.standardizedFileURL.path) + "/" }
}
