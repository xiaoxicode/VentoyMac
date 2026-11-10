import SwiftUI
import VentoyCore

struct DevicePane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("目标磁盘")
                    .font(.headline)
                Spacer()
                Button {
                    state.refreshDevices()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy)
            }

            Text("只列出外接整盘；内置盘、系统盘与虚拟磁盘一律排除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    if state.devices.isEmpty {
                        EmptyDeviceHint()
                    } else {
                        ForEach(state.devices) { device in
                            DeviceRow(device: device,
                                      selected: state.selectedDeviceID == device.id,
                                      eligible: device.isEligible) {
                                if device.isEligible {
                                    state.selectedDeviceID = device.id
                                    state.regeneratePreview()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if let device = state.selectedDevice {
                DeviceDetail(device: device, layout: state.layout)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }
}

private struct EmptyDeviceHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("未检测到外接磁盘")
                .font(.callout)
            Text("插入 U 盘后点击「刷新」。\n操作前请确认盘中数据已备份。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }
}

private struct DeviceRow: View {
    let device: DiskDevice
    let selected: Bool
    let eligible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: eligible ? "externaldrive.fill" : "externaldrive.badge.xmark")
                    .font(.title3)
                    .foregroundStyle(eligible ? Color.accentColor : Color.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(device.sizeDescription)
                        Text("/dev/" + device.bsdName)
                            .monospaced()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if !eligible {
                    Text("已排除")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.07),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!eligible)
    }
}

private struct DeviceDetail: View {
    let device: DiskDevice
    let layout: VentoyLayout?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 2)
            Text("设备详情")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            KeyValueRow(key: "设备节点", value: device.deviceNode, monospaced: true)
            KeyValueRow(key: "总线", value: device.busProtocol.isEmpty ? "—" : device.busProtocol)
            KeyValueRow(key: "逻辑扇区", value: "\(device.deviceBlockSize) B")
            KeyValueRow(key: "现有卷", value: device.volumesDescription)
            KeyValueRow(key: "安全校验", value: device.isEligible ? "通过（外接 / 可移除）" : device.rejectionReasons.joined(separator: "、"))

            if let layout {
                Divider().padding(.vertical, 2)
                Text("计算后的 GPT 布局")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(layout.summaryLines, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
