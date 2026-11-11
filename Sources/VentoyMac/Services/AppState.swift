import Foundation
import AppKit
import SwiftUI
import VentoyCore

enum AppTab: String, CaseIterable, Identifiable {
    case install = "安装"
    case images = "镜像"
    case assets = "引导资源"
    case logs = "日志"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .install: return "externaldrive.connected.to.line.below"
        case .images: return "opticaldiscdrive"
        case .assets: return "shippingbox"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

enum InstallExecutionMode: String, CaseIterable, Identifiable {
    /// Root script launched through the in-bundle writer helper, which is
    /// signed with the same designated requirement as the app so TCC's
    /// Full Disk Access grant matches the process that spawns `dd`/`gpt`.
    case helper
    /// Legacy: `security_authtrampoline` execs `/bin/bash` directly. Kept as
    /// a fallback for systems where the helper channel is unavailable.
    case privileged

    var id: String { rawValue }
    var title: String {
        self == .helper ? "签名 helper 提权（推荐）" : "直接提权（兼容模式）"
    }
    var channel: ProcessRunner.PrivilegedChannel {
        self == .helper ? .signedHelper : .directBash
    }
}

enum DiskAccessStatus: Equatable {
    case unknown
    case checking
    case ok
    case denied(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [DiskDevice] = []
    @Published var selectedDeviceID: String?
    @Published var isoPaths: [String] = []
    @Published var volumeLabel = VentoySpec.defaultVolumeLabel
    @Published var reservedMiB: UInt64 = 0
    @Published var logText = ""
    @Published var isBusy = false
    @Published var busyText = ""
    @Published var installProgress: Double = 0
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var generated: GeneratedScript?
    @Published var showInstallConfirm = false
    @Published var confirmationText = ""
    @Published var acknowledged = false
    @Published var selectedTab: AppTab = .install
    @Published var executionMode: InstallExecutionMode = {
        UserDefaults.standard.string(forKey: "VentoyMacExecutionMode") == "privileged"
            ? .privileged : .helper
    }()
    @Published var diskAccess: DiskAccessStatus = .unknown
    /// See `SecureBoot.swift` for why this cannot be a pure on/off switch: the
    /// one-time MokManager enrollment is imposed by the target firmware, not by
    /// the stick. The toggle controls whether the stick carries the verified
    /// shim chain plus ready-to-enroll material.
    @Published var secureBootEnabled: Bool = UserDefaults.standard.bool(forKey: "VentoyMacSecureBootEnabled")
    @Published var secureBootPolicy: SecureBootPolicy = SecureBootPolicy(
        rawValue: UserDefaults.standard.string(forKey: "VentoyMacSecureBootPolicy") ?? "") ?? .bypass
    @Published var secureBootInspection: SecureBootInspection?
    /// True when the .app on disk was rebuilt while this process was already
    /// running. The window then still executes the OLD install script.
    @Published var isStaleBuild = false

    let assetManager = BootAssetManager()

    private let stepRegex = try! NSRegularExpression(pattern: #"==>\s*\[(\d+)/(\d+)\]"#)

    var selectedDevice: DiskDevice? { devices.first { $0.id == selectedDeviceID } }
    var assets: BootAssets? { assetManager.assets }

    var layout: VentoyLayout? {
        guard let device = selectedDevice else { return nil }
        let sectorSize = device.deviceBlockSize > 0 ? device.deviceBlockSize : VentoySpec.sectorSize
        return try? VentoyLayoutCalculator.gpt(totalBytes: device.totalBytes,
                                               deviceSectorSize: sectorSize,
                                               reservedMiB: reservedMiB)
    }

    var canBuildPlan: Bool {
        selectedDevice?.isEligible == true && assets?.isComplete == true && layout != nil
    }

    var confirmationValid: Bool {
        guard let device = selectedDevice else { return false }
        return acknowledged && confirmationText.trimmingCharacters(in: .whitespaces) == device.bsdName
    }

    init() {
        appendLog(VentoyBuild.banner)
        appendLog("VentoyMac 已启动 · macOS arm64 原生构建")
        appendLog("引导资源来自 Ventoy 官方 Release；磁盘布局按 INSTALL/tool/ventoy_lib.sh 复刻。")
        appendLog("提示：Apple Silicon 本机不能从标准 UEFI U 盘启动，本工具用于「制作」启动盘。")
        appendLog("执行模式：\(executionMode.title)。裸盘写入需要 VentoyMac 本身获得「完全磁盘访问」。")
        isStaleBuild = VentoyBuild.isStaleAgainstBundle()
        if isStaleBuild {
            appendLog("⚠️ 应用已在磁盘上重新构建，但当前窗口仍是旧进程：它生成的安装脚本是旧版！")
            appendLog("   请点安装页顶部红色提示中的「退出应用」，再重新打开 VentoyMac.app。")
        }
        if ProcessRunner.helperPath == nil {
            appendLog("⚠️ 未找到应用内的签名 helper，将以兼容模式运行；请用 dist/VentoyMac.app 启动。")
        }
        refreshDevices()
        refreshSecureBootInspection()
    }

    // MARK: Secure Boot

    func setSecureBootEnabled(_ enabled: Bool) {
        guard secureBootEnabled != enabled else { return }
        secureBootEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "VentoyMacSecureBootEnabled")
        appendLog("")
        if enabled {
            appendLog("── 已启用 UEFI Secure Boot 支持 ──")
            appendLog("安装脚本将① 只读挂载 VTOYEFI 校验 shim / MokManager / 证书；② 把证书与中文说明写到数据分区 SecureBoot/。")
            appendLog("注意：首次在新机器上启动仍需在蓝色 MokManager 界面注册一次该证书——信任根在固件里，U 盘无法代替。")
            appendLog("      想彻底免按键：把这枚证书一次性写入该机固件 db（BIOS → Secure Boot → 密钥管理）。")
        } else {
            appendLog("已关闭 Secure Boot 支持选项：脚本不再校验注册材料（U 盘仍含完整 shim 链，固件开启 Secure Boot 时会提示注册）。")
        }
        if enabled && secureBootInspection == nil { refreshSecureBootInspection() }
        regeneratePreview()
    }

    func setSecureBootPolicy(_ policy: SecureBootPolicy) {
        guard secureBootPolicy != policy else { return }
        secureBootPolicy = policy
        UserDefaults.standard.set(policy.rawValue, forKey: "VentoyMacSecureBootPolicy")
        appendLog("Secure Boot 策略：\(policy.title)")
        regeneratePreview()
    }

    /// Parses the cached 32 MiB VTOYEFI image off the main thread. Purely
    /// in-memory: no disk image is attached, so the device list stays clean.
    func refreshSecureBootInspection() {
        guard let assets else {
            secureBootInspection = nil
            return
        }
        let path = assets.efiImage
        let version = assets.version
        Task.detached(priority: .utility) {
            let result: SecureBootInspection
            do {
                result = try SecureBootInspector.inspect(efiImage: URL(fileURLWithPath: path))
            } catch {
                result = SecureBootInspection(status: .unavailable(error.localizedDescription))
            }
            await MainActor.run {
                guard self.assets?.version == version else { return }
                self.secureBootInspection = result
                self.appendLog("Secure Boot 组件检查：\(result.summary)")
                if let fingerprint = result.certificateSHA256 {
                    self.appendLog("  证书 SHA-256：\(fingerprint)")
                }
                for item in result.found { self.appendLog("  · \(item)") }
            }
        }
    }

    // MARK: Disk access (no Terminal required)

    func setExecutionMode(_ mode: InstallExecutionMode) {
        executionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "VentoyMacExecutionMode")
        diskAccess = .unknown
        appendLog("已切换执行模式：\(mode.title)。请重新点「验证磁盘写入权限」。")
    }

    /// Persists a detected working channel without resetting the probe result.
    private func applyMode(_ mode: InstallExecutionMode) {
        executionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "VentoyMacExecutionMode")
    }

    /// Copies the path of the process TCC actually attributes elevated scripts
    /// to, and opens System Settings. Adding this one item is a one-time,
    /// Terminal-free fix when the signed-helper channel is still blocked.
    func authorizeSystemHelper() {
        let path = "/usr/libexec/security_authtrampoline"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        openFullDiskAccessSettings()
        appendLog("")
        appendLog("── 给系统提权进程授权（一次性，不需要终端）──")
        appendLog("已复制路径到剪贴板：\(path)")
        appendLog("在「完全磁盘访问」点 + 后按 Cmd-Shift-G，粘贴该路径 → 选中 → 打开开关。")
        appendLog("然后完全退出 VentoyMac、重新打开，再点「验证磁盘写入权限」。")
        infoMessage = "已复制系统提权进程路径，请在「完全磁盘访问」中添加它。"
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
        appendLog("已打开「完全磁盘访问」设置。请点 + 添加 VentoyMac.app 并打开开关。")
        appendLog("应用位置：\(Bundle.main.bundlePath)")
        appendLog("⚠️ 授权只在进程启动时生效：添加后必须完全退出 VentoyMac 再重新打开。")
    }

    func revealAppInFinder() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: folder.path)
        appendLog("已在访达中显示 VentoyMac.app，可直接拖进「完全磁盘访问」列表。")
    }

    /// Terminate a stale window so the freshly built .app can be relaunched.
    /// A running Mach-O is never replaced in memory when the bundle on disk
    /// changes, so quitting is the only reliable way to pick up new code.
    func quitApp() {
        appendLog("正在退出旧进程，请重新打开 \(Bundle.main.bundlePath)")
        NSApp.terminate(nil)
    }

    /// Probes every elevated channel with a ZERO-byte write-open and keeps the
    /// first one that works. Writes nothing to the disk.
    func verifyDiskAccess() {
        guard let device = selectedDevice else { return }
        let name = device.bsdName
        diskAccess = .checking
        appendLog("")
        appendLog("── 裸盘权限 / 扇区对齐 / diskutil 分区通道自检（0 字节写打开 + 对齐读，不写盘）──")
        appendLog("依次测试：签名 helper 提权 → 直接提权（兼容模式）；每个通道会弹一次系统密码框。")
        runBusy("正在验证裸盘写入权限") {
            var lastError = "未执行"
            for mode in InstallExecutionMode.allCases {
                self.appendLog("· 测试通道：\(mode.title) …")
                do {
                    let log = try await ProcessRunner.probePrivileged(
                        bsdName: name, channel: mode.channel)
                    self.appendLog(log)
                    self.applyMode(mode)
                    self.diskAccess = .ok
                    self.infoMessage = "✅ \(mode.title) 可用：可直接在应用内写入 \(name)。"
                    self.appendLog("✅ 已自动选用：\(mode.title)")
                    return
                } catch {
                    lastError = error.localizedDescription
                    self.appendLog("  ❌ 该通道不可用：\(String(lastError.prefix(160)))")
                }
            }
            self.diskAccess = .denied(lastError)
            self.appendLog("❌ 所有应用内通道均不可用。请点「给系统提权进程授权」做一次性设置。")
            self.selectedTab = .logs
        }
    }

    // MARK: Devices

    func refreshDevices() {
        Task {
            do {
                let found = try await DiskService.externalDisks()
                self.devices = found
                if self.selectedDeviceID == nil || !found.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = found.first(where: { $0.isEligible })?.id
                }
                appendLog("已扫描外部磁盘：\(found.count) 个")
                for disk in found {
                    appendLog("  · \(disk.bsdName)  \(disk.displayName)  \(disk.sizeDescription)  \(disk.isEligible ? "可选" : "已排除：\(disk.rejectionReasons.joined(separator: "、"))")")
                }
                if found.isEmpty {
                    appendLog("  未检测到外接磁盘。请插入 U 盘后点击刷新。")
                }
            } catch {
                fail(error)
            }
        }
    }

    // MARK: Images

    func addImages(_ urls: [URL]) {
        let allowed = Set(["iso", "img", "wim", "vhd", "vhdx", "efi", "vtoy"])
        for url in urls where allowed.contains(url.pathExtension.lowercased()) {
            if !isoPaths.contains(url.path) { isoPaths.append(url.path) }
        }
        regeneratePreview()
    }

    func removeImage(_ path: String) {
        isoPaths.removeAll { $0 == path }
        regeneratePreview()
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择要放入 Ventoy 数据分区的镜像文件"
        // Extensions are validated in addImages(); the panel stays unrestricted
        // so ISO/WIM/IMG/VHD variants with uncommon UTIs remain selectable.
        guard panel.runModal() == .OK else { return }
        addImages(panel.urls)
    }

    // MARK: Assets

    func downloadAssets() {
        runBusy("正在获取官方引导资源") {
            let result = try await self.assetManager.downloadLatest()
            self.infoMessage = "引导资源已就绪：Ventoy \(result.version)"
            self.refreshSecureBootInspection()
            self.regeneratePreview()
        }
    }

    func importAssets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "选择已下载的 ventoy-<版本>-linux.tar.gz"
        // Filename is validated in BootAssetManager.importPackage().
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runBusy("正在导入本地发布包") {
            let result = try await self.assetManager.importPackage(url)
            self.infoMessage = "已从本地包导入 Ventoy \(result.version)"
            self.refreshSecureBootInspection()
            self.regeneratePreview()
        }
    }

    func revealAssetCache() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: assetManager.cacheDirectory)
    }

    // MARK: Plan / preview

    func makePlan(mode: ScriptMode) throws -> InstallPlan {
        guard let device = selectedDevice else {
            throw InstallPlanError.ineligibleDevice(["尚未选择磁盘"])
        }
        guard let assets else {
            throw InstallPlanError.incompleteAssets(["引导资源未安装"])
        }
        guard let layout else {
            throw InstallPlanError.ineligibleDevice(["磁盘容量或扇区大小不符合要求"])
        }
        return InstallPlan(device: device,
                           layout: layout,
                           assets: assets,
                           volumeLabel: volumeLabel,
                           isoPaths: isoPaths,
                           mode: mode,
                           secureBoot: SecureBootOptions(enabled: secureBootEnabled,
                                                         policy: secureBootPolicy),
                           secureBootInspection: secureBootInspection)
    }

    func regeneratePreview() {
        guard canBuildPlan else { generated = nil; return }
        do {
            generated = try InstallScriptBuilder.build(makePlan(mode: .audit))
        } catch {
            generated = nil
            appendLog("生成预览失败：\(error.localizedDescription)")
        }
    }

    func refreshPreview() {
        regeneratePreview()
        infoMessage = "已按当前设置重新生成安装计划"
    }

    func runAudit() {
        guard let generated else { return }
        runBusy("正在执行审计演练（不写盘）") {
            let output = try await ProcessRunner.runScript(generated.text)
            self.appendLog(output)
            self.infoMessage = "审计演练完成：所有命令已核对，未写入任何数据。"
            self.selectedTab = .logs
        }
    }

    func exportScript() {
        guard let device = selectedDevice else { return }
        do {
            let live = try InstallScriptBuilder.build(makePlan(mode: .live))
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "VentoyMac-\(device.bsdName)-install.sh"
            panel.message = "导出可审阅、可手动执行的安装脚本"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try live.text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            appendLog("已导出实时安装脚本：\(url.path)")
            infoMessage = "脚本已导出。请逐条审阅后，在终端用 sudo 执行。"
        } catch {
            fail(error)
        }
    }

    // MARK: Install

    func requestInstall() {
        do {
            _ = try makePlan(mode: .live)
            confirmationText = ""
            acknowledged = false
            showInstallConfirm = true
        } catch {
            fail(error)
        }
    }

    /// Last-resort fallback: run the exported script from an FDA-granted
    /// Terminal.app. Not the default path — VentoyMac writes directly.
    func installViaTerminal() {
        guard confirmationValid, let device = selectedDevice else { return }
        showInstallConfirm = false
        do {
            let plan = try makePlan(mode: .live)
            let script = try InstallScriptBuilder.build(plan)
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let url = dir.appendingPathComponent("VentoyMac-\(device.bsdName)-install.sh")
            try script.text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)

            let command = "sudo bash " + ShellQuote.bash(url.path)
            let appleScript = """
            tell application "Terminal"
              activate
              do script "\(ShellQuote.appleScript(command))"
            end tell
            """

            appendLog("")
            appendLog("────────────────────────────────────────────")
            appendLog("已导出实时脚本：\(url.path)")
            appendLog("将尝试在「终端」中执行：\(command)")
            appendLog("前置条件：系统设置 → 完全磁盘访问 → 启用「终端」，并完全重启终端。")
            appendLog("────────────────────────────────────────────")
            selectedTab = .logs

            Task { @MainActor in
                do {
                    let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", appleScript])
                    if result.status != 0 {
                        throw RunnerError.commandFailed(result.status, result.stderr)
                    }
                    self.infoMessage = "已在终端发起执行，请在终端窗口输入管理员密码。"
                } catch {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    self.appendLog("⚠️ 无法自动唤起终端（\(error.localizedDescription)）。命令已复制到剪贴板，请手动打开终端粘贴执行。")
                    self.infoMessage = "命令已复制到剪贴板，请在终端手动粘贴执行。"
                }
            }
        } catch {
            fail(error)
        }
    }

    func performInstall() {
        guard confirmationValid, let device = selectedDevice else { return }
        showInstallConfirm = false
        let plan: InstallPlan
        let script: GeneratedScript
        do {
            plan = try makePlan(mode: .live)
            script = try InstallScriptBuilder.build(plan)
        } catch {
            fail(error)
            return
        }

        installProgress = 0
        appendLog("")
        appendLog("────────────────────────────────────────────")
        appendLog(VentoyBuild.banner)
        appendLog("开始安装 Ventoy \(plan.assets.version) → /dev/\(device.bsdName)（实时模式）")
        appendLog("执行模式：\(executionMode.title)（不通过终端）")
        appendLog("分区布局：")
        for line in plan.layout.summaryLines { appendLog("  " + line) }
        appendLog("────────────────────────────────────────────")
        selectedTab = .logs

        let mode = executionMode
        runBusy("正在写入 \(device.bsdName)") {
            try await DiskService.revalidate(device)
            self.appendLog("提权通道：\(mode.title)")
            _ = try await ProcessRunner.runPrivileged(script: script.text,
                                                     channel: mode.channel) { chunk in
                Task { @MainActor in
                    self.absorb(chunk)
                }
            }
            self.installProgress = 1
            self.appendLog("")
            self.appendLog("✅ 安装完成。可安全推出 U 盘。")
            self.infoMessage = "Ventoy \(plan.assets.version) 已写入 \(device.displayName)。"
            self.refreshDevices()
        }
    }

    // MARK: Utilities

    func clearLog() { logText = "" }

    func appendLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logText += trimmed + "\n"
        if logText.count > 200_000 {
            logText = String(logText.suffix(150_000))
        }
    }

    private func absorb(_ chunk: String) {
        appendLog(chunk)
        let ns = chunk as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = stepRegex.matches(in: chunk, range: range).last,
           match.numberOfRanges >= 3,
           let current = Double(ns.substring(with: match.range(at: 1))),
           let total = Double(ns.substring(with: match.range(at: 2))),
           total > 0 {
            installProgress = min(current / total, 1)
        }
    }

    private func runBusy(_ title: String, _ operation: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        busyText = title
        errorMessage = nil
        infoMessage = nil
        Task {
            defer {
                self.isBusy = false
                self.busyText = ""
            }
            do {
                try await operation()
            } catch {
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        appendLog("❌ 错误：\(message)")
        selectedTab = .logs
    }
}
