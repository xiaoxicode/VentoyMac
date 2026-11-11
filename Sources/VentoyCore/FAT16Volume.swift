import Foundation

/// Read-only FAT16 reader — just enough to inspect the official 32 MiB
/// `ventoy/ventoy.disk.img` (the VTOYEFI partition) **before** it is written
/// to a USB stick.
///
/// Why a hand-written parser instead of `hdiutil attach`:
/// attaching the image creates a `/dev/diskN` node, which would immediately
/// show up in this app's own external-disk list — the destructive target
/// selector. Parsing the image in memory keeps the Secure Boot probe free of
/// side effects, works before a disk is even selected, and is unit-testable.
///
/// The parser only supports what Ventoy actually ships
/// (`mkfs.vfat -F 16 -n VTOYEFI -s 1`: 512-byte sectors, 1 sector/cluster,
/// 512 root entries). Anything else fails loudly rather than mis-parsing.
public struct FAT16Volume: Sendable {

    public enum ParseError: Error, LocalizedError, Equatable {
        case truncated
        case invalidBootSector(String)
        case unsupportedClusterCount(UInt64)
        case corruption(String)

        public var errorDescription: String? {
            switch self {
            case .truncated:
                return "镜像不足一个扇区，无法解析 FAT16。"
            case .invalidBootSector(let detail):
                return "FAT16 引导扇区异常：\(detail)"
            case .unsupportedClusterCount(let count):
                return "不是 FAT16 文件系统（簇数量 \(count)）。"
            case .corruption(let detail):
                return "FAT16 结构损坏：\(detail)"
            }
        }
    }

    /// One directory entry, with any long-file-name fragments already applied.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let startCluster: UInt32
        public let size: UInt32

        public init(name: String, isDirectory: Bool, startCluster: UInt32, size: UInt32) {
            self.name = name
            self.isDirectory = isDirectory
            self.startCluster = startCluster
            self.size = size
        }
    }

    private let bytes: [UInt8]

    public let bytesPerSector: Int
    public let sectorsPerCluster: Int
    public let clusterCount: Int

    private let fatOffset: Int
    private let rootOffset: Int
    private let rootEntryCount: Int
    private let dataOffset: Int

    public var clusterSize: Int { bytesPerSector * sectorsPerCluster }

    public init(data: Data) throws {
        guard data.count >= 512 else { throw ParseError.truncated }
        // A copy is unavoidable for O(1) indexing; 32 MiB for the official
        // image, freed as soon as the inspection finishes.
        let raw = [UInt8](data)

        func u16(_ offset: Int) -> Int {
            Int(raw[offset]) | Int(raw[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            Int(raw[offset]) | Int(raw[offset + 1]) << 8
                | Int(raw[offset + 2]) << 16 | Int(raw[offset + 3]) << 24
        }

        let bps = u16(11)
        let spc = Int(raw[13])
        let reserved = u16(14)
        let fatCount = Int(raw[16])
        let rootEntries = u16(17)
        let totalSectors16 = u16(19)
        let fatSize = u16(22)
        let totalSectors32 = u32(32)

        guard [512, 1024, 2048, 4096].contains(bps) else {
            throw ParseError.invalidBootSector("每扇区字节数 \(bps) 非法")
        }
        guard spc > 0, spc & (spc - 1) == 0 else {
            throw ParseError.invalidBootSector("每簇扇区数 \(spc) 非法")
        }
        guard reserved > 0, fatCount > 0, fatSize > 0, rootEntries > 0 else {
            throw ParseError.invalidBootSector("保留扇区/ FAT 数量 / 根目录项数异常")
        }

        let totalSectors = totalSectors16 != 0 ? totalSectors16 : totalSectors32
        guard totalSectors > 0 else { throw ParseError.invalidBootSector("总扇区数为 0") }

        let rootDirSectors = (rootEntries * 32 + bps - 1) / bps
        let firstDataSector = reserved + fatCount * fatSize + rootDirSectors
        guard totalSectors > firstDataSector else {
            throw ParseError.invalidBootSector("数据区起点 \(firstDataSector) 超过总扇区数 \(totalSectors)")
        }
        let clusters = (totalSectors - firstDataSector) / spc
        // FAT16 cluster range per the Microsoft FAT specification.
        guard clusters >= 4_085, clusters < 65_525 else {
            throw ParseError.unsupportedClusterCount(UInt64(clusters))
        }

        let fatOff = reserved * bps
        let rootOff = (reserved + fatCount * fatSize) * bps
        let dataOff = rootOff + rootDirSectors * bps
        guard dataOff <= raw.count else {
            throw ParseError.invalidBootSector("数据区偏移 \(dataOff) 超出镜像长度 \(raw.count)")
        }

        self.bytes = raw
        self.bytesPerSector = bps
        self.sectorsPerCluster = spc
        self.clusterCount = clusters
        self.fatOffset = fatOff
        self.rootOffset = rootOff
        self.rootEntryCount = rootEntries
        self.dataOffset = dataOff
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - Public lookup

    /// Resolves `path` (forward slashes, case-insensitive, no leading slash
    /// required) to a directory entry.
    public func entry(at path: String) throws -> Entry? {
        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty else { return nil }

        var atRoot = true
        var cluster: UInt32 = 0

        for (index, component) in components.enumerated() {
            let listing = atRoot ? try rootDirectory() : try directory(startCluster: cluster)
            guard let match = listing.first(where: { $0.name.caseInsensitiveCompare(component) == .orderedSame }) else {
                return nil
            }
            if index == components.count - 1 { return match }
            guard match.isDirectory else { return nil }
            atRoot = false
            cluster = match.startCluster
        }
        return nil
    }

    public func exists(_ path: String) throws -> Bool {
        try entry(at: path) != nil
    }

    /// Resolves `path` inside `directory`, returning the matching entry only if
    /// it is a regular file. Handy for "find this file under EFI/BOOT".
    public func file(named name: String, `in` path: String) throws -> Entry? {
        let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var listing: [Entry]
        if components.isEmpty {
            listing = try rootDirectory()
        } else if let dirEntry = try entry(at: path), dirEntry.isDirectory {
            listing = try self.directory(startCluster: dirEntry.startCluster)
        } else {
            return nil
        }
        return listing.first {
            !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    public func data(of entry: Entry) throws -> Data {
        var collected: [UInt8] = []
        collected.reserveCapacity(Int(entry.size))
        for cluster in try clusterChain(from: entry.startCluster) {
            let offset = dataOffset + (Int(cluster) - 2) * clusterSize
            let end = min(offset + clusterSize, bytes.count)
            guard offset < end else { break }
            collected.append(contentsOf: bytes[offset..<end])
            if collected.count >= Int(entry.size) { break }
        }
        guard collected.count >= Int(entry.size) else {
            throw ParseError.corruption("文件 \(entry.name) 的簇链短于声明的 \(entry.size) 字节")
        }
        return Data(collected.prefix(Int(entry.size)))
    }

    public func data(at path: String) throws -> Data? {
        guard let entry = try entry(at: path), !entry.isDirectory else { return nil }
        return try data(of: entry)
    }

    // MARK: - Directory walking

    private func rootDirectory() throws -> [Entry] {
        let length = rootEntryCount * 32
        guard rootOffset + length <= bytes.count else {
            throw ParseError.corruption("根目录超出镜像长度")
        }
        return parseEntries(bytes[rootOffset..<(rootOffset + length)])
    }

    private func directory(startCluster: UInt32) throws -> [Entry] {
        var region: [UInt8] = []
        for cluster in try clusterChain(from: startCluster) {
            let offset = dataOffset + (Int(cluster) - 2) * clusterSize
            let end = min(offset + clusterSize, bytes.count)
            guard offset < end else { break }
            region.append(contentsOf: bytes[offset..<end])
        }
        return parseEntries(region[...])
    }

    private func clusterChain(from start: UInt32) throws -> [UInt32] {
        guard start >= 2 else { return [] }
        var chain: [UInt32] = []
        var current = start
        var steps = 0
        while current >= 2, Int(current) < clusterCount + 2 {
            chain.append(current)
            let offset = fatOffset + Int(current) * 2
            guard offset + 2 <= bytes.count else {
                throw ParseError.corruption("FAT 表越界（簇 \(current)）")
            }
            let next = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            if next >= 0xFFF8 { break }
            if next == 0xFFF7 { throw ParseError.corruption("簇 \(current) 被标记为坏簇") }
            current = next
            steps += 1
            if steps > clusterCount { throw ParseError.corruption("簇链成环") }
        }
        return chain
    }

    private func parseEntries(_ region: ArraySlice<UInt8>) -> [Entry] {
        var result: [Entry] = []
        var longName: [UInt16] = []
        var hasLongName = false

        let buffer = Array(region)
        var index = 0
        while index + 32 <= buffer.count {
            let first = buffer[index]
            if first == 0x00 { break }                 // end of directory
            if first == 0xE5 {                          // deleted entry
                longName = []
                hasLongName = false
                index += 32
                continue
            }

            let attributes = buffer[index + 11]

            // 0x0F marks a long-file-name fragment: 13 UTF-16 units spread over
            // three runs inside the 32-byte entry.
            if attributes & 0x3F == 0x0F {
                let sequence = Int(first & 0x1F)
                if first & 0x40 != 0 {                  // last (first in on-disk order)
                    longName = Array(repeating: 0, count: 20 * 13)
                    hasLongName = true
                }
                let base = max(sequence - 1, 0) * 13
                let slots = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
                if hasLongName, base + 13 <= longName.count {
                    for (position, offset) in slots.enumerated() {
                        longName[base + position] = UInt16(buffer[index + offset])
                            | UInt16(buffer[index + offset + 1]) << 8
                    }
                }
                index += 32
                continue
            }

            if attributes & 0x08 != 0 {                 // volume label
                longName = []
                hasLongName = false
                index += 32
                continue
            }

            let name: String
            if hasLongName {
                var units: [UInt16] = []
                for unit in longName {
                    if unit == 0x0000 || unit == 0xFFFF { break }
                    units.append(unit)
                }
                name = String(decoding: units, as: UTF16.self)
                longName = []
                hasLongName = false
            } else {
                name = Self.shortName(buffer, at: index)
            }

            let isDot = name == "." || name == ".."
            if !isDot, !name.isEmpty {
                let high = UInt32(buffer[index + 20]) | UInt32(buffer[index + 21]) << 8
                let low = UInt32(buffer[index + 26]) | UInt32(buffer[index + 27]) << 8
                let size = UInt32(buffer[index + 28])
                    | UInt32(buffer[index + 29]) << 8
                    | UInt32(buffer[index + 30]) << 16
                    | UInt32(buffer[index + 31]) << 24
                result.append(Entry(name: name,
                                    isDirectory: attributes & 0x10 != 0,
                                    startCluster: high << 16 | low,
                                    size: size))
            }
            index += 32
        }
        return result
    }

    private static func shortName(_ buffer: [UInt8], at index: Int) -> String {
        func trimmed(_ range: Range<Int>) -> String {
            var slice = Array(buffer[(index + range.lowerBound)..<(index + range.upperBound)])
            // 0x05 in the first byte stands for a real 0xE5 (Kanji lead byte).
            if range.lowerBound == 0, slice.first == 0x05 { slice[0] = 0xE5 }
            var text = String(decoding: slice, as: UTF8.self)
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
        let base = trimmed(0..<8)
        let ext = trimmed(8..<11)
        return ext.isEmpty ? base : base + "." + ext
    }
}
