# VentoyMac — macOS Apple Silicon 原生 Ventoy 安装器

> 用 Swift 6 / SwiftUI 在 macOS arm64 上重新实现 **Ventoy2Disk 安装器**，精确复用 Ventoy 官方发布包中的 GRUB2 / EFI 引导二进制，产出与 Windows / Linux 官方安装器**磁盘布局一致**的多启动 U 盘。

源仓库：`https://github.com/xiaoxicode/Ventoy.git`（`ventoy/Ventoy` 的镜像 fork，v1.1.18 布局）

---

## 1. 技术路线说明（先读这一节）

Ventoy 官方源码是 **C + Shell + GRUB2 + EDK2 + BusyBox**，`INSTALL/ventoy_pack.sh` 需要 `losetup` / `parted` / `mkexfatfs` / `grub-bios-setup` / 交叉编译工具链，官方只提供 **Linux（Docker）** 构建路径；产物是 Windows `.exe` 与 Linux `.sh` 安装器。**它不能在 macOS 上直接编译，也不存在可移植的 Swift 版引导器。**

因此「macOS arm 版 + Swift 框架」的可行落点是：

| 层次 | 做法 |
|---|---|
| 引导器（GRUB2、BOOTX64/BOOTAA64.EFI、VTOYEFI 分区镜像） | **复用官方二进制**，从 GitHub Release 的 `ventoy-<ver>-linux.tar.gz` 提取，SHA256 校验 |
| 安装器（分区、格式化、写引导、复制 ISO） | **Swift / SwiftUI 重写**，用 macOS 原生 `diskutil` / `newfs_exfat` / `dd` 精确复刻官方偏移；**不调用 `/usr/sbin/gpt` 的任何写子命令**（SIP 开启时被系统封锁，见第 10 节） |
| 界面与流程 | SwiftUI 原生 App（arm64），含设备枚举、安全校验、审计演练、提权执行、日志 |

本项目**逐行移植**了 `INSTALL/tool/ventoy_lib.sh` 的 `format_ventoy_disk_gpt()` 与 `INSTALL/tool/VentoyWorker.sh` 的 GPT 写入偏移，见 `Sources/VentoyCore/VentoyLayout.swift` 与 `InstallScriptBuilder.swift`。

---

## 2. 必须知道的限制

1. **Apple Silicon Mac 不能从标准 UEFI U 盘启动。** iBoot 启动链不支持通用 GRUB2 引导，外部 USB 只能引导符合 Apple 安全策略的 macOS。本工具在 Mac 上**制作**启动盘，成品用于 x86 PC / x86_64 UEFI / **ARM64 UEFI 设备**（树莓派、ARM 服务器、Windows on ARM 等）。要在 Apple Silicon 本机引导需 Asahi Linux 的 m1n1/U-Boot UEFI 环境，不在本项目范围。
2. **实时写盘链路尚未跑通到 UEFI 启动。** 真机共六轮：① TCC 拒绝（EPERM）；② FDA 已生效但第 4 步 `bs=64` 触发 `EINVAL`；③ 旧进程残留产生同样日志；④ 对齐写入成功（32 KiB）后第 5 步 `gpt create` 报 `operation not permitted: create`；⑤ b5/r4 的「真实 uid 自举」在 `uid=0 / ruid=0` 下仍失败；⑥ b6/r5 改用 `diskutil partitionDisk` 后报 `Error: -5344: MediaKit reports not enough space on device`。**第 ⑥ 轮根因**：`diskutil` 在大于约 200 MiB 的 GPT 磁盘上会**自动插入一个 200 MiB EFI 系统分区**（409600 扇区），而官方 Ventoy 布局尾部只剩 40 扇区余量，空间被挤爆；之前 128 MiB 的演练盘太小、不触发自动 ESP，所以没暴露。`-noEFI` 可关闭它，但关掉后首个分区默认起点从 LBA 2048 变成 LBA 40（会与 `core.img` 冲突），因此还要用**前导 `Free Space` 2048S** 把起点顶回去。已在与真机**同容量**（8,053,063,680 B / 15,728,640 扇区）的虚拟块设备上跑通完整 LIVE 脚本，得到与官方公式逐扇区一致的布局，并做了 19 项字节级断言（干净盘与「MBR windows 卷 + 盘头 32 KiB 已清零」场景均 19/19）。其余已验证：官方包 SHA256 校验与解包、xz 解压、引导镜像尺寸与内容、布局算法、脚本生成、审计演练、39 项单元测试、81 项 CLI 自检、app 构建与签名。写盘属于不可逆操作，请按第 8 节逐步验证后再用真实设备。
3. **每次重新构建后必须完全退出旧窗口。** macOS 不会替换已运行进程的内存映像：旧窗口会继续生成旧脚本，日志看起来和「修复没生效」一模一样（见第 7 节第 0 步与修正记录 6）。应用现在带构建标识 `2026.11.11-b10` / 安装脚本 `r7`，日志首行与脚本头都会打印它，可据此核对。
4. Ventoy 官方不支持 **4Kn 原生设备**（512 字节逻辑扇区假设）；本项目会主动拒绝。
5. **Secure Boot：那一次注册无法由制作端消除。** Ventoy 借用 Rocky 的微软签名 shim，而 grub 用 Ventoy 自签密钥，所以任何开启 Secure Boot 的机器首次启动都会停在 `Verification failed: (0x1a) Security Violation` —— 这是 MokManager 的注册界面，不是 BIOS 缺配置。信任根在目标机固件里、不在 U 盘上，因此"勾选后完全免注册"在物理上不成立。本项目把它做到可行范围内的最好：勾选「启用 Secure Boot 支持」后，① 写入前用只读 FAT16 解析器（不挂载任何设备）核对 shim / MokManager / 证书是否齐全，缺件直接拒绝制作（缺 MokManager 会让 `0x1a` 变成死路）；② 写入后**只读**挂载 VTOYEFI 复查并比对证书 SHA-256，防止镜像没写全；③ 把证书与中文说明放到数据分区根目录和 `SecureBoot/`，让注册变成"回车 + 选文件 + Enroll"三次按键；④ 可选写入 `ventoy/ventoy.json` 的 `VTOY_SECURE_BOOT_POLICY`。注册一次后同一台机器永久免操作；要彻底免按键，只能把该证书一次性写入该机固件 `db`。详见 [`SECURE_BOOT.md`](SECURE_BOOT.md)。
6. 项目源码**不内置**引导二进制。`dist/` 附带一份已校验的官方离线包 `ventoy-1.1.18-linux.tar.gz`（SHA256 `d86ff9de…`），可直接「导入本地」；也可在应用内联网下载最新版。
7. 只实现 **GPT** 布局（对应官方 `-g`）与破坏性安装（`-I`）。非破坏性安装（`-n`）、MBR 布局、插件系统、持久化分区未移植。
8. **待真机确认的兼容性细节**：`diskutil partitionDisk` 用 `%GUID%` 显式指定分区类型时，不写 GPT 分区项的 Name（`gpt -r show -l` 显示 `""`），而官方 `vtoygpt -f` 只在分区 2 的 Name 以 `VTOY` 开头时设置 `VENTOY_EFI_PART_ATTR`。分区类型 GUID、卷名、`VTOYEFI` 镜像内容均已验证正确，但该属性差异是否影响真机 UEFI 启动尚未验证。

---

## 3. 项目结构

| 路径 | 内容 |
|---|---|
| `Sources/VentoyCore/` | 纯 Swift 领域层：官方常量、GPT 布局算法、磁盘模型与 plist 解析、**`BootAssetInstaller`（SHA256 → tar → xz → 尺寸校验 → manifest，GUI/CLI 共用）**、**`DiskAccessProbe`（0 字节写打开 + 512 字节对齐读 + `diskutil`/`-noEFI` 分区通道探针）**、**`VentoyBuild`（构建标识与旧进程检测）**、可审计 Bash 脚本生成器（`partitionDisk -noEFI` + 前导空隙 + 子扇区补丁暂存 + 整扇区写回 + 卸载重试） |
| `Sources/VentoyMac/Services/` | `ProcessRunner`（签名 helper / 兼容两种提权通道、实时日志跟踪）、`DiskService`、`BootAssetManager`（下载与 UI 状态包装）、`AppState`（通道自动探测与权限自检） |
| `Sources/VentoyMac/Views/` | SwiftUI 界面：设备列表、镜像管理、引导资源、**完全磁盘访问授权卡片**、安装计划、确认弹窗、日志 |
| `Sources/VentoymacCLI/main.swift` | 只读命令行工具（自检 / 列盘 / 算布局 / 审计脚本 / 实时脚本 / 探针脚本 / **`rehearse-script` 虚拟盘演练脚本** / 离线导入与校验资源），外加供 GUI 提权调用的内部命令 `run-script` |
| `Tests/VentoyCoreTests/` | 27 个 XCTest 用例：官方公式、对齐、簇大小、异常输入、脚本偏移、内置盘拒绝、真实镜像尺寸、合成发布包端到端导入、裸盘权限预检顺序、**全部裸设备写入扇区对齐**、**子扇区补丁暂存**、**构建标识**、**`-noEFI` 分区通道 / 前导空隙 / 分区 1 LBA 断言**、探针（含 `PROBE_NOEFI_OK`）与组检测 |
| `Scripts/make_app.sh` | 组装 `.app`、生成 icns 图标、**写入 `BuildID.txt`**、**给 app 与包内 helper 签同一固定 designated requirement**（保证 FDA 授权跨重编译有效、且覆盖提权后的写盘进程） |
| `Makefile` | `build` / `test` / `selftest` / `app` / `run` / `clean` |

---

## 4. 快速开始

环境要求：macOS 13+ / Apple Silicon / **完整 Xcode**（仅装 Command Line Tools 会缺少 `SwiftUIMacros`，`@State` 宏无法编译）。

```bash
cd VentoyMac

make build       # Release 编译（arm64）
make selftest    # 核心算法自检，无需 U 盘、无需引导资源
make test        # XCTest 单元测试（39 项）
make app         # 生成 dist/VentoyMac.app
make run         # 构建并打开应用
make assets      # 查看已缓存的引导资源与校验结果
make import PKG=/路径/ventoy-1.1.18-linux.tar.gz SHA256=<官方摘要>
```

CLI 也可单独使用（只读，绝不写盘）：

```bash
.build/out/Products/Release/ventoymac-cli self-test
.build/out/Products/Release/ventoymac-cli disks
.build/out/Products/Release/ventoymac-cli plan disk4
.build/out/Products/Release/ventoymac-cli script disk4 > plan.sh
.build/out/Products/Release/ventoymac-cli demo-script > demo.sh && bash -n demo.sh
.build/out/Products/Release/ventoymac-cli live-script disk4 > ~/Downloads/ventoy-install.sh
.build/out/Products/Release/ventoymac-cli probe-script disk4 > ~/Downloads/probe.sh
.build/out/Products/Release/ventoymac-cli group-setup-script > ~/Downloads/group.sh
.build/out/Products/Release/ventoymac-cli build-id
# 虚拟块设备端到端演练（仅供开发者复现第 8 节的 14 步 LIVE 校验）
.build/out/Products/Release/ventoymac-cli rehearse-script disk5 134217728 > /tmp/vtoy-rehearse-live.sh
# 首选在应用内写入（需先给 VentoyMac.app 完全磁盘访问，见第 10 节）；
# 上面三份脚本只用于人工审阅 / 最后兜底，CLI 本身绝不执行它们。
.build/out/Products/Release/ventoymac-cli import-assets ~/Downloads/ventoy-1.1.18-linux.tar.gz d86ff9de63d94c8b8f1f6b14d23c55af4b88e8207bf2893890892a6a97b1ad54
.build/out/Products/Release/ventoymac-cli assets
.build/out/Products/Release/ventoymac-cli version
```

---

## 5. 磁盘布局：官方算法逐项对照

常量来自 `INSTALL/tool/ventoy_lib.sh`：`VENTOY_PART_SIZE=33554432`（32 MiB）、`VENTOY_SECTOR_NUM=65536`、`VENTOY_SECTOR_SIZE=512`。

对于容量为 `sector_num` 扇区的磁盘，GPT 布局（保留空间 `reserved_mb`）：

```
part1_start = 2048
part1_end   = sector_num - (reserved_mb*2048 + 33) - 65536 - 1
part2_start = part1_end + 1
若 part2_start % 8 != 0 → part1_end -= (part2_start % 8); part2_start = part1_end + 1
part2_end   = part2_start + 65536 - 1
```

| 区域 | LBA | 内容 | VentoyMac 写入方式（全部扇区对齐） |
|---|---|---|---|
| 盘头 0–33 / 末尾 33 扇区 | 0–33 / last-33…last | 保护 MBR、GPT 头、分区表、备份 GPT | **`diskutil partitionDisk -noEFI … 4 GPT …`（第一条写盘命令）** 由 DiskArbitration 建立 GPT 主/备表；`gpt create/add/label/destroy` 全部不再使用。LBA 34–2047 随后被 `core.img` 覆盖，无需单独 `dd` 清零 32 KiB |
| LBA 0 | 0 | 保护 MBR + Ventoy 引导代码前 446 字节 | 先 `dd if=/dev/rdiskN of=$VTOY_STAGE/mbr.bin bs=512 count=1` 读出保护 MBR；校验偏移 450=`ee`、510=`55aa`；`dd if=boot.img of=mbr.bin bs=446 count=1 conv=notrunc` 覆盖引导代码；最后由 `vtoy_raw_write` 以 `bs=512` 整扇区写回 |
| 字节 92 | — | GPT 模式标记 `0x22` | `printf '\042' \| dd of=$VTOY_STAGE/mbr.bin bs=1 seek=92`（暂存普通文件） |
| LBA 1–33 | 1–33 | GPT 头与分区表 | 同一条 `diskutil partitionDisk -noEFI` 写入；分区类型由 `%<GPT UUID>%` 显式指定 |
| LBA 34–2047 | 34–2047 | Legacy BIOS GRUB core（官方 `core.img` 共 2047 扇区，GPT 模式只写前 2014 扇区） | 先复制到 `$VTOY_STAGE/core.bin`，再 `vtoy_raw_write "$VTOY_STAGE/core.bin" 2014 34` |
| 字节 17908 | — | 第二 GPT 标记 `0x23` | `17908 = LBA34×512 + 500` → `printf '\043' \| dd of=$VTOY_STAGE/core.bin bs=1 seek=500` |
| 字节 384 / 440 | — | 16 字节 Ventoy 磁盘 UUID / 4 字节 MBR 签名 | `/dev/urandom` 生成后打到重新读回的 `mbr.bin`，整扇区写回 |
| 分区 1 | 2048 … part1_end | exFAT「Ventoy」，存放 ISO；>32 GiB 用 128 KiB 簇，否则 32 KiB | `newfs_exfat -v Ventoy -c <64\|256>`，在**所有整盘 `dd` 之后**执行 |
| 分区 2 | part2_start … +65535 | 32 MiB FAT16「VTOYEFI」，整镜像覆盖 | `vtoy_raw_write ventoy.disk.img 65536 "$VTOY_PART2_LBA"`；LBA 由第 5 步从 `diskutil info -plist /dev/diskNs2` 的 `PartitionMapPartitionOffset / 512` 运行时回读 |
| 末尾 33 扇区 | — | 备份 GPT 头与分区表 | `diskutil partitionDisk` 自动维护 |

> **为什么不能直接照搬官方 Linux 命令**：官方 `VentoyWorker.sh` 使用 `dd bs=64 count=512`、`dd bs=1 count=446`、`printf | dd bs=1 seek=92 / 17908 / 384 / 440`。Linux 的 `/dev/sdX` 是带页缓存的块设备，允许任意字节长度与偏移；macOS 的 `/dev/rdiskN` 是强制对齐的字符设备，**传输长度和字节偏移都必须是 512 的整数倍**，否则内核直接返回 `EINVAL (Invalid argument)`，表现为 `dd: /dev/rdiskN: Invalid argument` 且 `0+0 records out`。因此 VentoyMac 把所有子扇区字节补丁放到 `$VTOY_STAGE/` 的普通文件中完成，再以 `bs=512` 整扇区写回。第 9 步再以对齐读回校验 `0x22` / `0x23` / `0x55AA`。
>
> **为什么分区表由 `diskutil` 建立**：本机 `csrutil status` 为 enabled，`/usr/sbin/gpt` 带 `com.apple.rootless.restricted-block-devices` 且链接 `_csr_check`，所有写子命令（`create/add/label/destroy`）在 SIP 开启时被命令分派层无条件拒绝，`uid=0 / ruid=0`、临时普通文件、`hdiutil` 虚拟块设备上都能复现 `operation not permitted: create`。`diskutil` 有正式磁盘访问 entitlement，因此改为 `partitionDisk`；VTOYEFI 的实际 LBA 仍由脚本运行时回读作为防御性校验，也让官方 `vtoygpt.c` 中按分区 Name 判断的逻辑存在第 2 节第 8 条所述的待验证差异。
>
> **为什么必须 `-noEFI` + 前导空隙**：`diskutil partitionDisk` 对大于约 200 MiB 的 GPT 磁盘会**自动插入 200 MiB（409600 扇区）EFI 系统分区**，官方布局尾部只有 40 扇区余量，于是真机 8 GB U 盘报 `-5344: MediaKit reports not enough space`；128 MiB 演练盘因太小而不触发，这是之前虚拟盘演练的盲区。`-noEFI` 关掉它之后首个分区的**默认起点变成 LBA 40**（原本 2048），若不处理，`core.img`（LBA 34–2047）会覆盖 exFAT 数据区。命令加入一个 `Free Space gap 2048S` 前导条目把 part1 顶回 LBA 2048；再加尾部 `Free Space spare R` 防止 diskutil 把 VTOYEFI 拉伸到磁盘末尾。第 5 步会读取 `diskNs1` 的真实偏移并断言等于 2048，不满足就中止。实测布局与官方公式逐扇区一致（part1 @2048+15661016，part2 @15663064+65536）。

分区类型 GUID：分区 1 = `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`（Microsoft Basic Data），分区 2 = `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`（EFI System）。

实际命令（`disk4` / 8 GiB 示例，共 4 个条目：前导空隙 + 两个分区 + 尾部空隙；`S` 后缀为精确 512 字节扇区数）：

```bash
diskutil partitionDisk -noEFI disk4 4 GPT \
  'Free Space' 'gap' 2048S \
  '%EBD0A0A2-B9E5-4433-87C0-68B6B72699C7%' 'Ventoy' 15661016S \
  '%C12A7328-F81F-11D2-BA4B-00A0C93EC93B%' 'VTOYEFI' 65536S \
  'Free Space' 'spare' R
```

### 官方命令 → macOS 命令映射

| 官方 Linux | VentoyMac |
|---|---|
| `parted -s mklabel gpt ... mkpart` | `diskutil partitionDisk -noEFI <disk> 4 GPT 'Free Space' gap <part1Start>S '%<GUID>%' <name> <n>S … 'Free Space' 'spare' R` |
| `mkexfatfs -n Ventoy -s 64` | `newfs_exfat -v Ventoy -c 64` |
| `mkfs.vfat -F 16 -n VTOYEFI -s 1` | 由官方 32 MiB 镜像整体覆盖，无需单独格式化 |
| `xzcat ventoy.disk.img.xz \| dd ...` | 资源阶段先解压为 `ventoy.disk.img`，写盘阶段由 `vtoy_raw_write` 以 `bs=512` 写入 |
| `vtoy_gen_uuid` | `/dev/urandom` + `dd`，偏移一致 |
| `vtoycli gpt -f` | `partitionDisk` 的 `%C12A7328-…%` 直接设定标准 ESP GUID，不使用 `gpt add -t efi` |
| `mke2fs` / `partprobe` | `diskutil unmountDisk force` + 轮询 `/dev/rdiskNs1` / `s2` 设备节点 |

---

## 6. 安全机制

1. 只枚举 `diskutil list -plist external` 的**整盘**，并二次校验 `WholeDisk == true`、`Internal == false`、`VirtualOrPhysical != Virtual`、`Removable/Ejectable == true`；内置盘永远不出现在可选列表。
2. 生成的脚本**自带运行时自检**：即使导出后在别处执行，也会重新读取 `diskutil info -plist` 并拒绝内置盘 / 非整盘。
3. 默认 **审计模式（audit）**：只打印全部命令，不写盘。可「运行审计演练」实际跑一遍无副作用的流程。
4. 实时写入前需：勾选「已备份」+ **手动输入设备 BSD 名**（如 `disk4`），并执行 `DiskService.revalidate` 复检容量与可移除性。
5. 写入全程在应用内完成，不经过终端：`osascript` 系统密码框提权后，由 app 包内**签名 helper** 启动脚本（helper 与应用共用固定代码标识，使 FDA 覆盖真正 spawn `dd` / `diskutil` / `newfs_exfat` 的进程）。「验证磁盘写入权限」会自动测试「签名 helper 提权」与「直接提权（兼容）」并选用可用通道。不使用 `sudo` 明文或持久 setuid helper；日志全程可见，选择会持久化。
6. 下载资源校验 GitHub Release API 的 `digest`（`sha256:...`）字段，不匹配即丢弃文件并中止；离线导入亦会计算并记录 SHA256。
7. 每一步都可导出为独立 `.sh` 文件人工审阅。
8. **裸盘权限 / 分区通道 / 对齐预检**（第 3 步，卸载之后、任何破坏性命令之前）：对每个设备节点做 `dd ... count=0 conv=notrunc` 0 字节写打开（查 TCC/FDA）+ `bs=512 count=1` 对齐读（查非 512n / EINVAL）；打印有效/真实 uid 与计划布局。探针另用 `diskutil info -plist` 验证分区通道、`diskutil partitionDisk` 帮助文本中是否含 `-noEFI`（`PROBE_DISKUTIL_OK` / `PROBE_NOEFI_OK` / `PROBE_PARTITION_CHANNEL`）。**不再探测 `gpt` 写能力**——它在 SIP 开启时注定失败且不是本方案的依赖。详见第 10 节。
9. **所有裸设备写入强制 `bs=512`**：脚本生成器输出后由 XCTest / CLI 自检逐行扫描，凡 `of='/dev/disk*|/dev/rdisk*'` 的 `dd` 必须同时含 `bs=512` 与 `conv=notrunc`；子扇区补丁一律先落在 `$VTOY_STAGE/` 普通文件。
10. **分区通道为 `diskutil partitionDisk -noEFI`**：完全不调用 `/usr/sbin/gpt` 的写子命令（SIP / `rootless.restricted-block-devices` 会无条件拒绝）。`-noEFI` 阻止大容量盘上自动插入 200 MiB EFI 分区（`-5344`）；前导 `Free Space <part1Start>S` 把 part1 顶回 LBA 2048，尾部 `Free Space … R` 固定 VTOYEFI 为 65536 扇区。第 5 步同时**断言分区 1 的真实起始 LBA = 2048**，并从 `diskutil info -plist /dev/diskNs2` 的 `PartitionMapPartitionOffset` 运行时回读 `VTOY_PART2_LBA`、断言分区 2 类型为 `EFI`、偏移 512 对齐。
11. **整盘写入带卸载重试**：`vtoy_unmount()` + `vtoy_raw_write()` 在每次整盘 `dd` 前强制卸载、最多重试 5 次，规避写入有效 FAT/exFAT 镜像后 DiskArbitration 自动挂载造成的 `Resource busy`；所有整盘 `dd` 排在 `newfs_exfat` / 挂载之前。首个写入动作仍是第 4 步 `diskutil partitionDisk -noEFI`，若其失败，磁盘仍是零改动。

---

## 7. 使用流程

0. **确认构建标识。** 重新构建过应用后，务必 `Cmd-Q` 完全退出旧窗口再打开 `dist/VentoyMac.app`（macOS 不会替换已运行进程的代码）。启动日志首行、安装日志首行、脚本头与安装页右下角都会显示 `VentoyMac 构建 2026.11.11-b10 · 安装脚本 r7`；用 `ventoymac-cli build-id` 或 `cat dist/VentoyMac.app/Contents/Resources/BuildID.txt` 也可核对。若应用检测到自己是旧进程，安装页顶部会出现红色卡片并提供「退出应用」按钮。
1. 打开 `dist/VentoyMac.app`，切到「引导资源」→ 点击**下载官方最新版本**，或直接导入 `dist/ventoy-1.1.18-linux.tar.gz` 离线安装（本环境已预置缓存，启动即显示「已就绪 · Ventoy 1.1.18」）。
2. 插入 U 盘 → 左侧点击「刷新」→ 选中目标设备（显示 BSD 名、容量、现有卷）。
3. 「镜像」页添加 ISO/WIM/IMG 等（也可安装完成后直接在 Finder 拖入 `ISO` 目录）。
4. 「安装」页检查卷标与保留空间，展开查看生成的脚本，逐步核对。
5. 点击**运行审计演练** → 到「日志」页确认全部命令与自检通过。
6. 需要离线审阅时点**导出脚本**。
7. 首次使用先按第 10 节给 **VentoyMac.app** 加「完全磁盘访问」并重启应用，然后点 **验证磁盘写入权限**（0 字节写打开 + 512 字节对齐读 + `diskutil` / `-noEFI` 分区通道检查，并打印有效/真实 uid；不写盘）。日志出现 `PROBE_OK`、`PROBE_DISKUTIL_OK`、`PROBE_NOEFI_OK` 与 `PROBE_RESULT: OK` 才说明当前提权通道可用。
8. 点击**写入磁盘…** → 阅读警告 → 勾选备份 → 输入设备名 → 在弹窗选 **「应用内直接写入」**（默认主按钮）。若自检两个通道都失败，按第 10 节第 4 步给 `/usr/libexec/security_authtrampoline` 加一次 FDA 后重启应用再试。
9. 完成后 `gpt -r show -l /dev/diskN`（只读）或 `diskutil list /dev/diskN` 核对布局，安全推出 U 盘，在目标机器上测试启动。

---

## 8. 验证步骤与验证状态

| # | 验证项 | 命令 / 方法 | 状态 |
|---|---|---|---|
| 1 | 官方布局公式一致性 | `make selftest`（32 GiB / 64 GiB / 对齐 / 簇大小 / 4Kn 拒绝） | ✅ 68 项自检全通过，0 失败 |
| 2 | 脚本包含全部官方偏移 | `make selftest` + `make test` | ✅ 通过（27 个 XCTest） |
| 3 | 生成脚本的 Bash 语法与无副作用执行 | `ventoymac-cli demo-script > demo.sh && bash -n demo.sh && bash demo.sh` | ✅ 191 行审计脚本，语法与审计执行通过；`bash -n dist/*.sh` 4/4 通过 |
| 4 | 内置盘拒绝、卷标校验、资源缺失校验 | `make test` | ✅ 通过 |
| 5 | Release 编译与 arm64 产物 | `make build`；`lipo -archs` | ✅ `arm64` |
| 6 | `.app` 结构、签名、启动 | `make app`；`codesign -d -r-`；`open dist/VentoyMac.app` | ✅ 已验证可启动，且 designated requirement 固定 |
| 7 | `plutil` 运行时自检可用性 | `diskutil info -plist disk0 \| plutil -extract Internal raw -o - -` | ✅ 返回 `true` |
| 8 | 磁盘枚举 | `ventoymac-cli disks` | ✅ 检出外接 `disk4`（8.1 GB） |
| 9 | 官方发布包真实性 | `shasum -a 256 ventoy-1.1.18-linux.tar.gz` 对比 Release API `digest` | ✅ 均为 `d86ff9de63d94c8b8f1f6b14d23c55af4b88e8207bf2893890892a6a97b1ad54`（20,320,548 B） |
| 10 | SHA256 / 解包 / xz 解压 / 导入 / manifest | `ventoymac-cli import-assets <真包> <摘要>` → `ventoymac-cli assets` | ✅ 真包端到端通过，版本 `1.1.18` |
| 11 | 引导镜像实测尺寸 | `boot.img` / `core.img` / `ventoy.disk.img` | ✅ 512 B / 1,048,064 B（2047 扇区）/ 33,554,432 B（65,536 扇区） |
| 12 | VTOYEFI 镜像内含 ARM64 引导器 | 只读挂载 `ventoy.disk.img` 后列出 `EFI/BOOT` | ✅ `BOOTAA64.EFI`、`ventoy_aa64.efi`、`iso9660_aa64.efi`、`udf_aa64.efi` 等齐备 |
| 13 | 应用内下载流程 | 应用内「下载官方最新版本」 | ⚠️ 本环境 GitHub 大文件下载耗时约 20 分钟；已用同一核心链路完成离线导入验证，在线部分需真机网络确认 |
| 14 | 审计演练（外接盘场景） | 应用内「运行审计演练」 | ⚠️ 需外接盘后执行 |
| 15 | 实时写盘 + 目标机 UEFI 启动 | 插入 U 盘后按第 7 节操作 | ❌ **未验证**：真机六轮失败/中止——① 预检被 TCC 拒绝；② 第 4 步 `bs=64` → `EINVAL`；③ 旧进程残留产生同样日志；④ 32 KiB 对齐写入成功后第 5 步 `gpt create` → `operation not permitted`；⑤ b5/r4 `uid=0 / ruid=0` 仍被 `gpt create` 拒绝；⑥ b6/r5 `diskutil partitionDisk` → `-5344: MediaKit reports not enough space`（自动 200 MiB EFI 分区）。前三轮与第五、六轮零写入，第四轮仅盘头 32 KiB 被清零。已改 `-noEFI` + 前导空隙并在**同容量虚拟盘**完成完整 LIVE 演练，**仍待真机重跑与 UEFI 启动** |
| 16 | 裸盘写入权限预检时机 | `make test` 中 `testRawWritePreflightRunsBeforeAnyDestructiveCommand` | ✅ 卸载之后、破坏性命令之前，且标记为非破坏性 |
| 17 | EPERM 错误可读性 | `ProcessRunner` 检测 `Operation not permitted` | ✅ 抛出带完整解决步骤的 `diskAccessDenied`，而非原始 AppleScript 错误 |
| 18 | 0 字节探针 / 组检测 | `DiskAccessProbeTests` + `make selftest` | ✅ 探针不写数据、覆盖双设备节点、组检测无误判 |
| 19 | 签名 helper 提权通道 | `make app` 后对比 app 与 `VentoyWriter.app` 的 `codesign -d -r-`；`--verify --strict` | ✅ DR 完全一致，两者均 `satisfies its Designated Requirement`；`run-script` 执行链与路径白名单实测通过 |
| 20 | FDA 授权跨重编译保持 | 两次独立打包后对比 `codesign -d -r-` | ✅ 固定 DR 完全一致 |
| 21 | 两种权限错误区分 | 本机实测：root → `Operation not permitted`；普通用户 → `Permission denied` | ✅ 与第 10 节分析一致 |
| 22 | 系统命令 entitlement 盘点 | `codesign -d --entitlements -` | ✅ `diskutil`/`newfs_exfat` 有；`gpt`/`dd` 无 |
| 23 | 非 root 分区表操作 | 自建磁盘映像上 `gpt create/add` | ✅ 实测报 `operation not permitted`，确认 operator 组方案不可行；**补充**：root 身份下同样被拒（SIP/rootless，见第 32 项与修正记录 8），故 b6/r5 改走 `diskutil partitionDisk` |
| 24 | helper 路径白名单 | `ventoymac-cli run-script /tmp/evil.sh` | ✅ 拒绝执行，退出码 2 |
| 25 | FDA 记录与当前签名匹配 | TCC.db `csreq` 解出 `identifier + CFBundleVersion`，`auth_value=2` | ✅ 授权有效 |
| 26 | 裸设备写入扇区对齐回归 | `testEveryRawDiskWriteIsSectorAligned` + CLI 自检逐行扫描 | ✅ 所有 `of='/dev/*disk*'` 的 `dd` 均为 `bs=512 ... conv=notrunc`；已无 `bs=1` / `bs=64` 的裸设备写入 |
| 27 | 子扇区补丁落盘字节正确性 | 2 MiB 临时镜像文件端到端模拟 step 12–15 | ✅ 字节 92=`22`、17908=`23`、450=`ee`、510=`55aa`、引导码头 `eb6390`、签名@440 = UUID 末 4 字节 |
| 28 | 交付脚本语法与签名 | `bash -n dist/*.sh`；`codesign --verify --strict` app / helper | ✅ 4 份脚本通过；DR 仍为固定 `cn.ventoymac.VentoyMac` |
| 29 | 真实脚本命令的字节级全流程演练 | 从 `dist/VentoyMac-disk4-install.sh` 逐行抽取第 4、10–15 步命令，在 8 GiB 稀疏文件上执行（仅需替换设备路径为普通文件、跳过 `gpt`/`diskutil` 等需 root 的步骤） | ✅ 10/10 断言通过：字节 92=`22`、17908=`23`、450=`ee`、510=`55aa`、引导码头 `eb6390`、签名@440 = UUID 末 4 字节、LBA34 首扇区 = `core.img` 仅偏移 500 被补丁、part2 首扇区 = 官方 `ventoy.disk.img` |
| 30 | 构建标识与旧进程检测 | `ventoymac-cli build-id`；`Contents/Resources/BuildID.txt`；字节比对 app 二进制 | ✅ 当前 `2026.11.10-b7` / `script-r6` / `stale=no`（b4 阶段已验证机制可用） |
| 31 | 应用重启后加载新二进制 | 终止旧 PID → `make app` → `open dist/VentoyMac.app` → `pgrep` | ✅ b4 阶段新 PID 3227 从新包启动；每轮重建后均按此流程重启 |
| 32 | `gpt` EPERM 根因最终定位 | `csrutil status`；`strings /usr/sbin/gpt`；`dyld_info -imports`；`codesign -d --entitlements - /usr/sbin/gpt`；在普通临时文件、`hdiutil` 虚拟块设备 `/dev/disk5` 上以 root 复现 | ✅ SIP `enabled`；`gpt` 带 `com.apple.rootless.restricted-block-devices` 并导入 `_csr_check`；`gpt create -f` 在 `uid=0 / ruid=0`、普通文件、虚拟盘上**全部**报 `operation not permitted: create` → 写子命令被 rootless 分派层封锁，与 uid / FDA / 设备占用无关。**修正记录 7 的「真实 uid」结论被证伪** |
| 33 | `diskutil partitionDisk` 通道可行性 | 8 GiB 虚拟盘上 `diskutil partitionDisk -noEFI disk5 4 GPT 'Free Space' gap 2048S … 'Free Space' spare R` | ✅ 成功创建 GPT、两个分区节点并格式化；无 `-noEFI` 时同容量盘复现 `-5344` 并生成多余的 200 MiB EFI 分区 |
| 34 | 运行时回读与断言分区 LBA | `diskutil info -plist /dev/diskNs1` / `s2` → `PartitionMapPartitionOffset` | ✅ 第 5 步断言 `$VTOY_P1_OFFSET / 512 == 2048`（防止 `core.img` 覆盖数据区），`$VTOY_PART2_LBA = offset / 512`，并断言 `Content == EFI`、偏移 512 对齐；本轮实测 part1 @2048、part2 @15663064，与官方公式一致 |
| 35 | 首个写入动作与 `gpt` 写命令清零 | XCTest `testLiveScriptUsesDiskUtilPartitionChannel`；`grep -cE 'gpt (create\|add\|label\|destroy)' dist/*.sh` | ✅ 首个写入是第 4 步 `diskutil partitionDisk -noEFI`；LIVE 脚本中 `gpt` 写命令检出数 `0`，仅保留只读 `gpt -r show -l` |
| 36 | 干净虚拟盘完整 LIVE 演练（128 MiB） | `hdiutil create -size 128m -layout NONE -type UDIF` + `hdiutil attach -nomount` → `/dev/disk5`；`rehearse-script` 跳过 root gate 后执行真实 LIVE 脚本 | ✅ b6 阶段 exit=0，14/14 步 + 21/21 字节断言；b7 阶段也单独验证 `-noEFI` + 前导空隙在 128 MiB 盘上同样得到 part1 @2048 / part2 @196568 的官方布局 |
| 37 | 模拟真机盘头已损坏场景 | 先清零 LBA 0–63，再在同一虚拟盘重跑 b6/r5 脚本 | ✅ 初版暴露 `dd: /dev/rdisk5: Resource busy`（DiskArbitration 自动挂载竞态）；新增 `vtoy_unmount` / `vtoy_raw_write` 并重排整盘写入到 `newfs_exfat` 之前后，exit=0，14/14 步，20/20 字节级断言通过 |
| 38 | shell 非 ASCII 变量粘连静态扫描 | Python 扫描 LIVE 脚本中 `$VAR` 后紧跟中文全角标点的行 | ✅ 风险行数 `0`；`set -u` 下不再出现 `PROBE…: unbound variable` |
| 39 | 交付物重建与签名 | `make app`；`codesign --verify --strict` app / helper；`bash -n dist/*.sh`；`make test`；CLI `self-test` | ✅ b7 app + helper 签名通过、固定 DR 不变；4/4 脚本语法通过；27 XCTest / 0 失败；68 项自检 / 0 失败；b6 旧脚本归档至 `dist/archive/*.pre-noefi` |
| 40 | **-5344 真因复现** | `hdiutil create -sectors 15728640 -layout NONE -type UDIF`（与真机 `disk4` 逐字节同容量）→ `attach -nomount` → 执行 b6/r5 的 `partitionDisk` | ✅ 在虚拟盘上复现逐字相同的 `Error: -5344: MediaKit reports not enough space on device for requested operation`；去掉 `-noEFI` 时 `gpt -r show -l` 显示多出的 200 MiB EFI 分区（LBA 40 + 409600） |
| 41 | `-noEFI` 副作用与修正 | 同一 8 GiB 虚拟盘上对比 `3 GPT` / `4 GPT` / 前导 gap 2008S / 2048S | ✅ 无 `-noEFI` → `-5344`；`-noEFI` 但无前导空隙 → part1 落在 LBA 40；`-noEFI` + `gap 2008S` → LBA 2008；**`-noEFI` + `gap 2048S` + 尾部 `R`** → 官方布局且 part2 精确 65536 扇区 |
| 42 | 同容量 8 GiB 完整 LIVE 演练（干净盘） | `rehearse-script disk5 8053063680` 生成真实 LIVE 脚本（仅跳过 root 门禁），`bash` 全量执行 | ✅ exit=0，**14/14 步**，日志显示 part1 @2048、part2 @15663064、exFAT 挂载 `/Volumes/Ventoy`、ISO 目录创建 |
| 43 | 同容量 8 GiB 字节级断言 | `gpt -r show -l` + 直读 GPT 表项 + `dd` 对齐读 + `cmp` 全 32 MiB 镜像比对 | ✅ **19/19 通过**：两个分区类型 GUID、LBA 与大小、无多余 ESP 表项、LBA0 的 `eb6390`/`0x22`/`0xee`/`55aa`/UUID 签名、`core.img` 全 2014 扇区逐字节、`ventoy.disk.img` 全 32 MiB 逐字节、GPT 主/备头与 CRC、卷挂载与 ISO 目录 |
| 44 | 模拟真机当前状态（MBR `windows` + 盘头清零） | 先在虚拟盘建 `FDisk_partition_scheme / DOS_FAT_32 WINDOWS`，清零 LBA 0–63，再跑 b7/r6 完整 LIVE 脚本 | ✅ exit=0，14/14 步，事后 `gpt -r show -l` 与官方布局一致，**19/19 字节断言通过**；证明旧 MBR 卷与已清零盘头都不影响重建 |

> 修正记录 1：早期版本误把 GPT 写入用的 `2014` 扇区当作 `core.img` 的校验上限，会拒绝官方真包（真包为 2047 扇区）。现已拆分为 `coreImageSectorCount = 2014`（写入量）与 `coreImagePackagedSectors = 2047`（镜像实际尺寸），并加入回归测试。
>
> 修正记录 2：真机首次运行因 macOS TCC 拒绝裸盘写入而中止。现已加入 0 字节权限预检与专项错误提示；该次失败发生在任何破坏性命令之前，U 盘数据未受影响。
>
> 修正记录 3：原先把「终端 + sudo」当作唯一可靠路径，后改为应用内写入为主，并固定代码签名标识（避免重新打包使 FDA 失效）、新增 0 字节权限自检。其中「operator 组直写」分支后被证伪，见修正记录 4。
>
> 修正记录 4：实测发现 `/dev/disk*` 为 `root:operator rw-r-----`（组仅可读）且 `gpt create/add` 硬性要求 euid 0，故「应用内直写」不可行；同时确认 `dd`/`gpt` 无磁盘访问 entitlement、提权派生进程不继承 app 的 FDA。现改为**签名 helper 提权通道**（app 与包内 helper 共用固定 DR）+ 双通道自动探测 + 一键给 `/usr/libexec/security_authtrampoline` 授权，operator 组脚本降级为诊断用途。
>
> 修正记录 5：FDA 打通后真机在第 4 步报 `dd: /dev/rdisk4: Invalid argument`（0 字节预检通过、`1+0 records in / 0+0 records out`）。根因不是权限，而是把官方 Linux 的 `bs=64 count=512` 照搬到 macOS 强制对齐的裸字符设备；此外 `bs=1 seek=92/17908/384/440` 同样会 EINVAL。现改为「`$VTOY_STAGE` 普通文件暂存字节补丁 → `bs=512` 整扇区写回」，预检增加 512 字节对齐读，末尾增加对齐读回校验，并加入逐行对齐回归测试与临时镜像字节模拟。
>
> 修正记录 6：修复后的日志再次出现同样的 `Invalid argument`，排查发现**磁盘上的 app 已是新二进制、但用户窗口仍是旧进程**（macOS 不替换已映射的 Mach-O），旧窗口继续生成旧脚本。现加入 `VentoyBuild`：构建标识写入脚本头、安装日志首行、应用启动日志与界面右下角；`make_app.sh` 生成 `BuildID.txt`，应用启动时比较「编译进本进程的 id」与「包内 id」，不一致即在安装页顶部显示红色「旧进程」卡片并提供一键退出。旧版脚本按「先备份」习惯归档在 `dist/archive/*.pre-buildstamp`。
>
> 修正记录 7：真机第 4 次运行，第 4 步 32 KiB 对齐清零成功，第 5 步 `gpt create: operation not permitted: create`。排查：日志未打印「以普通用户运行」→ `id -u`（有效 uid）已是 0，所以 `dd` 能写；`gpt` 是 FreeBSD 血统，其 `main()` 对写子命令检查 `getuid()`（真实 uid），而 `do shell script ... with administrator privileges` / `security_authtrampoline` 只把有效 uid 提升为 0，真实 uid 仍是登录用户。在普通文件上以 uid 501 执行 `gpt create -f` 复现出逐字相同的错误，排除了 TCC / 设备占用。**修复**：① 签名 CLI helper 的 `run-script` 在 spawn 前 `setuid(0)`；② 实时脚本顶部检测 `euid=0 && ruid!=0` 时用 `python3 os.setuid(0)` 重新 exec 自身（覆盖「直接提权」通道与手动导出的脚本）；③ 预检打印有效/真实 uid 并在临时普通文件上探测 `gpt` 能力，应用内「验证磁盘写入权限」同步加入该探测；④ **删掉先于 `gpt` 的 32 KiB `dd` 清零**，`gpt create -f` 成为第一条写盘命令——它本就重写 LBA 0–33 与末尾备份 GPT，LBA 34–2047 随后被 `core.img` 覆盖，清零冗余；失败即零改动。构建标识升到 `2026.11.10-b5` / `r4`。**⚠️ 本记录中关于「真实 uid 是根因」的结论后被用户第 5 份日志与本机实验证伪，仅保留为历史记录；最终结论见修正记录 8。**
>
> 修正记录 8：b5/r4 真机日志显示 `身份：有效 uid=0  真实 uid=0`，`gpt create -f` 在临时普通文件与真实盘上**仍**报 `operation not permitted: create`，说明 `setuid(0)` / ruid 修复无效。重新定位：`csrutil status` = enabled；`dyld_info -imports /usr/sbin/gpt` 含 `_csr_check`；`codesign -d --entitlements - /usr/sbin/gpt` 含 `com.apple.rootless.restricted-block-devices = true`；`gpt create -f` 在 root 身份下的普通文件、`hdiutil` 虚拟块设备上都可复现同一错误，而 `diskutil partitionDisk` 在同一虚拟盘上成功创建 GPT 与分区。**这是 SIP / rootless 对 `gpt` 写子命令的系统级封锁，不是身份或 TCC 问题。** 修复（构建 `2026.11.10-b6` / 脚本 r5）：① `InstallScriptBuilder` 删除所有 `gpt create/add/label/destroy`、`gpt` 能力探测与 `os.setuid(0)` 自举，首个写盘命令改为 `diskutil partitionDisk <disk> 3 GPT '%GUID%' … 'Free Space' 'spare' R`；② 第 5 步运行时从 `PartitionMapPartitionOffset` 回读 `$VTOY_PART2_LBA`（`diskutil` 会把 part1 对齐到 1 MiB，静态公式不再可靠），并断言分区 2 为 EFI、偏移 512 对齐；③ 新增 `vtoy_unmount()` / `vtoy_raw_write()` 规避 FAT 镜像写入后 DiskArbitration 自动挂载引起的 `Resource busy`，所有整盘 `dd` 排到 `newfs_exfat` / 挂载之前；④ `DiskAccessProbe` 改为 `PROBE_DISKUTIL_OK` / `PROBE_PARTITION_CHANNEL`，探针不再触碰 `gpt`；⑤ 修复 `set -u` 下 `$PROBE（` / `$PTYPE）` 这类中文全角标点造成的「非 ASCII 变量粘连」，统一改成 `${PROBE}` / `${PTYPE}`；⑥ CLI 新增 `rehearse-script` 供虚拟块设备跑完整 LIVE 脚本。验证：虚拟盘干净盘 14/14 步 + 21/21 断言、模拟真机盘头损坏 14/14 步 + 20/20 断言、27 XCTest / 0 失败、61 项自检 / 0 失败、4 份 `dist/*.sh` 语法通过、app 与 helper 签名通过。b5 旧脚本归档 `dist/archive/*.pre-sipfix`。⚠️ 本记录的虚拟盘演练用的是 128 MiB 映像，未触发大容量盘特有的自动 EFI 分区，遗留了 `-5344` 盲区，见修正记录 9。
>
> 修正记录 9：b6/r5 真机日志显示 FDA / 对齐预检 / `uid=ruid=0` 全部通过，第 4 步 `diskutil partitionDisk` 报 `Error: -5344: MediaKit reports not enough space on device for requested operation`。用 `hdiutil create -sectors 15728640 -layout NONE -type UDIF`（与 `disk4` 精确同容量）复现出逐字相同报错。根因：`diskutil partitionDisk` 在大于约 200 MiB 的 GPT 磁盘上会**自动插入 200 MiB（409600 扇区）EFI 系统分区**；官方 Ventoy 布局尾部只有 40 扇区余量，被挤爆。128 MiB 演练盘太小不触发该行为，是上轮验证的盲区。`-noEFI` 可关闭它，但实测关掉后首个分区默认起点从 LBA 2048 变为 **LBA 40**，会与 `core.img`（LBA 34–2047）冲突。修复（构建 `2026.11.10-b7` / 脚本 r6）：① 分区命令改为 `diskutil partitionDisk -noEFI <disk> 4 GPT …`，加入 `Free Space gap 2048S` 前导条目把 part1 顶回 LBA 2048，尾部保留 `Free Space spare R` 固定 VTOYEFI 为 65536 扇区；② 第 5 步新增 `$VTOY_P1_OFFSET / 512 == 2048` 硬断言，不满足即中止，防止 `core.img` 覆盖 exFAT 数据区；③ `DiskAccessProbe` 增加 `PROBE_NOEFI_OK`（检查 `diskutil partitionDisk` 帮助文本含 `-noEFI`），CLI 自检与 XCTest 同步加断言；④ `InstallPane` 说明文案更新。验证：-5344 在同容量虚拟盘复现、四种尺寸方案对比、同容量 8 GiB 完整 LIVE 脚本 14/14 步 + **19/19 字节级断言**（含 GPT 表项 GUID/LBA、LBA0 标记、`core.img` 全 2014 扇区、VTOYEFI 全 32 MiB 逐字节、GPT 主/备头与 CRC）、模拟真机「MBR windows 卷 + 盘头清零」场景 14/14 步 + 19/19 断言、128 MiB 小盘通用性、27 XCTest / 0 失败、68 项自检 / 0 失败、4/4 `dist/*.sh` 语法、app/helper 签名通过。b6 旧脚本归档 `dist/archive/*.pre-noefi`。

> 修正记录 10：用户反馈「开启 Secure Boot 的机器上必现 `Verification failed: (0x1a) Security Violation`，需要手动选签名」，希望加一个勾选后就免手动的选项。**先定性：那一次注册无法由制作端消除。** 查阅上游 `SecureBoot.md` 与 `INSTALL/ventoy_pack.sh` 确认链路为「固件 `db` → 微软签名的 Rocky shim（`EFI/BOOT/BOOTX64.EFI`）→ Ventoy 自签的 `grubx64.efi`/`fbx64.efi` → `grubx64_real.efi`」；第二跳的公钥不在固件 `db` 里，shim 必须交给 MokManager 注册 `ENROLL_THIS_KEY_IN_MOKMANAGER.cer`。信任根在目标机固件中，U 盘只是申请方，因此「单靠制作盘零交互」不成立；唯一零交互路径是把该证书一次性写入目标机固件 `db`。**实现（构建 `2026.11.10-b8` / 脚本 r7）**：① 新增 `FAT16Volume`（只读 FAT16 解析器：BPB / 目录项 / LFN / 簇链）与 `SecureBootInspector`，在**不挂载任何设备**的前提下核对 `ventoy.disk.img` 内的 shim / MokManager / 证书，并算出证书 SHA-256；不能用 `hdiutil attach`——它会生成 `/dev/diskN` 并污染本应用自己的「外接磁盘」目标列表。② 安装脚本新增条件步骤「校验 VTOYEFI 内的 Secure Boot 组件」：以 `diskutil mount readOnly nobrowse` **只读**挂载（macOS 挂载 FAT 会写入 `._*` 与 `.fseventsd`，实测确认）复查三件文件并比对写入前算出的指纹，缺件或指纹不符则在**格式化数据分区之前**中止。③ 新增步骤「写入 Secure Boot 注册材料」：把证书复制到数据分区根目录与 `SecureBoot/`，并生成中文 `SECURE-BOOT-README.txt`（含指纹、5 步注册流程、固件 `db` 预置说明、缺 MokManager 的判别方法）；严格策略时写 `ventoy/ventoy.json` 的 `VTOY_SECURE_BOOT_POLICY=1`，已存在则不覆盖。④ `InstallPlan` 增加 `secureBoot` + `secureBootInspection`，`InstallPlanError.secureBootIncomplete` 对「已知缺件」硬失败；解析失败（`unavailable`）不阻断，交由脚本侧权威校验。⑤ GUI 增加「UEFI Secure Boot」卡片（开关 / 策略 / 组件状态 / 指纹与复制 / 4 条风险说明），CLI 增加 `--secure-boot[=strict|bypass]` 与 `secure-boot-check`。**验证**：对**真实官方** `ventoy.disk.img` 实测——Swift 解析器与 shell 校验块给出同一指纹 `8072e285…f97012e27`，只读挂载后 `mount` 显示 `read-only`，识别出 shim `BOOTX64.EFI` / `MokManager mmx64.efi` / 证书 1420 B / 加载器 `grubx64_real.efi`、`fbx64.efi`、`grubia32*`；手搓 FAT16 夹具覆盖 LFN、嵌套目录、缺 MokManager、缺证书、非 FAT 镜像五种场景；39 XCTest / 0 失败、81 项自检 / 0 失败；生成的 LIVE 脚本 `bash -n` 通过。详见 `SECURE_BOOT.md`。

> 修正记录 11：用户反馈「制作完一个启动盘之后，点 Dock 图标没反应，窗口不会回到桌面上」。**先复现再改**：用辅助功能接口实测——应用进程存活、`activationPolicy` 为 regular、`AXWindows` 计数为 0；随后发送 reopen 事件（`open dist/VentoyMac.app`，与点 Dock 时的 `kAEReopenApplication` 同一条路径），窗口**没有**回来。根因：SwiftUI `WindowGroup` 关掉最后一个窗口后会让进程继续存活，却不会重建窗口，而 AppKit 把「重建」这件事交给 `applicationShouldHandleReopen`；本项目此前没有 AppDelegate，事件无人接收，应用于是变成一个永远点不亮的 Dock 图标。制作完成后尤其容易踩到——写入要跑十几步、用户会切走窗口，回来顺手点关窗或最小化，就再也叫不出来（最小化同理：默认实现不会 `deminiaturize`）。**修复（构建 `2026.11.11-b9` / 脚本 r7，脚本无变化）**：① 新增 `AppDelegate`（`@NSApplicationDelegateAdaptor`）实现 `applicationShouldHandleReopen` → 调用 `MainWindow.show()`；`applicationShouldTerminateAfterLastWindowClosed` 返回 `false` 保留日志与设置；`applicationDidFinishLaunching` 强制 `setActivationPolicy(.regular)`；`applicationSupportsSecureRestorableState` 返回 `true` 消掉控制台警告。② `MainWindow` 在一个零尺寸的 `Registrar` 视图里用 `@Environment(\\.openWindow)` 捕获 `openWindow(id:)`，用它重建被销毁的窗口（`OpenWindowAction` 在窗口销毁后仍然有效，这是关键），窗口还在时则 `deminiaturize` + `makeKeyAndOrderFront` + `NSApp.activate`，覆盖「已关」「已最小化」「被别的 App 挡住」三种情况。③ `WindowGroup` 改为带 id 的 `WindowGroup("VentoyMac", id:)`，并在「窗口」菜单加入「显示主窗口 ⌘0」作为兜底入口。**验证**：全部用辅助功能接口真机驱动，不靠肉眼看——关窗后 reopen 重建出窗口（#25934）；最小化后 reopen 还原（#25937）；窗口为 0 时按 ⌘0 也能重建（#25939）；「窗口」菜单确认含「显示主窗口」。修复前的同样三步全部得到 `NO_VISIBLE_VENTOY_WINDOW`。

> 修正记录 12：容量矩阵演练（回答「512M/1G/2G/4G/8G/16G/32G/64G/128G/256G U 盘及 256GB 以上移动硬盘会不会报错」）。方法：每档用 `hdiutil create -type SPARSE -layout NONE` 建对应字数的虚拟盘 → `rehearse-script` 生成完整 LIVE 脚本（b9，仅跳过 root 门禁）→ 在映像上实跑 14 步 → 事后断言分区尺寸/EFI 类型/卷标。**11 档（512MB…512GB）全部 rc=0、14/14 步骤走完、无一条 ⚠/错误**；exFAT 簇按官方 `mkexfatfs -s` 语义在 >32 GiB 切 128 KiB（实测 32GiB 整走 64 扇区/32 KiB、64GB 档起走 256 扇区/128 KiB，分界正确）。结论：布局对 ≥34 MiB 的盘恒可解，`partitionDisk -noEFI` + 前导 2048S 空隙在所有尺寸下都把 part1 顶回 LBA 2048，不存在容量相关的报错分支。**演练暴露一个真缺陷**：<34 MiB 时 CLI 顶层 `try` 触发 Swift fatal error（退出码 133），像崩溃。修复（构建 `2026.11.11-b10`，安装脚本仍 r7）：`layoutOrDie` 包装 4 处顶层布局调用，改为打印「磁盘容量不足，Ventoy 至少需要 34 MiB 可用空间」并 exit(1)。GUI 路径本就安全（`layout == nil` → 按钮置灰 + canBuildPlan 拦截）。验证：16 MiB 档现返回 exit=1 与中文提示；39 XCTest / 0 失败、self-test 全绿。



真机验证建议（在有可丢弃 U 盘的环境）：

```bash
# 1. 写盘前
diskutil info -plist /dev/diskN | plutil -extract Internal raw -o - -   # 必须是 false

# 2. 写盘后核对布局
sudo gpt -r show -l /dev/diskN        # 只读；SIP 开启时 gpt 的写子命令不可用，读子命令不受影响
# 期望：index 1 起始 2048、类型 Microsoft Basic Data；index 2 大小 65536 扇区、类型 EFI System
# 注意：diskutil partitionDisk 用 %GUID% 指定类型时不写 GPT 分区项 Name，
#       `gpt -r show -l` 的名字列可能是 ""，请用 diskutil list 交叉核对卷名 Ventoy / VTOYEFI

# 3. 核对引导标记（必须 512 字节对齐读取；bs=1 在 macOS 裸设备上会 EINVAL）
sudo dd if=/dev/rdiskN of=/tmp/vtoy-lba0.bin bs=512 count=1
sudo dd if=/dev/rdiskN of=/tmp/vtoy-lba34.bin bs=512 count=1 skip=34
xxd -s 92  -l 1 -p /tmp/vtoy-lba0.bin    # 22
xxd -s 510 -l 2 -p /tmp/vtoy-lba0.bin    # 55aa
xxd -s 500 -l 1 -p /tmp/vtoy-lba34.bin   # 23（对应绝对字节 17908）
rm -f /tmp/vtoy-lba0.bin /tmp/vtoy-lba34.bin

# 4. 数据分区可挂载并含 ISO 目录
diskutil info /dev/diskNs1
ls -la /Volumes/Ventoy/ISO
```

---

## 9. 引导资源说明

从 `ventoy-1.1.18-linux.tar.gz` 提取并缓存到 `~/Library/Application Support/VentoyMac/boot-<version>/`：

| 文件 | 实测大小（v1.1.18） | 用途 |
|---|---|---|
| `boot.img` | 512 B | MBR 引导代码；只取前 446 字节覆盖到暂存 `mbr.bin`，保留 GPT 保护 MBR 分区项 |
| `core.img` | 1,048,064 B = 2047 扇区（由 `core.img.xz` 解压） | Legacy BIOS GRUB core；GPT 模式只写前 2014 扇区到 `seek=34`（MBR 模式官方写全部 2047 扇区到 `seek=1`） |
| `ventoy.disk.img` | 33,554,432 B = 65,536 扇区（由 `ventoy.disk.img.xz` 解压） | 完整 VTOYEFI FAT16 分区，根目录含 `EFI/BOOT/`、`grub/`、`ventoy/`、`tool/` |

只读挂载该 32 MiB 镜像后确认，`EFI/BOOT/` 中有 `BOOTX64.EFI`、`BOOTIA32.EFI`、`BOOTAA64.EFI`、`BOOTMIPS.EFI`，`ventoy/` 中有 `ventoy_aa64.efi`、`iso9660_aa64.efi`、`udf_aa64.efi`、`vtoyutil_aa64.efi` 等 ARM64 模块——所以成品可在 ARM64 UEFI 设备上启动（但**不能**直接在 Apple Silicon Mac 上启动，见第 2 节）。

`xz` 解压优先调用 `/opt/homebrew/bin/xz`，缺失时回退到系统 `/usr/bin/python3` 的 `lzma` 标准库，无第三方依赖。导入完成后写入 `manifest.json`，记录版本、缓存路径、来源文件名与 SHA256；GUI 与 CLI 均通过 `BootAssetInstaller` 读取同一份清单。

---

## 10. 完全磁盘访问：让 VentoyMac 在应用内直接写入（无需终端）

### 机制（本机实测结论）

| 事实 | 证据 |
|---|---|
| `/bin/dd` **没有** `com.apple.private.security.disk-device-access` entitlement | `codesign -d --entitlements -` |
| `/usr/sbin/gpt` 带 `com.apple.rootless.restricted-block-devices = true` 并导入 `_csr_check`；SIP 开启时 `create/add/label/destroy` 在命令分派层被无条件拒绝 | `codesign -d --entitlements - /usr/sbin/gpt`；`dyld_info -imports`；`csrutil status` |
| `/usr/sbin/diskutil`、`/sbin/newfs_exfat` **有**磁盘访问 entitlement | 同上 |
| 写 `/dev/disk*` / `/dev/rdisk*` 因此只能靠 **TCC 责任进程的 FDA** 放行，root 也不能绕过 | 应用内提权（uid 0）仍返回 `Operation not permitted` |
| `gpt create -f` 即使在 `uid=0 / ruid=0` 下，对**普通临时文件**与**虚拟块设备**也报 `operation not permitted: create` | 本机实测；证明这是 SIP/rootless 封锁，非身份、非 TCC、非设备占用 |
| `diskutil partitionDisk` 在同一虚拟块设备上成功创建 GPT、分区节点与文件系统 | 虚拟盘端到端演练（第 8 节第 36/37 项） |
| **不加 `-noEFI` 时，`diskutil` 会在 >200 MiB 的 GPT 磁盘上自动插入 200 MiB EFI 分区**（LBA 40 + 409600 扇区），挤爆官方布局尾部的 40 扇区余量 → `-5344` | `diskutil partitionDisk` 帮助文本 `[-noEFI]`；同容量 8 GiB 虚拟盘复现（第 40 项） |
| 加 `-noEFI` 后首个分区默认起点变成 LBA 40，需要 `Free Space gap <part1Start>S` 顶回 2048 | 四种尺寸方案对比（第 41 项） |
| `/dev/disk4`、`/dev/rdisk4` = `root:operator` **rw-r-----**（组仅可读） | `ls -l /dev/disk4 /dev/rdisk4` |
| 普通用户打开裸盘报 `Permission denied` | 本机实测 |

> **注意（对应修正记录 4）**：早期版本建议「把用户加入 operator 组让 app 以当前用户直写」，这条路**不成立** —— 组权限只有读，且分区/格式化操作需要 root。该方案已从 UI 主流程移除，`group-setup-script` 仅保留作诊断。
>
> **注意（对应修正记录 8/9）**：`gpt` 写命令的 EPERM 曾被误判为「真实 uid 非 0」，b5/r4 的 `setuid(0)` / `os.setuid(0)` 自举被真机日志直接证伪。真正原因是 SIP 开启时 `gpt` 的 `restricted-block-devices` 限制。因此 b6/r5 起**完全不使用 `gpt` 写命令**，改由 `diskutil partitionDisk`（DiskArbitration，具备 entitlement）建立分区表；b7/r6 进一步加上 `-noEFI`（关掉自动 200 MiB EFI 分区，解决 `-5344`）与前导 `Free Space`（把 part1 顶回 LBA 2048）。`/bin/dd` 仍负责写引导镜像，这部分依旧由 FDA 放行。

### 本轮修复：签名 helper 提权通道

`osascript ... with administrator privileges` 把脚本交给 `/usr/libexec/security_authtrampoline`，后者派生的 root 进程在 TCC 眼里**不是** VentoyMac.app，所以只给 app 加 FDA 仍会 EPERM（社区案例里给 Terminal 和 Script Editor 都授权也无效）。

现在提权命令不再直接 exec `/bin/bash`，而是 exec app 包内的 `Contents/Resources/VentoyWriter.app/Contents/MacOS/VentoyWriter run-script <脚本>`。它是一个**完整的嵌套 .app bundle**（自带 Info.plist，`CFBundleVersion=1`），被签上**与应用完全相同的固定 designated requirement**：

```
=designated => identifier "cn.ventoymac.VentoyMac" and info[CFBundleVersion] >= "1"
```

于是提权链里真正 spawn `dd` / `diskutil` / `newfs_exfat` 的进程，其代码标识与用户已授予的 FDA 记录匹配。「验证磁盘写入权限」会**自动依次测试** `签名 helper 提权` → `直接提权（兼容模式）`，并自动选用第一个可用通道，每个通道弹一次系统密码框。

> 为什么 helper 必须是 `.app` 而不是裸二进制：独立 Mach-O 没有 Info.plist，`codesign --verify --strict` 会报 `does not satisfy its Designated Requirement`（`info[CFBundleVersion] >= "1"` 恒为假），TCC 用同一条 csreq 评估它时也会失败。嵌套 bundle 实测为 `valid on disk` + `satisfies its Designated Requirement`。

对应实现：`Scripts/make_app.sh`（组装 `VentoyWriter.app` 并给 app 与 helper 签同款 DR）、`Sources/VentoymacCLI/main.swift` 的 `run-script`、`Sources/VentoyMac/Services/ProcessRunner.swift` 的 `PrivilegedChannel`、`AppState.verifyDiskAccess()`。

### 操作步骤（按序，不需要终端）

1. **系统设置 → 隐私与安全性 → 完全磁盘访问** → 添加并启用 `dist/VentoyMac.app`。应用「安装」页有「打开『完全磁盘访问』设置」和「在访达中显示应用」按钮可直接跳转。
   本机当前状态：`cn.ventoymac.VentoyMac` 已是 `auth_value=2`（允许），其 `csreq` 解出正是上述固定 DR，**授权有效且重新打包不会失效**。
2. **完全退出 VentoyMac 并重新打开**（授权只在进程启动时生效）。
3. 「安装」页 → **验证磁盘写入权限** → 观察日志自动选出的通道；显示 ✅ 且出现 `PROBE_DISKUTIL_OK` / `PROBE_NOEFI_OK` / `PROBE_RESULT: OK` 后直接点「写入磁盘…」→「应用内直接写入」。
4. **若两个通道都失败**：点 **「给系统提权进程授权」**（会复制路径并打开设置），在「完全磁盘访问」点 `+` → 按 **Cmd-Shift-G** → 粘贴 `/usr/libexec/security_authtrampoline` → 选中并打开开关 → **完全退出并重开 VentoyMac** → 再点一次「验证磁盘写入权限」。
   这一步针对的正是 TCC 实际判定的提权进程；一次性完成，不涉及终端，也不修改磁盘数据。

### 最后兜底：终端（明确不想用终端时可跳过）

给 Terminal.app 加 FDA → 完全退出重开终端 → `ventoymac-cli live-script disk4 > install.sh` → `bash -n install.sh` → `sudo bash install.sh`。也可在确认弹窗选「在终端中写入（备用）」。注意：本机系统 TCC 库中 `com.apple.Terminal` 的 FDA 当前是**关闭**状态，此路径需要先打开它。

### 数据安全

最初的 EPERM 失败发生在第一条 `dd`，`gpt destroy` 同样被拒（被 `|| true` 吞掉）；第二次 FDA 已通过预检，但第 4 步 `bs=64` 的非对齐写被内核以 `EINVAL` 拒绝，`0+0 records out`；第三次是旧进程残留的重复日志。**这三次都没有任何写入成功。** 第四次（b4）第 4 步成功写入了 **32 KiB 零**（LBA 0–63），随后被 `gpt create` 拒绝——这是唯一一次真正改动了 U 盘：原 MBR / 分区表已清零，LBA 2048 之后的数据区未动，但旧卷当前不可直接挂载。第五次（b5/r4）在首条写盘命令 `gpt create -f` 处中止，**零写入**；第六次（b6/r5）在第 4 步 `diskutil partitionDisk` 报 `-5344` 后中止，**同样零写入**（`Started partitioning` / `Creating the partition map` 只是 DiskArbitration 的准备日志，MediaKit 在空间检查阶段就拒绝了）。b7/r6 本轮全部工作只在 `hdiutil` 虚拟盘上进行，**未对真实 `disk4` 写入任何字节**；最后一次只读复核：`disk4` 8.1 GB、`15728640` 个 512 字节单元、`Mounted: No`、`Content: None`。由于本工具本来就要重建整盘，**不要尝试恢复旧卷，直接重跑完成安装即可**；若需临时访问旧数据，可用数据恢复工具按 LBA 2048（或原分区起始扇区）重建分区表。

现在第 3 步会在卸载之后、任何写入之前完成 0 字节写打开 + 512 字节对齐读 + 身份/分区通道打印；第 4 步 `diskutil partitionDisk -noEFI` 是首条写盘命令（若失败，磁盘零改动），第 5 步断言 part1 @2048 与 part2 类型/偏移；随后所有整盘 `dd` 都经过 `vtoy_raw_write` 的「卸载 → 写入 → 最多 5 次重试」，并在第 9 步做对齐读回校验。

### 相关 CLI（除 `run-script` 外全部只读输出，绝不执行）

```bash
ventoymac-cli probe-script disk4        # 0 字节写打开 + 512 字节对齐读 + diskutil/-noEFI 分区通道探针
ventoymac-cli live-script disk4         # 实时安装脚本（供人工审阅，14 步 / b7-r6；有 ISO 时会多一步「复制镜像」）
ventoymac-cli build-id                  # 构建标识与旧进程检测
ventoymac-cli group-setup-script        # 【已弃用】operator 组诊断脚本
```

---

## 11. `Verification failed: (0x1a) Security Violation` 排查（必读）

**这个报错不是 Ventoy 坏了，也不是用本工具制作盘做错了。** 它是 UEFI Secure Boot 的正常安全机制，官方 Windows / Linux 安装器做出来的盘同样会遇到。任何制作工具都改变不了这一点，原因如下。

### 为什么会出现

开启 Secure Boot 的电脑只会执行「固件信任库（db）里有签名」的引导程序。Ventoy 的启动链是：

```
固件 db ──验证──▶ shim（微软签名 ✓）──验证──▶ grubx64.efi（Ventoy 自签 ✗）
```

- Ventoy 的 GRUB 是 GPLv3 开源代码，微软不会对开源引导器签发 UEFI 签名，所以 Ventoy 借用了 Rocky Linux 的 **shim**（有微软签名，第一跳合法通过）。
- shim 之后要加载的 `grubx64.efi` 用 **Ventoy 自己的密钥**签名，这把钥匙不在你电脑的固件 db 里。
- 于是 shim 弹出 **MokManager** 注册界面让你手动确认「是否信任这把钥匙」，屏幕上先闪现的那行 `Verification failed: (0x1a) Security Violation` 就是这次"暂时不认识"的记录。**这是设计行为，不是错误**——它正是 Secure Boot「首次使用需人确认」的环节。

信任根在**目标电脑的固件**里、不在 U 盘上，所以没有任何制作端软件能"做一张盘就免掉这次确认"（官方文档：`https://www.ventoy.net/en/doc_secure.html`，本仓库 `SECURE_BOOT.md` 有完整分析）。

### 解决方案（三选一）

**方案 A：现场注册一次（推荐，每台电脑只需一次）**

看到 `0x1a` 后**不要关机**，屏幕下方会有 MokManager 蓝色菜单（"Perform MOK management"）。用键盘操作：

1. 选 **Enroll Key from Disk**（从磁盘注册密钥）→ 选择 Ventoy 分区；
2. 进入 `SecureBoot/` 目录（本工具制作的盘把它放在卷根目录也放了一份），选择 **`ENROLL_THIS_KEY_IN_MOKMANAGER.cer`**（约 1420 字节；**不要**选 `._` 开头或几 KB 的伴生假文件）；
3. 确认指纹（本工具制作的盘会把 SHA-256 写在数据分区 `SecureBoot/SECURE-BOOT-README.txt` 里）→ **Enroll** → 重启。

此后同一台电脑永久免操作。制作时勾选「启用 Secure Boot 支持」，本工具会自动预校验组件齐全并把证书和中文说明放进 U 盘，让上面三步变成"回车 + 选文件 + Enroll"。

⚠️ 若蓝屏只有 `0x1a` 一行、**没有** MokManager 菜单且直接弹回 BIOS，说明盘里缺 MokManager（`mmx64.efi`）——用本工具制作时缺件会被硬性拦截（见 `SECURE_BOOT.md`），此时应更换 Ventoy 官方发布包重新制作。

**方案 B：BIOS 里临时关闭 Secure Boot**

BIOS → Security / Boot → Secure Boot → Disabled。最快，但整台机器的启动防护也随之关闭；部分品牌（如某些 OEM 预装 Win11 的机器）需要先在 BIOS 设置管理员密码才能改此项。

**方案 C：把证书预置进固件 db（彻底免按键，适合企业批量）**

一次性把 `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` 导入目标机固件的 **Signature Database (db)**：BIOS → Security / Key Management → Custom Secure Boot Keys → Add to db。之后每次启动全自动，MokManager 不再出现。这是唯一"零交互"路径，代价是需要在每台机器上操作一次（可用厂商工具批量推送）。

### 常见误解

| 误解 | 事实 |
|---|---|
| "在 BIOS 里找到对应签名选一下就好" | `0x1a` 界面是 shim/MokManager 画的，不是 BIOS 菜单，BIOS 里没有"选择签名"选项 |
| "换个制作工具就不会报 0x1a" | 官方 Ventoy2Disk（Windows/Linux）做的盘同样会弹；区别只在这一次确认的体验 |
| "证书注册后换台电脑还要再来一次" | 对——每台开 Secure Boot 的电脑各注册一次（或方案 C 预置固件） |
| "U 盘上的注册材料就是问题本身" | 注册材料（`.cer`）只是"申请入库的钥匙副本"，装不装盘都能启动，装了只是让注册更快 |

---

## 12. 许可与版权

本仓库是 Ventoy 官方安装器在 macOS/Apple Silicon 上的移植实现，逐行复刻其磁盘布局算法并复用其发布的引导二进制，因此**整体按 GNU GPLv3 分发**（与上游 Ventoy 相同），全文见仓库根目录 [`LICENSE`](LICENSE)。

- **Copyright (C) 2026 VentoyMac contributors**（本仓库新增的 Swift 安装器代码）
- **Copyright (C) 2020-2026 Ventoy contributors**（被移植的布局算法与复用的引导镜像；本仓库不包含其源码修改，运行时从官方 Release 获取并经 SHA-256 校验，见第 9 节）
- 复用镜像内部组件各自的许可证随官方发布包一并分发：GNU GRUB2（GPLv3）、shim / MokManager（源自 Rocky Linux，含 MIT 与 GPLv2 组件）、exFAT 工具（GPLv2）等。

你可以自由地复制、修改、再分发本项目，条件是以 GPLv3 公开完整对应源码并保留本声明。**关于 Mac App Store**：GPLv3 第 10 节禁止对下游施加额外限制，而 MAS 的 DRM 与强制商店更新机制构成额外限制，因此本类 GPL 软件不适合通过 Mac App Store 分发；推荐的分发方式是 GitHub Release + Developer ID 签名 + Apple 公证（notarytool），同样能通过 Gatekeeper 直接安装。

---

## 13. 参考

- 磁盘布局：`https://www.ventoy.net/en/doc_disk_layout_gpt.html`
- 官方构建：`DOC/BuildVentoyFromSource.txt`、`INSTALL/ventoy_pack.sh`
- 布局算法：`INSTALL/tool/ventoy_lib.sh`（`format_ventoy_disk_gpt`）
- 写盘流程：`INSTALL/tool/VentoyWorker.sh`
- Release：`https://github.com/ventoy/Ventoy/releases/tag/v1.1.18`

Ventoy 为 GPLv3 项目。本项目仅复用其发布的引导二进制与磁盘格式，未修改其源码；使用时请遵守 Ventoy 许可证。
