# pg-db (LXC 106) — アプリ用 PostgreSQL

最終更新: 2026-05-16

ホームラボの汎用 PostgreSQL サーバ。RKE2 上で動かす Django アプリ等の外部 DB として用意したもの。Zabbix 用 DB（LXC 190 同居の PG16）とは別の系統。

> **2026-05-16 整備実施:** myappdb / app_user 削除、pg_hba/ufw から worker2 (.84) 撤去、Zabbix 監視導入 (Linux + PostgreSQL by Zabbix agent 2 テンプレ適用、unix socket 経由)、PG SSL を snakeoil → step-ca cert に切替。詳細は §10 を参照。

## 1. 基本情報

| 項目 | 値 |
|---|---|
| VMID / hostname | 106 / `pg-db` |
| 種別 | unprivileged LXC, `nesting=1` |
| OS | Ubuntu 24.04.4 LTS (Noble) |
| IPv4 | 192.168.11.60/24, gw 192.168.11.1 |
| DNS | 192.168.11.53 (内部 dns) |
| CPU / RAM / Swap | 1 core / 2 GiB / 512 MiB |
| Disk | `local-lvm:vm-106-disk-0`, 20 GB（うち使用 1.6 GB） |
| onboot | 1 |
| PVE storage | NVMe (`local-lvm`) |

## 2. PostgreSQL 構成

| 項目 | 値 |
|---|---|
| バージョン | **PostgreSQL 17.9** (PGDG `pgdg24.04+1`) |
| クラスタ | `17/main` (Debian/Ubuntu 標準パッケージ運用) |
| Data dir | `/var/lib/postgresql/17/main` |
| Log | `/var/log/postgresql/postgresql-%Y-%m-%d.log` (logging_collector 有効) |
| Listen | `192.168.11.60:5432` のみ（`listen_addresses` を明示）+ Unix socket |
| `max_connections` | 100 (デフォルト) |
| `shared_buffers` | 128MB (デフォルト) |
| SSL | `ssl=on`、cert は **step-ca 発行** (`/etc/ssl/step/cert.pem`、CN=192.168.11.60、SAN IP=.60、30 日有効、15 日 renew) |

### ロール

| Role | 属性 | 用途 |
|---|---|---|
| `postgres` | Superuser | 管理 |
| `ics_user` | LOGIN のみ | `icsdb` 専用アプリユーザ |
| `zbx_monitor` | LOGIN, `pg_monitor` グループ | Zabbix agent2 PG プラグイン専用、unix socket からのみ接続 |

### データベース

| DB | Owner | size | 状態 |
|---|---|---|---|
| `icsdb` | postgres | dump 212KB | **Django アプリのスキーマだけ存在、全テーブル 0 行**。`accounts_customuser` / `admin_portal_*` / `auth_*` / `shop_*` (cart/category/orderitem) / `contact_inquiry` / `token_blacklist_outstandingtoken` (DRF JWT) / `django_celery_beat_*` / `django_celery_results_*`。 |

`ics_user` には `c` (CONNECT) のみ付与、テーブル所有者は `postgres`。
`zbx_monitor` のパスワードは pg-db CT 内 `/root/.zbx-monitor-password` (mode 600) に保管。

### `pg_hba.conf` (auth)

```
local   all     postgres                            peer
local   all     all                                 scram-sha-256
host    all     all     127.0.0.1/32                scram-sha-256
host    all     all     ::1/128                     scram-sha-256
host    icsdb   ics_user    192.168.11.80/32        scram-sha-256
host    icsdb   ics_user    192.168.11.83/32        scram-sha-256
host    all     postgres    192.168.11.11/32        scram-sha-256
host    all     postgres    192.168.11.80/32        scram-sha-256
host    all     postgres    192.168.11.83/32        scram-sha-256
```

許可元は **PVE ホスト (.11) と RKE2 ノード (cp1=.80, worker1=.83)** に限定。
`zbx_monitor` は unix socket 経由でのみ接続するため `local all all scram-sha-256` で認証される（追加エントリ不要）。
バックアップは `/etc/postgresql/17/main/pg_hba.conf.bak.<timestamp>` に保管。

### CT 内 ufw

ホスト側 PVE Firewall は CT 106 で未適用 (`firewall=0`)、CT 内の **ufw が実際の access control を担当** している。

```
[ 1] 22/tcp                     ALLOW IN    192.168.11.11             # SSH from PVE
[ 2] 5432/tcp                   ALLOW IN    192.168.11.80             # PG from cp1
[ 3] 5432/tcp                   ALLOW IN    192.168.11.83             # PG from worker1
[ 4] 5432/tcp                   ALLOW IN    192.168.11.11             # PG from PVE
[ 5] 10050/tcp                  ALLOW IN    192.168.11.55             # Zabbix agent
```

Default policy は `deny (incoming) / allow (outgoing) / deny (routed)`。pg_hba と ufw の許可元は同期させる運用とする（追加 / 削除時は両方触ること）。

## 3. 接続元（実態）

PG ログ（2026-05-16）から確認できた接続元:

| client | role / db | パターン |
|---|---|---|
| `192.168.11.80` (cp1) | `ics_user@icsdb` | **約 30 秒間隔で短時間接続 → 即 disconnect**。Django アプリの health check または connection pool の min-idle 維持。常時 1 本 idle で持続。 |
| `192.168.11.83` (worker1) | `ics_user@icsdb` | 同上、別レプリカ |
| `[local]` | `postgres@*` | バックアップ cron + 手動メンテ |

実際にアプリ DB を読み書きしているのは **RKE2 上の Django ワークロード**。具体的な Deployment / namespace の特定は別途 (`kubectl get cm,secret -A | grep 192.168.11.60`)。

## 4. バックアップ

### 自動 (内部) — `pg_backup.sh`

| 項目 | 値 |
|---|---|
| スクリプト | `/usr/local/bin/pg_backup.sh` (リポジトリ内コピー: [scripts/lxc-pg-db/pg_backup.sh](../scripts/lxc-pg-db/pg_backup.sh)) |
| Cron | `/etc/cron.d/pg_backup` — `0 2 * * * root /usr/local/bin/pg_backup.sh` (リポジトリ内: [scripts/lxc-pg-db/pg_backup.cron](../scripts/lxc-pg-db/pg_backup.cron)) |
| 出力先 | `/var/backups/postgresql/` (postgres:postgres 700) |
| 形式 | DB ごとに `pg_dump -Fc` (custom format) + `pg_dumpall --globals-only` |
| ファイル名 | `<db>_YYYY-MM-DD_HHMM.dump`, `globals_YYYY-MM-DD_HHMM.sql` |
| 保持 | **14 日**（mtime ベースで自動削除） |
| Log | `/var/log/postgresql/backup.log` |
| 直近サイズ | icsdb 212KB / myappdb 12KB / globals 1.2KB / **合計 3.4 MB** (15 世代) |

### 外部 (PVE vzdump)

PVE host 側の `/etc/pve/jobs.cfg` で **VMID 106 を含む** 日次 vzdump 対象に登録済 ([docs/proxmox-zabbix-monitoring.md §5 Phase 6-B](proxmox-zabbix-monitoring.md))。

- 02:00 JST 起動（pg_backup と同じ時刻 — DB dump は CT 内、vzdump はホスト snapshot で並走）
- storage `store-sdb` (Fanxiang QLC、バックアップ専用)
- 圧縮 zstd, mode snapshot
- 保持 keep-daily=7 / keep-weekly=4 / keep-monthly=6

## 5. 周辺ユーティリティ

### step-ca cert (PG SSL に適用済)

`/etc/ssl/step/cert.pem` に **step-ca 発行の cert** (CN=192.168.11.60, SAN IP=.60, 30 日有効) と key が配置され、**postgresql.conf から参照**:

```
ssl_cert_file = '/etc/ssl/step/cert.pem'
ssl_key_file  = '/etc/ssl/step/key.pem'
```

ファイル所有は `root:postgres 640` (PG 11+ の group readable 許容を利用、key も group 経由で postgres が読める)。

更新 cron `/etc/cron.d/step-ca-renew` は 15 日おきに `step ca renew --force` を実行し、`--exec` フックで:
```
chown root:postgres /etc/ssl/step/{cert,key}.pem
chmod 640 /etc/ssl/step/{cert,key}.pem
systemctl reload postgresql
```
を実行する。renew 時に所有権が root:root にリセットされても自動で復元 + PG SSL context が SIGHUP で読み直される。

クライアント側で `sslmode=verify-full` を使うには step-ca の Root CA (`/etc/nginx/ssl/ca.crt` 相当) をクライアント (Django の RKE2 pod 等) に配布する必要あり。現状 Django 側は `sslmode=prefer` または `disable` で接続しているはずなので互換性影響なし。

### `step-ca` の bootstrap

- `/root/.step/config/defaults.json` で `ca-url=https://step-ca.home.yagamin.net`、fingerprint 設定済
- root CA は `/root/.step/certs/root_ca.crt`

## 6. Zabbix 監視

**2026-05-16 構築完了** (hostid=10702、Zabbix server LXC 190)。

| 項目 | 値 |
|---|---|
| Agent | `zabbix-agent2 1:7.0.26-2+ubuntu24.04` (passive、`*:10050`) |
| Server / ServerActive | 192.168.11.55 |
| Hostname (zabbix_agent2.conf) | `pg-db` |
| Templates | `Linux by Zabbix agent` (10001), `PostgreSQL by Zabbix agent 2` (10329) |
| Host groups | `Linux servers` (2), `Databases` (20) |
| 追加パッケージ | `zabbix-agent2-plugin-postgresql` (PG プラグインは 7.0 から別パッケージ) |

### 接続方式（Unix socket）

PG は `192.168.11.60:5432` のみで listen し、`127.0.0.1:5432` を持たない。テンプレ既定の `tcp://localhost:5432` は使えないため、**Unix socket 経由** に切替えた:

```
{$PG.CONNSTRING.AGENT2} = unix:/var/run/postgresql/.s.PGSQL.5432
{$PG.USER}              = zbx_monitor
{$PG.PASSWORD}          = (secret macro)
{$PG.DATABASE}          = postgres
```

これにより pg_hba 側に `zbx_monitor` 用の host エントリを追加せず、`local all all scram-sha-256` で認証できる。

### LXC 共通の trigger 調整

[docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) §「LXC は `/proc/loadavg` を PVE ホストと共有する」の運用ルール通り、`Linux: Load average is too high` (triggerid=27732) は LXC では `/proc/loadavg` をホストと共有するため誤発火源 → **disable 済**。

### 動作確認 (構築直後)

- 206 items 登録、初回 30s で 184 件が値取得（残りは leverage rate 計算系で次サンプル待ち）
- `pgsql.ping = 1.0`、`pgsql.uptime = ~41000s`
- Linux テンプレ系 (CPU/Mem/Disk/Network) も全て green

## 7. 運用 Tips

### よく使うコマンド (PVE ホストから)

```bash
# 接続状況
pct exec 106 -- su - postgres -c \
  'psql -c "SELECT datname,usename,client_addr,state,backend_start FROM pg_stat_activity WHERE pid<>pg_backend_pid();"'

# DB サイズ
pct exec 106 -- su - postgres -c \
  'psql -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"'

# 最新バックアップ確認
pct exec 106 -- bash -c 'ls -lah /var/backups/postgresql/ | tail -10; tail -5 /var/log/postgresql/backup.log'

# 直近の接続元
pct exec 106 -- bash -c 'grep "connection received" /var/log/postgresql/postgresql-$(date +%F).log | grep -oE "host=[^ ]+" | sort | uniq -c'
```

### リストア手順 (custom dump)

```bash
# CT 内で:
DB=icsdb
DUMP=/var/backups/postgresql/${DB}_YYYY-MM-DD_HHMM.dump

# 既存 DB を破棄して入れ直す場合（破壊的）:
sudo -u postgres dropdb --if-exists "$DB"
sudo -u postgres createdb -O postgres "$DB"
sudo -u postgres pg_restore -d "$DB" --no-owner --role=postgres "$DUMP"

# 別名 DB に展開して比較する場合:
sudo -u postgres createdb -O postgres "${DB}_restore_test"
sudo -u postgres pg_restore -d "${DB}_restore_test" --no-owner "$DUMP"
```

### major upgrade 時の注意

PG 17 → 18 を行う場合:

- `pg_upgradecluster` (Debian/Ubuntu の `postgresql-common` 同梱) で in-place アップグレード
- 事前に最新 dump を取得（cron は 02:00 なので終わってから作業推奨）
- `pg_hba.conf` / `postgresql.conf` のカスタム設定を新クラスタに移植する必要あり（`listen_addresses`, ssl 関連、ホスト許可ルール）

## 8. 既知の宿題

- [x] ~~**Zabbix 未登録**~~ — 2026-05-16 完了 (§6)
- [x] ~~`pg_hba.conf` の `192.168.11.84/32` (存在しない worker2) を整理~~ — 2026-05-16 完了 (ufw からも撤去済)
- [x] ~~`myappdb` の用途確定~~ — 2026-05-16 drop、`app_user` も併せて削除
- [x] ~~step-ca cert を PG SSL に紐付ける~~ — 2026-05-16 完了 (§5、renew フックで chown + reload 自動化)
- [ ] バックアップの **オフサイト退避**（外部ストレージへの rsync/restic 等、Zabbix DB と同じ宿題）
- [ ] (任意) Django pod に step-ca Root CA を配布 → `sslmode=verify-full` に引き上げ

## 9. 関連ドキュメント

- [README.md](../README.md) — 主要対象テーブル
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Zabbix 構築履歴 (pg-db は §10 で追加)
- [docs/rke2-cluster.md](rke2-cluster.md) — 接続元の Django アプリは RKE2 上
- [docs/internal-tls.md](internal-tls.md) — step-ca の運用パターン (PG にも同型を適用したい場合)

## 10. 2026-05-16 整備作業ログ

### 実施内容

1. **`myappdb` + `app_user` を drop** — 過去に一度も接続実績なし、空 DB のまま放置されていたため。最終 dump (`myappdb_2026-05-16_0200.dump`, 8KB) はバックアップ世代に残存
2. **`pg_hba.conf` から worker2 (.84) のエントリ撤去** + 上記 drop に伴い `myappdb / app_user` 行も削除 → 残りは PVE / cp1 / worker1 のみの 9 行
3. **CT 内 ufw からも 5432/.84 を削除** + Zabbix agent 用に **10050/tcp from 192.168.11.55** を追加
4. **`zabbix-agent2` + `zabbix-agent2-plugin-postgresql` 1:7.0.26-2+ubuntu24.04 を導入** (Server=.55, Hostname=pg-db、systemctl restart で反映)
5. **PG に `zbx_monitor` ユーザ作成** (24-byte hex random password、`pg_monitor` グループ付与、パスワードは `/root/.zbx-monitor-password` 600 に保管)
6. **Zabbix host `pg-db` (hostid=10702) を API で登録** — Linux + PostgreSQL by Zabbix agent 2 テンプレ、Linux servers + Databases group、4 macros (CONNSTRING.AGENT2 を unix socket に上書き)
7. **`Linux: Load average is too high` trigger (27732) を disable** — LXC は `/proc/loadavg` をホストと共有するため
8. **PG SSL を snakeoil → step-ca cert に切替** — `/etc/ssl/step/{cert,key}.pem` を `root:postgres 640` に、`postgresql.conf` の `ssl_cert_file/ssl_key_file` を切替、`pg_ctlcluster 17 main reload`。renew cron に `--exec "chown + chmod + systemctl reload postgresql"` を付与。reload 中も既存 Django 接続は無瞬断、TLS handshake で新 cert (CN=192.168.11.60, issuer=Home Lab CA Intermediate CA) を提示することを `openssl s_client -starttls postgres` で確認

### 引っかかりポイント

- **Zabbix 7.0 の PG プラグインは別パッケージ** — `zabbix-agent2` だけ入れて `pgsql.ping` を試すと `Unknown metric` で失敗。`zabbix-agent2-plugin-postgresql` を別途 apt install する必要あり
- **Unix socket URI の正しい形式** — テンプレ既定の `tcp://localhost:5432` は PG の `listen_addresses` が `192.168.11.60` 専用なので使えない。`unix:/var/run/postgresql:5432` は parser エラーで `unix:/var/run/postgresql/.s.PGSQL.5432` (フルソケットパス) が正解
- **CT 内 ufw が deny-all** — pg_hba を直してもネットワーク到達できなければ Zabbix agent からの監視は動かない。**ufw と pg_hba は同期させる運用ルール** とする
- **PG SSL key の権限要件** — PG 11+ では `0600 (postgres:postgres)` 以外に `0640 (root:postgres)` も許容。後者なら step renew が root で動く前提とも整合性が取れて運用が綺麗
