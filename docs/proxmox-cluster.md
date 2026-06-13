# Proxmox 2 ノードクラスタ `homelab`

2026-06-10、ほぼ同一構成の 2 台目 PC に Proxmox を導入し、`192.168.11.12` に設置して **2 ノードクラスタ `homelab`** を構築した。狙いは [docs/rke2-cluster.md](rke2-cluster.md) の RKE2（特に worker1）で逼迫していた既存ホスト (`192.168.11.11`) の RAM を新ノードへ逃がすこと。

単一ホスト時代のハードウェア詳細は [docs/hardware.md](hardware.md)、ホスト自律復旧層は [docs/proxmox-host-self-healing.md](proxmox-host-self-healing.md) を参照。

## ノード構成

| ノード | nodeid | IP | 機種 | CPU | RAM | ストレージ | 役割 |
|---|---|---|---|---|---|---|---|
| `proxmox` | 1 | 192.168.11.11 | HP EliteDesk 800 G4 SFF | i5-8500 (6C/6T) | 32 GiB | NVMe 1TB (`local-lvm`) + SATA SSD 2 本 (`store-sda`/`store-sdb`) + USB HDD 4 本 | 本番。移設不可ワークロード固定 |
| `pve2` | 2 | 192.168.11.12 | 同型 (EliteDesk 800 G4 SFF 相当) | i5-9500 (6C/6T) | 32 GiB | **SATA SSD 480 GB 1 本のみ** (`local-lvm` ≈ 349 GiB) | 受け皿。RAM 逃がし先 |

- 両ノードとも **Proxmox VE 9.2.3 / kernel 7.0.6-2-pve**。クラスタはバージョンを揃えるのが鉄則のため、`pve2` 導入時に `apt dist-upgrade` で `.11` と統一した。
- 「ほぼ同一」だが**唯一の大差はディスク**: `pve2` は SSD 1 本のみで、cp1 (185 GB) + worker1 (233 GB) を両方は載せられない。どちらか一方が限界。
- `pve2` の SATA SSD (SPCC) は持続書き込みが `.11` 系より遅い (SLC キャッシュ枯渇後に律速)。worker1 をここに置いたことによる I/O 性能差として認識しておく。

## クラスタ構成 (corosync)

- 単一リンク構成: `corosync.conf` の `link0` に各ノードの LAN IP (`.11` / `.12`) を使用。専用クラスタ網は無く `vmbr0` (1 GbE) と同居。
- **`two_node: 1` + `wait_for_all: 0`** を `quorum{}` に設定済。
  - `wait_for_all: 0` により「両機同時停止後に `.11` だけ先に起動しても単独で quorate」になり、VM 自動起動が止まらない。`.11` は unattended 自動再起動運用 ([docs/proxmox-host-self-healing.md](proxmox-host-self-healing.md) 関連) かつ過去に全停止を経験しているため、本番ノードの自立を優先した判断。
  - 代償の split-brain リスクは、HA フェンシング未使用 + 同一スイッチ直結のため実害確率は低いと評価。
- `pvecm status` の `WaitForAll` は表示上のもので、runtime は `wait_for_all_status=0`（無効）。

> **注意:** join は `pvecm add <既存ノード> --link0 <自IP> --use_ssh` で行う。無印の `pvecm add` は API 用 root パスワードを対話要求し、非対話だと `EOF while reading password` で失敗する。`--use_ssh` で keyless SSH ベースの join になり非対話で通る（事前に新ノード root → 既存ノードの keyless SSH を通しておくこと）。

## ゲスト配置 (2026-06-13 時点)

`pvesh get /cluster/resources --type vm` の実測。RAM 逼迫解消後、観測/操作系を「`.11` が落ちても道連れにしない」目的で `.12` へ寄せている。

| ノード | ゲスト |
|---|---|
| `proxmox` (.11) | OMV(100) / mail(101, 停止) / puter(102) / dns(104) / pg-db(106) / step-ca(107) / nextcloud(108) / freepbx(109) / **k8s-cp1(110)** / **admin-vm(150)** |
| `pve2` (.12) | dns2(105) / **k8s-worker1(120)** / icstv-playout2(131) / zabbix(190) / ntfy(191) |

### `.11` に固定する理由 (pinned)

- **OMV(100) / icstv 送出系**: USB HDD / iGPU の HW パススルーがありノードを跨げない（icstv-playout2 は `pve2` の iGPU を使うため `.12` 固定）。
- **k8s-cp1(110)**: etcd の `fdatasync` 都合で NVMe のある `.11` に残置 ([docs/rke2-cluster.md](rke2-cluster.md) / memory `proxmox_rke2_etcd_fsync`)。
- **pg-db(106)**: DB 書き込みが遅い `pve2` SSD を避ける。
- **dns(104)**: dns2 (`.12`) の相方として物理分散（後述）。

### 冗長化のための物理分散

- **DNS**: dns(104, .53) を `.11`、dns2(105, .54) を `.12` に分けた。従来は両 DNS が `.11` 同居で「`.11` 障害＝名前解決全滅」だったのを解消 ([docs/internal-dns.md](internal-dns.md))。VM 丸ごと移動のため IP・cert・firewall ルール (105.fw) はそのまま移動。
- **観測/操作系**: zabbix(190, DB は CT 内蔵 PG=localhost で pg-db 非依存) / ntfy(191) を `.12` へ。`.11` 障害時にも監視・通知が生き残る。

## ストレージ

- join 後、`storage.cfg` はクラスタ共有になる。`local-lvm` は元々 `nodes proxmox` 制限だったため `pve2` で disabled になる。**`pvesm set local-lvm --nodes proxmox,pve2`** で両ノード有効化（両ノードに同名 vg `pve` / thinpool `data` があり、各ノードは自分のプールを使う）。
- `store-sda` / `store-sdb` は `.11` の物理ディスクなので `nodes proxmox` 据え置き。

## ⚠️ 運用上の最重要教訓 — migration が Longhorn を巻き込む

worker1 を `.12` に分けたことで、**Longhorn のレプリカ複製が `.11`↔`.12` の 1 GbE を恒常的に跨ぐ**ようになった。大容量の `qm migrate` がこのリンクを飽和させると、Longhorn のノード間 I/O が詰まり連鎖障害（DB pod の liveness timeout kill → 再起動時の権限/RO リマウント不整合）に至る実例を経験した。

- **恒久対策（実施済）**: `datacenter.cfg` に **`bwlimit: migration=61440`**（60 MiB/s）を設定。以降の migration は Longhorn 複製帯域を残す。
- **運用ルール**: 今後 `.11`↔`.12` で大量転送を伴う作業（VM/CT migration 等）は必ず帯域制限する。単発なら `qm migrate ... --bwlimit 61440`。
- 物理対策としては 2.5 GbE NIC 増設で複製帯域に余裕を持たせるのが本筋（[docs/hardware.md](hardware.md) 将来拡張）。

関連: Longhorn の `default-replica-count=1` リスク ([docs/remaining-tasks.md](remaining-tasks.md) 項番 17)。重要 PVC は個別にレプリカ数を引き上げるかバックアップで担保する。

## Firewall

- datacenter firewall は現状 `enable: 0`（クラスタ化に伴う FW 副作用は無し）。PVE Firewall のパス・ロックアウト復旧手順は [docs/proxmox-firewall.md](proxmox-firewall.md) を参照。

## 関連

- [docs/hardware.md](hardware.md) — `.11` のハードウェア詳細・storage tier
- [docs/rke2-cluster.md](rke2-cluster.md) — cp1/worker1 のノード配置と最適化履歴
- [docs/internal-dns.md](internal-dns.md) — dns/dns2 の Primary/Secondary 冗長
- [docs/admin-vm-tooling.md](admin-vm-tooling.md) — admin-vm からの `pvesh`/`pct`/`qm` 操作（`PVE_HOST` で対象ノード切替）
