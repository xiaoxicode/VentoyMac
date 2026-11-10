import Foundation
import SwiftUI
import VentoyCore

enum AssetError: Error, LocalizedError {
    case noLinuxAsset
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .noLinuxAsset: return "该 Release 未找到 linux.tar.gz 资源。"
        case .downloadFailed(let m): return "下载失败：\(m)"
        case .checksumMismatch(let e, let a):
            return "SHA256 校验失败。\n期望：\(e)\n实际：\(a)\n已丢弃该文件。"
        }
    }
}

/// GUI-facing wrapper around `BootAssetInstaller` (VentoyCore).
/// The actual verify/extract/decompress/validate pipeline lives in the core
/// module so the CLI and XCTest exercise the very same code.
@MainActor
final class BootAssetManager: ObservableObject {
    @Published private(set) var assets: BootAssets?
    @Published private(set) var release: ReleaseInfo?
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText: String = "尚未安装引导资源"
    @Published private(set) var isWorking = false

    private let supportDir: URL

    init() {
        supportDir = BootAssetInstaller.defaultCacheDirectory
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        loadCached()
    }

    var cacheDirectory: String { supportDir.path }

    func loadCached() {
        if let cached = BootAssetInstaller.loadCached(from: supportDir) {
            assets = cached
            statusText = "已就绪 · Ventoy \(cached.version)"
        } else {
            assets = nil
            statusText = "尚未安装引导资源"
        }
    }

    func fetchLatestRelease() async throws -> ReleaseInfo {
        let (data, response) = try await URLSession.shared.data(from: URL(string: VentoySpec.latestReleaseAPI)!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AssetError.downloadFailed("GitHub API 返回异常")
        }
        let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        release = info
        return info
    }

    /// Downloads the official Linux release package, then installs it through
    /// the shared core pipeline (which verifies SHA256 against the API digest).
    func downloadLatest() async throws -> BootAssets {
        let info = try await fetchLatestRelease()
        guard let asset = info.linuxPackage,
              let url = URL(string: asset.browserDownloadURL) else {
            throw AssetError.noLinuxAsset
        }
        let package = supportDir.appendingPathComponent(asset.name)
        let temp = supportDir.appendingPathComponent(asset.name + ".part")

        isWorking = true
        progress = 0
        statusText = "正在下载 \(asset.name)…"
        defer { isWorking = false }

        do {
            try await Self.download(url, to: temp) { [weak self] fraction in
                Task { @MainActor in
                    self?.progress = fraction
                    self?.statusText = String(format: "下载中… %.1f%% (%.1f / %.1f MB)",
                                              fraction * 100,
                                              fraction * Double(asset.size) / 1_048_576,
                                              Double(asset.size) / 1_048_576)
                }
            }
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.moveItem(at: temp, to: package)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AssetError.downloadFailed(error.localizedDescription)
        }

        progress = 1.0
        return try await install(package: package, expectedSHA256: info.expectedSHA256)
    }

    /// Offline path: import an already downloaded `ventoy-*-linux.tar.gz`.
    func importPackage(_ url: URL) async throws -> BootAssets {
        guard url.lastPathComponent.contains(VentoySpec.releaseAssetSuffix) else {
            throw AssetImportError.invalidPackage
        }
        isWorking = true
        statusText = "正在校验并解包 \(url.lastPathComponent)…"
        progress = 0
        defer { isWorking = false }
        return try await install(package: url, expectedSHA256: nil)
    }

    private func install(package: URL, expectedSHA256: String?) async throws -> BootAssets {
        let dir = supportDir
        statusText = "正在校验 SHA256 并解包官方引导镜像…"
        let result = try await Task.detached(priority: .userInitiated) {
            try BootAssetInstaller.install(package: package,
                                           cacheDirectory: dir,
                                           expectedSHA256: expectedSHA256)
        }.value
        progress = 1.0
        assets = result
        statusText = "已就绪 · Ventoy \(result.version)"
        return result
    }

    private static func download(_ url: URL,
                                 to destination: URL,
                                 onProgress: @escaping (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel() }
        try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress: (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }
}
