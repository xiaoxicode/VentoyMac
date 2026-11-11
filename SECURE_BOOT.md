# UEFI Secure Boot 支持：能做到什么、做不到什么、以及本项目怎么实现

> 适用构建：`2026.11.10-b8` / 安装脚本 `r7`
> 上游依据：`ventoy/Ventoy` v1.1.18 的 `SecureBoot.md`、`INSTALL/ventoy_pack.sh`、`INSTALL/tool/VentoyWorker.sh`

---

## 1. 现象：为什么插上就报 `0x1a`

在开启 Secure Boot 的机器上第一次从 Ventoy 盘启动，会看到蓝底一行：

```
Verification failed: (0x1a) Security Violation
```

回车后进入一个只能上下选择的简陋菜单，里面才有 `Enroll key from disk`。

**这不是 BIOS 里少勾了什么，也不是 U 盘做坏了。** 这是 **shim**（`shimx64.efi` 那一层）在按 UEFI 规范拒绝加载下一阶段，并把控制权交给 **MokManager**（`mmx64.efi`）。菜单是 MokManager 画的，不是 BIOS 画的——所以在 BIOS 里翻不到「选择签名」这种选项是正常的。

## 2. 根因：Ventoy 的引导链有两把钥匙

Ventoy 的 grub2 是 GPL，拿不到 UEFI CA 的签名，所以它**借用了 Rocky Linux 的 shim**（微软签名，在每台机器的固件 `db` 里都能验过）：

| 阶段 | 文件（在 VTOYEFI 分区内） | 签名者 | 固件/`db` 是否信任 |
|---|---|---|---|
| 固件 → 第一阶段 | `EFI/BOOT/BOOTX64.EFI`（Rocky shim） | Microsoft UEFI CA 2011 / 2023 | ✅ 信任 |
| 第一阶段 → 第二阶段 | `EFI/BOOT/grubx64.efi` / `fbx64.efi` | **Ventoy 自己的密钥** | ❌ 不信任 |
| 第二阶段 → grub | `EFI/BOOT/grubx64_real.efi` | Ventoy 自己的密钥 + 内嵌 SHA256 校验 | ❌ 不信任 |

因为第二跳是用 Ventoy 私钥签的，而固件的 `db` 里没有这枚公钥，**shim 必须停下来问一次**：

> 要不要把这枚 Ventoy 证书加进这台机器的信任列表？（`ENROLL_THIS_KEY_IN_MOKMANAGER.cer`）

用户点了 `Enroll` 之后，证书写进该机的 **MOK**（Machine Owner Key）列表，shim 以后就认这把钥匙了。

官方文档原话（`SecureBoot.md`）：

> Ventoy does not have its own shim and must make use of a third-part shim. When boot Ventoy with Secure Boot enabled, the shim will not directly boot Ventoy grub because Ventoy grub is not signed with the shim embedded Certificate. The shim will open the MokManager and we must enroll Ventoy's Secure Boot Key and reboot.

## 3. 结论：为什么"勾一下就彻底免掉"做不到

**信任根在目标机固件里，不在 U 盘上。** Secure Boot 的定义就是"只执行被我信任的代码"，而这个"我"是每台机器的固件。U 盘是申请方，不是授权方——它能做的极限是"把申请材料准备好"，不能替固件做决定。

逐个排除其他可能：

| 想法 | 为什么不可行 |
|---|---|
| 制作盘时把证书塞进 U 盘就免验证 | 证书必须在**目标机**的 `db`/MOK 里，放在 U 盘上只是给 MokManager 读的材料 |
| 换用微软签名的 grub 代替 Ventoy grub | Ventoy 的 grub 带 `vtoy` 私有模块（读 ISO、注入、持久化都靠它），换掉就不是 Ventoy 了 |
| 让 shim 跳过校验 | 那是 shim 的安全边界，只有 `db` 里的私钥能改；能改意味着 Secure Boot 形同虚设 |
| 关掉 Secure Boot 再启动 | 可行，但那是另一条路（且很多企业策略不允许） |

所以**任何"单靠制作盘就零交互"的承诺都是假的**。真正能做到零交互的只有一条路：**把这枚证书一次性写进目标机固件 `db`**，之后这台机器上的任何 Ventoy 盘都直接启动、永不询问。

## 4. 本项目实现的方案

勾选「启用 Secure Boot 支持」后，安装流程多出两件事——都发生在**能由 U 盘控制**的范围内：

### 4.1 写入前：离线校验镜像（不挂载任何设备）

`SecureBootInspector` 用自写的只读 FAT16 解析器（`Sources/VentoyCore/FAT16Volume.swift`）直接读 `ventoy.disk.img`，确认三件东西在不在：

| 组件 | 缺了会怎样 |
|---|---|
| `EFI/BOOT/BOOTX64.EFI`（shim） | 固件在跑 Ventoy 代码之前就拒绝，**连 MokManager 都进不去** |
| `EFI/BOOT/mmx64.efi`（MokManager） | 只能显示 `0x1a`，没有 `Enroll key from disk` 菜单 → **这台机器永远启动不了这张盘** |
| `ENROLL_THIS_KEY_IN_MOKMANAGER.cer` | 没有可注册的对象 |

同时算出证书的 **SHA-256 指纹**并显示在界面上（本项目实测官方 1.1.18 的指纹为 `8072e285ed57…f97012e27`）。这个指纹有三个用处：企业白名单、固件 `db` 预置核对、以及下面 4.2 的完整性校验。

**为什么不用 `hdiutil attach` 来检查**：attach 会创建 `/dev/diskN` 节点，立刻出现在本应用自己的「外接磁盘」列表里——那是破坏性操作的目标选择器，绝不能混入虚拟盘。纯内存解析没有这个副作用，也能在没插 U 盘时就给出结论。

### 4.2 写入后：权威校验（只读挂载）

`diskutil partitionDisk` 之后写完整 32 MiB EFI 镜像，紧接着**只读挂载** VTOYEFI 分区复查同样的三件文件：

```bash
/usr/sbin/diskutil mount readOnly nobrowse /dev/diskNs2
```

- 只读是必须的：macOS 挂载 FAT 会顺手写入 `._*`、`.fseventsd`，污染引导分区（实测会生成 4 个 `._*` 文件和一个 `.fseventsd` 目录）。
- 复查失败 → **在格式化数据分区之前中止**，并明确告知"U 盘引导区完整、数据区未格式化、请重新制作"。避免做出一张"看起来成功但永远启动不了"的盘。
- 复查通过 → 用 `shasum -a 256` 比对写入前算出的指纹。不一致说明 EFI 镜像没写全（例如被系统占用后重试失败），同样中止。

### 4.3 数据分区：把注册做成"两次按键"

MokManager 的文件浏览器从卷根开始、界面是纯文本列表。所以注册材料放在**伸手就能拿到**的位置：

```
<数据分区>/
├── ENROLL_THIS_KEY_IN_MOKMANAGER.cer      ← 卷根，第 4 步第一屏就能选中
├── SecureBoot/
│   ├── ENROLL_THIS_KEY_IN_MOKMANAGER.cer
│   └── SECURE-BOOT-README.txt             ← 中文步骤 + 指纹 + 各厂商路径
└── ventoy/ventoy.json                     ← 仅"严格策略"时生成
```

说明文件里写清了完整流程（含 `0x1a` 是正常现象、注册只需一次、如何彻底免按键、以及"蓝屏只有 0x1a 没有菜单＝缺 MokManager"的判断方法）。

**实际跑出来的一个坑**：macOS 的 exFAT 实现在新建文件/目录时会同时写一份 `._xxx` 伴生元数据（实测 `cp`、`cp -X`、`ditto --noextattr` 都躲不掉）。MokManager 的文件列表会把它一并列出、而且它排在前排——用户很容易选中那个 4096 字节的假文件，然后注册失败。所以脚本在写完材料后会把本次安装自己创建的 `._` 条目删掉（路径全部写死，不用通配符），实测删除后重新挂载也不会复现。

### 4.4 策略选择（官方全局控制插件）

| 选项 | `VTOY_SECURE_BOOT_POLICY` | 行为 |
|---|---|---|
| 完全绕过验证（默认） | 不写（等同 `0`） | 注册 Ventoy 密钥后 Ventoy 自己跳过对镜像的签名检查，功能全开 |
| 遵循固件策略（严格） | `1` | 每个 EFI 负载仍按固件策略验签，只能启动 UEFI CA 签名的镜像；`grub2boot` / `insmod` 等受限 |

严格策略写入 `ventoy/ventoy.json`：

```json
{ "control": [ { "VTOY_SECURE_BOOT_POLICY": "1" } ] }
```

若该文件已存在（例如用户自己维护插件），脚本**不覆盖**，只打印提示。

## 5. 用户侧完整流程

### 5.1 每台新机器一次（约 15 秒）

1. 开机启动菜单选 **UEFI:** 开头的那一项（不要选 Legacy/CSM 项）。
2. 蓝屏 `0x1a` → 按 **回车**。
3. `Enroll key from disk` → 选 U 盘根目录的 `ENROLL_THIS_KEY_IN_MOKMANAGER.cer`。
4. `Enroll` 确认 → `Reboot`。
5. 再启动，直接进 Ventoy 菜单。

之后**同一台机器**、任何用同一枚证书做的 Ventoy 盘（本项目重做的盘证书完全相同），都不会再问。

### 5.2 想彻底免按键：写入固件 `db`

多数商用机支持以下之一，做一次即可永久生效：

| 厂商 | 路径 |
|---|---|
| Dell / Lenovo / HP 商用机 | BIOS → Security → Secure Boot → **Key Management** → `db` → Append / Enroll Key |
| 支持 "Enroll EFI Image" 的机型 | BIOS 里直接选 U 盘上的 `bootx64.efi`，厂商会代为入 `db` |
| 企业批量 | 用厂商管理工具（Dell Command Configure / Lenovo WMI / HP BCU）在装机阶段推送 `db` 证书 |

写入对象就是数据分区里那枚 `.cer`；核对其 SHA-256 与界面显示的指纹一致再写。

> ⚠️ 部分消费级主板只有在 **Setup Mode**（清空平台密钥）下才允许改 `db`。改 `db` 属于安全边界操作，出错可能导致机器拒绝启动已装的系统——企业环境请先在测试机验证。

## 6. 已知的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| BIOS 里没有 "Allow Microsoft 3rd Party UEFI CA"，且根本进不到 `0x1a` 界面 | 固件直接拒绝了微软第三方 CA 签名的 shim | 在 BIOS 里开启该选项（部分机型叫 "Select UEFI file as trusted for executing"），或关闭 Secure Boot |
| 蓝屏只有 `0x1a`，没有 `Enroll key from disk` | VTOYEFI 里缺 `mmx64.efi`，或 EFI 镜像没写全 | 本项目已在写入时拦截；手工做的盘请重新制作 |
| 某次升级 Ventoy 后所有机器又开始问 | **Ventoy 1.1.13 起更换了新密钥**（UEFI CA 2023 问题），证书指纹变了 | 每台机器重新注册一次；旧盘不受影响 |
| 已注册过，换一张旧版本做的盘又提示 | 两张盘的证书不是同一枚 | 用界面上的指纹核对；统一用同一版本镜像制作 |
| 严格策略下某些 ISO 启动失败 | 策略 2 只允许 UEFI CA 签名的 EFI 负载 | 换回默认策略，或改用官方签名的引导器 |
| 挂载 VTOYEFI 后分区里多出 `._*` / `.fseventsd` | macOS 挂载 FAT 的元数据行为 | 本项目脚本用 `mount readOnly nobrowse` 规避；手工检查时务必加 `readOnly` |
| MokManager 列表里有两个同名 `.cer`，一个 4096 字节 | 那个是 macOS 的 `._` 伴生元数据，不是证书 | 选不带 `._` 前缀的（1420 字节）；本项目已自动清理 |
| 数据分区根目录有 `.fseventsd` / `.Trashes` | macOS 挂载外部卷时自行创建 | 无害，不影响 Ventoy 与 MokManager |

## 7. 代码位置

| 文件 | 作用 |
|---|---|
| `Sources/VentoyCore/SecureBoot.swift` | 常量、`SecureBootOptions` / `SecureBootPolicy`、`SecureBootInspector`（组件判定 + 指纹） |
| `Sources/VentoyCore/FAT16Volume.swift` | 只读 FAT16 解析器（BPB / 目录项 / LFN / 簇链），无磁盘副作用 |
| `Sources/VentoyCore/InstallScriptBuilder.swift` | 两个条件步骤：写入后只读校验、数据分区注册材料 |
| `Sources/VentoyMac/Views/InstallPane.swift` | 「UEFI Secure Boot」卡片：开关、策略、组件状态、指纹 |
| `Sources/VentoymacCLI/main.swift` | `--secure-boot[=strict\|bypass]`、`secure-boot-check` |

## 8. 验证方法

```bash
make selftest                                   # 81 项自检（含 Secure Boot 断言）
make test                                       # 39 项 XCTest（含手搓 FAT16 夹具）
./.build/out/Products/Release/ventoymac-cli secure-boot-check
#   状态  : Secure Boot 组件齐全（shim + MokManager + 证书）
#   SHA256: 8072e285ed57ffd63421beb52d5c27cb5ad70a8d7377b67b358f816f97012e27

# 生成含 Secure Boot 的脚本并做语法检查
./.build/out/Products/Release/ventoymac-cli rehearse-script disk9 8589934592 --secure-boot-policy=strict > /tmp/live.sh
bash -n /tmp/live.sh
```
