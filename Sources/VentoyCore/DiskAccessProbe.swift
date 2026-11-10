import Foundation

/// macOS raw-disk access helpers that let VentoyMac write disks without
/// Terminal.app being involved at all.
///
/// Background: `/bin/dd` has no `com.apple.private.security.disk-device-access`
/// entitlement, so a raw block-device write is allowed only when the
/// **TCC-responsible process** holds Full Disk Access. `/usr/sbin/gpt` is a
/// different case: it carries `com.apple.rootless.restricted-block-devices`,
/// which makes ALL of its write subcommands fail with
/// "operation not permitted: <cmd>" while SIP is enabled — regardless of
/// uid, FDA, or the target device (verified on a virtual disk and a regular
/// file). The partition map is therefore created by the entitled
/// `diskutil partitionDisk -noEFI`, while `dd` only writes boot images. Without
/// `-noEFI` diskutil silently prepends a 200 MiB EFI System Partition on disks
/// larger than ~200 MiB, which overflows the official Ventoy geometry and
/// fails with `Error: -5344: MediaKit reports not enough space`. Terminal
/// inherits its grant to `sudo dd`; for VentoyMac the app is signed with a
/// fixed designated requirement that is also applied to the in-bundle
/// `ventoymac-cli` writer helper, so the grant matches the root process that
/// actually spawns `dd`. If TCC instead attributes the script to
/// `security_authtrampoline`, that path must be added to Full Disk Access too.
public enum DiskAccessProbe {

    /// A ZERO-BYTE write-open probe plus an aligned 512-byte read on both the
    /// buffered and raw device nodes, followed by a `diskutil` channel check.
    /// Never modifies the disk. The aligned read matters because macOS
    /// `/dev/rdisk*` rejects non-sector-aligned I/O with EINVAL, which is a
    /// different failure from a TCC denial. Run through the exact same
    /// execution path as the real install to verify that path's TCC
    /// responsibility up front.
    public static func script(bsdName: String) -> String {
        let q = ShellQuote.bash
        let dev = "/dev/" + bsdName
        let raw = "/dev/r" + bsdName
        return """
        #!/bin/bash
        # VentoyMac 裸盘权限 + 分区通道自检（对磁盘写入 0 字节）
        set -u
        for node in \(q(dev)) \(q(raw)); do
          if [ ! -e "$node" ]; then
            echo "PROBE_MISSING: $node"
            exit 1
          fi
          if ! /bin/dd if=/dev/null of="$node" bs=512 count=0 conv=notrunc 2>/dev/null; then
            echo "PROBE_DENIED: $node"
            exit 1
          fi
          if ! /bin/dd if="$node" of=/dev/null bs=512 count=1 2>/dev/null; then
            echo "PROBE_UNALIGNED: $node"
            exit 1
          fi
          echo "PROBE_OK: $node"
        done
        echo "PROBE_IDENTITY: euid=$(/usr/bin/id -u) ruid=$(/usr/bin/id -ru)"
        if /usr/sbin/diskutil info -plist \(q(dev)) >/dev/null 2>&1; then
          echo "PROBE_DISKUTIL_OK"
        else
          echo "PROBE_DISKUTIL_DENIED"
          exit 1
        fi
        if /usr/sbin/diskutil partitionDisk 2>&1 | /usr/bin/grep -q -- '-noEFI'; then
          echo "PROBE_NOEFI_OK"
        else
          echo "PROBE_NOEFI_MISSING: 当前 diskutil 不支持 -noEFI，分区命令会插入 200 MiB EFI 分区并触发 -5344"
          exit 1
        fi
        echo "PROBE_PARTITION_CHANNEL: diskutil partitionDisk -noEFI + 前导 2048S 空隙 (gpt 写命令被 SIP 封锁，不使用)"
        echo "PROBE_RESULT: OK"
        """
    }

    /// DEPRECATED — kept only for diagnostics and regression tests.
    /// Adding the console user to `operator` does NOT enable app-direct
    /// writing: /dev/disk* is `root:operator rw-r-----` (group is read-only)
    /// and `diskutil partitionDisk` / `newfs_exfat` need euid 0. Use the signed helper
    /// channel described in README section 10 instead.
    public static func groupSetupScript(user: String) -> String {
        let q = ShellQuote.bash
        return """
        #!/bin/bash
        set -eu
        # `dseditgroup` returns non-zero when the user is already a member.
        /usr/sbin/dseditgroup -o edit -a \(q(user)) -t user operator || true
        /usr/sbin/dseditgroup -o checkmember -m \(q(user)) operator
        echo "OPERATOR_GROUP_READY"
        """
    }

    /// Whether `id -Gn` output contains the `operator` group.
    public static func isOperator(_ idGnOutput: String) -> Bool {
        idGnOutput
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .contains("operator")
    }
}
