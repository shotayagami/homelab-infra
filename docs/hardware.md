# ハードウェア構成

Proxmox VE ホスト 1 台構成のホームラボ。1U / SFF クラスのスペックで、Phase 1-6 の Zabbix 監視基盤 + Phase 4-D の RKE2 検証クラスタ (cp1/worker1) を同居させている。

## 筐体・CPU

| 項目 | 内容 |
|---|---|
| メーカー / 型番 | HP EliteDesk 800 G4 SFF |
| CPU | Intel Core i5-8500 (Coffee Lake, 6 コア / 6 スレッド) |
| 周波数 | base 3.0 GHz / max turbo 4.1 GHz / min 800 MHz |
| キャッシュ | L1d 192 KiB / L1i 192 KiB / L2 1.5 MiB / L3 9 MiB |
| 仮想化 | VT-x / VT-d 有効、KVM full-virt 使用 |
| マイクロコード | intel-microcode 3.20251111.1 (Debian 13) |

i5-8500 は HT 非搭載のため物理 6 コア = 論理 6 スレッド。RKE2 cp1 (2 vCPU) + worker1 (2 vCPU) + Zabbix LXC + その他 LXC で常時 25% 程度の負荷、ピーク時で 50% 前後を見ている。

## メモリ

| 項目 | 内容 |
|---|---|
| 容量 | 32 GiB (4 × 8 GB DDR4) |
| 速度 | 全 DIMM 2400 MT/s で稼働 (チップ自体は 2667/3200 MT/s 対応品も混在) |
| スロット | 4 スロット全埋め (DIMM1/2/3/4)、追加余地なし |
| 上限 | 64 GB (マザー仕様) → 16 GB DIMM × 4 でアップグレード可 |
| メーカー | Samsung / Adata / unknown の混在 (ジャンクで都度買い足し) |

`free -h` で常時 25 GiB 程度 used、available 6 GiB 前後。Phase 4-D RKE2 を入れてから余裕が薄くなってきている。Longhorn replica + Harbor を本格運用するなら 64 GB へのアップグレードが現実的な next step。

## ストレージ

### 階層構造

| デバイス | モデル | 容量 | I/F | PVE storage 名 | 主な役割 |
|---|---|---|---|---|---|
| `nvme0n1` | Samsung 970 EVO Plus 1TB | 931.5 GiB | NVMe (PCIe 3.0 x4) | `local-lvm` (LVM-thin 794 GB) + `local` (96 GB) | **OS (`pve-root`) + 主要 VM/LXC ディスク + RKE2 cp1 etcd** |
| `sda` | SPCC Solid State Disk | 476.9 GiB | SATA SSD (TLC 推定) | `store-sda` (dir, ext4) | RKE2 worker1 ルートディスク / Longhorn replica |
| `sdb` | Fanxiang S101Q 1TB | 953.9 GiB | SATA SSD (QLC) | `store-sdb` (dir, ext4) | **バックアップ専用** (Zabbix dump / Config export) |
| `sdc` | WDC WD80EAZZ-00BKLB0 | 7.3 TiB | USB 3.x HDD | (PVE 非管理) | **OMV (VMID 100) に disk passthrough** → `sata1` |
| `sdd` | WDC WD40EZAZ-00SF3B0 | 3.6 TiB | USB 3.x HDD | (PVE 非管理) | **OMV (VMID 100) に disk passthrough** → `sata4` |
| `sde` | Seagate ST3000DM001-1ER166 | 2.7 TiB | USB 3.x HDD | (PVE 非管理) | **OMV (VMID 100) に disk passthrough** → `sata2` |
| `sdf` | Seagate ST2000DM001-1CH164 | 1.8 TiB | USB 3.x HDD | (PVE 非管理) | **OMV (VMID 100) に disk passthrough** → `sata3` |

### Storage tier の決定経緯

2026-05-16 の RKE2 etcd 安定化作業 ([proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) §2026-05-16) で **fdatasync レイテンシ起因の etcd リーダー喪失** が観測され、ディスク階層を組み直した:

| 用途 | 移動前 | 移動後 | 理由 |
|---|---|---|---|
| RKE2 cp1 (etcd を載せる) | `store-sdb` (Fanxiang QLC) | `local-lvm` (Samsung NVMe) | QLC SSD の fdatasync が遅く、etcd が `slow fdatasync` 警告 → leader lost を頻発 |
| RKE2 worker1 (Longhorn replica) | `store-sdb` (Fanxiang QLC) | `store-sda` (SPCC TLC SATA) | etcd ほど厳しくはないが、Longhorn の syncwrite で同じ症状を回避 |
| バックアップ全般 | (混在) | `store-sdb` (Fanxiang QLC) | QLC の弱点は書き込み持続性能。逐次書き込み主体のバックアップなら問題なし |

**学び:** QLC SSD は単発の sequential write は早いが、4KB random write + fsync が混ざる workload (etcd / Longhorn / DB) では NVMe TLC との差が桁違い。homelab スケールでも QLC は backup / archive 用途、TLC NVMe は live workload、という棲み分けが必要。

### Storage 用途別の使い分け

- **`local-lvm` (NVMe LVM-thin)**: 全 VM/LXC ディスクのデフォルト置き場。snapshot 対応、thin provisioning で実使用は 21%
- **`local` (NVMe / `/var/lib/vz`)**: ISO、CT template、vzdump backup の一時置き
- **`store-sda` (SPCC SATA SSD)**: 性能が必要な「2 軍ストレージ」枠。worker1 ルート、Longhorn replica
- **`store-sdb` (Fanxiang QLC SATA SSD)**: バックアップ専用。`vzdump` の保存先、Zabbix Config export
- **USB HDD 群 (`sdc`–`sdf`)**: PVE 側ではマウントせず、`qm config 100` で `sata1`〜`sata4` として OpenMediaVault VM (VMID 100) に **disk passthrough** 済。OMV 内で ZFS/ext4 のプールを構成し、SMB/NFS で他 VM・LXC・物理クライアントから利用 (例: Nextcloud は `files_external` 経由で `/mnt/omv/nas/*` を参照していた経緯あり、`docs/proxmox-zabbix-monitoring.md` の Nextcloud 復旧ログ参照)。**PVE ホスト側で直接マウント/フォーマットしない** こと (OMV のファイルシステムを破壊する)

## ネットワーク

| 項目 | 内容 |
|---|---|
| オンボード NIC | Intel I219-LM (PCIe Bus 00:1f.6, rev 10) |
| 速度 | 1000BASE-T (1 GbE、フルデュプレックス) |
| ブリッジ | `vmbr0` 192.168.11.11/24、全 VM/LXC が乗る |
| 内部 CNI | `cilium_host` 10.42.0.4/32 (RKE2 のみ、admin-vm から static route で到達) |
| Docker bridge | `docker0` 172.17.0.0/16 (現在 DOWN、未使用) |

1 GbE 1 本のため、Longhorn replica の同期帯域が NIC 飽和することがある (実測あり)。マルチノード化するなら 2.5 GbE NIC 増設 (PCIe x1 で十分) が現実的。

## ハイパーバイザ・OS

| 項目 | バージョン |
|---|---|
| Proxmox VE | 9.1.11 (running 9.1.11/8eac2c86f015bdda) |
| Kernel | Linux 6.17.13-8-pve (signed, Debian 13 ベース) |
| ストレージドライバ | LVM 2.03.31-2+pmx1、ZFS 2.4.2-pve1 (zfsutils インストール済だが未使用) |
| Container | lxc-pve 7.0.0-1、lxcfs 7.0.0-pve1 |
| KVM | pve-qemu-kvm 11.0.0-2、qemu-server 9.1.10 |
| クラスタ | corosync 3.1.10-pve2 インストール済 (シングルノードのため未参加) |
| Ceph | 19.2.3-pve4 インストール済 (未使用) |
| Backup | proxmox-backup-client 4.2.0-1 (`vzdump` で sdb に出力) |

## 将来の拡張余地

1. **メモリ 64 GB 化**: 16 GB DDR4-2666 ECC 非対応モジュール × 4 で 1 万円台。Longhorn + Harbor 本番運用で必須レベル
2. **2.5 GbE NIC**: Realtek RTL8125B 系の安価カードで 1 GbE → 2.5 GbE 化。Longhorn replica の同期で恩恵
3. **NVMe 増設**: マザー上の 2nd M.2 スロット (もしあれば) で OS と VM 領域を物理分離
4. **PVE クラスタ化**: 同型機 (EliteDesk 800 G4 SFF) をジャンク調達 → 2 ノード化、HA 検証。corosync は既に入っているので追加コストは低い

## 関連

- [README.md](../README.md) — リポジトリ入口、ハードウェアサマリ表
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Phase 4-D RKE2 監視 / etcd fsync 詳細
- [docs/remaining-tasks.md](remaining-tasks.md) — Longhorn / Harbor 本格化に伴う容量見積もり
