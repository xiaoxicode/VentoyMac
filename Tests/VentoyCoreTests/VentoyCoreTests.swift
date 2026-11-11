import XCTest
@testable import VentoyCore

final class VentoyLayoutTests: XCTestCase {

    // Reference values computed from the official shell formula for a 32 GiB disk.
    func testOfficialGPTLayoutFor32GiBDisk() throws {
        let bytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
        let totalSectors = bytes / 512            // 67_108_864
        let layout = try VentoyLayoutCalculator.gpt(totalBytes: bytes)

        let expectedPart1End = totalSectors - (0 + 33) - 65_536 - 1
        var expectedPart2Start = expectedPart1End + 1
        let remainder = expectedPart2Start % 8
        if remainder > 0 {
            expectedPart2Start -= remainder
        }

        XCTAssertEqual(layout.totalSectors, totalSectors)
        XCTAssertEqual(layout.part1Start, 2_048)
        XCTAssertEqual(layout.part2Start, expectedPart2Start)
        XCTAssertEqual(layout.part2End, expectedPart2Start + 65_536 - 1)
        XCTAssertEqual(layout.part2Sectors, 65_536)
        XCTAssertEqual(layout.part1End + 1, layout.part2Start)
        XCTAssertEqual(layout.part1Sectors, layout.part1End - 2_048 + 1)
        XCTAssertLessThanOrEqual(layout.part2End + 34, totalSectors)
    }

    func testPart2IsAlways4KiBAligned() throws {
        for gb in [8, 16, 32, 64, 128, 256, 512, 1_024] {
            let bytes = UInt64(gb) * 1_024 * 1_024 * 1_024
            let layout = try VentoyLayoutCalculator.gpt(totalBytes: bytes)
            XCTAssertEqual(layout.part2Start % 8, 0, "disk \(gb) GiB")
            XCTAssertEqual(layout.part2End + 1, layout.part2Start + 65_536)
        }
    }

    func testReservedSpaceShrinksPart1() throws {
        let bytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
        let plain = try VentoyLayoutCalculator.gpt(totalBytes: bytes)
        let reserved = try VentoyLayoutCalculator.gpt(totalBytes: bytes, reservedMiB: 2_048)
        XCTAssertEqual(plain.part2Sectors, reserved.part2Sectors)
        // 4 KiB alignment may shift each boundary by up to 7 sectors.
        let delta = Int(plain.part1Sectors) - Int(reserved.part1Sectors)
        XCTAssertLessThanOrEqual(abs(delta - 2_048 * 2_048), 7)
    }

    func testClusterSizeThreshold() throws {
        let small = try VentoyLayoutCalculator.gpt(totalBytes: 16 * 1_024 * 1_024 * 1_024)
        let large = try VentoyLayoutCalculator.gpt(totalBytes: 64 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(small.exFATClusterSectors, 64)    // 32 KiB
        XCTAssertEqual(large.exFATClusterSectors, 256)   // 128 KiB
    }

    func testRejectsTinyDisk() {
        XCTAssertThrowsError(try VentoyLayoutCalculator.gpt(totalBytes: 32 * 1_024 * 1_024)) { error in
            XCTAssertEqual(error as? VentoyLayoutError, .diskTooSmall(minimumBytes: (2_048 + 65_536 + 34 + 2_048) * 512))
        }
    }

    func testRejects4KnDevice() {
        XCTAssertThrowsError(try VentoyLayoutCalculator.gpt(totalBytes: 64 * 1_024 * 1_024 * 1_024,
                                                           deviceSectorSize: 4_096)) { error in
            XCTAssertEqual(error as? VentoyLayoutError, .sectorSizeMismatch)
        }
    }

    func testRejectsExcessiveReservedSpace() {
        XCTAssertThrowsError(try VentoyLayoutCalculator.gpt(totalBytes: 8 * 1_024 * 1_024 * 1_024,
                                                           reservedMiB: 9_000)) { error in
            XCTAssertEqual(error as? VentoyLayoutError, .invalidReservedSpace)
        }
    }
}

final class InstallScriptTests: XCTestCase {

    private func fixture() throws -> InstallPlan {
        let device = DiskDevice(
            bsdName: "disk9",
            deviceNode: "/dev/disk9",
            mediaName: "Test USB",
            busProtocol: "USB",
            totalBytes: 32 * 1_024 * 1_024 * 1_024,
            isWholeDisk: true,
            isInternal: false,
            isRemovable: true,
            isEjectable: true,
            isVirtual: false,
            content: "GUID_partition_scheme",
            volumeNames: [],
            deviceBlockSize: 512
        )
        let dir = NSTemporaryDirectory() + "vtoymac-tests"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Real sizes observed in ventoy-1.1.18-linux.tar.gz.
        for (name, size) in [("boot.img", 512),
                             ("core.img", Int(VentoySpec.coreImagePackagedBytes)),
                             ("ventoy.disk.img", Int(VentoySpec.efiBytes))] {
            let path = dir + "/" + name
            let existing = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.intValue ?? -1
            if existing != size {
                try? FileManager.default.removeItem(atPath: path)
                FileManager.default.createFile(atPath: path, contents: Data(count: size))
            }
        }
        let assets = BootAssets(version: "1.1.18", directory: dir)
        let layout = try VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes)
        return InstallPlan(device: device, layout: layout, assets: assets, mode: .audit)
    }

    func testAuditScriptContainsOfficialOffsets() throws {
        let script = try InstallScriptBuilder.build(fixture())
        XCTAssertEqual(script.mode, .audit)
        XCTAssertTrue(script.text.contains("set -euo pipefail"))
        XCTAssertTrue(script.text.contains("diskutil partitionDisk"))
        XCTAssertTrue(script.text.contains("Free Space"))
        XCTAssertTrue(script.text.contains("65536S"))
        XCTAssertFalse(script.text.contains("gpt create -f"), "gpt 写命令已被 SIP 封锁，不得出现在脚本中")
        XCTAssertTrue(script.text.contains(VentoySpec.basicDataGUID))
        XCTAssertTrue(script.text.contains(VentoySpec.efiSystemGUID))
        XCTAssertTrue(script.text.contains("vtoy_raw_write \"$VTOY_STAGE/core.bin\" 2014 34"),
                      "core.img 应写入 LBA 34 共 2014 扇区")
        XCTAssertTrue(script.text.contains("count=2014"))
        XCTAssertTrue(script.text.contains("seek=92"))
        XCTAssertTrue(script.text.contains("17908"))
        XCTAssertTrue(script.text.contains("seek=384"))
        XCTAssertTrue(script.text.contains("seek=440"))
        XCTAssertTrue(script.text.contains("newfs_exfat"))
        XCTAssertTrue(script.text.contains("Internal raw"))
    }

    /// Regression for the on-device `dd: /dev/rdiskN: Invalid argument` (EINVAL)
    /// failure. macOS raw devices force 512-byte aligned size AND offset, so
    /// the official Linux `bs=64 count=512` / `bs=1 seek=92` commands cannot
    /// be used verbatim. Every write whose `of=` is a /dev node must use
    /// `bs=512`; sub-sector patches live in $VTOY_STAGE regular files.
    func testEveryRawDiskWriteIsSectorAligned() throws {
        var plan = try fixture()
        plan = InstallPlan(device: plan.device, layout: plan.layout, assets: plan.assets, mode: .live)
        let script = try InstallScriptBuilder.build(plan)
        // Whole-disk writes go through the vtoy_raw_write helper defined in
        // the script header, so scan script.text rather than step commands.
        let rawWrites = script.text
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("/bin/dd") &&
                     ($0.contains("of='/dev/disk") || $0.contains("of='/dev/rdisk")) }
        XCTAssertFalse(rawWrites.isEmpty, "应当存在裸设备写入命令")
        for line in rawWrites {
            XCTAssertTrue(line.contains("bs=512"), "非 512 字节对齐写入：\(line)")
            XCTAssertTrue(line.contains("conv=notrunc"), "缺少 conv=notrunc：\(line)")
            XCTAssertFalse(line.contains("bs=1 ") || line.contains("bs=64 "),
                           "残留非对齐块大小：\(line)")
        }
        XCTAssertFalse(script.text.contains("bs=64 count=512"))
    }

    func testGeneratedScriptCarriesBuildStamp() throws {
        let script = try InstallScriptBuilder.build(fixture())
        XCTAssertTrue(script.text.contains(VentoyBuild.id),
                      "脚本头必须携带构建标识，便于定位旧进程产生的日志")
        XCTAssertTrue(script.text.contains(VentoyBuild.banner),
                      "脚本第一行输出必须打印构建标识")
        XCTAssertFalse(VentoyBuild.isStaleAgainstBundle(Bundle(for: type(of: self))),
                       "测试进程不应被判为旧进程")
    }

    /// Regression for `gpt create: operation not permitted: create` with SIP
    /// enabled and uid=0 / ruid=0. `/usr/sbin/gpt` carries
    /// `com.apple.rootless.restricted-block-devices`, so ALL of its write
    /// subcommands are rejected at command dispatch regardless of identity,
    /// target device, or Full Disk Access. The partition map must come from
    /// the entitled `diskutil partitionDisk -noEFI`; the actual VTOYEFI LBA is
    /// still read back at runtime as a defensive check (older macOS / other
    /// capacities may align partition 1 differently).
    func testLiveScriptUsesDiskUtilPartitionChannel() throws {
        var plan = try fixture()
        plan = InstallPlan(device: plan.device, layout: plan.layout, assets: plan.assets, mode: .live)
        let live = try InstallScriptBuilder.build(plan)
        let audit = try InstallScriptBuilder.build(fixture())

        XCTAssertTrue(live.text.contains("VTOY_EUID"), "实时脚本需要 root 有效 uid 门禁")
        XCTAssertTrue(live.text.contains("身份：有效 uid="), "应打印有效/真实 uid")
        XCTAssertFalse(live.text.contains("os.setuid(0)"), "不再需要真实 uid 自举（已移除 gpt 写命令）")
        XCTAssertFalse(audit.text.contains("os.setuid(0)"), "审计脚本不得做身份自举")
        for forbidden in ["gpt create -f", "/usr/sbin/gpt add", "/usr/sbin/gpt label",
                          "/usr/sbin/gpt destroy", "gpt-capability.img"] {
            XCTAssertFalse(live.text.contains(forbidden), "残留被 SIP 封锁的命令：\(forbidden)")
        }

        guard let partStep = live.steps.first(where: { $0.title.contains("重建 GPT") }) else {
            return XCTFail("缺少重建 GPT 步骤")
        }
        XCTAssertTrue(partStep.command.contains("/usr/sbin/diskutil partitionDisk"),
                      "重建 GPT 步骤必须由 diskutil partitionDisk 完成")
        XCTAssertTrue(partStep.command.contains("-noEFI"),
                      "必须用 -noEFI 关掉 diskutil 自动插入的 200 MiB EFI 分区（否则 -5344）")
        XCTAssertTrue(partStep.command.contains("4 GPT"),
                      "4 个条目：前导空隙 + Ventoy + VTOYEFI + 尾部空隙")
        XCTAssertTrue(partStep.command.contains("'gap' 2048S"),
                      "前导 2048S 空隙把 part1 顶回官方 LBA 2048")
        XCTAssertTrue(partStep.command.contains(VentoySpec.efiSystemGUID), "分区 2 必须是 EFI System 类型")
        XCTAssertTrue(partStep.command.contains(VentoySpec.basicDataGUID), "分区 1 必须是 Basic Data 类型")
        XCTAssertTrue(partStep.command.contains("Free Space"), "必须有 Free Space 收尾以固定 part2 大小")
        XCTAssertTrue(partStep.command.contains("65536S"), "part2 必须精确请求 65536 扇区")
        XCTAssertFalse(partStep.command.contains("/bin/dd"),
                       "分区命令之前不得用 dd 改写磁盘，避免半写入状态")
        XCTAssertTrue(live.text.contains("VTOY_P1_OFFSET"),
                      "运行时必须断言分区 1 起始 LBA，防止 core.img 覆盖数据区")
        let idx = live.steps.firstIndex { $0.id == partStep.id }!
        XCTAssertTrue(live.steps[idx - 1].title.contains("权限预检"),
                      "权限预检必须紧邻在首个写入步骤之前")
        XCTAssertTrue(live.text.contains("PartitionMapPartitionOffset"),
                      "运行时必须回读实际 VTOYEFI 分区 LBA")
        XCTAssertTrue(live.text.contains("$VTOY_PART2_LBA") && live.text.contains("vtoy_raw_write"),
                      "VTOYEFI 镜像写入必须使用运行时 LBA")
        XCTAssertTrue(live.text.contains("gpt -r show -l"),
                      "仅保留只读 gpt show 作为布局报告")
    }

    func testSubSectorPatchesAreStagedInRegularFiles() throws {
        let script = try InstallScriptBuilder.build(fixture())
        XCTAssertTrue(script.text.contains("VTOY_STAGE=\"$(/usr/bin/mktemp -d -t vtoymac-stage)\""))
        XCTAssertTrue(script.text.contains("trap cleanup_stage EXIT"))
        XCTAssertTrue(script.text.contains("$VTOY_STAGE/mbr.bin"))
        XCTAssertTrue(script.text.contains("$VTOY_STAGE/core.bin"))
        // 17908 = LBA 34 * 512 + 500 → patch offset 500 in the staged core image.
        XCTAssertTrue(script.text.contains("seek=500"))
        XCTAssertTrue(script.text.contains("xxd -s 92 -l 1 -p"))
        XCTAssertTrue(script.text.contains("xxd -s 500 -l 1 -p"))
        XCTAssertTrue(script.text.contains("0xEE 保护 MBR"), "覆盖引导代码前应校验保护 MBR")
        XCTAssertTrue(script.text.contains("seek=384") && script.text.contains("seek=440"))
    }

    func testRawWritePreflightRunsBeforeAnyDestructiveCommand() throws {
        let script = try InstallScriptBuilder.build(fixture())
        let steps = script.steps
        guard let unmount = steps.firstIndex(where: { $0.title.contains("卸载目标磁盘") }),
              let preflight = steps.firstIndex(where: { $0.title.contains("权限预检") }),
              let wipe = steps.firstIndex(where: { $0.title.contains("重建 GPT") }) else {
            return XCTFail("缺少卸载 / 权限预检 / 重建 GPT 步骤")
        }
        XCTAssertLessThan(unmount, preflight)
        XCTAssertLessThan(preflight, wipe)
        XCTAssertTrue(steps[wipe].command.contains("diskutil partitionDisk"),
                      "首个写入动作必须由 diskutil 完成")
        XCTAssertFalse(steps[preflight].isDestructive)
        let probe = steps[preflight].command
        XCTAssertTrue(probe.contains("count=0 conv=notrunc"))
        XCTAssertTrue(probe.contains("bs=512 count=1"), "预检应验证扇区对齐读")
        XCTAssertTrue(probe.contains("id -u"))
        XCTAssertTrue(probe.contains("完全磁盘访问"))
        XCTAssertTrue(probe.contains("未对磁盘做任何修改"))
    }

    func testLiveScriptDoesNotPrintCommands() throws {
        var plan = try fixture()
        plan = InstallPlan(device: plan.device, layout: plan.layout, assets: plan.assets, mode: .live)
        let script = try InstallScriptBuilder.build(plan)
        XCTAssertFalse(script.text.contains("printf '    $ %s"))
        XCTAssertTrue(script.text.contains("/bin/dd if="))
    }

    func testInternalDiskIsRejected() throws {
        var plan = try fixture()
        let systemDisk = DiskDevice(
            bsdName: "disk0", deviceNode: "/dev/disk0", mediaName: "APPLE SSD",
            busProtocol: "Apple Fabric", totalBytes: 512 * 1_024 * 1_024 * 1_024,
            isWholeDisk: true, isInternal: true, isRemovable: false, isEjectable: false,
            isVirtual: false, content: "GUID_partition_scheme", volumeNames: [], deviceBlockSize: 512
        )
        plan = InstallPlan(device: systemDisk, layout: plan.layout, assets: plan.assets)
        XCTAssertThrowsError(try InstallScriptBuilder.build(plan)) { error in
            guard case InstallPlanError.ineligibleDevice = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testShellQuoting() {
        XCTAssertEqual(ShellQuote.bash("a b'c"), "'a b'\\''c'")
        XCTAssertEqual(ShellQuote.appleScript("say \"hi\""), "say \\\"hi\\\"")
    }
}

final class BootAssetTests: XCTestCase {

    private func makeFixture(coreBytes: Int64, efiBytes: Int64 = 33_554_432) throws -> BootAssets {
        let dir = NSTemporaryDirectory() + "vtoymac-assets-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, size) in [("boot.img", Int64(512)),
                             ("core.img", coreBytes),
                             ("ventoy.disk.img", efiBytes)] {
            FileManager.default.createFile(atPath: dir + "/" + name,
                                           contents: Data(count: Int(size)))
        }
        return BootAssets(version: "1.1.18", directory: dir)
    }

    /// Regression: the official core.img is 2047 sectors, not the 2014 sectors
    /// that GPT installs actually write. An earlier build rejected the genuine
    /// package because it used the write count as the validation upper bound.
    func testOfficialImageSizesPassValidation() throws {
        let assets = try makeFixture(coreBytes: Int64(VentoySpec.coreImagePackagedBytes))
        XCTAssertTrue(assets.isComplete)
        XCTAssertTrue(assets.validationIssues.isEmpty, assets.validationIssues.joined(separator: "; "))
        XCTAssertEqual(VentoySpec.coreImagePackagedBytes, 2_047 * 512)
    }

    func testOversizedCoreImageIsRejected() throws {
        let assets = try makeFixture(coreBytes: 2_048 * 512)
        XCTAssertFalse(assets.validationIssues.isEmpty)
    }

    func testTruncatedCoreImageIsRejected() throws {
        let assets = try makeFixture(coreBytes: 2_013 * 512)
        XCTAssertFalse(assets.validationIssues.isEmpty)
    }

    func testWrongEFIImageSizeIsRejected() throws {
        let assets = try makeFixture(coreBytes: 2_047 * 512, efiBytes: 16 * 1_024 * 1_024)
        XCTAssertFalse(assets.validationIssues.isEmpty)
    }

    func testSHA256MatchesKnownVector() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "vtoymac-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try BootAssetInstaller.sha256(url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testVersionFromFilename() {
        XCTAssertEqual(BootAssetInstaller.versionFromFilename("ventoy-1.1.18-linux.tar.gz"), "1.1.18")
    }

    func testInstallerRejectsMismatchedChecksum() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "vtoymac-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pkg = root.appendingPathComponent("ventoy-9.9.9-linux.tar.gz")
        try Data([0x00]).write(to: pkg)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try BootAssetInstaller.install(package: pkg,
                                                            cacheDirectory: root,
                                                            expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case AssetImportError.checksumMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    /// End-to-end: build a synthetic official-style archive (xz payloads made
    /// with the same Python lzma the installer reads) and install it offline.
    func testInstallerEndToEndWithSyntheticRelease() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "vtoymac-e2e-\(UUID().uuidString)")
        let tree = root.appendingPathComponent("ventoy-1.1.18")
        let boot = tree.appendingPathComponent("boot")
        let ventoy = tree.appendingPathComponent("ventoy")
        try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ventoy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(count: 512).write(to: boot.appendingPathComponent("boot.img"))
        try Data("1.1.18".utf8).write(to: ventoy.appendingPathComponent("version"))
        for (name, bytes) in [("core.img.xz", Int(VentoySpec.coreImagePackagedBytes)),
                              ("ventoy.disk.img.xz", Int(VentoySpec.efiBytes))] {
            let plain = root.appendingPathComponent(name + ".bin")
            FileManager.default.createFile(atPath: plain.path, contents: Data(count: bytes))
            let script = "import lzma,shutil,sys\nwith open(sys.argv[1],'rb') as i, lzma.open(sys.argv[2],'wb') as o: shutil.copyfileobj(i,o,1048576)\n"
            let target = name == "core.img.xz" ? boot.appendingPathComponent(name) : ventoy.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", script, plain.path, target.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        let package = root.appendingPathComponent("ventoy-1.1.18-linux.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", package.path, "-C", root.path, "ventoy-1.1.18"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let cache = root.appendingPathComponent("cache")
        let expected = try BootAssetInstaller.sha256(package)
        let result = try BootAssetInstaller.install(package: package,
                                                    cacheDirectory: cache,
                                                    expectedSHA256: expected)
        XCTAssertEqual(result.version, "1.1.18")
        XCTAssertEqual(result.sourceSHA256, expected)
        XCTAssertTrue(result.validationIssues.isEmpty)
        XCTAssertEqual(BootAssetInstaller.loadCached(from: cache)?.version, "1.1.18")
        for file in result.requiredFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file))
        }
    }
}

final class DiskAccessProbeTests: XCTestCase {

    func testProbeIsZeroByteAndCoversBothNodes() {
        let script = DiskAccessProbe.script(bsdName: "disk7")
        XCTAssertTrue(script.contains("/dev/disk7"))
        XCTAssertTrue(script.contains("/dev/rdisk7"))
        XCTAssertTrue(script.contains("count=0 conv=notrunc"))
        XCTAssertTrue(script.contains("bs=512 count=1"), "探针应验证 512 字节对齐读")
        XCTAssertTrue(script.contains("PROBE_UNALIGNED"))
        XCTAssertTrue(script.contains("PROBE_RESULT: OK"))
        XCTAssertTrue(script.contains("PROBE_IDENTITY"), "探针应打印有效/真实 uid")
        XCTAssertTrue(script.contains("PROBE_DISKUTIL_OK"), "探针应验证 diskutil 分区通道")
        XCTAssertTrue(script.contains("PROBE_NOEFI_OK"), "探针应验证 -noEFI 开关存在")
        XCTAssertTrue(script.contains("PROBE_PARTITION_CHANNEL"), "探针应声明分区通道")
        XCTAssertFalse(script.contains("gpt create -f"),
                       "探针不得再调用被 SIP 封锁的 gpt 写命令")
        XCTAssertFalse(script.contains("if=/dev/zero of='/dev/"),
                       "探针不得向任何磁盘节点写入数据")
    }

    func testOperatorGroupDetection() {
        XCTAssertTrue(DiskAccessProbe.isOperator("staff everyone operator admin"))
        XCTAssertFalse(DiskAccessProbe.isOperator("staff everyone _lpoperator admin"))
        XCTAssertFalse(DiskAccessProbe.isOperator(""))
    }

    func testGroupSetupOnlyChangesMembership() {
        let script = DiskAccessProbe.groupSetupScript(user: "daijh")
        XCTAssertTrue(script.contains("dseditgroup -o edit -a 'daijh' -t user operator"))
        XCTAssertTrue(script.contains("dseditgroup -o checkmember"))
        XCTAssertFalse(script.contains("/dev/disk"), "设置脚本不得触碰磁盘")
    }
}

// MARK: - FAT16 / Secure Boot

/// Hand-built FAT16 image (512 B/sector, 1 sector/cluster, 512 root entries)
/// shaped like the official VTOYEFI partition:
///
///   /EFI/BOOT/BOOTX64.EFI    8.3 name
///   /EFI/BOOT/mmx64.efi      8.3 name
///   /EFI/BOOT/grubx64.efi    8.3 name
///   /ENROLL_THIS_KEY_IN_MOKMANAGER.cer   long name (LFN) + 8.3 alias
///
/// Clusters: 2 = \EFI, 3 = \EFI\BOOT, 4/5 = loader files, 6-8 = certificate.
struct FAT16Fixture {
    static let sector = 512
    static let reserved = 1
    static let fatSize = 32
    static let rootEntries = 512
    static let totalSectors = 8_192

    static var dataOffset: Int { (reserved + fatSize + rootEntries * 32 / sector) * sector }

    var certificate = Data(repeating: 0xA5, count: 1_420)
    var includeMokManager = true
    var includeShim = true
    var includeCertificate = true

    func render() -> Data {
        var image = Data(count: Self.totalSectors * Self.sector)

        // ---- boot sector -------------------------------------------------
        image[0] = 0xEB; image[1] = 0x3C; image[2] = 0x90
        put(Array("MSDOS5.0".utf8), at: 3, in: &image)
        put16(UInt16(Self.sector), at: 11, in: &image)
        image[13] = 1                                     // sectors per cluster
        put16(UInt16(Self.reserved), at: 14, in: &image)
        image[16] = 1                                     // number of FATs
        put16(UInt16(Self.rootEntries), at: 17, in: &image)
        put16(0, at: 19, in: &image)                      // total sectors 16
        image[21] = 0xF8
        put16(UInt16(Self.fatSize), at: 22, in: &image)
        put32(UInt32(Self.totalSectors), at: 32, in: &image)
        image[38] = 0x29
        put(Array("VTOYEFI    ".utf8), at: 43, in: &image)
        put(Array("FAT16   ".utf8), at: 54, in: &image)
        image[510] = 0x55; image[511] = 0xAA

        // ---- FAT ---------------------------------------------------------
        let fatOffset = Self.reserved * Self.sector
        func setFat(_ cluster: Int, _ value: UInt16) {
            put16(value, at: fatOffset + cluster * 2, in: &image)
        }
        setFat(0, 0xFFF8)
        setFat(1, 0xFFFF)
        setFat(2, 0xFFFF)          // \EFI, one cluster
        setFat(3, 0xFFFF)          // \EFI\BOOT, one cluster
        setFat(4, 0xFFFF)          // BOOTX64.EFI
        setFat(5, 0xFFFF)          // mmx64.efi
        setFat(6, 0xFFFF)          // grubx64.efi
        setFat(7, 8)               // certificate: 7 -> 8 -> 9
        setFat(8, 9)
        setFat(9, 0xFFFF)

        // ---- directories -------------------------------------------------
        var root = Data()
        root.append(Self.entry(short: "EFI     ", ext: "   ", attr: 0x10, cluster: 2, size: 0))
        if includeCertificate {
            for fragment in Self.longNameEntries("ENROLL_THIS_KEY_IN_MOKMANAGER.cer",
                                                 short: "ENROLL~1CER") {
                root.append(fragment)
            }
            root.append(Self.entry(short: "ENROLL~1", ext: "CER", attr: 0x20, cluster: 7,
                                   size: UInt32(certificate.count)))
        }
        let rootOffset = (Self.reserved + Self.fatSize) * Self.sector
        put(Array(root), at: rootOffset, in: &image)

        var efi = Data()
        efi.append(Self.entry(short: ".       ", ext: "   ", attr: 0x10, cluster: 2, size: 0))
        efi.append(Self.entry(short: "..      ", ext: "   ", attr: 0x10, cluster: 0, size: 0))
        efi.append(Self.entry(short: "BOOT    ", ext: "   ", attr: 0x10, cluster: 3, size: 0))
        put(Array(efi), at: clusterOffset(2), in: &image)

        var boot = Data()
        boot.append(Self.entry(short: ".       ", ext: "   ", attr: 0x10, cluster: 2, size: 0))
        boot.append(Self.entry(short: "..      ", ext: "   ", attr: 0x10, cluster: 2, size: 0))
        if includeShim {
            boot.append(Self.entry(short: "BOOTX64 ", ext: "EFI", attr: 0x20, cluster: 4, size: 4))
        }
        if includeMokManager {
            boot.append(Self.entry(short: "MMX64   ", ext: "EFI", attr: 0x20, cluster: 5, size: 4))
        }
        boot.append(Self.entry(short: "GRUBX64 ", ext: "EFI", attr: 0x20, cluster: 6, size: 4))
        put(Array(boot), at: clusterOffset(3), in: &image)

        // ---- file contents ----------------------------------------------
        put(Array("SHIM".utf8), at: clusterOffset(4), in: &image)
        put(Array("MOKM".utf8), at: clusterOffset(5), in: &image)
        put(Array("GRUB".utf8), at: clusterOffset(6), in: &image)
        if includeCertificate {
            for (index, cluster) in [7, 8, 9].enumerated() {
                let start = index * Self.sector
                let end = min(start + Self.sector, certificate.count)
                guard start < end else { break }
                put(Array(certificate[start..<end]), at: clusterOffset(cluster), in: &image)
            }
        }
        return image
    }

    private func clusterOffset(_ cluster: Int) -> Int {
        Self.dataOffset + (cluster - 2) * Self.sector
    }

    private func put(_ bytes: [UInt8], at offset: Int, in image: inout Data) {
        guard offset + bytes.count <= image.count else { return }
        image.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private func put16(_ value: UInt16, at offset: Int, in image: inout Data) {
        put([UInt8(value & 0xFF), UInt8(value >> 8)], at: offset, in: &image)
    }

    private func put32(_ value: UInt32, at offset: Int, in image: inout Data) {
        put([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
             UInt8((value >> 16) & 0xFF), UInt8(value >> 24)], at: offset, in: &image)
    }

    static func entry(short: String, ext: String, attr: UInt8, cluster: UInt32, size: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0x20, count: 32)
        let nameBytes = Array((short + ext).utf8)
        for (index, byte) in nameBytes.enumerated() where index < 11 { bytes[index] = byte }
        bytes[11] = attr
        bytes[20] = UInt8((cluster >> 16) & 0xFF)
        bytes[21] = UInt8((cluster >> 24) & 0xFF)
        bytes[26] = UInt8(cluster & 0xFF)
        bytes[27] = UInt8((cluster >> 8) & 0xFF)
        bytes[28] = UInt8(size & 0xFF)
        bytes[29] = UInt8((size >> 8) & 0xFF)
        bytes[30] = UInt8((size >> 16) & 0xFF)
        bytes[31] = UInt8(size >> 24)
        return Data(bytes)
    }

    /// Long-file-name fragments, written back-to-front as Windows does.
    static func longNameEntries(_ name: String, short: String) -> [Data] {
        let units = Array(name.utf16)
        let count = (units.count + 12) / 13
        let checksum = shortNameChecksum(short)
        var entries: [Data] = []
        for sequence in stride(from: count, through: 1, by: -1) {
            var bytes = [UInt8](repeating: 0xFF, count: 32)
            bytes[0] = UInt8(sequence) | (sequence == count ? 0x40 : 0)
            bytes[11] = 0x0F
            bytes[12] = 0
            bytes[13] = checksum
            bytes[26] = 0
            bytes[27] = 0
            let start = (sequence - 1) * 13
            let slots = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
            for offset in 0..<13 {
                let index = start + offset
                let value: UInt16 = index < units.count ? units[index]
                    : (index == units.count ? 0x0000 : 0xFFFF)
                bytes[slots[offset]] = UInt8(value & 0xFF)
                bytes[slots[offset] + 1] = UInt8(value >> 8)
            }
            entries.append(Data(bytes))
        }
        return entries
    }

    static func shortNameChecksum(_ short: String) -> UInt8 {
        var sum: UInt8 = 0
        for byte in Array(short.utf8) {
            sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte
        }
        return sum
    }
}

final class FAT16VolumeTests: XCTestCase {

    func testParsesNestedDirectoriesAndLongNames() throws {
        let volume = try FAT16Volume(data: FAT16Fixture().render())
        XCTAssertEqual(volume.bytesPerSector, 512)
        XCTAssertEqual(volume.sectorsPerCluster, 1)
        XCTAssertGreaterThanOrEqual(volume.clusterCount, 4_085)

        let shim = try XCTUnwrap(try volume.entry(at: "EFI/BOOT/BOOTX64.EFI"))
        XCTAssertEqual(shim.size, 4)
        XCTAssertEqual(try volume.data(of: shim), Data("SHIM".utf8))

        // Path lookup is case-insensitive, like the firmware's FAT driver.
        XCTAssertNotNil(try volume.entry(at: "efi/boot/mmx64.efi"))

        // Long name from LFN fragments; the 8.3 alias is ENROLL~1.CER.
        let cert = try XCTUnwrap(try volume.entry(at: "ENROLL_THIS_KEY_IN_MOKMANAGER.cer"))
        XCTAssertEqual(cert.size, 1_420)
        XCTAssertEqual(try volume.data(of: cert), FAT16Fixture().certificate)
    }

    func testMissingPathReturnsNil() throws {
        let volume = try FAT16Volume(data: FAT16Fixture().render())
        XCTAssertNil(try volume.entry(at: "EFI/BOOT/nope.efi"))
        XCTAssertFalse(try volume.exists("EFI/NOPE"))
    }

    func testRejectsNonFAT16Images() {
        XCTAssertThrowsError(try FAT16Volume(data: Data(count: 512)))
        XCTAssertThrowsError(try FAT16Volume(data: Data(count: 64))) { error in
            XCTAssertEqual(error as? FAT16Volume.ParseError, .truncated)
        }
    }
}

final class SecureBootInspectorTests: XCTestCase {

    func testCompleteImageReportsEveryComponent() throws {
        let fixture = FAT16Fixture()
        let inspection = SecureBootInspector.inspect(imageData: fixture.render())
        XCTAssertEqual(inspection.status, .complete, inspection.summary)
        XCTAssertTrue(inspection.missing.isEmpty)
        XCTAssertEqual(inspection.certificateSize, 1_420)

        let expected = try BootAssetInstaller.sha256(
            URL(fileURLWithPath: writeTemporary(fixture.certificate)))
        XCTAssertEqual(inspection.certificateSHA256, expected, "证书指纹必须与文件字节的 SHA-256 一致")
        XCTAssertTrue(inspection.isPinnable)
    }

    func testMissingMokManagerIsIncomplete() {
        var fixture = FAT16Fixture()
        fixture.includeMokManager = false
        let inspection = SecureBootInspector.inspect(imageData: fixture.render())
        XCTAssertEqual(inspection.status, .incomplete)
        XCTAssertTrue(inspection.missing.contains { $0.contains("mmx64.efi") },
                      "缺少 MokManager 必须被识别（否则 0x1a 会变成死路）：\(inspection.missing)")
    }

    func testMissingCertificateIsIncomplete() {
        var fixture = FAT16Fixture()
        fixture.includeCertificate = false
        let inspection = SecureBootInspector.inspect(imageData: fixture.render())
        XCTAssertEqual(inspection.status, .incomplete)
        XCTAssertNil(inspection.certificateSHA256)
        XCTAssertFalse(inspection.isPinnable)
    }

    func testUnparseableImageIsUnavailableNotFatal() {
        // The CLI/GUI fixtures use a zero-filled 32 MiB placeholder: the
        // inspector must report `unavailable`, never a false "complete".
        let inspection = SecureBootInspector.inspect(imageData: Data(count: 33_554_432))
        guard case .unavailable = inspection.status else {
            return XCTFail("应报告 unavailable，实际 \(inspection.status)")
        }
        XCTAssertFalse(inspection.isComplete)
    }

    private func writeTemporary(_ data: Data) -> String {
        let path = NSTemporaryDirectory() + "vtoy-cert-\(UUID().uuidString).cer"
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }
}

final class SecureBootScriptTests: XCTestCase {

    private func makePlan(secureBoot: SecureBootOptions,
                          inspection: SecureBootInspection? = nil,
                          mode: ScriptMode = .audit) throws -> InstallPlan {
        let device = DiskDevice(
            bsdName: "disk9", deviceNode: "/dev/disk9", mediaName: "Test USB",
            busProtocol: "USB", totalBytes: 32 * 1_024 * 1_024 * 1_024,
            isWholeDisk: true, isInternal: false, isRemovable: true, isEjectable: true,
            isVirtual: false, content: "GUID_partition_scheme", volumeNames: [],
            deviceBlockSize: 512)
        let dir = NSTemporaryDirectory() + "vtoymac-sb-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, size) in [("boot.img", 512),
                             ("core.img", Int(VentoySpec.coreImagePackagedBytes)),
                             ("ventoy.disk.img", Int(VentoySpec.efiBytes))] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data(count: size))
        }
        let assets = BootAssets(version: "1.1.18", directory: dir)
        let layout = try VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes)
        return InstallPlan(device: device, layout: layout, assets: assets, mode: mode,
                           secureBoot: secureBoot, secureBootInspection: inspection)
    }

    func testDisabledProducesNoSecureBootWork() throws {
        let script = try InstallScriptBuilder.build(makePlan(secureBoot: SecureBootOptions()))
        XCTAssertFalse(script.text.contains("vty_sb_has"))
        XCTAssertFalse(script.text.contains("SecureBoot/"))
        XCTAssertFalse(script.steps.contains { $0.title.contains("Secure Boot") })
        XCTAssertTrue(script.text.contains("SecureBoot: disabled"))
    }

    func testEnabledVerifiesChainReadOnlyAndStagesMaterial() throws {
        let inspection = SecureBootInspector.inspect(imageData: FAT16Fixture().render())
        let script = try InstallScriptBuilder.build(
            makePlan(secureBoot: SecureBootOptions(enabled: true, policy: .strict),
                     inspection: inspection))

        // Authoritative post-write check, mounted read-only so macOS does not
        // litter the boot partition with ._* / .fseventsd files.
        XCTAssertTrue(script.text.contains("diskutil mount readOnly nobrowse"))
        XCTAssertTrue(script.text.contains("vty_sb_has"))
        XCTAssertTrue(script.text.contains("MokManager"))

        // Fingerprint computed before the write is pinned into the script.
        let sha = try XCTUnwrap(inspection.certificateSHA256)
        XCTAssertTrue(script.text.contains(sha), "脚本必须固定写入前算出的证书指纹")

        // Enrollment material lands on the data partition, twice.
        XCTAssertTrue(script.text.contains("\"$MP/\(SecureBootSpec.dataDirectory)/\(SecureBootSpec.certificateName)\""))
        XCTAssertTrue(script.text.contains("\"$MP/\(SecureBootSpec.certificateName)\""))
        XCTAssertTrue(script.text.contains(SecureBootSpec.readmeName))
        XCTAssertTrue(script.text.contains("Enroll key from disk"))

        // Strict policy → global control plugin.
        XCTAssertTrue(script.text.contains("\"VTOY_SECURE_BOOT_POLICY\": \"1\""))

        // Step order: verify after writing VTOYEFI, before formatting part 1.
        let verify = try XCTUnwrap(script.steps.firstIndex { $0.title.contains("Secure Boot 组件") })
        let write = try XCTUnwrap(script.steps.firstIndex { $0.title.contains("写入官方 VTOYEFI") })
        let format = try XCTUnwrap(script.steps.firstIndex { $0.title.contains("exFAT") })
        XCTAssertLessThan(write, verify)
        XCTAssertLessThan(verify, format)
        XCTAssertFalse(script.steps[verify].isDestructive, "只读挂载的校验步骤不应标记为写入")
    }

    func testBypassPolicyDoesNotWritePlugin() throws {
        let script = try InstallScriptBuilder.build(
            makePlan(secureBoot: SecureBootOptions(enabled: true, policy: .bypass)))
        XCTAssertFalse(script.text.contains("\"VTOY_SECURE_BOOT_POLICY\": \"1\""))
        XCTAssertTrue(script.text.contains("完全绕过验证"))
    }

    func testPlanRejectsKnownIncompleteChain() {
        var fixture = FAT16Fixture()
        fixture.includeMokManager = false
        let inspection = SecureBootInspector.inspect(imageData: fixture.render())
        XCTAssertThrowsError(try InstallScriptBuilder.build(
            makePlan(secureBoot: SecureBootOptions(enabled: true), inspection: inspection))) { error in
            guard case InstallPlanError.secureBootIncomplete = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPlanToleratesUnknownImageWhenSecureBootDisabled() throws {
        // Zero-filled placeholder → inspector reports `unavailable`; that must
        // not block a normal (Secure Boot disabled) install.
        let inspection = SecureBootInspector.inspect(imageData: Data(count: 33_554_432))
        let script = try InstallScriptBuilder.build(
            makePlan(secureBoot: SecureBootOptions(), inspection: inspection))
        XCTAssertFalse(script.text.contains("vty_sb_has"))
    }
}
