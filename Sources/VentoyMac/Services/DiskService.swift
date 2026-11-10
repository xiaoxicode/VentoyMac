import Foundation
import VentoyCore

enum DiskServiceError: Error, LocalizedError {
    case diskutilFailed(String)
    case deviceChanged(String)

    var errorDescription: String? {
        switch self {
        case .diskutilFailed(let message): return "diskutil 执行失败：\(message)"
        case .deviceChanged(let message): return "目标磁盘状态已变化，为安全起见已中止：\(message)"
        }
    }
}

enum DiskService {

    /// Enumerates only *external whole disks*. Internal/system disks are never
    /// even returned as selectable targets.
    static func externalDisks() async throws -> [DiskDevice] {
        let list = try await ProcessRunner.run("/usr/sbin/diskutil",
                                               ["list", "-plist", "external"])
        guard list.status == 0 else {
            throw DiskServiceError.diskutilFailed(list.stderr)
        }

        let names = try DiskPlistParser.externalWholeDiskNames(list.stdout)
        var devices: [DiskDevice] = []
        for name in names {
            let info = try await ProcessRunner.run("/usr/sbin/diskutil",
                                                   ["info", "-plist", name])
            guard info.status == 0 else { continue }
            let volumes = DiskPlistParser.volumeNames(for: name, in: list.stdout)
            if let device = try? DiskPlistParser.device(from: info.stdout, volumeNames: volumes),
               device.isWholeDisk {
                devices.append(device)
            }
        }
        return devices.sorted { lhs, rhs in
            (Int(lhs.bsdName.dropFirst(4)) ?? 0) < (Int(rhs.bsdName.dropFirst(4)) ?? 0)
        }
    }

    /// Re-reads the device immediately before a destructive operation so a
    /// hot-plugged/re-enumerated disk cannot accidentally be targeted.
    static func revalidate(_ expected: DiskDevice) async throws {
        let info = try await ProcessRunner.run("/usr/sbin/diskutil",
                                               ["info", "-plist", expected.bsdName])
        guard info.status == 0,
              let current = try? DiskPlistParser.device(from: info.stdout) else {
            throw DiskServiceError.deviceChanged("\(expected.bsdName) 已不存在")
        }
        guard current.isEligible else {
            throw DiskServiceError.deviceChanged(current.rejectionReasons.joined(separator: "、"))
        }
        guard current.totalBytes == expected.totalBytes else {
            throw DiskServiceError.deviceChanged("设备容量发生变化，可能已被更换")
        }
    }
}
