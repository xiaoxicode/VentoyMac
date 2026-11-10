import Foundation

public enum ScriptMode: String, Codable, Sendable {
    /// Print every command without touching the disk.
    case audit
    /// Actually write to the target disk (requires root).
    case live
}

public struct InstallStep: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let command: String
    public let isDestructive: Bool
}

public struct GeneratedScript: Sendable {
    public let steps: [InstallStep]
    public let text: String
    public let mode: ScriptMode
}

public struct InstallPlan: Sendable {
    public let device: DiskDevice
    public let layout: VentoyLayout
    public let assets: BootAssets
    public let volumeLabel: String
    public let isoPaths: [String]
    public let mode: ScriptMode

    public init(device: DiskDevice,
                layout: VentoyLayout,
                assets: BootAssets,
                volumeLabel: String = VentoySpec.defaultVolumeLabel,
                isoPaths: [String] = [],
                mode: ScriptMode = .audit) {
        self.device = device
        self.layout = layout
        self.assets = assets
        self.volumeLabel = volumeLabel
        self.isoPaths = isoPaths
        self.mode = mode
    }
}

public enum InstallPlanError: Error, LocalizedError, Equatable {
    case ineligibleDevice([String])
    case incompleteAssets([String])
    case invalidVolumeLabel
    case missingISO(String)
    case unsupportedSectorSize(UInt64)

    public var errorDescription: String? {
        switch self {
        case .ineligibleDevice(let reasons):
            return "目标磁盘不可用：" + reasons.joined(separator: "、")
        case .incompleteAssets(let issues):
            return "引导资源未就绪：" + issues.joined(separator: "；")
        case .invalidVolumeLabel:
            return "exFAT 卷标必须为 1–11 个字符，且不能包含 / \\ : * ? \" < > | 。"
        case .missingISO(let path):
            return "镜像文件不存在：\(path)"
        case .unsupportedSectorSize(let size):
            return "不支持 \(size) 字节扇区设备（Ventoy 要求 512 字节）。"
        }
    }
}

public extension InstallPlan {
    func validate() throws {
        guard device.isEligible else {
            throw InstallPlanError.ineligibleDevice(device.rejectionReasons)
        }
        if device.deviceBlockSize > 0 && device.deviceBlockSize != VentoySpec.sectorSize {
            throw InstallPlanError.unsupportedSectorSize(device.deviceBlockSize)
        }
        let issues = assets.validationIssues
        guard issues.isEmpty else { throw InstallPlanError.incompleteAssets(issues) }

        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        guard !volumeLabel.isEmpty,
              volumeLabel.count <= 11,
              volumeLabel.rangeOfCharacter(from: invalid) == nil else {
            throw InstallPlanError.invalidVolumeLabel
        }
        for path in isoPaths where !FileManager.default.fileExists(atPath: path) {
            throw InstallPlanError.missingISO(path)
        }
    }
}

// MARK: - Script generation

/// Builds a fully self-contained, auditable /bin/bash script that reproduces
/// `Ventoy2Disk.sh -g -I <disk>` on macOS using DiskArbitration-era CLI tools.
public enum InstallScriptBuilder {

    public static func build(_ plan: InstallPlan) throws -> GeneratedScript {
        try plan.validate()

        let q = ShellQuote.bash
        let disk = plan.device.bsdName
        let dev = "/dev/" + disk
        let raw = "/dev/r" + disk
        let p1 = raw + "s1"
        let part1 = plan.layout.part1Start
        let part1Count = plan.layout.part1Sectors
        let efiCount = plan.layout.part2Sectors
        let cluster = plan.layout.exFATClusterSectors
        let label = plan.volumeLabel
        let assets = plan.assets

        // macOS `/dev/rdisk*` is a character device that forces 512-byte
        // aligned I/O: both the transfer size AND the byte offset must be
        // sector multiples. The official Linux script (`bs=64 count=512`,
        // `bs=1 seek=92`, ...) works there because /dev/sdX is a buffered
        // block device. Porting those commands verbatim yields
        // `dd: /dev/rdiskN: Invalid argument` (EINVAL) on the very first
        // write. Every sub-sector patch is therefore staged in a regular
        // temporary file and flushed as whole sectors.
        let sector = VentoySpec.sectorSize
        let flag2Sector = VentoySpec.gptFlag2Offset / sector        // LBA 34
        let flag2ByteInSector = VentoySpec.gptFlag2Offset % sector  // 500
        // `diskutil` expresses an exact 512-byte-sector count with the `S`
        // suffix; `Free Space` as the last triplet stops it from stretching
        // the second partition to the end of the disk.
        let part1Size = "\(part1Count)S"
        let efiSize = "\(efiCount)S"
        // Runtime value read back from `diskutil info -plist diskNs2`, because
        // diskutil aligns partition 1 down to a 1 MiB boundary.
        let part2LBA = "$VTOY_PART2_LBA"

        var rawSteps: [(String, String, Bool)] = []

        func add(_ title: String, _ command: String, _ destructive: Bool = true) {
            rawSteps.append((title, command, destructive))
        }

        // 0. Hard safety gate. Also protects a script that was exported and run later.
        add("校验目标磁盘与引导资源", """
INFO="$(/usr/sbin/diskutil info -plist \(q(dev)))" || { echo "错误：无法读取 \(disk) 信息"; exit 1; }
INTERNAL="$(printf '%s' "$INFO" | /usr/bin/plutil -extract Internal raw -o - -)"
WHOLE="$(printf '%s' "$INFO" | /usr/bin/plutil -extract WholeDisk raw -o - -)"
[ "$INTERNAL" = "false" ] || { echo "拒绝执行：\(disk) 是内置磁盘"; exit 1; }
[ "$WHOLE" = "true" ] || { echo "拒绝执行：\(disk) 不是整盘设备"; exit 1; }
for f in \(q(assets.bootImage)) \(q(assets.coreImage)) \(q(assets.efiImage)); do
  [ -f "$f" ] || { echo "拒绝执行：缺少引导文件 $f"; exit 1; }
done
""", false)

        add("卸载目标磁盘上的所有卷",
            "/usr/sbin/diskutil unmountDisk force \(q(dev)) || true")

        // macOS `/usr/sbin/gpt` carries the
        // `com.apple.rootless.restricted-block-devices` entitlement. While SIP
        // is enabled, EVERY write subcommand (create/add/label/destroy) is
        // rejected at command dispatch with
        // "gpt create: operation not permitted: create" — even as root (both
        // euid and ruid 0), even on a regular file, even on a virtual disk.
        // Verified on this machine: SIP enabled, uid=0/ruid=0, both
        // /dev/diskN and a temp file rejected. `diskutil partitionDisk` is the
        // supported high-level alternative and, crucially, creates the kernel
        // partition nodes that `newfs_exfat` needs. Only the READ-ONLY
        // `gpt -r show` is used, for the final layout report.

        // macOS TCC/SIP blocks raw block-device writes (EPERM) even for root when
        // the responsible process lacks Full Disk Access. In addition, a raw
        // device returns EINVAL for any transfer whose size or offset is not a
        // multiple of 512 bytes. Probe BOTH properties here, after unmount and
        // before ANY destructive command, using a 0-byte write-open plus an
        // aligned 512-byte read (neither changes a single byte on the disk).
        add("裸盘写入权限预检与扇区对齐检查（0 字节写入 + 对齐读）", """
if [ "$(/usr/bin/id -u)" != "0" ]; then
  echo "  ℹ 以普通用户运行：diskutil partitionDisk / newfs_exfat 需要管理员授权"
fi
# 分区表由 diskutil（DiskArbitration）写，引导区由 dd 写裸节点；TCC 可能
# 只放行其中一个，两个设备节点都要验。
for PROBE in \(q(dev)) \(q(raw)); do
  if [ ! -e "$PROBE" ]; then
    echo "错误：找不到设备 ${PROBE}，请重新确认 U 盘设备名。"; exit 1
  fi
  if ! /bin/dd if=/dev/null of="$PROBE" bs=512 count=0 conv=notrunc 2>/dev/null; then
    echo "=================================================================="
    echo "拒绝执行：当前进程无法以写方式打开裸磁盘 $PROBE"
    echo "原因：macOS 的「完全磁盘访问」(TCC / SIP) 会阻止非授权进程写入"
    echo "      /dev/disk* 与 /dev/rdisk*，即使已获得 root 权限也一样。"
    echo ""
    echo "解决步骤（不需要终端）："
    echo "  1) 系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加并启用 VentoyMac.app"
    echo "  2) 完全退出 VentoyMac 并重新打开（授权在进程启动时生效）"
    echo "  3) 在应用「安装」页点「验证磁盘写入权限」，自动挑选可用提权通道"
    echo "  4) 若仍失败，点「给系统提权进程授权」，把"
    echo "     /usr/libexec/security_authtrampoline 也加入完全磁盘访问，再重启应用"
    echo ""
    echo "备用：导出本脚本，在已获完全磁盘访问的终端中执行 sudo bash <脚本>"
    echo "=================================================================="
    echo "预检未通过：未对磁盘做任何修改（仅执行过卸载，可重新插拔恢复）。"
    exit 1
  fi
  if ! /bin/dd if="$PROBE" of=/dev/null bs=512 count=1 2>/dev/null; then
    echo "拒绝执行：$PROBE 无法完成 512 字节扇区对齐读（设备不是 512n/512e，或仍被占用）"
    echo "预检未通过：未对磁盘做任何修改（仅执行过卸载，可重新插拔恢复）。"
    exit 1
  fi
  echo "  ✓ 可写且可对齐访问：${PROBE}（0 字节写入 + 512 字节对齐读）"
done
echo "  ℹ 身份：有效 uid=$(/usr/bin/id -u)，真实 uid=$(/usr/bin/id -ru)"
echo "  ℹ 分区通道：diskutil partitionDisk -noEFI + 前导 \(part1)S 空隙（不调用被 SIP 封锁的 gpt 写命令）"
echo "  ℹ 计划布局：part1 LBA \(part1) + \(part1Count)，part2 \(efiCount) 扇区 / EFI System"
echo "权限与对齐预检通过：\(dev) 与 \(raw) 均未写入任何字节"
""", false)

        // FIRST destructive command: `diskutil partitionDisk`. It goes through
        // DiskArbitration (entitled) rather than the SIP-blocked `gpt` write
        // path, and creates the /dev/diskNs1 + s2 kernel nodes.
        //
        // `-noEFI` is MANDATORY: on a disk larger than ~200 MiB, `diskutil`
        // silently prepends its own 200 MiB (409600-sector) EFI System
        // Partition. The official Ventoy layout leaves only 40 sectors of
        // slack at the end, so that extra partition produced
        //   Error: -5344: MediaKit reports not enough space on device
        // on the real 8 GB USB stick, while a 128 MiB rehearsal image never
        // triggered it (too small for an auto-ESP). `-noEFI` also changes the
        // default start of the first partition from LBA 2048 to LBA 40, which
        // would collide with core.img (LBA 34–2047); a leading `Free Space`
        // triplet of exactly `part1Start` sectors pushes it back to LBA 2048.
        // The trailing `Free Space ... R` stops diskutil from stretching
        // VTOYEFI beyond 65536 sectors. Explicit `%GUID%` types plus `S` sizes
        // then reproduce the official geometry byte-for-byte:
        //   PMBR / GPT @ 0–33, gap 34–2047, part1 @ 2048, part2 @ 15663064.
        add("重建 GPT 与两个分区（首个写入动作）", """
/usr/sbin/diskutil unmountDisk force \(q(dev)) 2>/dev/null || true
/usr/sbin/diskutil partitionDisk -noEFI \(q(disk)) 4 GPT \
  \(q("Free Space")) \(q("gap")) \(part1)S \
  \(q("%" + VentoySpec.basicDataGUID + "%")) \(q(label)) \(part1Size) \
  \(q("%" + VentoySpec.efiSystemGUID + "%")) \(q(VentoySpec.efiVolumeLabel)) \(efiSize) \
  \(q("Free Space")) \(q("spare")) R
""")

        add("读取实际分区布局并等待设备节点", """
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -e \(q(p1)) ] && [ -e \(q(raw + "s2")) ] && break
  /usr/sbin/diskutil list \(q(dev)) >/dev/null 2>&1 || true
  /bin/sleep 1
done
[ -e \(q(p1)) ] || { echo "错误：分区 1 设备节点未出现，中止"; exit 1; }
[ -e \(q(raw + "s2")) ] || { echo "错误：分区 2 设备节点未出现，中止"; exit 1; }
# -noEFI 会把首个分区默认挪到 LBA 40；前导 Free Space 必须把它顶回
# LBA \(part1)，否则 core.img（LBA 34–2047）会覆盖 exFAT 数据区。
P1INFO="$(/usr/sbin/diskutil info -plist \(q(dev + "s1")))" || { echo "错误：无法读取分区 1 信息"; exit 1; }
VTOY_P1_OFFSET="$(printf '%s' "$P1INFO" | /usr/bin/plutil -extract PartitionMapPartitionOffset raw -o - - 2>/dev/null || true)"
[ -n "$VTOY_P1_OFFSET" ] || { echo "错误：diskutil 未返回分区 1 偏移"; exit 1; }
[ "$(( VTOY_P1_OFFSET / \(sector) ))" = "\(part1)" ] || { echo "错误：分区 1 起始 LBA 为 $(( VTOY_P1_OFFSET / \(sector) ))（应为 \(part1)），中止以免 core.img 覆盖数据区"; exit 1; }
echo "  ✓ Ventoy 分区：LBA \(part1) / Microsoft Basic Data / \(part1Count) 扇区"
P2INFO="$(/usr/sbin/diskutil info -plist \(q(dev + "s2")))" || { echo "错误：无法读取分区 2 信息"; exit 1; }
VTOY_P2_CONTENT="$(printf '%s' "$P2INFO" | /usr/bin/plutil -extract Content raw -o - - 2>/dev/null || true)"
VTOY_P2_OFFSET="$(printf '%s' "$P2INFO" | /usr/bin/plutil -extract PartitionMapPartitionOffset raw -o - - 2>/dev/null || true)"
[ -n "$VTOY_P2_OFFSET" ] || { echo "错误：diskutil 未返回分区 2 偏移"; exit 1; }
[ "$VTOY_P2_CONTENT" = "EFI" ] || { echo "错误：分区 2 类型为 '${VTOY_P2_CONTENT}'（应为 EFI），中止"; exit 1; }
[ "$(( VTOY_P2_OFFSET % \(sector) ))" = "0" ] || { echo "错误：分区 2 偏移未按 512 字节对齐"; exit 1; }
VTOY_PART2_LBA=$(( VTOY_P2_OFFSET / \(sector) ))
echo "  ✓ VTOYEFI 分区：LBA $VTOY_PART2_LBA / EFI System / \(efiCount) 扇区"
""", false)

        // All whole-disk `dd` writes happen BEFORE any filesystem exists.
        // DiskArbitration automounts a partition as soon as a valid FAT/exFAT
        // appears (observed right after the 32 MiB FAT16 image); a later
        // whole-disk write then fails with `Resource busy` (EBUSY). Creating
        // the filesystems last removes that race, and `vtoy_raw_write` also
        // unmounts + retries as a second line of defence.
        //
        // LBA 0 is the only sector that needs sub-sector patches.
        // `diskutil partitionDisk` puts the protective MBR entry at bytes
        // 446...511; the official installer overwrites ONLY the first 446
        // bytes so that entry survives. We read the sector back from the RAW
        // node (bypassing any stale buffer cache), stage every byte patch in a
        // regular file, then flush one aligned sector.
        add("写入 MBR 引导代码与 GPT 模式标记", """
/bin/dd if=\(q(raw)) of="$VTOY_STAGE/mbr.bin" bs=\(sector) count=1
# 确认读到的是 diskutil 生成的保护 MBR，否则宁可中止也不覆盖分区项
PTYPE="$(/usr/bin/xxd -s 450 -l 1 -p "$VTOY_STAGE/mbr.bin")"
[ "$PTYPE" = "ee" ] || { echo "错误：LBA 0 偏移 450 不是 0xEE 保护 MBR（实际 0x${PTYPE}），中止以免破坏分区表"; exit 1; }
[ "$(/usr/bin/xxd -s 510 -l 2 -p "$VTOY_STAGE/mbr.bin")" = "55aa" ] || { echo "错误：LBA 0 缺少 0x55AA 签名"; exit 1; }
/bin/dd if=\(q(assets.bootImage)) of="$VTOY_STAGE/mbr.bin" bs=\(VentoySpec.mbrBootstrapBytes) count=1 conv=notrunc
# 0x22 → 八进制 \\042；普通文件允许任意字节偏移，裸设备不允许
printf '\\042' | /bin/dd of="$VTOY_STAGE/mbr.bin" bs=1 count=1 seek=\(VentoySpec.gptFlag1Offset) conv=notrunc
vtoy_raw_write "$VTOY_STAGE/mbr.bin" 1 0
""")

        // Official: `xzcat core.img.xz | dd bs=512 count=2014 seek=34`, then
        // patch absolute byte 17908 to 0x23. 17908 = LBA 34 * 512 + 500, i.e.
        // it lands inside the FIRST sector of the staged core image.
        add("写入 Legacy BIOS GRUB core（LBA 34–2047）", """
# 官方字节 17908 = LBA34×512 + \(flag2ByteInSector)，落在 core 镜像首个扇区
/bin/dd if=\(q(assets.coreImage)) of="$VTOY_STAGE/core.bin" bs=\(sector) count=\(VentoySpec.coreImageSectorCount)
printf '\\043' | /bin/dd of="$VTOY_STAGE/core.bin" bs=1 count=1 seek=\(flag2ByteInSector) conv=notrunc
vtoy_raw_write "$VTOY_STAGE/core.bin" \(VentoySpec.coreImageSectorCount) \(VentoySpec.coreImageStartSector)
""")

        add("生成 Ventoy 磁盘 UUID 与 MBR 签名", """
UUIDFILE="$VTOY_STAGE/uuid.bin"
/bin/dd if=/dev/urandom of="$UUIDFILE" bs=16 count=1 2>/dev/null
# 重新读出 LBA 0，保留引导代码与保护 MBR；UUID / 签名补丁只落在暂存文件上
/bin/dd if=\(q(raw)) of="$VTOY_STAGE/mbr.bin" bs=\(sector) count=1
/bin/dd if="$UUIDFILE" of="$VTOY_STAGE/mbr.bin" bs=1 count=\(VentoySpec.diskUUIDLength) seek=\(VentoySpec.diskUUIDOffset) conv=notrunc
/bin/dd if="$UUIDFILE" of="$VTOY_STAGE/mbr.bin" bs=1 count=\(VentoySpec.diskSignatureLength) skip=12 seek=\(VentoySpec.diskSignatureOffset) conv=notrunc
vtoy_raw_write "$VTOY_STAGE/mbr.bin" 1 0
sync
""")

        add("对齐读回校验 GPT 模式标记与 MBR 签名", """
/bin/dd if=\(q(raw)) of="$VTOY_STAGE/verify.bin" bs=\(sector) count=1
/bin/dd if=\(q(raw)) of="$VTOY_STAGE/verify-core.bin" bs=\(sector) count=1 skip=\(flag2Sector)
FLAG1="$(/usr/bin/xxd -s \(VentoySpec.gptFlag1Offset) -l 1 -p "$VTOY_STAGE/verify.bin")"
FLAG2="$(/usr/bin/xxd -s \(flag2ByteInSector) -l 1 -p "$VTOY_STAGE/verify-core.bin")"
SIGNATURE="$(/usr/bin/xxd -s 510 -l 2 -p "$VTOY_STAGE/verify.bin")"
[ "$FLAG1" = "22" ] || { echo "校验失败：字节 92 应为 0x22，实际为 0x$FLAG1"; exit 1; }
[ "$FLAG2" = "23" ] || { echo "校验失败：字节 17908 应为 0x23，实际为 0x$FLAG2"; exit 1; }
[ "$SIGNATURE" = "55aa" ] || { echo "校验失败：MBR 签名 0x55AA 缺失"; exit 1; }
echo "  ✓ 字节 92=0x22、17908=0x23、MBR 签名 0x55AA"
""", false)

        // The 32 MiB image is a complete FAT16 filesystem, so no separate
        // newfs_msdos is needed: the image overwrites the partition wholesale.
        add("清空 VTOYEFI 分区引导扇区",
            "vtoy_raw_write /dev/zero 32 \(part2LBA)")

        add("写入官方 VTOYEFI 分区镜像（GRUB2 + x86/IA32/ARM64 EFI）",
            "vtoy_raw_write \(q(assets.efiImage)) \(efiCount) \(part2LBA)")

        add("格式化分区 1 为 exFAT（卷标 \(label)）", """
vtoy_unmount
/sbin/newfs_exfat -v \(q(label)) -c \(cluster) \(q(p1))
""")

        add("挂载 Ventoy 卷并准备 ISO 目录", """
/usr/sbin/diskutil unmountDisk force \(q(dev)) 2>/dev/null || true
/usr/sbin/diskutil mount \(q(dev + "s1")) 2>/dev/null || true
MP="$(ventoy_mount_point \(q(dev + "s1")))"
if [ -z "$MP" ]; then
  MP="$(/usr/bin/mktemp -d -t ventoy-mount)"
  /sbin/mount -t exfat \(q(dev + "s1")) "$MP" || { echo "错误：无法挂载 Ventoy 数据分区，请手动挂载后复制 ISO"; exit 1; }
fi
/bin/mkdir -p "$MP/\(VentoySpec.isoDirectoryName)"
echo "挂载点：$MP"
""", false)

        for path in plan.isoPaths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            // `cp src dir/` preserves the source basename and needs no name quoting.
            add("复制镜像 \(name)", """
MP="$(ventoy_mount_point \(q(dev + "s1")))"
if [ -z "$MP" ]; then
  MP="$(/usr/bin/mktemp -d -t ventoy-mount)"
  /sbin/mount -t exfat \(q(dev + "s1")) "$MP" || { echo "错误：无法挂载 Ventoy 数据分区"; exit 1; }
fi
/bin/mkdir -p "$MP/\(VentoySpec.isoDirectoryName)"
/bin/cp \(q(path)) "$MP/\(VentoySpec.isoDirectoryName)/"
""", false)
        }

        add("同步并输出完成信息", """
sync
echo "Ventoy \(assets.version) 已写入 \(dev)"
echo "VTOYEFI 分区起始 LBA：$VTOY_PART2_LBA"
/usr/sbin/diskutil list \(q(dev)) || true
/usr/sbin/gpt -r show -l \(q(dev)) || true
""", false)

        let steps = rawSteps.enumerated().map {
            InstallStep(id: $0.offset + 1,
                        title: $0.element.0,
                        command: $0.element.1,
                        isDestructive: $0.element.2)
        }

        return GeneratedScript(steps: steps,
                               text: render(steps: steps, mode: plan.mode, plan: plan),
                               mode: plan.mode)
    }

    private static func render(steps: [InstallStep], mode: ScriptMode, plan: InstallPlan) -> String {
        let q = ShellQuote.bash
        var out: [String] = []
        out.append("#!/bin/bash")
        out.append("# =====================================================================")
        out.append("# VentoyMac generated install script")
        out.append("# Target : /dev/\(plan.device.bsdName)  (\(plan.device.displayName), \(plan.device.sizeDescription))")
        out.append("# Version: Ventoy \(plan.assets.version)")
        out.append("# Mode   : \(mode == .audit ? "AUDIT (no writes)" : "LIVE (destructive)")")
        out.append("# Layout : GPT / part1 LBA \(plan.layout.part1Start) + \(plan.layout.part1Sectors), part2 LBA \(plan.layout.part2Start) + \(plan.layout.part2Sectors)")
        out.append("# Build  : \(VentoyBuild.id)  (install script r\(VentoyBuild.scriptRevision))")
        out.append("# Source : https://github.com/ventoy/Ventoy  (INSTALL/tool/ventoy_lib.sh)")
        out.append("# =====================================================================")
        out.append("# 警告：本脚本会彻底清空目标磁盘上的所有数据，请在执行前逐条审阅。")
        out.append("")
        out.append("set -euo pipefail")
        out.append("export PATH=/usr/sbin:/usr/bin:/bin:/sbin:/opt/homebrew/bin:$PATH")
        out.append("")
        if mode == .live {
            // `diskutil partitionDisk` on a physical USB disk and
            // `newfs_exfat` both need root. No `gpt` write command is used
            // any more (SIP blocks them regardless of uid), so a real-uid
            // bootstrap is unnecessary — only the effective uid is checked.
            out.append("""
# ---- Identity gate (live mode only) -------------------------------------
VTOY_EUID="$(/usr/bin/id -u)"
if [ "$VTOY_EUID" != "0" ]; then
  echo "拒绝执行：未获得 root 有效权限，diskutil partitionDisk / newfs_exfat 无法运行。"; exit 1
fi
echo "身份：有效 uid=$VTOY_EUID  真实 uid=$(/usr/bin/id -ru)"
echo "分区通道：diskutil partitionDisk -noEFI（gpt 写命令在 SIP 开启时被系统封锁；关闭自动 200 MiB EFI 分区）"
""")
            out.append("")
        }
        out.append("emit_step() { printf '\\n==> [%s/%s] %s\\n' \"$1\" \"$2\" \"$3\"; }")
        out.append("ventoy_mount_point() {")
        out.append("  /usr/sbin/diskutil info -plist \"$1\" 2>/dev/null | /usr/bin/plutil -extract MountPoint raw -o - - 2>/dev/null || true")
        out.append("}")
        // DiskArbitration automounts a partition as soon as it sees a valid
        // filesystem; a subsequent whole-disk write then fails with EBUSY.
        // Every whole-disk write unmounts first and retries a few times.
        out.append("vtoy_unmount() {")
        out.append("  /usr/sbin/diskutil unmountDisk force \(q("/dev/" + plan.device.bsdName)) >/dev/null 2>&1 || true")
        out.append("}")
        out.append("# $1 = source file, $2 = sector count, $3 = destination LBA")
        out.append("vtoy_raw_write() {")
        out.append("  local src=\"$1\" sectors=\"$2\" seek_lba=\"$3\" n=0")
        out.append("  while [ \"$n\" -lt 5 ]; do")
        out.append("    vtoy_unmount")
        out.append("    if /bin/dd if=\"$src\" of=\(q("/dev/r" + plan.device.bsdName)) bs=\(VentoySpec.sectorSize) count=\"$sectors\" seek=\"$seek_lba\" conv=notrunc; then")
        out.append("      return 0")
        out.append("    fi")
        out.append("    n=$((n+1))")
        out.append("    echo \"  ⚠ 整盘写入被系统占用（Resource busy），卸载后重试 $n/5\"")
        out.append("    /bin/sleep 1")
        out.append("  done")
        out.append("  echo \"错误：整盘写入重试 5 次仍失败\"")
        out.append("  return 1")
        out.append("}")
        out.append("")
        // Staging area for sub-sector byte patches. A regular file accepts
        // arbitrary byte offsets; /dev/rdisk* does not. Keeping every staged
        // file in one mktemp directory also makes cleanup deterministic.
        out.append("VTOY_STAGE=\"$(/usr/bin/mktemp -d -t vtoymac-stage)\"")
        out.append("cleanup_stage() {")
        out.append("  /bin/rm -f \"$VTOY_STAGE/mbr.bin\" \"$VTOY_STAGE/core.bin\" \"$VTOY_STAGE/uuid.bin\" \\")
        out.append("           \"$VTOY_STAGE/verify.bin\" \"$VTOY_STAGE/verify-core.bin\"")
        out.append("  /bin/rmdir \"$VTOY_STAGE\" 2>/dev/null || true")
        out.append("}")
        out.append("trap cleanup_stage EXIT")
        out.append("")
        // First line of every install log: unambiguously ties a pasted error
        // report to the exact binary that generated this script.
        out.append("echo \(q(VentoyBuild.banner + " · 目标 /dev/" + plan.device.bsdName))")
        out.append("")

        for step in steps {
            out.append("emit_step \(step.id) \(steps.count) \(q(step.title))")
            if mode == .audit {
                // Print the exact command; nothing is evaluated.
                let flat = step.command
                    .replacingOccurrences(of: "\n", with: "\n           ")
                out.append("printf '    $ %s\\n' \(q(flat))")
            } else {
                out.append(step.command)
            }
            out.append("")
        }

        if mode == .audit {
            out.append("echo ''")
            out.append("echo '审计模式完成：未对 /dev/\(plan.device.bsdName) 做任何写入。'")
        } else {
            out.append("echo ''")
            out.append("echo '完成。可安全推出 U 盘。'")
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}
