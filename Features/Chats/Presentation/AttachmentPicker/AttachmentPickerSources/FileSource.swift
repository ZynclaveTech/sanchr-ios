// FileSource.swift
import Foundation
import UIKit
import UniformTypeIdentifiers
import SanchrShared

enum FileSource {

    static let maxBytes: Int64 = 100 * 1024 * 1024

    static func isSizeAcceptable(bytes: Int64) -> Bool { bytes <= maxBytes }

    static func stagingDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-staging", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tmp.path) {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        }
        return tmp
    }

    /// Copies bytes from a (possibly security-scoped) URL into the app sandbox.
    static func copyIntoSandbox(url: URL, filename: String) throws -> URL {
        let dir = try stagingDirectory()
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// Note: extension "zzzzz" (and similar) is used in tests as a truly unknown
    /// extension because UTType may resolve common-sounding strings like "unknown".
    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Full flow: receive a security-scoped URL, copy into sandbox, emit PickedFile.
    static func makePickedFile(fromSecurityScopedURL url: URL) throws -> PickedFile {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard isSizeAcceptable(bytes: size) else {
            throw NSError(domain: "FileSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "File exceeds 100MB limit"])
        }
        let filename = url.lastPathComponent
        let sandboxURL = try copyIntoSandbox(url: url, filename: filename)
        return PickedFile(url: sandboxURL, filename: filename, sizeBytes: size,
                          mimeType: mimeType(forFilename: filename))
    }
}
