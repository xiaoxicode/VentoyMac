import Foundation
import CryptoKit

// MARK: - What Ventoy's UEFI Secure Boot support actually is
//
// Transcribed from ventoy/Ventoy @ v1.1.18:
//   SecureBoot.md              (why a shim is needed)
//   INSTALL/ventoy_pack.sh     (which files land in the 32 MiB VTOYEFI image)
//   INSTALL/EFI/BOOT/*         (shim, MokManager, loaders)
//
// Ventoy's grub is GPL, so it cannot be signed by the UEFI CA. Ventoy therefore
// borrows Rocky Linux's Microsoft-signed shim:
//
//   firmware db (Microsoft UEFI CA 2011/2023)
//     └─ VTOYEFI/EFI/BOOT/BOOTX64.EFI   Rocky shim, MS-signed
//          └─ Ventoy loader             signed with **Ventoy's own key**
//               └─ grubx64_real.efi     Ventoy-signed grub
//
// The second hop is signed with a key that is NOT in the firmware db, so shim
// MUST stop on the first boot of every new machine and hand over to MokManager
// ("Verification failed: (0x1a) Security Violation" → blue enrollment screen).
// After `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` is enrolled once, that machine
// trusts Ventoy's key for good — no firmware/BIOS change, and no repeat prompt
// for any later Ventoy stick carrying the same key.
//
// Consequences that drive this file's design:
//   * No stick-side option can remove that one enrollment: the trust anchor
//     lives in the target firmware, not on the USB device. This is the whole
//     point of Secure Boot.
//   * What the installer CAN do is make the one-time step unavoidable-but-easy
//     and guarantee it never repeats: ship the enrollment certificate on the
//     data partition, verify the shim/MokManager chain is intact (a truncated
//     or partially written VTOYEFI is the one failure that turns 0x1a into a
//     dead end), and record the certificate fingerprint so a re-made stick is
//     provably the same trust target.
//   * The only zero-touch path is putting Ventoy's certificate into the
//     machine's db once (firmware "Enroll key", or IT-preprovisioned firmware).
//     `SecureBootInspection.certificateSHA256` is what an admin pins there.

/// Ventoy's documented global control plugin values for `VTOY_SECURE_BOOT_POLICY`.
public enum SecureBootPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Policy 1 (Ventoy default, value 0 / key absent): the enrolled Ventoy
    /// key is used to bypass verification, so every EFI payload boots. All
    /// Ventoy features (grub2boot, insmod, ...) keep working.
    case bypass
    /// Policy 2 (value 1): keep following the firmware's Secure Boot policy for
    /// every payload. Only UEFI-CA-signed EFI files boot; some Ventoy features
    /// are disabled. This is the "compliant" mode.
    case strict

    public var id: String { rawValue }

    public var pluginValue: String { self == .strict ? "1" : "0" }

    public var title: String {
        switch self {
        case .bypass: return "完全绕过验证（Ventoy 默认）"
        case .strict: return "遵循固件 Secure Boot 策略（严格）"
        }
    }

    public var detail: String {
        switch self {
        case .bypass:
            return "注册 Ventoy 密钥后，Ventoy 用它跳过对镜像的签名检查，所有功能可用。风险：Secure Boot 实际被绕过。"
        case .strict:
            return "每个 EFI 负载仍按固件策略校验，只能启动 UEFI CA 签名的镜像；grub2boot / insmod 等功能受限。"
        }
    }
}

/// The Secure Boot half of an install plan.
public struct SecureBootOptions: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var policy: SecureBootPolicy

    public init(enabled: Bool = false, policy: SecureBootPolicy = .bypass) {
        self.enabled = enabled
        self.policy = policy
    }
}

// MARK: - On-disk paths

public enum SecureBootSpec {
    /// Enrollment certificate, stored in the root of the VTOYEFI partition.
    public static let certificateName = "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"

    /// First stage: the Microsoft-signed shim (x64 / ia32 fallback).
    public static let shimNames = ["BOOTX64.EFI", "BOOTIA32.EFI"]

    /// MokManager. Without it a shim mismatch becomes an unrecoverable
    /// "0x1a Security Violation" stop instead of an enrollment screen.
    public static let mokManagerNames = ["mmx64.efi", "mmia32.efi"]

    /// Ventoy-signed second stages (informational; names differ between the
    /// x64 and ia32 chains and between release branches).
    public static let loaderNames = ["grubx64.efi", "grubx64_real.efi", "fbx64.efi",
                                     "grubia32.efi", "grubia32_real.efi", "fbia32.efi"]

    /// Directory created on the exFAT data partition with the enrollment
    /// material, reachable from MokManager's "Enroll key from disk" browser
    /// without digging into the 32 MiB VTOYEFI partition.
    public static let dataDirectory = "SecureBoot"
    /// ASCII-only on purpose: the file is also read from firmware-side file
    /// browsers (MokManager / Grub), which are happiest with 8.3-safe names.
    public static let readmeName = "SECURE-BOOT-README.txt"

    /// Ventoy global control plugin (data partition, relative path).
    public static let pluginPath = "ventoy/ventoy.json"
}

// MARK: - Inspection

public struct SecureBootInspection: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// shim + MokManager + certificate are all present.
        case complete
        /// At least one essential piece is missing: enrollment would dead-end.
        case incomplete
        /// The image could not be parsed. Never blocks: the generated script
        /// performs the authoritative check after writing.
        case unavailable(String)
    }

    public let status: Status
    public let found: [String]
    public let missing: [String]
    public let certificateSize: Int?
    public let certificateSHA256: String?

    public init(status: Status,
                found: [String] = [],
                missing: [String] = [],
                certificateSize: Int? = nil,
                certificateSHA256: String? = nil) {
        self.status = status
        self.found = found
        self.missing = missing
        self.certificateSize = certificateSize
        self.certificateSHA256 = certificateSHA256
    }

    public var isComplete: Bool { status == .complete }

    /// True when the certificate fingerprint can be pinned into a firmware db.
    public var isPinnable: Bool { certificateSHA256 != nil }

    public var summary: String {
        switch status {
        case .complete:
            return "Secure Boot 组件齐全（shim + MokManager + 证书）"
        case .incomplete:
            return "Secure Boot 组件缺失：\(missing.joined(separator: "、"))"
        case .unavailable(let reason):
            return "无法解析 VTOYEFI 镜像：\(reason)"
        }
    }

    /// Short fingerprint form used in logs and UI (`AB12 CD34 …`).
    public var fingerprintDisplay: String {
        guard let hash = certificateSHA256, hash.count >= 16 else { return "—" }
        let head = String(hash.prefix(16)).uppercased()
        var grouped: [String] = []
        var index = head.startIndex
        while index < head.endIndex {
            let next = head.index(index, offsetBy: 4, limitedBy: head.endIndex) ?? head.endIndex
            grouped.append(String(head[index..<next]))
            index = next
        }
        return grouped.joined(separator: " ") + " …"
    }
}

/// Reads the Secure Boot chain out of a `ventoy.disk.img` without mounting it.
public enum SecureBootInspector {

    public static func inspect(efiImage: URL) throws -> SecureBootInspection {
        let data = try Data(contentsOf: efiImage, options: .mappedIfSafe)
        return inspect(imageData: data)
    }

    public static func inspect(imageData: Data) -> SecureBootInspection {
        let volume: FAT16Volume
        do {
            volume = try FAT16Volume(data: imageData)
        } catch {
            return SecureBootInspection(status: .unavailable(error.localizedDescription))
        }

        var found: [String] = []
        var missing: [String] = []

        // 1. shim — the only Microsoft-signed link, without it firmware stops
        //    before any of Ventoy's code runs.
        let shim = firstPresent(SecureBootSpec.shimNames, in: "EFI/BOOT", volume: volume)
        if let shim { found.append("shim \(shim)") } else {
            missing.append("EFI/BOOT/BOOTX64.EFI（shim）")
        }

        // 2. MokManager — needed to enroll the Ventoy key on first boot.
        let mok = firstPresent(SecureBootSpec.mokManagerNames, in: "EFI/BOOT", volume: volume)
        if let mok { found.append("MokManager \(mok)") } else {
            missing.append("EFI/BOOT/mmx64.efi（MokManager）")
        }

        // 3. The enrollment certificate.
        var certificateSize: Int?
        var certificateSHA256: String?
        do {
            if let entry = try volume.entry(at: SecureBootSpec.certificateName) {
                let bytes = try volume.data(of: entry)
                certificateSize = bytes.count
                certificateSHA256 = SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }
                    .joined()
                found.append("证书 \(entry.name)（\(bytes.count) 字节）")
            } else {
                missing.append(SecureBootSpec.certificateName)
            }
        } catch {
            missing.append("\(SecureBootSpec.certificateName)（读取失败：\(error.localizedDescription)）")
        }

        // 4. Informational: which Ventoy-signed loaders are present.
        for name in SecureBootSpec.loaderNames {
            if (try? volume.file(named: name, in: "EFI/BOOT")) != nil {
                found.append("loader \(name)")
            }
        }

        return SecureBootInspection(status: missing.isEmpty ? .complete : .incomplete,
                                    found: found,
                                    missing: missing,
                                    certificateSize: certificateSize,
                                    certificateSHA256: certificateSHA256)
    }

    private static func firstPresent(_ names: [String],
                                     in directory: String,
                                     volume: FAT16Volume) -> String? {
        for name in names where (try? volume.file(named: name, in: directory)) != nil {
            return name
        }
        return nil
    }
}
