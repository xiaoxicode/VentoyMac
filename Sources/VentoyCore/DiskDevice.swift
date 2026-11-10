import Foundation

/// A whole physical disk as reported by `diskutil info -plist <disk>`.
public struct DiskDevice: Identifiable, Hashable, Sendable {
    public var id: String { bsdName }
    public let bsdName: String
    public let deviceNode: String
    public let mediaName: String
    public let busProtocol: String
    public let totalBytes: UInt64
    public let isWholeDisk: Bool
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isVirtual: Bool
    public let content: String
    public let volumeNames: [String]
    public let deviceBlockSize: UInt64

    public init(bsdName: String,
                deviceNode: String,
                mediaName: String,
                busProtocol: String,
                totalBytes: UInt64,
                isWholeDisk: Bool,
                isInternal: Bool,
                isRemovable: Bool,
                isEjectable: Bool,
                isVirtual: Bool,
                content: String,
                volumeNames: [String],
                deviceBlockSize: UInt64) {
        self.bsdName = bsdName
        self.deviceNode = deviceNode
        self.mediaName = mediaName
        self.busProtocol = busProtocol
        self.totalBytes = totalBytes
        self.isWholeDisk = isWholeDisk
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isVirtual = isVirtual
        self.content = content
        self.volumeNames = volumeNames
        self.deviceBlockSize = deviceBlockSize
    }

    public var isEligible: Bool {
        isWholeDisk && !isInternal && !isVirtual && (isRemovable || isEjectable)
    }

    /// Human readable reasons why a disk must never be offered as a target.
    public var rejectionReasons: [String] {
        var reasons: [String] = []
        if !isWholeDisk { reasons.append("不是整盘设备") }
        if isInternal { reasons.append("内置磁盘 / 系统盘") }
        if isVirtual { reasons.append("虚拟磁盘镜像") }
        if !isRemovable && !isEjectable { reasons.append("不可移除设备") }
        return reasons
    }

    public var displayName: String {
        let trimmed = mediaName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? bsdName : trimmed
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(totalBytes, UInt64(Int64.max))),
                                  countStyle: .decimal)
    }

    public var volumesDescription: String {
        volumeNames.isEmpty ? content : volumeNames.joined(separator: " / ")
    }

    public var rawDiskNode: String {
        "/dev/r" + bsdName
    }
}

public enum DiskPlistError: Error, LocalizedError {
    case invalidPlist
    case missingIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidPlist: return "diskutil 返回的 plist 无法解析。"
        case .missingIdentifier: return "diskutil 返回的 plist 缺少设备标识。"
        }
    }
}

/// Parses `diskutil list -plist external` and `diskutil info -plist diskN` output.
public enum DiskPlistParser {

    public static func externalWholeDiskNames(_ data: Data) throws -> [String] {
        let plist = try rootDictionary(data)
        if let whole = plist["WholeDisks"] as? [String], !whole.isEmpty {
            return whole.filter { $0.hasPrefix("disk") }
        }
        // Fallback: derive whole disks from AllDisksAndPartitions.
        guard let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        return all.compactMap { $0["DeviceIdentifier"] as? String }
            .filter { $0.hasPrefix("disk") }
    }

    public static func volumeNames(for bsdName: String, in listData: Data) -> [String] {
        guard let plist = try? rootDictionary(listData),
              let all = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        return all.first(where: { ($0["DeviceIdentifier"] as? String) == bsdName })
            .flatMap { $0["Partitions"] as? [[String: Any]] }?
            .compactMap { $0["VolumeName"] as? String } ?? []
    }

    public static func device(from infoData: Data, volumeNames: [String] = []) throws -> DiskDevice {
        let d = try rootDictionary(infoData)
        guard let name = d["DeviceIdentifier"] as? String else {
            throw DiskPlistError.missingIdentifier
        }
        func bool(_ key: String) -> Bool {
            if let b = d[key] as? Bool { return b }
            if let n = d[key] as? NSNumber { return n.boolValue }
            return false
        }
        func uint(_ key: String) -> UInt64 {
            if let n = d[key] as? NSNumber { return n.uint64Value }
            if let i = d[key] as? UInt64 { return i }
            if let s = d[key] as? String, let v = UInt64(s) { return v }
            return 0
        }
        func str(_ key: String) -> String { d[key] as? String ?? "" }

        let size = uint("TotalSize") != 0 ? uint("TotalSize") : uint("Size")
        let virtualOrPhysical = str("VirtualOrPhysical")

        return DiskDevice(
            bsdName: name,
            deviceNode: str("DeviceNode").isEmpty ? "/dev/" + name : str("DeviceNode"),
            mediaName: str("MediaName"),
            busProtocol: str("BusProtocol"),
            totalBytes: size,
            isWholeDisk: bool("WholeDisk"),
            isInternal: bool("Internal"),
            isRemovable: bool("RemovableMedia") || bool("Removable"),
            isEjectable: bool("Ejectable") || bool("RemovableMediaOrExternalDevice"),
            isVirtual: virtualOrPhysical.lowercased() == "virtual",
            content: str("Content"),
            volumeNames: volumeNames,
            deviceBlockSize: uint("DeviceBlockSize")
        )
    }

    private static func rootDictionary(_ data: Data) throws -> [String: Any] {
        guard let any = try? PropertyListSerialization.propertyList(from: data,
                                                                    options: [],
                                                                    format: nil),
              let dict = any as? [String: Any] else {
            throw DiskPlistError.invalidPlist
        }
        return dict
    }
}
