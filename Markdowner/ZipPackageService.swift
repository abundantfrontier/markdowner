import AppKit
import Foundation
import UniformTypeIdentifiers

/// An opened Markdown package (zip) extracted to a private cache for browsing.
struct PackageSession: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Original user-selected `.zip` (security-scoped while session is live).
    let packageURL: URL
    /// Expanded tree on disk (temp/cache). Treated as the sidebar root.
    let extractRoot: URL
    let displayName: String

    var isReadOnly: Bool { true }
}

/// Opens zip archives into a cache directory so the existing folder browser / links / images work.
enum ZipPackageService {
    private static let cacheFolderName = "MarkdownerPackages"

    static var zipContentTypes: [UTType] {
        var types: [UTType] = []
        if let zip = UTType(filenameExtension: "zip") { types.append(zip) }
        types.append(.zip)
        return types
    }

    /// Expand `zipURL` into a unique cache directory. Caller should retain `PackageSession`
    /// and call `close` when done (or when replacing with another package).
    static func open(_ zipURL: URL) throws -> PackageSession {
        let standardized = zipURL.standardizedFileURL
        let accessed = standardized.startAccessingSecurityScopedResource()

        let id = UUID()
        let root = try packageCacheRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try extract(zip: standardized, to: root)
        } catch {
            try? FileManager.default.removeItem(at: root)
            if accessed { standardized.stopAccessingSecurityScopedResource() }
            throw error
        }

        // Keep security scope for the zip file for the life of the session
        // (needed if we re-read or extract-to-user-folder later).
        if !accessed {
            // Non-scoped open (e.g. already accessible path) — still OK.
        }

        let name = standardized.deletingPathExtension().lastPathComponent
        return PackageSession(
            id: id,
            packageURL: standardized,
            extractRoot: root,
            displayName: name.isEmpty ? standardized.lastPathComponent : name
        )
    }

    static func close(_ session: PackageSession) {
        session.packageURL.stopAccessingSecurityScopedResource()
        try? FileManager.default.removeItem(at: session.extractRoot)
    }

    /// Copy the expanded package tree to a user-chosen folder (for real editing later).
    static func extractToUserFolder(_ session: PackageSession, destinationParent: URL) throws -> URL {
        let dest = destinationParent.appendingPathComponent(session.displayName, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw PackageError.destinationExists(dest.lastPathComponent)
        }
        try FileManager.default.copyItem(at: session.extractRoot, to: dest)
        return dest
    }

    // MARK: - Extract

    private static func packageCacheRoot() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent(cacheFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func extract(zip: URL, to destination: URL) throws {
        // Prefer system unzip (handles deflate, folders, unicode names).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zip.path, "-d", destination.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PackageError.unzipFailed("Couldn’t run unzip: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PackageError.unzipFailed(msg?.isEmpty == false ? msg! : "unzip exited with status \(process.terminationStatus)")
        }

        // If the archive is a single top-level folder, leave it — hierarchy is intentional.
        // Ensure we actually got content.
        let contents = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if contents.isEmpty {
            throw PackageError.emptyArchive
        }
    }

    enum PackageError: LocalizedError {
        case unzipFailed(String)
        case emptyArchive
        case destinationExists(String)
        case notAPackage

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let detail):
                return "Couldn’t open package.\n\(detail)"
            case .emptyArchive:
                return "That zip archive is empty."
            case .destinationExists(let name):
                return "“\(name)” already exists in the chosen folder."
            case .notAPackage:
                return "That file isn’t a Markdown package (.zip)."
            }
        }
    }
}
