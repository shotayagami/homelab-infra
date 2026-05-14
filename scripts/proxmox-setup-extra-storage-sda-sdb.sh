#!/bin/bash
#
# Proxmox 追加ストレージ: /dev/sda, /dev/sdb を ext4 でマウントし Directory ストレージとして登録する。
# 実行場所: proxmox (192.168.11.11 など) で root として実行。
#
# 【重要】 /dev/sdb1 の NTFS は削除されます。バックアップのうえ CONFIRM_DESTROY_SDB=yes を付けて実行すること。
#
set -euo pipefail

MP_SDA="/mnt/pve-store-sda"
MP_SDB="/mnt/pve-store-sdb"
ID_SDA="store-sda"
ID_SDB="store-sdb"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "root で実行してください。"
  exit 1
fi

if [[ "${CONFIRM_DESTROY_SDB:-}" != "yes" ]]; then
  echo "sdb の既存パーティション（NTFS）は破棄されます。"
  echo "続ける場合は CONFIRM_DESTROY_SDB=yes を付けて再実行してください。"
  exit 1
fi

command -v parted >/dev/null || { echo "parted が必要です: apt install parted"; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "e2fsprogs が必要です"; exit 1; }

echo "=== 現在の sda / sdb ==="
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS /dev/sda /dev/sdb || true

echo "=== sda: GPT + 単一パーティション + ext4 ==="
parted -s /dev/sda mklabel gpt
parted -s /dev/sda mkpart primary ext4 1MiB 100%
partprobe /dev/sda 2>/dev/null || true
sleep 2
mkfs.ext4 -F -L pve-store-sda /dev/sda1

echo "=== sdb: 既存削除 → GPT + 単一パーティション + ext4 ==="
parted -s /dev/sdb mklabel gpt
parted -s /dev/sdb mkpart primary ext4 1MiB 100%
partprobe /dev/sdb 2>/dev/null || true
sleep 2
mkfs.ext4 -F -L pve-store-sdb /dev/sdb1

echo "=== マウントポイント ==="
mkdir -p "$MP_SDA" "$MP_SDB"
chmod 755 "$MP_SDA" "$MP_SDB"

UUID_SDA=$(blkid -s UUID -o value /dev/sda1)
UUID_SDB=$(blkid -s UUID -o value /dev/sdb1)
if [[ -z "$UUID_SDA" || -z "$UUID_SDB" ]]; then
  echo "UUID の取得に失敗しました。"
  exit 1
fi

FSTAB=/etc/fstab
stamp="# proxmox extra storage sda/sdb $(date -Iseconds)"
if ! grep -q "UUID=$UUID_SDA" "$FSTAB" 2>/dev/null; then
  {
    echo ""
    echo "$stamp"
    echo "UUID=$UUID_SDA $MP_SDA ext4 defaults,nofail 0 2"
    echo "UUID=$UUID_SDB $MP_SDB ext4 defaults,nofail 0 2"
  } >>"$FSTAB"
fi

mount -a

echo "=== Proxmox Directory ストレージ登録（既存同名があればスキップ） ==="
if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$ID_SDA"; then
  pvesm add dir "$ID_SDA" --path "$MP_SDA" \
    --content images,rootdir,iso,backup,vztmpl,snippets,import
fi
if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$ID_SDB"; then
  pvesm add dir "$ID_SDB" --path "$MP_SDB" \
    --content images,rootdir,iso,backup,vztmpl,snippets,import
fi

echo ""
echo "完了。確認:"
df -hT "$MP_SDA" "$MP_SDB"
echo ""
pvesm status | grep -E "^($ID_SDA|$ID_SDB)|Name" || pvesm status
