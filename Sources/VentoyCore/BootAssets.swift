import Foundation

/// Cached, verified copy of Ventoy's official bootloader images.
///
/// Extracted from `ventoy-<version>-linux.tar.gz`:
///   boot/boot.img                 (512 B MBR bootstrap)
///   boot/core.img.xz           -> core.img        (legacy BIOS GRUB core, decompressed)
///   ventoy/ventoy.disk.img.xz  -> ventoy.disk.img (32 MiB VTOYEFI FAT16 filesystem)
///   ventoy/version
public struct BootAssets: Codable, Hashable, Sendable {
    public let version: String
    public let directory: String
    public let sourceSHA256: String?
    public let sourceFileName: String?
    public let importedAt: Date

    public init(version: String,
                directory: String,
                sourceSHA256: String? = nil,
                sourceFileName: String? = nil,
                importedAt: Date = Date()) {
        self.version = version
        self.directory = directory
        self.sourceSHA256 = sourceSHA256
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
    }

    public var bootImage: String { URL(fileURLWithPath: directory).appendingPathComponent("boot.img").path }
    public var coreImage: String { URL(fileURLWithPath: directory).appendingPathComponent("core.img").path }
    public var efiImage: String { URL(fileURLWithPath: directory).appendingPathComponent("ventoy.disk.img").path }

    public var requiredFiles: [String] { [bootImage, coreImage, efiImage] }

    public var missingFiles: [String] {
        requiredFiles.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    public var isComplete: Bool { missingFiles.isEmpty }

    /// Basic size/structure sanity checks against the official packaging script.
    public var validationIssues: [String] {
        var issues = missingFiles.map { "缺少文件：\($0)" }
        if isComplete {
            if let size = fileSize(bootImage), size != 512 {
                issues.append("boot.img 大小异常：\(size) 字节（应为 512）")
            }
            if let size = fileSize(efiImage), size != Int64(VentoySpec.efiBytes) {
                issues.append("ventoy.disk.img 大小异常：\(size) 字节（应为 \(VentoySpec.efiBytes)）")
            }
            if let size = fileSize(coreImage) {
                // The official core.img is 2047 sectors (1 MiB); GPT installs
                // consume only the first 2014. Reject anything outside that
                // range so a truncated or wrong-version image cannot be used.
                let minimum = Int64(VentoySpec.coreImageSectorCount * VentoySpec.sectorSize)
                let maximum = Int64(VentoySpec.coreImagePackagedBytes)
                if size < minimum {
                    issues.append("core.img 不足 \(VentoySpec.coreImageSectorCount) 扇区，可能损坏")
                } else if size > maximum {
                    issues.append("core.img 超过 \(VentoySpec.coreImagePackagedSectors) 扇区，可能损坏")
                }
            }
        }
        return issues
    }

    private func fileSize(_ path: String) -> Int64? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
              let n = attr[.size] as? NSNumber else { return nil }
        return n.int64Value
    }
}

public struct ReleaseInfo: Decodable, Sendable {
    public let tagName: String
    public let name: String
    public let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case assets
    }
}

public struct ReleaseAsset: Decodable, Sendable {
    public let name: String
    public let size: Int64
    public let browserDownloadURL: String
    public let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

public extension ReleaseInfo {
    var linuxPackage: ReleaseAsset? {
        assets.first { $0.name.hasSuffix(VentoySpec.releaseAssetSuffix) }
    }

    var expectedSHA256: String? {
        linuxPackage?.digest?.replacingOccurrences(of: "sha256:", with: "")
    }
}
