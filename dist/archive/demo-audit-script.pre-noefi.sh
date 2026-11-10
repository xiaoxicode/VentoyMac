#!/bin/bash
# =====================================================================
# VentoyMac generated install script
# Target : /dev/disk9  (CLI Fixture, 34.36 GB)
# Version: Ventoy self-test
# Mode   : AUDIT (no writes)
# Layout : GPT / part1 LBA 2048 + 67041240, part2 LBA 67043288 + 65536
# Build  : 2026.11.10-b6  (install script r5)
# Source : https://github.com/ventoy/Ventoy  (INSTALL/tool/ventoy_lib.sh)
# =====================================================================
# 警告：本脚本会彻底清空目标磁盘上的所有数据，请在执行前逐条审阅。

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/bin:/sbin:/opt/homebrew/bin:$PATH

emit_step() { printf '\n==> [%s/%s] %s\n' "$1" "$2" "$3"; }
ventoy_mount_point() {
  /usr/sbin/diskutil info -plist "$1" 2>/dev/null | /usr/bin/plutil -extract MountPoint raw -o - - 2>/dev/null || true
}
vtoy_unmount() {
  /usr/sbin/diskutil unmountDisk force '/dev/disk9' >/dev/null 2>&1 || true
}
# $1 = source file, $2 = sector count, $3 = destination LBA
vtoy_raw_write() {
  local src="$1" sectors="$2" seek_lba="$3" n=0
  while [ "$n" -lt 5 ]; do
    vtoy_unmount
    if /bin/dd if="$src" of='/dev/rdisk9' bs=512 count="$sectors" seek="$seek_lba" conv=notrunc; then
      return 0
    fi
    n=$((n+1))
    echo "  ⚠ 整盘写入被系统占用（Resource busy），卸载后重试 $n/5"
    /bin/sleep 1
  done
  echo "错误：整盘写入重试 5 次仍失败"
  return 1
}

VTOY_STAGE="$(/usr/bin/mktemp -d -t vtoymac-stage)"
cleanup_stage() {
  /bin/rm -f "$VTOY_STAGE/mbr.bin" "$VTOY_STAGE/core.bin" "$VTOY_STAGE/uuid.bin" \
           "$VTOY_STAGE/verify.bin" "$VTOY_STAGE/verify-core.bin"
  /bin/rmdir "$VTOY_STAGE" 2>/dev/null || true
}
trap cleanup_stage EXIT

echo 'VentoyMac 构建 2026.11.10-b6 · 安装脚本 r5 · 目标 /dev/disk9'

emit_step 1 14 '校验目标磁盘与引导资源'
printf '    $ %s\n' 'INFO="$(/usr/sbin/diskutil info -plist '\''/dev/disk9'\'')" || { echo "错误：无法读取 disk9 信息"; exit 1; }
           INTERNAL="$(printf '\''%s'\'' "$INFO" | /usr/bin/plutil -extract Internal raw -o - -)"
           WHOLE="$(printf '\''%s'\'' "$INFO" | /usr/bin/plutil -extract WholeDisk raw -o - -)"
           [ "$INTERNAL" = "false" ] || { echo "拒绝执行：disk9 是内置磁盘"; exit 1; }
           [ "$WHOLE" = "true" ] || { echo "拒绝执行：disk9 不是整盘设备"; exit 1; }
           for f in '\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/boot.img'\'' '\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/core.img'\'' '\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/ventoy.disk.img'\''; do
             [ -f "$f" ] || { echo "拒绝执行：缺少引导文件 $f"; exit 1; }
           done'

emit_step 2 14 '卸载目标磁盘上的所有卷'
printf '    $ %s\n' '/usr/sbin/diskutil unmountDisk force '\''/dev/disk9'\'' || true'

emit_step 3 14 '裸盘写入权限预检与扇区对齐检查（0 字节写入 + 对齐读）'
printf '    $ %s\n' 'if [ "$(/usr/bin/id -u)" != "0" ]; then
             echo "  ℹ 以普通用户运行：diskutil partitionDisk / newfs_exfat 需要管理员授权"
           fi
           # 分区表由 diskutil（DiskArbitration）写，引导区由 dd 写裸节点；TCC 可能
           # 只放行其中一个，两个设备节点都要验。
           for PROBE in '\''/dev/disk9'\'' '\''/dev/rdisk9'\''; do
             if [ ! -e "$PROBE" ]; then
               echo "错误：找不到设备 ${PROBE}，请重新确认 U 盘设备名。"; exit 1
             fi
             if ! /bin/dd if=/dev/null of="$PROBE" bs=512 count=0 conv=notrunc 2>/dev/null; then
               echo "=================================================================="
               echo "拒绝执行：当前进程无法以写方式打开裸磁盘 $PROBE"
               echo "原因：macOS 的「完全磁盘访问」(TCC / SIP) 会阻止非授权进程写入"
               echo "      /dev/disk* 与 /dev/rdisk*，即使已获得 root 权限也一样。"
               echo ""
               echo "解决步骤（不需要终端）："
               echo "  1) 系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加并启用 VentoyMac.app"
               echo "  2) 完全退出 VentoyMac 并重新打开（授权在进程启动时生效）"
               echo "  3) 在应用「安装」页点「验证磁盘写入权限」，自动挑选可用提权通道"
               echo "  4) 若仍失败，点「给系统提权进程授权」，把"
               echo "     /usr/libexec/security_authtrampoline 也加入完全磁盘访问，再重启应用"
               echo ""
               echo "备用：导出本脚本，在已获完全磁盘访问的终端中执行 sudo bash <脚本>"
               echo "=================================================================="
               echo "预检未通过：未对磁盘做任何修改（仅执行过卸载，可重新插拔恢复）。"
               exit 1
             fi
             if ! /bin/dd if="$PROBE" of=/dev/null bs=512 count=1 2>/dev/null; then
               echo "拒绝执行：$PROBE 无法完成 512 字节扇区对齐读（设备不是 512n/512e，或仍被占用）"
               echo "预检未通过：未对磁盘做任何修改（仅执行过卸载，可重新插拔恢复）。"
               exit 1
             fi
             echo "  ✓ 可写且可对齐访问：${PROBE}（0 字节写入 + 512 字节对齐读）"
           done
           echo "  ℹ 身份：有效 uid=$(/usr/bin/id -u)，真实 uid=$(/usr/bin/id -ru)"
           echo "  ℹ 分区通道：diskutil partitionDisk（不调用被 SIP 封锁的 gpt 写命令）"
           echo "  ℹ 计划布局：part1 LBA 2048 + 67041240，part2 65536 扇区 / EFI System"
           echo "权限与对齐预检通过：/dev/disk9 与 /dev/rdisk9 均未写入任何字节"'

emit_step 4 14 '重建 GPT 与两个分区（首个写入动作）'
printf '    $ %s\n' '/usr/sbin/diskutil unmountDisk force '\''/dev/disk9'\'' 2>/dev/null || true
           /usr/sbin/diskutil partitionDisk '\''disk9'\'' 3 GPT   '\''%EBD0A0A2-B9E5-4433-87C0-68B6B72699C7%'\'' '\''Ventoy'\'' 67041240S   '\''%C12A7328-F81F-11D2-BA4B-00A0C93EC93B%'\'' '\''VTOYEFI'\'' 65536S   '\''Free Space'\'' '\''spare'\'' R'

emit_step 5 14 '读取实际分区布局并等待设备节点'
printf '    $ %s\n' 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
             [ -e '\''/dev/rdisk9s1'\'' ] && [ -e '\''/dev/rdisk9s2'\'' ] && break
             /usr/sbin/diskutil list '\''/dev/disk9'\'' >/dev/null 2>&1 || true
             /bin/sleep 1
           done
           [ -e '\''/dev/rdisk9s1'\'' ] || { echo "错误：分区 1 设备节点未出现，中止"; exit 1; }
           [ -e '\''/dev/rdisk9s2'\'' ] || { echo "错误：分区 2 设备节点未出现，中止"; exit 1; }
           P2INFO="$(/usr/sbin/diskutil info -plist '\''/dev/disk9s2'\'')" || { echo "错误：无法读取分区 2 信息"; exit 1; }
           VTOY_P2_CONTENT="$(printf '\''%s'\'' "$P2INFO" | /usr/bin/plutil -extract Content raw -o - - 2>/dev/null || true)"
           VTOY_P2_OFFSET="$(printf '\''%s'\'' "$P2INFO" | /usr/bin/plutil -extract PartitionMapPartitionOffset raw -o - - 2>/dev/null || true)"
           [ -n "$VTOY_P2_OFFSET" ] || { echo "错误：diskutil 未返回分区 2 偏移"; exit 1; }
           [ "$VTOY_P2_CONTENT" = "EFI" ] || { echo "错误：分区 2 类型为 '\''${VTOY_P2_CONTENT}'\''（应为 EFI），中止"; exit 1; }
           [ "$(( VTOY_P2_OFFSET % 512 ))" = "0" ] || { echo "错误：分区 2 偏移未按 512 字节对齐"; exit 1; }
           VTOY_PART2_LBA=$(( VTOY_P2_OFFSET / 512 ))
           echo "  ✓ VTOYEFI 分区：LBA $VTOY_PART2_LBA / EFI System / 65536 扇区"'

emit_step 6 14 '写入 MBR 引导代码与 GPT 模式标记'
printf '    $ %s\n' '/bin/dd if='\''/dev/rdisk9'\'' of="$VTOY_STAGE/mbr.bin" bs=512 count=1
           # 确认读到的是 diskutil 生成的保护 MBR，否则宁可中止也不覆盖分区项
           PTYPE="$(/usr/bin/xxd -s 450 -l 1 -p "$VTOY_STAGE/mbr.bin")"
           [ "$PTYPE" = "ee" ] || { echo "错误：LBA 0 偏移 450 不是 0xEE 保护 MBR（实际 0x${PTYPE}），中止以免破坏分区表"; exit 1; }
           [ "$(/usr/bin/xxd -s 510 -l 2 -p "$VTOY_STAGE/mbr.bin")" = "55aa" ] || { echo "错误：LBA 0 缺少 0x55AA 签名"; exit 1; }
           /bin/dd if='\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/boot.img'\'' of="$VTOY_STAGE/mbr.bin" bs=446 count=1 conv=notrunc
           # 0x22 → 八进制 \042；普通文件允许任意字节偏移，裸设备不允许
           printf '\''\042'\'' | /bin/dd of="$VTOY_STAGE/mbr.bin" bs=1 count=1 seek=92 conv=notrunc
           vtoy_raw_write "$VTOY_STAGE/mbr.bin" 1 0'

emit_step 7 14 '写入 Legacy BIOS GRUB core（LBA 34–2047）'
printf '    $ %s\n' '# 官方字节 17908 = LBA34×512 + 500，落在 core 镜像首个扇区
           /bin/dd if='\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/core.img'\'' of="$VTOY_STAGE/core.bin" bs=512 count=2014
           printf '\''\043'\'' | /bin/dd of="$VTOY_STAGE/core.bin" bs=1 count=1 seek=500 conv=notrunc
           vtoy_raw_write "$VTOY_STAGE/core.bin" 2014 34'

emit_step 8 14 '生成 Ventoy 磁盘 UUID 与 MBR 签名'
printf '    $ %s\n' 'UUIDFILE="$VTOY_STAGE/uuid.bin"
           /bin/dd if=/dev/urandom of="$UUIDFILE" bs=16 count=1 2>/dev/null
           # 重新读出 LBA 0，保留引导代码与保护 MBR；UUID / 签名补丁只落在暂存文件上
           /bin/dd if='\''/dev/rdisk9'\'' of="$VTOY_STAGE/mbr.bin" bs=512 count=1
           /bin/dd if="$UUIDFILE" of="$VTOY_STAGE/mbr.bin" bs=1 count=16 seek=384 conv=notrunc
           /bin/dd if="$UUIDFILE" of="$VTOY_STAGE/mbr.bin" bs=1 count=4 skip=12 seek=440 conv=notrunc
           vtoy_raw_write "$VTOY_STAGE/mbr.bin" 1 0
           sync'

emit_step 9 14 '对齐读回校验 GPT 模式标记与 MBR 签名'
printf '    $ %s\n' '/bin/dd if='\''/dev/rdisk9'\'' of="$VTOY_STAGE/verify.bin" bs=512 count=1
           /bin/dd if='\''/dev/rdisk9'\'' of="$VTOY_STAGE/verify-core.bin" bs=512 count=1 skip=34
           FLAG1="$(/usr/bin/xxd -s 92 -l 1 -p "$VTOY_STAGE/verify.bin")"
           FLAG2="$(/usr/bin/xxd -s 500 -l 1 -p "$VTOY_STAGE/verify-core.bin")"
           SIGNATURE="$(/usr/bin/xxd -s 510 -l 2 -p "$VTOY_STAGE/verify.bin")"
           [ "$FLAG1" = "22" ] || { echo "校验失败：字节 92 应为 0x22，实际为 0x$FLAG1"; exit 1; }
           [ "$FLAG2" = "23" ] || { echo "校验失败：字节 17908 应为 0x23，实际为 0x$FLAG2"; exit 1; }
           [ "$SIGNATURE" = "55aa" ] || { echo "校验失败：MBR 签名 0x55AA 缺失"; exit 1; }
           echo "  ✓ 字节 92=0x22、17908=0x23、MBR 签名 0x55AA"'

emit_step 10 14 '清空 VTOYEFI 分区引导扇区'
printf '    $ %s\n' 'vtoy_raw_write /dev/zero 32 $VTOY_PART2_LBA'

emit_step 11 14 '写入官方 VTOYEFI 分区镜像（GRUB2 + x86/IA32/ARM64 EFI）'
printf '    $ %s\n' 'vtoy_raw_write '\''/var/folders/vg/7wcyntmd16b73jzbtkt1zqfm0000gn/T/vtoymac-cli-selftest/ventoy.disk.img'\'' 65536 $VTOY_PART2_LBA'

emit_step 12 14 '格式化分区 1 为 exFAT（卷标 Ventoy）'
printf '    $ %s\n' 'vtoy_unmount
           /sbin/newfs_exfat -v '\''Ventoy'\'' -c 64 '\''/dev/rdisk9s1'\'''

emit_step 13 14 '挂载 Ventoy 卷并准备 ISO 目录'
printf '    $ %s\n' '/usr/sbin/diskutil unmountDisk force '\''/dev/disk9'\'' 2>/dev/null || true
           /usr/sbin/diskutil mount '\''/dev/disk9s1'\'' 2>/dev/null || true
           MP="$(ventoy_mount_point '\''/dev/disk9s1'\'')"
           if [ -z "$MP" ]; then
             MP="$(/usr/bin/mktemp -d -t ventoy-mount)"
             /sbin/mount -t exfat '\''/dev/disk9s1'\'' "$MP" || { echo "错误：无法挂载 Ventoy 数据分区，请手动挂载后复制 ISO"; exit 1; }
           fi
           /bin/mkdir -p "$MP/ISO"
           echo "挂载点：$MP"'

emit_step 14 14 '同步并输出完成信息'
printf '    $ %s\n' 'sync
           echo "Ventoy self-test 已写入 /dev/disk9"
           echo "VTOYEFI 分区起始 LBA：$VTOY_PART2_LBA"
           /usr/sbin/diskutil list '\''/dev/disk9'\'' || true
           /usr/sbin/gpt -r show -l '\''/dev/disk9'\'' || true'

echo ''
echo '审计模式完成：未对 /dev/disk9 做任何写入。'

