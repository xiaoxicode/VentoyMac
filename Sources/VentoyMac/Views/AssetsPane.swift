import SwiftUI
import VentoyCore

struct AssetsPane: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var assets: BootAssetManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard("引导资源", subtitle: "Ventoy 的引导代码是 GRUB2 / EDK2 二进制，无法用 Swift 重写。VentoyMac 精确复用官方发布包中的引导镜像，只把「安装器」用 Swift 重新实现。") {
                    HStack(spacing: 10) {
                        Button {
                            state.downloadAssets()
                        } label: {
                            Label("下载官方最新版本", systemImage: "arrow.down.circle")
                        }
                        .disabled(assets.isWorking || state.isBusy)

                        Button {
                            state.importAssets()
                        } label: {
                            Label("导入本地 tar.gz", systemImage: "folder")
                        }
                        .disabled(assets.isWorking || state.isBusy)

                        Spacer()
                        Button {
                            state.revealAssetCache()
                        } label: {
                            Label("显示缓存目录", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                    }

                    if assets.isWorking {
                        ProgressView(value: assets.progress)
                            .controlSize(.small)
                        Text(assets.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let release = assets.release {
                        Divider()
                        KeyValueRow(key: "最新版本", value: release.tagName)
                        if let pkg = release.linuxPackage {
                            KeyValueRow(key: "发布包", value: pkg.name)
                            KeyValueRow(key: "大小", value: ByteCountFormatter.string(fromByteCount: pkg.size, countStyle: .decimal))
                        }
                    }
                }

                if let current = assets.assets {
                    SectionCard("已安装的引导资源") {
                        KeyValueRow(key: "Ventoy 版本", value: current.version)
                        KeyValueRow(key: "来源包", value: current.sourceFileName ?? "本地导入")
                        KeyValueRow(key: "缓存位置", value: current.directory, monospaced: true)
                        if let hash = current.sourceSHA256 {
                            KeyValueRow(key: "SHA256", value: hash, monospaced: true)
                        }
                        Divider()
                        ForEach(current.requiredFiles, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: FileManager.default.fileExists(atPath: path)
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .green : .red)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.caption.monospaced())
                                Spacer()
                                Text(sizeOf(path))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        let issues = current.validationIssues
                        if !issues.isEmpty {
                            Divider()
                            ForEach(issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                SectionCard("资源用途说明") {
                    VStack(alignment: .leading, spacing: 7) {
                        assetLine("boot.img", "512 B · 写入 MBR 引导代码区（LBA 0 前 446 字节）")
                        assetLine("core.img", "2047 扇区（1 MiB）· Legacy BIOS GRUB core；GPT 模式写前 2014 扇区到 LBA 34")
                        assetLine("ventoy.disk.img", "32 MiB · 完整 VTOYEFI FAT16 分区镜像，实测含 BOOTX64/BOOTIA32/BOOTAA64 与各架构 ventoy_*.efi")
                    }
                    Text("下载后自动校验 GitHub Release 提供的 SHA256，任何不匹配都会丢弃文件并中止。离线环境可提前下载 tar.gz 后用「导入本地」安装。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .task {
            if assets.release == nil {
                _ = try? await assets.fetchLatestRelease()
            }
        }
    }

    private func assetLine(_ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name)
                .font(.caption.monospaced().weight(.semibold))
                .frame(width: 132, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sizeOf(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber else { return "缺失" }
        return ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .decimal)
    }
}
