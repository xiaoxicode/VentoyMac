#!/bin/bash
# VentoyMac 裸盘权限 + 分区通道自检（对磁盘写入 0 字节）
set -u
for node in '/dev/disk4' '/dev/rdisk4'; do
  if [ ! -e "$node" ]; then
    echo "PROBE_MISSING: $node"
    exit 1
  fi
  if ! /bin/dd if=/dev/null of="$node" bs=512 count=0 conv=notrunc 2>/dev/null; then
    echo "PROBE_DENIED: $node"
    exit 1
  fi
  if ! /bin/dd if="$node" of=/dev/null bs=512 count=1 2>/dev/null; then
    echo "PROBE_UNALIGNED: $node"
    exit 1
  fi
  echo "PROBE_OK: $node"
done
echo "PROBE_IDENTITY: euid=$(/usr/bin/id -u) ruid=$(/usr/bin/id -ru)"
if /usr/sbin/diskutil info -plist '/dev/disk4' >/dev/null 2>&1; then
  echo "PROBE_DISKUTIL_OK"
else
  echo "PROBE_DISKUTIL_DENIED"
  exit 1
fi
if /usr/sbin/diskutil partitionDisk 2>&1 | /usr/bin/grep -q -- '-noEFI'; then
  echo "PROBE_NOEFI_OK"
else
  echo "PROBE_NOEFI_MISSING: 当前 diskutil 不支持 -noEFI，分区命令会插入 200 MiB EFI 分区并触发 -5344"
  exit 1
fi
echo "PROBE_PARTITION_CHANNEL: diskutil partitionDisk -noEFI + 前导 2048S 空隙 (gpt 写命令被 SIP 封锁，不使用)"
echo "PROBE_RESULT: OK"
