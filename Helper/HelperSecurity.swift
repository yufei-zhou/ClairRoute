import Foundation
import Security
import SystemConfiguration
import Darwin

enum HelperFailure: Error, LocalizedError {
    case refused(String)
    var errorDescription: String? { if case let .refused(message) = self { message } else { nil } }
}

struct AuthenticatedClient: Equatable, Sendable {
    let connectionID: UUID
    let uid: uid_t
    let pid: pid_t

    func requireConsoleOwner() throws {
        var currentUID: uid_t = 0
        var currentGID: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &currentUID, &currentGID) != nil,
              uid > 0, uid == currentUID, pid > 1 else {
            throw HelperFailure.refused("Only the current signed-in console user can control ClairRoute.")
        }
    }
}

enum HelperSecurity {
    static let root = URL(fileURLWithPath: AppConstants.supportDirectory, isDirectory: true)
    static let binary = root.appendingPathComponent("bin/mihomo")
    static let manifest = root.appendingPathComponent("CoreManifest.json")
    static let state = root.appendingPathComponent("state", isDirectory: true)
    static let runtime = root.appendingPathComponent("run", isDirectory: true)
    static let controller = runtime.appendingPathComponent("controller.sock").path
    static let expectedArchiveDigest = "d131f44b3deb2a8356f7ac75048ad67a10d53243323951c4f3cda7b672922963"

    static func requirement(key: String, identifier: String) throws -> String {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !text.isEmpty, !text.contains("$("), !text.contains("PLACEHOLDER"),
              text.contains(identifier), text.contains("certificate leaf") else {
            throw HelperFailure.refused("A pinned code-signing requirement is missing. Prepare and sign this build before installing its Helper.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw HelperFailure.refused("The bundled code-signing requirement is invalid.")
        }
        return text
    }

    static func verifyCode(_ url: URL, requirement: String, directory: Bool = false) throws {
        try assertRootOwned(url, directory: directory)
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              let code, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), rule) == errSecSuccess else {
            throw HelperFailure.refused("Installed code does not satisfy the pinned code signature.")
        }
    }

    /// Every component must be root-owned, not symlinked, and not writable by other users.
    static func assertRootOwned(_ url: URL, directory: Bool) throws {
        let components = url.standardizedFileURL.pathComponents
        var path = ""
        for (index, component) in components.enumerated() {
            path = index == 0 ? "/" : (path as NSString).appendingPathComponent(component)
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw HelperFailure.refused("Cannot inspect a protected installation path.")
            }
            // macOS ships /Applications root:admin 0775. Never chmod that shared directory.
            // The installed app itself and every component below it remain strictly protected.
            let systemApplicationsParent = path == "/Applications" &&
                (url.path.hasPrefix("/Applications/ClairRoute.app/") ||
                 url.path == "/Applications/ClairRoute.app")
            let permittedMode = info.st_mode & 0o022 == 0 ||
                (systemApplicationsParent && info.st_gid == 80 && info.st_mode & 0o002 == 0)
            guard info.st_uid == 0, permittedMode,
                  info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw HelperFailure.refused("The installed Helper/core paths must be root-owned and protected from modification.")
            }
            let expected = index == components.count - 1 && !directory ? S_IFREG : S_IFDIR
            guard info.st_mode & mode_t(S_IFMT) == mode_t(expected) else {
                throw HelperFailure.refused("An installed Helper/core path has an unexpected file type.")
            }
        }
    }

    static func prepareDirectories() throws {
        guard getuid() == 0, geteuid() == 0 else {
            throw HelperFailure.refused("The Helper requires a root LaunchDaemon installation.")
        }
        try assertRootOwned(root, directory: true)
        for directory in [state, runtime] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                guard mkdir(directory.path, 0o700) == 0 else {
                    throw HelperFailure.refused("Cannot create the protected runtime directory.")
                }
            }
            try assertRootOwned(directory, directory: true)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & 0o077 == 0 else {
                throw HelperFailure.refused("The runtime and recovery directories must have mode 0700.")
            }
        }
    }
}
