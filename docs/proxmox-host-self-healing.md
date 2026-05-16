# PVE ホストの自律復旧 — network-watchdog / vm-health-monitor

PVE host (192.168.11.11) で常駐している自作監視・自動復旧スクリプト 2 本のリファレンス。Zabbix の外部観測層 ([docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md)) が「気づかせる」役なら、こちらは「自力で立て直す」役。

PVE 自身がネットワーク断や VM ハングを検知して自動復旧する一次防衛線として配置されている。

---

## 1. 全体像

```
┌─────────────────────────────────────────────────────────┐
│  PVE host (192.168.11.11)                                │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────────┐ │
│  │ network-watchdog     │  │ vm-health-monitor        │ │
│  │ ping → GW + 8.8.8.8  │  │ ping → 各 VM/CT IP       │ │
│  │ 30s 間隔             │  │ 60s 間隔                 │ │
│  │ → NIC reset / reboot │  │ → qm reset / pct restart │ │
│  └──────────────────────┘  └──────────────────────────┘ │
│                                                          │
│  ┌──────────────────────┐                                │
│  │ node_exporter :9100  │ ← Zabbix (192.168.11.55)       │
│  │ (PVE host metrics)   │   が外部観測                   │
│  └──────────────────────┘                                │
└─────────────────────────────────────────────────────────┘
```

| レイヤ | 役割 | 失敗時のアクション |
|---|---|---|
| network-watchdog | host の uplink (gateway + internet) 死活監視 | NIC reset → networking restart → reboot のエスカレーション |
| vm-health-monitor | 各 VM/CT の生死監視 | VM reset (qm reset) / LXC restart (pct restart) |
| node_exporter | Prometheus 互換メトリクス公開 | 観測のみ ([Zabbix](proxmox-zabbix-monitoring.md) が取りに来る) |

---

## 2. network-watchdog

PVE host 自身がネットワーク断に陥ったとき、外部からはどうしようもないので **自分で立て直す**。

| 項目 | 値 |
|---|---|
| 本体スクリプト | `/usr/local/bin/network-watchdog.sh` (リポジトリ内: [scripts/pve-host/network-watchdog.sh](../scripts/pve-host/network-watchdog.sh)) |
| systemd unit | `network-watchdog.service` (リポジトリ内: [scripts/pve-host/network-watchdog.service](../scripts/pve-host/network-watchdog.service)) |
| 監視対象 | gateway (192.168.11.1) + `8.8.8.8` への ping |
| 周期 | 30 秒 |
| Log | `/var/log/network-watchdog.log` |

### エスカレーションロジック

| 連続失敗 | アクション |
|---|---|
| 3 回 (90 秒) | **NIC リセット** (`ip link set eth0 down/up`) |
| 6 回 (3 分) | **networking サービス再起動** (`systemctl restart networking`) |
| 12 回 (6 分) | **host 全体 reboot** |

### 状態確認

```bash
ssh root@192.168.11.11 'systemctl status network-watchdog.service'
ssh root@192.168.11.11 'tail -50 /var/log/network-watchdog.log'
```

### 停止 / 一時無効化 (メンテ時)

```bash
ssh root@192.168.11.11 'systemctl stop network-watchdog.service'
# 作業完了後
ssh root@192.168.11.11 'systemctl start network-watchdog.service'
```

メンテで NIC を意図的に落とすときは必ず停止する (12 回失敗で reboot される)。

---

## 3. vm-health-monitor

VM/CT が応答しなくなったとき、PVE 内部から強制再起動する。

| 項目 | 値 |
|---|---|
| 本体スクリプト | `/usr/local/bin/vm-health-monitor.sh` (リポジトリ内: [scripts/pve-host/vm-health-monitor.sh](../scripts/pve-host/vm-health-monitor.sh)) |
| 設定ファイル | `/etc/vm-health-monitor/targets.conf` (テンプレート: [scripts/pve-host/vm-health-monitor.targets.conf.example](../scripts/pve-host/vm-health-monitor.targets.conf.example)) |
| systemd unit | `vm-health-monitor.service` (リポジトリ内: [scripts/pve-host/vm-health-monitor.service](../scripts/pve-host/vm-health-monitor.service)) |
| 周期 | 60 秒 |
| Log | `/var/log/vm-health-monitor.log` |
| ガード | **1 時間あたり最大 2 回までしか再起動しない** (リブートループ防止) |

### エスカレーションロジック

| 連続失敗 | アクション |
|---|---|
| 3 回 (3 分) | 種別に応じて `qm reset <VMID>` (VM) または `pct restart <VMID>` (LXC) |

### 設定ファイル形式

`/etc/vm-health-monitor/targets.conf` (空白区切り):
```
# VMID  type  ip            label
104     ct    192.168.11.53  dns
105     ct    192.168.11.54  dns2
106     ct    192.168.11.60  pg-db
107     ct    192.168.11.61  step-ca
108     ct    192.168.11.62  nextcloud
110     vm    192.168.11.80  k8s-cp1
120     vm    192.168.11.83  k8s-worker1
```

> Zabbix CT (190) / ntfy CT (191) は監視対象に入れていない (Zabbix 自身が落ちると通知も止まる、別系統が必要)。

### 監視対象の変更手順

```bash
ssh root@192.168.11.11 'cat /etc/vm-health-monitor/targets.conf'
# 編集
ssh root@192.168.11.11 'systemctl restart vm-health-monitor.service'
# ログで反映確認
ssh root@192.168.11.11 'tail -20 /var/log/vm-health-monitor.log'
```

---

## 4. ハマりポイント

### 4-1. 撤去済 VM のエントリを残すとログ汚染 (2026-05-16 体験)

設定ファイルに**存在しない VM** を残すと、毎分 ping 失敗 → `qm reset` 失敗 で**ログが大量に出力**される。

2026-05-16 に撤去済の worker2 (VMID 121, 192.168.11.84) のエントリが残っていて、毎分エラーログ出力 + 無用な reset attempt が記録されていた。

**対処:** 撤去時は必ず `targets.conf` から該当行を削除 (または `#` コメントアウト) して `systemctl restart vm-health-monitor.service` まで一連で実施。

### 4-2. メンテ作業中の意図的停止

VM を計画的に shutdown / migrate / disk move する際、vm-health-monitor が 3 分後に `qm reset` をかけてしまう。

**対処:** メンテ前に:
```bash
ssh root@192.168.11.11 'systemctl stop vm-health-monitor.service'
# 作業
ssh root@192.168.11.11 'systemctl start vm-health-monitor.service'
```

もしくは該当 VM だけ targets.conf からコメントアウト + restart。

### 4-3. 1 時間 2 回ガードを超えた場合の挙動

3 回連続失敗 → reset → また 3 回失敗 → reset、を 1 時間に 2 回踏むと、3 回目は実行されず**ログに警告だけ出る**。気づかないと「監視対象は落ちているが復旧アクションも止まっている」状態になる。

**対処:** Zabbix 側で「3 回連続 host down が継続している」alert を別途仕込んでおく ([docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) の standard host availability trigger でカバー)。

---

## 5. node_exporter (Prometheus 互換)

過去に RKE2 上の Prometheus からメトリクス取得するために導入。Zabbix 主体に切替後も継続稼働。

| 項目 | 値 |
|---|---|
| パッケージ | `prometheus-node-exporter` (Debian apt) |
| Listen | `:9100` (全 IF) |
| メトリクス | CPU / Memory / Disk I/O / Network / FileSystem 等 |
| Zabbix 連携 | 現状は `Proxmox VE by HTTP` + `Linux by Zabbix agent` ([docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) Phase 2/3) で代替できているので、node_exporter 出力を直接消費していない |

### 旧 RKE2 連携の名残

RKE2 `monitoring` ns に `proxmox-node-exporter` Service / Endpoints / ServiceMonitor が存在する (PVE host を K8s 外の target として静的登録)。Prometheus 観点では今もスクレイプ可能。

> Zabbix 主体運用なので、node_exporter は将来 `apt remove` してもよい (Zabbix で同等以上の情報が取れている)。即時の判断は不要。

---

## 6. Zabbix 観測層との関係

| 役割分担 | network-watchdog / vm-health-monitor | Zabbix |
|---|---|---|
| 復旧判断 | host 内、自律 | 外部観測、復旧は人 (または webhook) |
| 反応時間 | 90 秒〜3 分 | trigger 評価間隔 (60 秒〜) |
| 通知 | ログのみ (`/var/log/*-watchdog.log`) | ntfy / Discord / Mailgun の 3 系統 |
| host 自身の障害 | **対応可能** (network-watchdog が立て直す) | **対応不可** (Zabbix も agent 経由で見ているので一緒に死ぬ) |
| 個別 VM 障害 | 3 分後に reset | trigger 後通知 → 人判断 |

**運用シナリオ:**
- VM が落ちる → vm-health-monitor が 3 分後に reset、ほぼ同時に Zabbix が trigger 発火 → 通知が来た時点で既に復旧していることが多い
- host のネットワーク断 → network-watchdog が NIC reset / reboot で立て直し、Zabbix 側は host down → up を観測
- host の hardware 故障 → どちらも復旧不能、人による物理対応

---

## 7. 関連ドキュメント

- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — 外部観測層、通知設定
- [docs/hardware.md](hardware.md) — PVE host のハードウェア構成
- [docs/proxmox-firewall.md](proxmox-firewall.md) — host firewall 運用
- [docs/admin-vm-tooling.md](admin-vm-tooling.md) — admin-vm からの管理コマンド
