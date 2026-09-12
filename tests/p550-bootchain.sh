#!/usr/bin/env bash
# p550-bootchain.sh — P550 启动链/固件证据采集（只读，无需 sudo）
#
# 目的: 记录"固件→引导器→内核"这条真实链条的痕迹，用于
#       results/<date>-bootchain.md 与「QEMU vs 真机」对照表。
#       QEMU 侧是 `-kernel` 直启 + OpenSBI，没有 U-Boot/GRUB/EFI 这些层。
#
# 机器可读输出: BOOTCHAIN_STATUS=PASS
set -u

echo "===== 内核命令行 ====="
cat /proc/cmdline 2>/dev/null
echo

echo "===== 设备树 model / compatible ====="
[ -r /sys/firmware/devicetree/base/model ] && tr -d '\0' < /sys/firmware/devicetree/base/model && echo
[ -r /sys/firmware/devicetree/base/compatible ] && tr -d '\0' < /sys/firmware/devicetree/base/compatible && echo
echo

echo "===== 固件层 ====="
echo "EFI 变量表: $([ -d /sys/firmware/efi ] && echo yes || echo no)"
[ -d /sys/firmware/efi/efivars ] && echo "efivars 条目: $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l)"
for f in /sys/firmware/efi/fw_platform_size /sys/firmware/efi/runtime-map; do
  [ -e "$f" ] && echo "$f: $(cat "$f" 2>/dev/null | head -c 200)"
done
echo

echo "===== 引导器 / 固件相关内核日志 ====="
if command -v journalctl >/dev/null 2>&1 && journalctl -kb >/dev/null 2>&1; then
  journalctl -kb --no-pager 2>/dev/null | grep -iE 'u-boot|opensbi|efi|grub|eswin|sifive' | head -25
elif dmesg >/dev/null 2>&1; then
  dmesg 2>/dev/null | grep -iE 'u-boot|opensbi|efi|grub|eswin|sifive' | head -25
else
  echo "(无权限读内核日志，跳过；不影响结论)"
fi
echo

echo "===== 根文件系统与引导介质 ====="
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,MOUNTPOINT 2>/dev/null
echo

echo "===== /boot 内容（引导件线索）====="
ls -1 /boot 2>/dev/null | head -20
echo

echo "===== 内存布局（真机专有）====="
grep -iE 'Memory:|reserved' /proc/iomem 2>/dev/null | head -10
echo

echo "BOOTCHAIN_STATUS=PASS"
exit 0
