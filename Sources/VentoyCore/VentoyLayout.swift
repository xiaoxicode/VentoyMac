import Foundation

// MARK: - Official Ventoy on-disk constants
//
// Transcribed from ventoy/Ventoy @ v1.1.18
//   INSTALL/tool/ventoy_lib.sh        (VENTOY_SECTOR_NUM / format_ventoy_disk_gpt)
//   INSTALL/tool/VentoyWorker.sh      (dd offsets for GPT installs)
//   INSTALL/ventoy_pack.sh            (boot.img / core.img.xz / ventoy.disk.img.xz)
//
// Keeping these in one place is what makes a macOS re-implementation produce a
// byte-compatible disk with the official Windows/Linux installers.

public enum VentoySpec {
    /// Logical sector size assumed by Ventoy (512n/512e devices only).
    public static let sectorSize: UInt64 = 512

    /// VTOYEFI partition: 32 MiB = 65_536 sectors.
    public static let efiSectors: UInt64 = 65_536
    public static let efiBytes: UInt64 = 33_554_432

    /// Partition 1 starts at 1 MiB; LBA 34...2047 holds the legacy BIOS boot code.
    public static let firstDataSector: UInt64 = 2_048

    /// Legacy BIOS GRUB core image (`boot/core.img.xz`) occupies 2_047 sectors
    /// on disk (1 MiB). In GPT mode Ventoy writes only the first 2_014 sectors
    /// starting at LBA 34; in MBR mode it writes all 2_047 starting at LBA 1.
    /// The *packaged* image is the full 2_047 sectors, so validation must use
    /// that upper bound rather than the GPT write count.
    public static let coreImageStartSector: UInt64 = 34
    public static let coreImageSectorCount: UInt64 = 2_014
    public static let coreImagePackagedSectors: UInt64 = 2_047
    public static var coreImagePackagedBytes: UInt64 { coreImagePackagedSectors * sectorSize }

    /// Partition 2 must be 4 KiB aligned (8 x 512-byte sectors).
    public static let alignmentSectors: UInt64 = 8

    /// Primary GPT (1 header + 32 table sectors) and the mirrored tail.
    public static let gptReservedTailSectors: UInt64 = 34

    /// MBR bootstrap area written from boot.img (does not touch the MBR entries).
    public static let mbrBootstrapBytes: UInt64 = 446

    /// Two single-byte GPT mode markers patched into the BIOS boot code.
    public static let gptFlag1Offset: UInt64 = 92
    public static let gptFlag1Byte: UInt8 = 0x22
    public static let gptFlag2Offset: UInt64 = 17_908
    public static let gptFlag2Byte: UInt8 = 0x23

    /// Ventoy disk UUID and MBR disk signature locations.
    public static let diskUUIDOffset: UInt64 = 384
    public static let diskUUIDLength: UInt64 = 16
    public static let diskSignatureOffset: UInt64 = 440
    public static let diskSignatureLength: UInt64 = 4

    public static let basicDataGUID = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
    public static let efiSystemGUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    public static let defaultVolumeLabel = "Ventoy"
    public static let efiVolumeLabel = "VTOYEFI"
    public static let isoDirectoryName = "ISO"

    /// Official release endpoint used to obtain the bootloader images.
    public static let latestReleaseAPI = "https://api.github.com/repos/ventoy/Ventoy/releases/latest"
    public static let releaseAssetSuffix = "-linux.tar.gz"
}

// MARK: - Computed GPT layout

public struct VentoyLayout: Equatable, Sendable {
    public let totalBytes: UInt64
    public let totalSectors: UInt64
    public let reservedMiB: UInt64

    /// Partition 1 ("Ventoy"): exFAT, holds the ISO files.
    public let part1Start: UInt64
    public let part1End: UInt64
    public let part1Sectors: UInt64

    /// Partition 2 ("VTOYEFI"): 32 MiB FAT16 image, holds GRUB2 + EFI binaries.
    public let part2Start: UInt64
    public let part2End: UInt64
    public let part2Sectors: UInt64

    /// `mkexfatfs -s` equivalent: 128 KiB clusters above 32 GiB, else 32 KiB.
    public var exFATClusterSectors: UInt64 {
        totalBytes > 32 * 1_024 * 1_024 * 1_024 ? 256 : 64
    }

    public var part1Bytes: UInt64 { part1Sectors * VentoySpec.sectorSize }

    public var summaryLines: [String] {
        [
            "分区 1  Ventoy (exFAT)   LBA \(part1Start) ... \(part1End)  (\(part1Sectors) 扇区 / \(Self.human(part1Bytes)))",
            "分区 2  VTOYEFI (FAT16)  LBA \(part2Start) ... \(part2End)  (\(part2Sectors) 扇区 / 32 MiB)",
            "保留空间  \(reservedMiB) MiB    exFAT 簇  \(exFATClusterSectors * VentoySpec.sectorSize / 1_024) KiB"
        ]
    }

    private static func human(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GiB", gb)
    }
}

public enum VentoyLayoutError: Error, LocalizedError, Equatable {
    case diskTooSmall(minimumBytes: UInt64)
    case sectorSizeMismatch
    case arithmeticOverflow
    case invalidReservedSpace

    public var errorDescription: String? {
        switch self {
        case .diskTooSmall(let minimum):
            return "磁盘容量不足，Ventoy 至少需要 \(minimum / 1_048_576) MiB 可用空间。"
        case .sectorSizeMismatch:
            return "Ventoy 仅支持 512 字节逻辑扇区的设备，不支持 4Kn 原生设备。"
        case .arithmeticOverflow:
            return "计算分区布局时发生整数溢出。"
        case .invalidReservedSpace:
            return "保留空间超过磁盘可用容量。"
        }
    }
}

public enum VentoyLayoutCalculator {

    /// Faithful Swift port of `format_ventoy_disk_gpt()` in `INSTALL/tool/ventoy_lib.sh`.
    ///
    /// Official shell logic:
    ///   reserve_sector_num = reserved_mb * 2048 + 33
    ///   part1_end   = sector_num - reserve_sector_num - 65536 - 1
    ///   part2_start = part1_end + 1
    ///   if part2_start % 8 != 0: part1_end -= mod; part2_start = part1_end + 1
    ///   part2_end   = part2_start + 65536 - 1
    public static func gpt(
        totalBytes: UInt64,
        deviceSectorSize: UInt64 = VentoySpec.sectorSize,
        reservedMiB: UInt64 = 0
    ) throws -> VentoyLayout {
        guard deviceSectorSize == VentoySpec.sectorSize else {
            throw VentoyLayoutError.sectorSizeMismatch
        }

        let sectorSize = VentoySpec.sectorSize
        let totalSectors = totalBytes / sectorSize

        let minimumSectors = VentoySpec.firstDataSector
            + VentoySpec.efiSectors
            + VentoySpec.gptReservedTailSectors
            + 2_048
        guard totalBytes >= minimumSectors * sectorSize else {
            throw VentoyLayoutError.diskTooSmall(minimumBytes: minimumSectors * sectorSize)
        }

        let (reserveScaled, overflow1) = reservedMiB.multipliedReportingOverflow(by: 2_048)
        guard !overflow1 else { throw VentoyLayoutError.arithmeticOverflow }
        let (reserveSectors, overflow2) = reserveScaled.addingReportingOverflow(33)
        guard !overflow2 else { throw VentoyLayoutError.arithmeticOverflow }

        let tail = reserveSectors + VentoySpec.efiSectors + 1
        guard totalSectors > VentoySpec.firstDataSector + tail else {
            throw VentoyLayoutError.invalidReservedSpace
        }

        var part1End = totalSectors - tail
        var part2Start = part1End + 1

        let remainder = part2Start % VentoySpec.alignmentSectors
        if remainder > 0 {
            part1End -= remainder
            part2Start = part1End + 1
        }

        let part2End = part2Start + VentoySpec.efiSectors - 1
        guard part2End + VentoySpec.gptReservedTailSectors <= totalSectors else {
            throw VentoyLayoutError.invalidReservedSpace
        }

        let part1Start = VentoySpec.firstDataSector
        let part1Sectors = part1End - part1Start + 1

        return VentoyLayout(
            totalBytes: totalBytes,
            totalSectors: totalSectors,
            reservedMiB: reservedMiB,
            part1Start: part1Start,
            part1End: part1End,
            part1Sectors: part1Sectors,
            part2Start: part2Start,
            part2End: part2End,
            part2Sectors: VentoySpec.efiSectors
        )
    }
}
