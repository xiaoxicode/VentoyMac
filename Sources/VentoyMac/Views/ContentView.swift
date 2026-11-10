import SwiftUI
import VentoyCore

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            AppleSiliconNotice()
            Divider()

            HSplitView {
                DevicePane()
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

                VStack(spacing: 0) {
                    TabPicker()
                    Divider()
                    ZStack {
                        switch state.selectedTab {
                        case .install: InstallPane()
                        case .images: ImagesPane()
                        case .assets: AssetsPane()
                        case .logs: LogPane()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            StatusBar()
        }
        .frame(minWidth: 1020, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $state.showInstallConfirm) { ConfirmSheet() }
        .alert("操作失败", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("完成", isPresented: Binding(
            get: { state.infoMessage != nil },
            set: { if !$0 { state.infoMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(state.infoMessage ?? "")
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("VentoyMac")
                    .font(.title2.bold())
                Text("Ventoy 官方引导 · macOS Apple Silicon 原生安装器 · Swift / SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Label("arm64", systemImage: "cpu")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("GPT / exFAT / VTOYEFI 32 MiB")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct AppleSiliconNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Apple Silicon Mac 使用 iBoot 启动链，不能从标准 UEFI 启动 U 盘直接引导。本工具在 Mac 上「制作」Ventoy U 盘，成品请在 x86 PC 或支持 ARM64 UEFI 的设备上使用。")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}

// MARK: - Tabs

private struct TabPicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    state.selectedTab = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(state.selectedTab == tab
                                      ? Color.accentColor.opacity(0.14)
                                      : Color.clear)
                        )
                        .foregroundStyle(state.selectedTab == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var assets: BootAssetManager

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.assets?.isComplete == true ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(assets.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if assets.isWorking {
                ProgressView(value: assets.progress)
                    .frame(width: 130)
                    .controlSize(.small)
            }

            if state.isBusy {
                ProgressView(value: state.installProgress)
                    .frame(width: 150)
                    .controlSize(.small)
                Text(state.busyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("审计模式默认开启 · 写入前需二次确认")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Shared components

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
