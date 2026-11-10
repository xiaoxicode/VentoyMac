import Foundation
import CryptoKit

/// Errors raised while turning an official `ventoy-<ver>-linux.tar.gz` into a
/// verified, ready-to-write set of bootloader images.
public enum AssetImportError: Error, LocalizedError, Equatable {
    case invalidPackage
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case missingPayload([String])
    case decompressFailed(String)
    case invalidPayload([String])

    public var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "所选文件不是 Ventoy 官方 linux.tar.gz 发布包。"
        case .checksumMismatch(let e, let a):
            return "SHA256 校验失败。\n期望：\(e)\n实际：\(a)\n已丢弃该文件。"
        case .extractionFailed(let m):
            return "解包失败：\(m)"
        case .missingPayload(let names):
            return "发布包内缺少文件：\(names.joined(separator: ", "))"
        case .decompressFailed(let m):
            return "xz 解压失败：\(m)"
        case .invalidPayload(let issues):
            return "引导镜像校验失败：\(issues.joined(separator: "；"))"
        }
    }
}

/// The single source of truth for "import a Ventoy release archive".
///
/// Lives in `VentoyCore` (no SwiftUI dependency) so both the GUI and the
/// read-only CLI exercise exactly the same code path:
///
///   verify SHA256 → /usr/bin/tar -xzf → copy boot.img →
///   decompress core.img.xz + ventoy.disk.img.xz → validate sizes → manifest
public enum BootAssetInstaller {

    public static let manifestName = "manifest.json"

    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VentoyMac", isDirectory: true)
    }

    public static func manifestURL(for cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(manifestName)
    }

    public static func loadCached(from cacheDirectory: URL = defaultCacheDirectory) -> BootAssets? {
        guard let data = try? Data(contentsOf: manifestURL(for: cacheDirectory)),
              let cached = try? JSONDecoder().decode(BootAssets.self, from: data),
              cached.isComplete else { return nil }
        return cached
    }

    /// Streamed SHA256, identical to `shasum -a 256`.
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Install the archive into `boot-<version>/` and write `manifest.json`.
    /// Synchronous on purpose: callers offload it to a background task.
    public static func install(package: URL,
                               cacheDirectory: URL = defaultCacheDirectory,
                               expectedSHA256: String? = nil) throws -> BootAssets {
        guard package.lastPathComponent.contains(VentoySpec.releaseAssetSuffix) else {
            throw AssetImportError.invalidPackage
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let actual = try sha256(package)
        if let expected = expectedSHA256, !expected.isEmpty,
           actual.lowercased() != expected.lowercased() {
            throw AssetImportError.checksumMismatch(expected: expected, actual: actual)
        }

        let extractRoot = cacheDirectory.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractRoot) }

        let tar = try run("/usr/bin/tar", ["-xzf", package.path, "-C", extractRoot.path])
        guard tar.status == 0 else {
            throw AssetImportError.extractionFailed(tar.stderr)
        }

        let entries = (try? fm.subpathsOfDirectory(atPath: extractRoot.path)) ?? []
        func find(_ suffix: String) -> URL? {
            entries.first { $0.hasSuffix(suffix) }.map { extractRoot.appendingPathComponent($0) }
        }
        guard let bootIMG = find("/boot/boot.img"),
              let coreXZ = find("/boot/core.img.xz"),
              let efiXZ = find("/ventoy/ventoy.disk.img.xz") else {
            throw AssetImportError.missingPayload([
                "boot/boot.img", "boot/core.img.xz", "ventoy/ventoy.disk.img.xz"
            ])
        }

        var version = versionFromFilename(package.lastPathComponent)
        if let file = find("/ventoy/version"),
           let text = try? String(contentsOf: file, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let target = cacheDirectory.appendingPathComponent("boot-\(version)", isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        try fm.copyItem(at: bootIMG, to: target.appendingPathComponent("boot.img"))
        try decompressXZ(coreXZ, to: target.appendingPathComponent("core.img"))
        try decompressXZ(efiXZ, to: target.appendingPathComponent("ventoy.disk.img"))

        let result = BootAssets(version: version,
                                directory: target.path,
                                sourceSHA256: actual,
                                sourceFileName: package.lastPathComponent)
        let issues = result.validationIssues
        guard issues.isEmpty else {
            throw AssetImportError.invalidPayload(issues)
        }

        let data = try JSONEncoder().encode(result)
        try data.write(to: manifestURL(for: cacheDirectory), options: .atomic)
        return result
    }

    public static func versionFromFilename(_ name: String) -> String {
        guard let range = name.range(of: "ventoy-") else { return "unknown" }
        let rest = name[range.upperBound...]
        return rest.components(separatedBy: "-linux").first.map { String($0) } ?? "unknown"
    }

    /// Prefers a real `xz`; falls back to the system Python 3 `lzma` module,
    /// which is always present on macOS and matches the official `.xz` stream.
    public static func decompressXZ(_ input: URL, to output: URL) throws {
        let q = ShellQuote.bash
        let candidates = ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
        let command: String
        if let xz = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            command = "\(q(xz)) -dc \(q(input.path)) > \(q(output.path))"
        } else {
            let py = "/usr/bin/python3"
            let script = "import lzma,shutil,sys\nwith lzma.open(sys.argv[1],'rb') as i, open(sys.argv[2],'wb') as o: shutil.copyfileobj(i,o,1048576)\n"
            command = "\(q(py)) -c \(q(script)) \(q(input.path)) \(q(output.path))"
        }
        let result = try run("/bin/bash", ["-c", command])
        guard result.status == 0 else {
            throw AssetImportError.decompressFailed(result.stderr)
        }
    }

    // MARK: - Process helper (file-backed pipes avoid deadlocks on large output)

    private struct CommandResult {
        let status: Int32
        let stderr: String
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> CommandResult {
        let fm = FileManager.default
        let tag = "vtoymac-\(UUID().uuidString)"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tag + ".out")
        let errURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tag + ".err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            try? out.close()
            try? err.close()
            throw AssetImportError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        try? out.close()
        try? err.close()
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus,
                             stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
