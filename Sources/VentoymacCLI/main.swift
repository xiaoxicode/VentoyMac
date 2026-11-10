import Foundation
import Darwin
import VentoyCore

// A companion CLI. Its read-only subcommands verify the ported layout
// algorithm and audit generated scripts. The single exception is
// `run-script`, which is the elevated writer helper used by the GUI app.
let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

func capture(_ path: String, _ args: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

func externalDevices() throws -> [DiskDevice] {
    let list = try capture("/usr/sbin/diskutil", ["list", "-plist", "external"])
    let names = try DiskPlistParser.externalWholeDiskNames(list)
    return names.compactMap { name in
        guard let info = try? capture("/usr/sbin/diskutil", ["info", "-plist", name]) else { return nil }
        return try? DiskPlistParser.device(from: info,
                                           volumeNames: DiskPlistParser.volumeNames(for: name, in: list))
    }
}

func cachedAssets() -> BootAssets? {
    BootAssetInstaller.loadCached()
}

func fakeAssets() throws -> BootAssets {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vtoymac-cli-selftest")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // These are the real sizes from ventoy-1.1.18-linux.tar.gz:
    // boot.img 512 B, core.img 2047 sectors, ventoy.disk.img 32 MiB.
    for (name, size) in [("boot.img", 512),
                         ("core.img", Int(VentoySpec.coreImagePackagedBytes)),
                         ("ventoy.disk.img", Int(VentoySpec.efiBytes))] {
        let url = dir.appendingPathComponent(name)
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? -1
        if existing != size {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        }
    }
    return BootAssets(version: "self-test", directory: dir.path)
}

func sampleDevice(internalDisk: Bool = false) -> DiskDevice {
    DiskDevice(bsdName: internalDisk ? "disk0" : "disk9",
               deviceNode: internalDisk ? "/dev/disk0" : "/dev/disk9",
               mediaName: "CLI Fixture",
               busProtocol: "USB",
               totalBytes: 32 * 1_024 * 1_024 * 1_024,
               isWholeDisk: true,
               isInternal: internalDisk,
               isRemovable: !internalDisk,
               isEjectable: !internalDisk,
               isVirtual: false,
               content: "GUID_partition_scheme",
               volumeNames: [],
               deviceBlockSize: 512)
}

switch command {

case "self-test":
    var failures = 0
    func check(_ condition: Bool, _ label: String) {
        print("  \(condition ? "✓" : "✗") \(label)")
        if !condition { failures += 1 }
    }

    print("VentoyMac 核心自检（不访问任何磁盘）")
    do {
        let bytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
        let sectors = bytes / 512
        let layout = try VentoyLayoutCalculator.gpt(totalBytes: bytes)
        var expected = sectors - 33 - 65_536 - 1 + 1
        expected -= expected % 8
        check(layout.part2Start == expected, "GPT 布局与官方 ventoy_lib.sh 公式一致")
        check(layout.part1Start == 2_048, "分区 1 起始于 LBA 2048")
        check(layout.part2Sectors == 65_536, "VTOYEFI 分区为 32 MiB")
        check(layout.part2Start % 8 == 0, "分区 2 满足 4 KiB 对齐")
        check(layout.exFATClusterSectors == 64, "32 GiB 磁盘使用 32 KiB 簇")

        let large = try VentoyLayoutCalculator.gpt(totalBytes: 64 * 1_024 * 1_024 * 1_024)
        check(large.exFATClusterSectors == 256, "大于 32 GiB 磁盘使用 128 KiB 簇")

        var rejected4Kn = false
        do { _ = try VentoyLayoutCalculator.gpt(totalBytes: bytes, deviceSectorSize: 4_096) }
        catch { rejected4Kn = true }
        check(rejected4Kn, "拒绝 4Kn 原生设备")

        let assets = try fakeAssets()
        check(assets.validationIssues.isEmpty,
              "真实尺寸引导镜像通过校验（boot 512B / core 2047 扇区 / VTOYEFI 32 MiB）")

        let badDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vtoymac-cli-oversize")
        try? FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        for (name, size) in [("boot.img", 512),
                             ("core.img", 2_048 * 512),
                             ("ventoy.disk.img", Int(VentoySpec.efiBytes))] {
            FileManager.default.createFile(atPath: badDir.appendingPathComponent(name).path,
                                           contents: Data(count: size))
        }
        let bad = BootAssets(version: "oversize", directory: badDir.path)
        check(!bad.validationIssues.isEmpty, "拒绝超过 2047 扇区的 core.img")

        let plan = InstallPlan(device: sampleDevice(), layout: layout, assets: assets, mode: .audit)
        let script = try InstallScriptBuilder.build(plan)
        let required = ["diskutil partitionDisk -noEFI", "4 GPT", "Free Space",
                        "65536S", "2048S", "VTOY_P1_OFFSET",
                        "newfs_exfat", "2014 34", "count=2014",
                        "seek=92", "17908", "seek=384", "seek=440",
                        "VTOY_STAGE", "seek=500", "$VTOY_PART2_LBA",
                        "PartitionMapPartitionOffset", "count=0 conv=notrunc",
                        "完全磁盘访问", VentoySpec.basicDataGUID, VentoySpec.efiSystemGUID]
        for token in required {
            check(script.text.contains(token), "脚本包含 \(token)")
        }
        for forbidden in ["gpt create -f", "/usr/sbin/gpt add", "/usr/sbin/gpt label",
                          "/usr/sbin/gpt destroy", "gpt-capability.img", "os.setuid(0)"] {
            check(!script.text.contains(forbidden), "已移除被 SIP 封锁/已废弃的逻辑：\(forbidden)")
        }
        // Inspect the generated script text: whole-disk writes live in the
        // vtoy_raw_write helper in the header, not in the step commands.
        let rawWrites = script.text
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("/bin/dd") &&
                     ($0.contains("of='/dev/disk") || $0.contains("of='/dev/rdisk")) }
        check(!rawWrites.isEmpty && rawWrites.allSatisfy { $0.contains("bs=512") && $0.contains("conv=notrunc") },
              "所有裸设备写入均为 512 字节扇区对齐（规避 EINVAL）")
        check(script.text.contains("vtoy_raw_write") && script.text.contains("vtoy_unmount"),
              "整盘写入经卸载 + 重试封装（规避 EBUSY 自动挂载竞态）")
        check(!script.text.contains("bs=64 count=512"), "已移除官方 Linux 版非对齐清零命令")
        check(script.text.contains(VentoyBuild.id), "脚本头携带构建标识 \(VentoyBuild.id)")
        check(script.text.contains(VentoyBuild.banner), "安装日志首行输出构建标识")
        let liveScript = try InstallScriptBuilder.build(
            InstallPlan(device: sampleDevice(), layout: layout, assets: assets, mode: .live))
        check(liveScript.text.contains("VTOY_EUID"), "实时脚本包含有效 uid 门禁")
        check(liveScript.text.contains("身份：有效 uid="), "实时脚本打印有效/真实 uid 诊断行")
        check(liveScript.text.contains("分区通道：diskutil partitionDisk"), "实时脚本声明分区通道")
        check(liveScript.text.contains("VTOY_P1_OFFSET"), "实时脚本断言分区 1 起始 LBA=2048")
        check(liveScript.text.contains("partitionDisk -noEFI") && liveScript.text.contains("4 GPT"),
              "分区命令关闭自动 200 MiB EFI 分区")
        check(liveScript.text.contains("'gap' 2048S"), "前导 Free Space 空隙把 part1 顶回 LBA 2048")
        check(liveScript.text.contains("gpt -r show -l"), "仅保留只读 gpt show 用于布局报告")
        check(!liveScript.text.contains("count=64 conv=notrunc"),
              "已移除会先写盘的 32 KiB dd 清零，分区命令是首个写入动作")
        check(!script.text.contains("os.setuid(0)"), "审计模式不做身份自举")
        let preflight = script.steps.firstIndex { $0.title.contains("权限预检") }
        let firstWrite = script.steps.firstIndex { $0.title.contains("重建 GPT") }
        let unmount = script.steps.firstIndex { $0.title.contains("卸载目标磁盘") }
        check(preflight != nil && unmount != nil && firstWrite != nil
              && unmount! < preflight! && preflight! < firstWrite!,
              "权限预检位于卸载之后、任何破坏性命令之前")
        if let firstWrite {
            check(script.steps[firstWrite].command.contains("diskutil partitionDisk"),
                  "首个写入步骤是 diskutil partitionDisk")
        }

        var rejectedInternal = false
        do {
            _ = try InstallScriptBuilder.build(
                InstallPlan(device: sampleDevice(internalDisk: true), layout: layout, assets: assets))
        } catch { rejectedInternal = true }
        check(rejectedInternal, "拒绝内置磁盘作为写入目标")

        let probe = DiskAccessProbe.script(bsdName: "disk9")
        check(probe.contains("count=0 conv=notrunc"), "0 字节探针不写数据")
        check(probe.contains("bs=512 count=1"), "探针同时验证 512 字节对齐读")
        check(probe.contains("/dev/disk9") && probe.contains("/dev/rdisk9"),
              "探针同时检查缓冲与裸设备节点")
        check(probe.contains("PROBE_RESULT: OK"), "探针输出可判定结果")
        check(probe.contains("PROBE_DISKUTIL_OK"), "探针验证 diskutil 分区通道可用")
        check(probe.contains("PROBE_NOEFI_OK"), "探针验证 -noEFI 开关可用（避免自动 200 MiB EFI 分区）")
        check(probe.contains("PROBE_PARTITION_CHANNEL"), "探针声明不使用 gpt 写命令")
        check(!probe.contains("gpt create -f"), "探针不再调用被 SIP 封锁的 gpt 写命令")
        check(probe.contains("PROBE_IDENTITY"), "探针打印有效/真实 uid 供排障")
        check(DiskAccessProbe.isOperator("staff everyone operator admin"), "operator 组检测（已加入）")
        check(!DiskAccessProbe.isOperator("staff everyone admin"), "operator 组检测（未加入）")
        check(DiskAccessProbe.groupSetupScript(user: "daijh")
                .contains("dseditgroup -o edit -a 'daijh' -t user operator"),
              "【已弃用】operator 组诊断脚本内容完整")
        check(!script.text.contains("需要 root 权限"), "安装脚本不强制 root（身份由提权通道决定）")
        check(script.text.contains("security_authtrampoline"), "预检指引包含系统提权进程授权步骤")
        check(script.text.contains("添加并启用 VentoyMac.app"), "预检指引以给 VentoyMac.app 授权为主")
    } catch {
        print("  ✗ 自检异常：\(error)")
        failures += 1
    }

    print(failures == 0 ? "\n自检通过，0 项失败。" : "\n自检失败：\(failures) 项。")
    exit(failures == 0 ? 0 : 1)

case "disks":
    let devices = try externalDevices()
    if devices.isEmpty {
        print("未检测到外接磁盘。")
    } else {
        for device in devices {
            let mark = device.isEligible ? "可选" : "排除"
            print("\(device.bsdName)\t\(device.sizeDescription)\t\(mark)\t\(device.displayName)\t\(device.volumesDescription)")
        }
    }

case "plan":
    guard arguments.count >= 2 else {
        print("用法: ventoymac-cli plan <diskN> [reservedMiB]")
        exit(2)
    }
    let name = arguments[1]
    let reserved = arguments.count >= 3 ? UInt64(arguments[2]) ?? 0 : 0
    guard let device = try externalDevices().first(where: { $0.bsdName == name }) else {
        print("未找到外接整盘 \(name)")
        exit(1)
    }
    let sectorSize = device.deviceBlockSize > 0 ? device.deviceBlockSize : 512
    let layout = try VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes,
                                                deviceSectorSize: sectorSize,
                                                reservedMiB: reserved)
    print("设备: /dev/\(device.bsdName)  \(device.displayName)  \(device.sizeDescription)")
    for line in layout.summaryLines { print(line) }

case "script":
    guard arguments.count >= 2 else {
        print("用法: ventoymac-cli script <diskN>  （输出审计模式脚本）")
        exit(2)
    }
    let name = arguments[1]
    guard let device = try externalDevices().first(where: { $0.bsdName == name }) else {
        print("未找到外接整盘 \(name)")
        exit(1)
    }
    guard let assets = cachedAssets() else {
        print("尚未安装引导资源。请先在 VentoyMac 应用中下载或导入官方 tar.gz。")
        exit(1)
    }
    let sectorSize = device.deviceBlockSize > 0 ? device.deviceBlockSize : 512
    let layout = try VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes,
                                                deviceSectorSize: sectorSize)
    let plan = InstallPlan(device: device, layout: layout, assets: assets, mode: .audit)
    print(try InstallScriptBuilder.build(plan).text)

case "probe-script":
    let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "disk4"
    // Keep stdout a clean, executable script; guidance goes to stderr.
    FileHandle.standardError.write(Data("""
    VentoyMac 自检脚本（0 字节写打开 + 512 字节对齐读 + diskutil 分区通道检查；不修改磁盘）
    请用与应用内写入完全相同的执行路径来运行它：
      应用「安装」页的「验证磁盘写入权限」会自动测试全部提权通道
      手动复核：应用内提权后执行本脚本，或在已获 FDA 的终端里 sudo bash <本文件>

    """.utf8))
    print(DiskAccessProbe.script(bsdName: name))

case "group-setup-script":
    FileHandle.standardError.write(Data("""
    【已弃用】把当前用户加入 operator 组。仅用于诊断，不解决写盘问题：
    /dev/disk* 为 root:operator rw-r-----（组仅可读），且 diskutil 分区 / newfs_exfat 需要 root。
    正确做法见 README 第 10 节：给 VentoyMac.app（必要时连同
    /usr/libexec/security_authtrampoline）授予「完全磁盘访问」。

    """.utf8))
    print(DiskAccessProbe.groupSetupScript(user: NSUserName()))

case "live-script":
    // Prints (never runs) a destructive install script. Redirect to a file and
    // execute it from a Terminal.app that has Full Disk Access:
    //   ventoymac-cli live-script disk4 > ~/Downloads/install.sh
    //   sudo bash ~/Downloads/install.sh
    guard arguments.count >= 2 else {
        print("用法: ventoymac-cli live-script <diskN>  （输出可执行脚本，但不执行）")
        exit(2)
    }
    let name = arguments[1]
    guard let device = try externalDevices().first(where: { $0.bsdName == name }) else {
        print("未找到外接整盘 \(name)")
        exit(1)
    }
    guard let assets = cachedAssets() else {
        print("尚未安装引导资源。请先在 VentoyMac 应用中下载或导入官方 tar.gz。")
        exit(1)
    }
    let sectorSize = device.deviceBlockSize > 0 ? device.deviceBlockSize : 512
    let layout = try VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes,
                                                deviceSectorSize: sectorSize)
    let plan = InstallPlan(device: device, layout: layout, assets: assets, mode: .live)
    let script = try InstallScriptBuilder.build(plan)
    // Keep stdout a clean, executable script; guidance goes to stderr.
    FileHandle.standardError.write(Data("""
    注意：此脚本会清空 /dev/\(name) 的全部数据，请逐条审阅后再执行。
    首选：在 VentoyMac 应用内写入（需先给 VentoyMac.app「完全磁盘访问」，见 README 第 10 节）。
    兜底：在拥有「完全磁盘访问」的终端执行 sudo bash <本文件>。

    """.utf8))
    print(script.text)

case "rehearse-script":
    // Generates a LIVE script for a synthetic disk of the given size, so the
    // complete write chain can be rehearsed on a `hdiutil attach -nomount`
    // disk image (owned by the current user) without root or a real USB disk.
    guard arguments.count >= 3, let bytes = UInt64(arguments[2]) else {
        print("用法: ventoymac-cli rehearse-script <diskN> <totalBytes>  （只打印，不执行）")
        exit(2)
    }
    let name = arguments[1]
    guard let assets = cachedAssets() else {
        print("尚未安装引导资源。请先在 VentoyMac 应用中下载或导入官方 tar.gz。")
        exit(1)
    }
    let layout = try VentoyLayoutCalculator.gpt(totalBytes: bytes)
    let device = DiskDevice(bsdName: name,
                            deviceNode: "/dev/" + name,
                            mediaName: "Rehearsal Disk Image",
                            busProtocol: "Disk Image",
                            totalBytes: bytes,
                            isWholeDisk: true,
                            isInternal: false,
                            isRemovable: true,
                            isEjectable: true,
                            isVirtual: false,
                            content: "",
                            volumeNames: [],
                            deviceBlockSize: 512)
    let plan = InstallPlan(device: device, layout: layout, assets: assets, mode: .live)
    var text = try InstallScriptBuilder.build(plan).text
    // A disk image is owned by the current user, so the root identity gate is
    // the only line that must be relaxed for a local rehearsal. The production
    // script is untouched.
    text = text.replacingOccurrences(
        of: "VTOY_EUID=\"$(/usr/bin/id -u)\"",
        with: "VTOY_EUID=0  # 演练模式：虚拟盘 owner 为当前用户，无需 root")
    FileHandle.standardError.write(Data("""
    演练脚本：目标 /dev/\(name)，合成容量 \(bytes) 字节；已跳过 root 门禁。
    只在 hdiutil attach 出来的磁盘映像上运行，切勿指向真实磁盘。

    """.utf8))
    print(text)

case "demo-script":
    // Emits the full audit script for a synthetic 32 GiB disk, so the
    // generated Bash can be linted and executed without any real hardware.
    let layout = try VentoyLayoutCalculator.gpt(totalBytes: 32 * 1_024 * 1_024 * 1_024)
    let assets = try fakeAssets()
    let plan = InstallPlan(device: sampleDevice(), layout: layout, assets: assets, mode: .audit)
    print(try InstallScriptBuilder.build(plan).text)

case "assets":
    guard let assets = cachedAssets() else {
        print("引导资源: 未安装")
        print("缓存目录: \(BootAssetInstaller.defaultCacheDirectory.path)")
        exit(1)
    }
    print("Ventoy \(assets.version)")
    print("来源包  : \(assets.sourceFileName ?? "本地导入")")
    print("SHA256  : \(assets.sourceSHA256 ?? "—")")
    print("缓存目录: \(assets.directory)")
    for file in assets.requiredFiles {
        let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)??.int64Value ?? 0
        print("  \(URL(fileURLWithPath: file).lastPathComponent)\t\(size) bytes")
    }
    let issues = assets.validationIssues
    print(issues.isEmpty ? "校验: 通过" : "校验: 失败 → \(issues.joined(separator: "；"))")

case "import-assets":
    guard arguments.count >= 2 else {
        print("用法: ventoymac-cli import-assets <ventoy-<版本>-linux.tar.gz> [期望SHA256]")
        exit(2)
    }
    let package = URL(fileURLWithPath: arguments[1])
    let expected = arguments.count >= 3 ? arguments[2] : nil
    guard FileManager.default.fileExists(atPath: package.path) else {
        print("文件不存在：\(package.path)")
        exit(1)
    }
    do {
        let result = try BootAssetInstaller.install(package: package, expectedSHA256: expected)
        print("安装完成 · Ventoy \(result.version)")
        print("SHA256  : \(result.sourceSHA256 ?? "—")")
        print("缓存目录: \(result.directory)")
        for file in result.requiredFiles {
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)??.int64Value ?? 0
            print("  \(URL(fileURLWithPath: file).lastPathComponent)\t\(size) bytes")
        }
        print("校验: 通过")
    } catch {
        print("安装失败：\(error.localizedDescription)")
        exit(1)
    }

case "run-script":
    // Elevated writer helper. Invoked via `osascript ... with administrator
    // privileges`, so this process runs as root. It is signed with the SAME
    // fixed designated requirement as VentoyMac.app, so TCC matches the
    // user's Full Disk Access grant to THIS process — and therefore to every
    // child (`bash` -> `diskutil` / `dd`) — instead of to security_authtrampoline.
    // Do not accept arbitrary paths: only VentoyMac's own temp scripts.
    guard arguments.count > 1 else {
        FileHandle.standardError.write(Data("用法: ventoymac-cli run-script <install.sh>\n".utf8))
        exit(2)
    }
    let scriptPath = arguments[1]
    guard scriptPath.contains("/vtoymac-"), scriptPath.hasSuffix(".sh") else {
        FileHandle.standardError.write(Data("拒绝执行：脚本路径不是 VentoyMac 临时脚本\n".utf8))
        exit(2)
    }
    // Normalise the real uid as well as the effective uid, so every child
    // (bash -> diskutil / newfs_exfat / dd) inherits a consistent identity.
    // This is no longer a hard requirement of `gpt` (all of its write
    // subcommands were removed because SIP blocks them), but it keeps the
    // elevated helper deterministic. No-op when already fully root.
    if geteuid() == 0 && getuid() != 0 {
        if setuid(0) != 0 {
            FileHandle.standardError.write(Data("警告：无法把真实 uid 统一为 0（部分 diskutil 操作可能失败）\n".utf8))
        }
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/bash")
    child.arguments = [scriptPath]
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    do {
        try child.run()
    } catch {
        FileHandle.standardError.write(Data("无法启动安装脚本：\(error)\n".utf8))
        exit(1)
    }
    child.waitUntilExit()
    exit(child.terminationStatus)

case "build-id":
    print(VentoyBuild.id)
    print("script-r\(VentoyBuild.scriptRevision)")
    print("stale=\(VentoyBuild.isStaleAgainstBundle() ? "yes" : "no")")

case "version":
    print(VentoyBuild.banner)
    print("ventoymac-cli · arm64-apple-macosx · Ventoy 1.1.18 磁盘布局")
    if let assets = cachedAssets() {
        print("引导资源: Ventoy \(assets.version)  \(assets.directory)")
    } else {
        print("引导资源: 未安装")
    }

default:
    print("""
    ventoymac-cli — VentoyMac 命令行辅助工具

    用法:
      ventoymac-cli self-test              运行核心算法与脚本自检
      ventoymac-cli disks                 列出外接磁盘及可选状态
      ventoymac-cli plan <diskN> [MiB]    计算指定磁盘的 GPT 布局
      ventoymac-cli script <diskN>        输出该盘的审计模式安装脚本
      ventoymac-cli live-script <diskN>   输出实时安装脚本（只打印，不执行；供 sudo 使用）
      ventoymac-cli rehearse-script <diskN> <bytes>  输出虚拟盘演练脚本（只打印，不执行）
      ventoymac-cli probe-script <diskN>  输出 0 字节写打开 + 对齐读 + 分区通道探针（只打印，不执行）
      ventoymac-cli group-setup-script    输出 operator 组设置脚本（已弃用，仅供诊断）
      ventoymac-cli demo-script           输出合成磁盘的完整审计脚本（可 bash -n 校验）
      ventoymac-cli import-assets <pkg>  校验并导入官方 linux.tar.gz（可附期望 SHA256）
      ventoymac-cli assets               显示已缓存引导资源及校验结果
      ventoymac-cli version               显示构建标识、版本与引导资源状态
      ventoymac-cli build-id             只输出构建标识（便于核对粘贴的日志）

    内部命令（由 GUI 提权调用，勿手动使用）:
      ventoymac-cli run-script <install.sh>  以当前身份执行 VentoyMac 临时脚本
    """)
}
