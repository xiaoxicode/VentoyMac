import SwiftUI
import VentoyCore

struct ImagesPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard("镜像文件", subtitle: "安装完成后直接复制到 Ventoy 数据分区的 ISO 目录；无需解压，可随时增删。") {
                    HStack(spacing: 10) {
                        Button {
                            state.chooseImages()
                        } label: {
                            Label("添加 ISO / IMG / WIM", systemImage: "plus")
                        }
                        .disabled(state.isBusy)

                        if !state.isoPaths.isEmpty {
                            Button(role: .destructive) {
                                state.isoPaths.removeAll()
                                state.regeneratePreview()
                            } label: {
                                Label("清空", systemImage: "trash")
                            }
                        }
                        Spacer()
                        Text("\(state.isoPaths.count) 个文件 · \(totalSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if state.isoPaths.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "opticaldiscdrive")
                                    .font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                                Text("尚未添加镜像")
                                    .font(.callout)
                                Text("Ventoy 的核心优势是「拷贝即用」，制作完成后也可以直接在 Finder 里拖入 ISO。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 22)
                            Spacer()
                        }
                    } else {
                        ForEach(state.isoPaths, id: \.self) { path in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(path)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                Text(fileSize(path))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Button {
                                    state.removeImage(path)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }

                SectionCard("支持的镜像类型") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 8) {
                        ForEach(["ISO", "WIM", "IMG", "VHD(x)", "EFI", "VTOY"], id: \.self) { kind in
                            Text(kind)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                        }
                    }
                    Text("引导能力由官方 GRUB2 提供，支持 x86 Legacy BIOS、x86_64 / IA32 / ARM64 UEFI。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private var totalSize: String {
        let total = state.isoPaths.reduce(UInt64(0)) { sum, path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let number = attrs[.size] as? NSNumber else { return sum }
            return sum + number.uint64Value
        }
        return ByteCountFormatter.string(fromByteCount: Int64(min(total, UInt64(Int64.max))), countStyle: .decimal)
    }

    private func fileSize(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.size] as? NSNumber else { return "—" }
        return ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .decimal)
    }
}
