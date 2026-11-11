import Foundation

/// A build stamp that travels with the binary, the generated install script,
/// the GUI log and the .app bundle.
///
/// Why this exists: macOS keeps a running Mach-O mapped even after the .app on
/// disk is replaced. A user who rebuilt VentoyMac but kept the old window open
/// keeps executing the OLD install script, and the resulting error log looks
/// identical to a fresh failure. Printing the stamp at the top of every log
/// makes a pasted error unambiguous; `BuildID.txt` in the bundle lets a running
/// app detect that it is stale and ask to be restarted.
public enum VentoyBuild {
    /// Bump on every .app rebuild that changes behaviour.
    public static let id = "2026.11.11-b9"

    /// Bump only when the generated Bash script changes.
    /// r3 = all raw-device writes are 512-byte sector aligned (fixes EINVAL).
    /// r4 = real-uid bootstrap + `gpt` capability preflight (later proven wrong).
    /// r5 = remove ALL `gpt` write subcommands: SIP/rootless blocks them
    ///      unconditionally. Partition map now comes from `diskutil
    ///      partitionDisk` with explicit GUIDs and exact sector counts; the
    ///      real VTOYEFI LBA is read back at runtime with `diskutil info -plist`.
    /// r6 = `partitionDisk -noEFI` + 4 entries (leading `Free Space` gap of
    ///      part1Start sectors, trailing `Free Space ... R`). On disks larger
    ///      than ~200 MiB diskutil silently inserts a 200 MiB EFI partition,
    ///      which caused `Error: -5344: MediaKit reports not enough space` on
    ///      the real 8 GB USB stick. `-noEFI` also moves the first partition
    ///      to LBA 40; the leading gap restores the official LBA 2048. Step 5
    ///      now asserts partition 1's real offset so core.img cannot overlap
    ///      the data partition.
    /// r7 = Secure Boot support: verify shim / MokManager / enrollment
    ///      certificate inside the freshly written VTOYEFI partition (read-only
    ///      mount, so macOS metadata does not pollute the boot partition),
    ///      pin the certificate SHA-256 computed before the write, and stage
    ///      the enrollment material + Chinese instructions on the data
    ///      partition (`SecureBoot/`), optionally writing
    ///      `ventoy/ventoy.json` with VTOY_SECURE_BOOT_POLICY.
    public static let scriptRevision = 7

    public static var banner: String {
        "VentoyMac 构建 \(id) · 安装脚本 r\(scriptRevision)"
    }

    /// Compares the id compiled into this process with the id of the .app that
    /// is currently on disk. A mismatch means the bundle was rebuilt while this
    /// process was running, i.e. the window is executing obsolete code.
    public static func isStaleAgainstBundle(_ bundle: Bundle = .main) -> Bool {
        guard let url = bundle.url(forResource: "BuildID", withExtension: "txt"),
              let onDisk = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !onDisk.isEmpty else {
            // Running from `swift run` / a bare executable: no bundle marker,
            // so there is nothing to compare and no stale state to report.
            return false
        }
        return onDisk != id
    }
}
