# バックアップ戦略 — 多層構造の俯瞰

ホームラボ全体のバックアップは **6 つの層**で構成されている。各層が独立した障害モードを救う設計。

このドキュメントは個別 doc に散在していた情報を**一枚にまとめた俯瞰図**。詳細は各層の参照先を参照。

| 散在元 (個別 doc 内) | 集約先 (本書) |
|---|---|
| [proxmox-zabbix-monitoring.md §6 Phase 6-B](proxmox-zabbix-monitoring.md) — PVE vzdump | §3-1 |
| [pg-db-postgresql.md §4](pg-db-postgresql.md) — pg-db 独自 cron | §3-3 |
| [rke2-cluster.md §3](rke2-cluster.md) — Velero / Longhorn / MinIO の存在 | §3-4, §3-5, §3-6 |
| (本書で新規) per-DB CronJob + etcd snapshot | §3-2, §3-7 |

---

## 1. 層の全体像

```
        高頻度・短保持 ←─────────────────────────→ 低頻度・長保持
         (運用ミス対応)                              (DR)

  Longhorn snapshot  →  per-DB CronJob  →  PVE vzdump  →  Velero
  (日次、7世代、同 disk)  (日次、7日、PVC)   (日次、7+4+6)   (日次、7日、MinIO)

  pg-db 独自 cron (LXC 内)      etcd snapshot (12h毎、5世代)
```

| # | 層 | 対象 | 頻度 | 保持 | 物理場所 | 救う障害モード |
|---|---|---|---|---|---|---|
| 1 | **PVE vzdump** | LXC/VM 全部 | 毎日 02:00 | 7d + 4w + 6m | `store-sdb` (Fanxiang QLC) | LXC/VM レベルの破損、世代復元 |
| 2 | **per-DB CronJob** | postgres / mongodb / mariadb / redis | 毎日 02:00〜04:00 | 7日 | PVC `backup-storage-longhorn` | DB レベルの論理障害 (誤 DROP 等) |
| 3 | **pg-db 独自 cron** | icsdb + globals (LXC 106) | 毎日 02:00 | 14日 | LXC 内 `/var/backups/postgresql/` | pg-db 単体障害、PIT 復元 |
| 4 | **Longhorn snapshot** | mariadb / mongodb / harbor-registry / gitea / wordpress / backend-media / backup-storage | 毎日 01:00 + 日曜 00:00 | 7世代 / 4世代 | Longhorn replica disk (`store-sda`) | Volume レベル、誤削除の即時復元 |
| 5 | **Velero** | namespace 単位 (ics / databases / wordpress / backups / gitea / harbor) | 毎日 05:00 (daily) + 日曜 06:00 (critical) | 7日 / 30日 | MinIO BSL (velero ns) | namespace 全体の復元、K8s 構成含む |
| 6 | **etcd snapshot** | RKE2 etcd | 12 時間毎 | 5世代 | `/var/lib/rancher/rke2/server/db/snapshots/` (cp1) | クラスタ状態の復元 |

---

## 2. なぜ多層が必要か

各層が**独立した障害モード**を救うため:

| 障害シナリオ | 一次救う層 | バックアップ |
|---|---|---|
| 「アプリで間違って DELETE FROM users してしまった」 | per-DB CronJob (2) | pg-db 独自 (3) |
| 「Helm upgrade で値を壊した、PVC ごと作り直したい」 | Velero (5) | Longhorn snapshot (4) |
| 「VM が起動しなくなった」 | PVE vzdump (1) | Velero (5) で再構成 |
| 「Longhorn replica disk (store-sda) が物理故障」 | Velero (5) ※注意点 §5 参照 | PVE vzdump (1)、pg-db 独自 (3) |
| 「PVE host 自体が死んだ」 | **オフサイト退避が無い** ← 既知の GAP | — |
| 「ArgoCD が暴走して全リソースを誤削除」 | Velero (5) | etcd snapshot (6) で巻き戻し |
| 「cp1 が起動不能」 | etcd snapshot (6) で他ノードに復元 | — |

---

## 3. 各層の詳細

### 3-1. PVE vzdump

| 項目 | 値 |
|---|---|
| 設定 | `/etc/pve/jobs.cfg` |
| 対象 VMID | 104, 105, 106, 107, 108, 190, 191 (+ 必要に応じ追加) |
| スケジュール | 毎日 02:00 (systemd timer 形式) |
| storage | `store-sdb` (Fanxiang QLC 1TB、バックアップ専用) |
| 圧縮 | zstd |
| mode | snapshot (無停止) |
| 保持 | keep-daily=7 / keep-weekly=4 / keep-monthly=6 |
| 通知 | PVE 8+ ネイティブ通知 |

詳細・初回構築の経緯は [proxmox-zabbix-monitoring.md Phase 6-B](proxmox-zabbix-monitoring.md)。

### 3-2. per-DB CronJob (RKE2 `backups` namespace)

[docs/rke2-cluster.md](rke2-cluster.md) で名前だけ言及されていた **K8s 内 DB バックアップ層** の実体。

| Job 名 | 時刻 | image | コマンド | 対象 |
|---|---|---|---|---|
| `postgres-backup` | 02:00 | `postgres:17` | `pg_dumpall` | RKE2 内 postgres (※ pg-db LXC は別) |
| `mongodb-backup` | 03:00 | `mongo:4.4` | `mongodump` | mongodb.databases ns |
| `mariadb-backup` | 03:30 | `mariadb:latest` ※注意 | `mariadb-dump` | mariadb.databases ns |
| `redis-backup` | 04:00 | `redis:latest` | `redis-cli --rdb` | redis.databases ns |

**注意:**
- 出力先は **PVC `backup-storage-longhorn` (10Gi、Longhorn RWO)** に集約
- RWO PVC なのでノード競合を避けるため**スケジュールを 30 分ずつずらしてある**
- `mariadb-dump` には公式 `mariadb:latest` (uid=999) を使う — Bitnami `bitnami/mariadb` (uid=1001) は権限不整合 ([rke2-lessons-learned §7-2](rke2-lessons-learned.md))
- 保持は 7 日 (Job 内 `find -mtime +7 -delete` で実装)

### 3-3. pg-db LXC 独自 cron

K8s 外 DB (pg-db LXC 106) は per-DB CronJob では取れないので独自に cron で取る。詳細は [pg-db-postgresql.md §4](pg-db-postgresql.md)。

| 項目 | 値 |
|---|---|
| スクリプト | `/usr/local/bin/pg_backup.sh` |
| Cron | `0 2 * * *` (`/etc/cron.d/pg_backup`) |
| 形式 | `pg_dump -Fc` (custom format) + `pg_dumpall --globals-only` |
| 出力先 | `/var/backups/postgresql/` (postgres:postgres 700) |
| 保持 | 14日 |
| Log | `/var/log/postgresql/backup.log` |

### 3-4. Longhorn RecurringJob

Volume レベルの即時復元用。Longhorn 自身が管理する snapshot 機構。

| Job 名 | スケジュール | 世代 | 対象 |
|---|---|---|---|
| `daily-snapshot` | 毎日 01:00 | 7 | mariadb, mongodb, harbor-registry, gitea, wordpress, backend-media, backup-storage |
| `weekly-snapshot` | 日曜 00:00 | 4 | 同上 |

**特徴:**
- snapshot は **同じ Longhorn replica disk 上** に作られる → disk 物理故障では一緒に消える
- 復元は秒〜分単位、Volume を時間軸の任意の世代に戻せる
- 「うっかり削除」「アプリ起因の論理破損」に強い

### 3-5. Velero

namespace 単位の K8s リソース + Volume のバックアップ。**最も「広い」層**。

| Schedule 名 | 時刻 | 保持 | 対象 namespace | 備考 |
|---|---|---|---|---|
| `daily-all-namespaces` | 毎日 05:00 | 7 日 | ics, databases, wordpress, backups, gitea, harbor | Volume snapshot 含む |
| `weekly-critical` | 日曜 06:00 | 30 日 | ics, databases, wordpress | FSBackup 有効 (Restic 経由) |

**Backup Storage Location (BSL):**
- type: aws (S3 互換)
- endpoint: MinIO (velero ns、PVC backed)
- 初期テスト: 285 items / 0 errors 成功確認済

**Restore 例:**
```bash
velero restore create --from-backup daily-all-namespaces-20260516020000 \
  --include-namespaces wordpress
```

### 3-6. MinIO

Velero の BSL 実体。

| 項目 | 値 |
|---|---|
| K8s namespace | `velero` |
| PVC | 20 GiB |
| アクセス | Velero からのみ (cluster 内通信) |

**既知の弱点 (§5 参照):** MinIO PVC が同一 RKE2 クラスタ内なので、クラスタ全滅時は MinIO ごと消える。**真の DR としては機能しない** (オフサイト退避が必須)。

### 3-7. RKE2 etcd snapshot

RKE2 標準機能、自動有効。

| 項目 | 値 |
|---|---|
| 間隔 | 12 時間 |
| 保持 | 5 世代 |
| 場所 | `/var/lib/rancher/rke2/server/db/snapshots/` (cp1 上) |
| 復元 | `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>` |

[rke2-cluster.md](rke2-cluster.md) の cp1 → NVMe 移行 (2026-05-16) 以降は snapshot も NVMe (`local-lvm`) 上にあるので fsync 性能の心配なし。

---

## 4. 復元手順 (層別)

### 4-1. アプリ DB の論理破損 (per-DB CronJob 経由)

```bash
# backups ns の最新 dump を確認
kubectl exec -n backups deploy/postgres-restore-helper -- ls -lah /backups/postgres/

# 復元 (例)
kubectl exec -n backups deploy/postgres-restore-helper -- \
  bash -c 'gunzip -c /backups/postgres/postgres-20260516.sql.gz | psql -h postgres.databases.svc.cluster.local -U postgres'
```

### 4-2. pg-db (LXC 106) 復元

```bash
DB=icsdb
DUMP=/var/backups/postgresql/${DB}_2026-05-16_0200.dump

pct exec 106 -- bash -c "
  sudo -u postgres dropdb --if-exists '$DB' &&
  sudo -u postgres createdb -O postgres '$DB' &&
  sudo -u postgres pg_restore -d '$DB' --no-owner --role=postgres '$DUMP'
"
```

詳細: [pg-db-postgresql.md §7](pg-db-postgresql.md)

### 4-3. namespace 全体復元 (Velero)

```bash
# 利用可能 backup 一覧
velero backup get

# 復元 (新 namespace に展開する場合 namespace-mappings 使用)
velero restore create wordpress-20260516 \
  --from-backup daily-all-namespaces-20260516050000 \
  --include-namespaces wordpress
```

### 4-4. VM/CT 復元 (PVE vzdump)

```bash
# 一覧
ssh root@192.168.11.11 'ls -lah /mnt/pve/store-sdb/dump/'

# 復元 (新 VMID で展開)
ssh root@192.168.11.11 'qmrestore /mnt/pve/store-sdb/dump/vzdump-qemu-110-*.vma.zst 110 --storage local-lvm'
ssh root@192.168.11.11 'pct restore 106 /mnt/pve/store-sdb/dump/vzdump-lxc-106-*.tar.zst --storage local-lvm'
```

### 4-5. etcd 復元 (cp1)

```bash
ssh root@192.168.11.80 'ls -lah /var/lib/rancher/rke2/server/db/snapshots/'

# RKE2 を停止して復元 (慎重に)
ssh root@192.168.11.80 '
  systemctl stop rke2-server
  rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot-name>
  systemctl start rke2-server
'
```

---

## 5. 既知の GAP

| GAP | 影響 | 緩和策候補 |
|---|---|---|
| **オフサイト退避なし** | PVE host 物理破損で全層消失 | `store-sdb` の vzdump を NAS / クラウドに rsync / restic / rclone で定期同期 ([remaining-tasks.md](remaining-tasks.md) #7) |
| **MinIO BSL が同クラスタ内** | RKE2 クラスタ全滅で Velero も死ぬ | MinIO を別ホストへ、または S3 互換クラウド (R2, Backblaze B2) に切替 |
| **Longhorn snapshot が同 disk 上** | `store-sda` 物理故障で snapshot 一緒に消失 | Longhorn の Backup Target (S3/NFS) を別途設定して定期バックアップ |
| **backup-storage PVC が RWO** | CronJob の同時実行ノード競合 | RWX (Longhorn NFS provisioner) に切替、または node affinity で一台に pin |
| **Zabbix DB は LXC 内のみ** | LXC 190 全損で Zabbix DB 復旧不可 | `/var/backups/zabbix/` を store-sdb 等にコピー追加 ([proxmox-zabbix-monitoring.md Phase 6-E](proxmox-zabbix-monitoring.md) 残課題) |
| **`backup-storage-longhorn` PVC は 10 GiB** | DB が大きくなると詰まる | サイズ監視 (Zabbix Longhorn template) + 必要に応じて拡張 |

---

## 6. 運用 Tips

### 6-1. バックアップが正常に取れているかの確認

```bash
# PVE vzdump 状態
ssh root@192.168.11.11 'tail -30 /var/log/vzdump/*.log'

# pg-db 独自 cron
pct exec 106 -- tail -20 /var/log/postgresql/backup.log

# per-DB CronJob
kubectl get cronjob -n backups
kubectl get jobs -n backups --sort-by=.status.startTime | tail -10

# Velero
velero backup get | head -10
velero backup describe daily-all-namespaces-20260516050000

# Longhorn snapshot
kubectl get volumesnapshot -A
```

### 6-2. リストアテストの推奨頻度

- **per-DB**: 月1 で別 DB 名に restore して動作確認
- **Velero**: 四半期に1回、検証 namespace に restore
- **vzdump**: 半年に1回、新 VMID で展開して boot 確認
- **etcd**: クラスタ作り直しのタイミングで実地確認 (普段は触らない)

「取れている」と「戻せる」は別。**戻したことのない backup は無いのと同じ。**

### 6-3. Job 失敗の一次切り分け

[proxmox-zabbix-monitoring.md §「KubeJobFailed 過渡的失敗の掃除」](proxmox-zabbix-monitoring.md) 参照。

VM 再起動や Longhorn replica patch の直後に過渡的に失敗することがあるので、`kubectl get jobs -A | grep Failed` をワンスショットで掃除する流れにする:
```bash
for ns in backups longhorn-system; do
  kubectl get jobs -n $ns --field-selector status.successful=0 -o name \
    | xargs -r kubectl delete -n $ns
done
```

---

## 7. 関連ドキュメント

- [docs/rke2-cluster.md](rke2-cluster.md) — クラスタ全体構成
- [docs/pg-db-postgresql.md](pg-db-postgresql.md) — pg-db 個別バックアップ
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — PVE vzdump 構築履歴、Job 監視
- [docs/rke2-lessons-learned.md](rke2-lessons-learned.md) — Longhorn / Bitnami 周辺の罠
- [docs/remaining-tasks.md](remaining-tasks.md) — オフサイト退避の宿題 (#7)
