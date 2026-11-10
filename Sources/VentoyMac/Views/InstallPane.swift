import SwiftUI
import VentoyCore

struct InstallPane: View {
    @EnvironmentObject private var state: AppState
    @State private var showScript = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.isStaleBuild { StaleBuildCard() }
                    ReadinessCard()
                    PermissionCard()
                    ConfigurationCard()
                    if let generated = state.generated {
                        PlanCard(script: generated)
                        ScriptPreviewCard(text: generated.text, expanded: $showScript)
                    } else {
                        PlaceholderCard()
                    }
                }
                .padding(16)
            }

            Divider()
            ActionBar()
        }
    }
}

// MARK: - Stale process guard

private struct StaleBuildCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("当前窗口仍是旧进程，生成的安装脚本是旧版")
                    .font(.callout.weight(.semibold))
                Text("应用已在磁盘上重新构建，但 macOS 不会替换正在运行的进程。请完全退出后重新打开 VentoyMac.app，否则写盘会继续执行旧脚本（例如再次出现 Invalid argument）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("本进程编译标识：\(VentoyBuild.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("退出应用") { state.quitApp() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.35)))
    }
}

// MARK: - Readiness

private struct ReadinessCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SectionCard("安装前检查") {
            HStack(spacing: 16) {
                CheckItem(title: "已选择外接磁盘", ok: state.selectedDevice?.isEligible == true,
                          detail: state.selectedDevice.map { "/dev/\($0.bsdName)" } ?? "未选择")
                CheckItem(title: "引导资源就绪", ok: state.assets?.isComplete == true,
                          detail: state.assets.map { "Ventoy \($0.version)" } ?? "未安装")
                CheckItem(title: "分区布局可计算", ok: state.layout != nil,
                          detail: state.layout.map { "LBA \($0.part2Start)" } ?? "—")
            }
        }
    }
}

private struct CheckItem: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - macOS raw-disk permission guidance

private struct PermissionCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SectionCard("完全磁盘访问 · 应用内直接写入",
                    subtitle: "不需要终端。分区表由有权限的 diskutil 建立；/bin/dd 写引导镜像仍受 TCC「完全磁盘访问」约束，由应用内签名 helper 承担写盘进程。") {
            VStack(alignment: .leading, spacing: 4) {
                guide("1", "系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加并启用 VentoyMac.app")
                guide("2", "完全退出 VentoyMac 并重新打开（授权只在进程启动时生效）")
                guide("3", "点「验证磁盘写入权限」——0 字节写打开、512 字节对齐读、diskutil 分区通道检查，不改 U 盘")
                guide("4", "若全部失败：点「给系统提权进程授权」，一次性添加 security_authtrampoline")
                Text("说明：/usr/sbin/gpt 的写命令受 SIP（rootless.restricted-block-devices）封锁，与 uid / FDA 无关，分区表改由 diskutil partitionDisk -noEFI 建立——该开关可阻止系统在大容量磁盘上自动插入 200 MiB EFI 分区（否则报 -5344 空间不足）；把用户加入 operator 组也不能直写裸盘。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    state.openFullDiskAccessSettings()
                } label: {
                    Label("打开「完全磁盘访问」设置", systemImage: "gearshape")
                }
                .controlSize(.small)
                Button {
                    state.revealAppInFinder()
                } label: {
                    Label("在访达中显示应用", systemImage: "folder")
                }
                .controlSize(.small)
                Button {
                    state.authorizeSystemHelper()
                } label: {
                    Label("给系统提权进程授权", systemImage: "lock.shield")
                }
                .controlSize(.small)
                .help("复制 /usr/libexec/security_authtrampoline 路径并打开设置，一次性添加即可")
                Button {
                    state.verifyDiskAccess()
                } label: {
                    Label("验证磁盘写入权限", systemImage: "checkmark.shield")
                }
                .controlSize(.small)
                .disabled(!state.canBuildPlan || state.isBusy)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            statusView

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Picker("执行方式", selection: Binding(
                    get: { state.executionMode },
                    set: { state.setExecutionMode($0) }
                )) {
                    ForEach(InstallExecutionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
                .controlSize(.small)
                Text("「验证磁盘写入权限」会自动选用可用通道；此处可手动覆盖。签名 helper 与应用共用固定代码标识，重新编译不会让 FDA 授权失效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func guide(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 14)
            Text(text)
                .font(.caption)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.diskAccess {
        case .unknown:
            Text("状态：尚未验证。建议先点「验证磁盘写入权限」再做安装。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            Text("状态：正在逐通道验证…（每个通道会弹一次管理员密码框）")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ok:
            Text("✅ 状态：已找到可写裸盘的应用内通道，可直接点「写入磁盘…」。")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .denied(let detail):
            VStack(alignment: .leading, spacing: 2) {
                Text("❌ 状态：所有应用内通道均失败。请点「给系统提权进程授权」添加 security_authtrampoline，然后完全退出并重开应用。")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}

// MARK: - Configuration

private struct ConfigurationCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SectionCard("安装选项", subtitle: "对应官方 Ventoy2Disk.sh 的 -L（卷标）与 -r（保留空间）参数。") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("exFAT 卷标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                TextField("Ventoy", text: $state.volumeLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onChange(of: state.volumeLabel) { _ in state.regeneratePreview() }
                Text("最多 11 个字符")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("保留空间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Picker("", selection: $state.reservedMiB) {
                    Text("不保留").tag(UInt64(0))
                    Text("512 MiB").tag(UInt64(512))
                    Text("1 GiB").tag(UInt64(1_024))
                    Text("2 GiB").tag(UInt64(2_048))
                    Text("4 GiB").tag(UInt64(4_096))
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .onChange(of: state.reservedMiB) { _ in state.regeneratePreview() }
                Text("磁盘末尾预留，可自行建立第 3 分区")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("分区风格")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Text("GPT（Ventoy2Disk.sh -g）")
                    .font(.caption.monospaced())
                Spacer()
            }
        }
    }
}

// MARK: - Plan

private struct PlanCard: View {
    let script: GeneratedScript

    var body: some View {
        SectionCard("安装计划", subtitle: "共 \(script.steps.count) 步 · 当前为审计模式预览，命令不会被执行。") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(script.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(String(format: "%02d", step.id))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)
                        Image(systemName: step.isDestructive ? "internaldrive.fill" : "doc.text")
                            .font(.caption2)
                            .foregroundStyle(step.isDestructive ? Color.orange : Color.secondary)
                            .frame(width: 15)
                        Text(step.title)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.caption2)
                Text("橙色标记为会写入磁盘的步骤；GPT 表、引导代码与 32 MiB EFI 镜像按官方偏移写入。")
                    .font(.caption2)
            }
            .foregroundStyle(.orange)
        }
    }
}

// MARK: - Script preview

private struct ScriptPreviewCard: View {
    let text: String
    @Binding var expanded: Bool

    var body: some View {
        SectionCard("生成的 Bash 脚本", subtitle: "可完整导出审阅；每一行都对应官方安装流程中的一条命令。") {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .frame(height: 230)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
            } label: {
                HStack {
                    Text("展开查看 \(text.split(separator: "\n").count) 行脚本")
                        .font(.caption)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        SectionCard("安装计划") {
            HStack(spacing: 10) {
                Image(systemName: "square.dashed")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("等待前置条件就绪")
                        .font(.callout)
                    Text("插入外接 U 盘、安装官方引导资源后，这里会生成完整的分区与写盘计划。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Button {
                state.refreshPreview()
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
            .disabled(!state.canBuildPlan || state.isBusy)

            Button {
                state.runAudit()
            } label: {
                Label("运行审计演练", systemImage: "play.rectangle")
            }
            .disabled(state.generated == nil || state.isBusy)

            Button {
                state.exportScript()
            } label: {
                Label("导出脚本", systemImage: "square.and.arrow.up")
            }
            .disabled(!state.canBuildPlan || state.isBusy)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("审计演练不会写入任何数据")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(VentoyBuild.id)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Button {
                state.requestInstall()
            } label: {
                Label("写入磁盘…", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!state.canBuildPlan || state.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

// MARK: - Destructive confirmation

struct ConfirmSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("⚠️ 此操作非常危险，可能导致不可逆的数据丢失！")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("请逐字确认目标设备后再继续。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let device = state.selectedDevice {
                VStack(alignment: .leading, spacing: 6) {
                    Text("即将被完全清空的设备")
                        .font(.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 4) {
                        KeyValueRow(key: "设备节点", value: "/dev/\(device.bsdName)", monospaced: true)
                        KeyValueRow(key: "名称", value: device.displayName)
                        KeyValueRow(key: "容量", value: device.sizeDescription)
                        KeyValueRow(key: "现有卷", value: device.volumesDescription)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.red.opacity(0.07)))
                }

                VStack(alignment: .leading, spacing: 7) {
                    bullet("删除磁盘上所有现有分区与分区表")
                    bullet("重建 GPT：exFAT 数据分区 + 32 MiB VTOYEFI")
                    bullet("写入 MBR 引导代码、Legacy BIOS GRUB core 与官方 EFI 镜像")
                    bullet("格式化数据分区并复制 \(state.isoPaths.count) 个镜像文件")
                }

                Toggle("我已备份该 U 盘上的全部数据，并理解数据不可恢复", isOn: $state.acknowledged)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 5) {
                    Text("请输入 \(device.bsdName) 以确认")
                        .font(.caption)
                    TextField(device.bsdName, text: $state.confirmationText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("在终端中写入（备用）") {
                    state.installViaTerminal()
                }
                .disabled(!state.confirmationValid)
                .help("仅在应用内写入失败时使用：需先给终端「完全磁盘访问」，并在终端输入 sudo 密码")
                Button("应用内直接写入") {
                    state.performInstall()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!state.confirmationValid)
                .keyboardShortcut(.defaultAction)
                .help("按当前执行模式在应用内写入，不通过终端")
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
    }
}
