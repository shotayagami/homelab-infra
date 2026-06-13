# homelab-infra

ホームラボ Proxmox VE 環境の構成管理リポジトリ。2 ノードクラスタ `homelab` (192.168.11.11 / .12) 上で、Zabbix 監視基盤 + 通知 (ntfy / Discord / Email) を中心に、関連スクリプトとドキュメントを集約する。

## ハードウェア構成

2026-06-10 より **2 ノードクラスタ `homelab`** で運用している。以下の表は本番ノード `proxmox` (192.168.11.11) の詳細。2 台目 `pve2` (192.168.11.12、i5-9500 / 32 GiB / SATA SSD 480 GB 1 本) を加えたクラスタ構成・ゲスト配置・移行時の帯域制限は [docs/proxmox-cluster.md](docs/proxmox-cluster.md) を参照。

| 項目 | 内容 |
|---|---|
| 筐体 | HP EliteDesk 800 G4 SFF |
| CPU | Intel Core i5-8500 (Coffee Lake, 6C/6T, 3.0–4.1 GHz) |
| メモリ | 32 GiB DDR4-2400 (4×8 GB、4 スロット全埋め、最大 64 GB) |
| 主ストレージ | Samsung 970 EVO Plus 1 TB NVMe — `local-lvm` (LVM-thin 794 GB) + `local` |
| 追加 SSD A | SPCC 480 GB SATA TLC — `store-sda` (旧 RKE2 worker1 ルート。worker1 を `pve2` へ移設後は空き) |
| 追加 SSD B | Fanxiang S101Q 1 TB SATA QLC — `store-sdb` (バックアップ専用) |
| USB HDD ×4 | WDC 8/4 TB + Seagate 3/2 TB (計 ~15.6 TiB) — **OpenMediaVault VM (VMID 100) に disk passthrough**、PVE 側ではマウントしない |
| NIC | Intel I219-LM オンボード 1 GbE → `vmbr0` 192.168.11.11/24 |
| Hypervisor | Proxmox VE 9.2.3 / Kernel 7.0.6-2-pve (`pve2` とクラスタ版を統一) |

詳細・storage tier の決定経緯・拡張余地は [docs/hardware.md](docs/hardware.md)、クラスタ全体は [docs/proxmox-cluster.md](docs/proxmox-cluster.md) を参照。

## 主要対象

「ノード」列は 2 ノードクラスタ上での現在の稼働ノード。HW パススルー・etcd・DB 書き込みの都合で固定するもの、冗長化のため意図的に分散するものがある (詳細と固定理由は [docs/proxmox-cluster.md](docs/proxmox-cluster.md))。

| 役割 | VMID/CTID | 種別 | ノード | IP | 概要 |
|---|---|---|---|---|---|
| Proxmox VE 9.2 (ハイパーバイザ・本番) | — | host | proxmox (.11) | 192.168.11.11 | nodeid 1、Debian 13 ベース。移設不可ワークロードを固定 |
| Proxmox VE 9.2 (ハイパーバイザ・受け皿) | — | host | pve2 (.12) | 192.168.11.12 | nodeid 2、i5-9500 / 32 GiB / SSD 480 GB。RAM 逃がし先・冗長化 |
| OpenMediaVault (NAS) | 100 | VM | proxmox | (LAN 上) | USB HDD 4 台 (8/4/3/2 TB) を SATA1-4 として passthrough、SMB/NFS で配信 |
| puter | 102 | LXC | proxmox | 192.168.11.174 | セルフホスト Internet OS (Docker Compose、CF Tunnel で `puter.yagamin.net` 他公開) |
| dns (Technitium DNS Primary) | 104 | LXC | proxmox | 192.168.11.53 | 内部 DNS Primary |
| pg-db | 106 | LXC | proxmox | 192.168.11.60 | アプリ用 PostgreSQL 17 (RKE2 上の Django アプリの外部 DB)。書き込み律速回避で `.11` 固定 |
| step-ca | 107 | LXC | proxmox | 192.168.11.61 | 内部 PKI (smallstep) |
| nextcloud | 108 | LXC | proxmox | 192.168.11.62 | ファイル共有 + Office |
| freepbx | 109 | LXC | proxmox | 192.168.11.57 | 構内内線 PBX (FreePBX 17 / Asterisk 22) |
| k8s-cp1 (RKE2 control plane) | 110 | VM | proxmox | 192.168.11.80 | RKE2 v1.34.3、ArgoCD/Harbor/Gitea/Longhorn 等。etcd fsync の都合で NVMe のある `.11` 固定 |
| admin-vm | 150 | VM | proxmox | 192.168.11.10 | 運用クライアント、`/usr/local/bin` に `pct/qm/pvesh/pveum` SSH ラッパー設置済、Zabbix 監視 (hostid=10704、2026-05-19 追加) |
| dns2 (Technitium DNS Secondary) | 105 | LXC | pve2 | 192.168.11.54 | 内部 DNS Secondary。dns(.11) と物理分散して冗長化 |
| k8s-worker1 (RKE2 worker) | 120 | VM | pve2 | 192.168.11.83 | Longhorn replica ホスト (`store-sda` ではなく `pve2` の `local-lvm` 上)。RAM 逃がしで `.12` へ移設 |
| icstv-playout2 | 131 | LXC | pve2 | 192.168.11.20 | ICS-TV 送出ノード (CasparCG/MediaMTX/icstv-agent)、`pve2` iGPU を passthrough |
| Zabbix 7.0 LTS | 190 | LXC | pve2 | 192.168.11.55 | 監視サーバ + Web UI + PostgreSQL 16。`.11` 障害でも生存させるため `.12` へ |
| ntfy 2.22 | 191 | LXC | pve2 | 192.168.11.56 | モバイル push 通知、CF Tunnel 公開 |

## ディレクトリ構成

```
.
├── README.md                     ← 本書（リポジトリの入口）
├── .gitignore                    ← 機微情報を除外する設定
├── .env.example                  ← .env のテンプレート
├── docs/                         ← 運用ドキュメント
│   ├── hardware.md                    ← ハードウェア詳細 + storage tier 設計 (本番ノード .11)
│   ├── proxmox-cluster.md             ← 2 ノードクラスタ homelab (ノード/配置/移行帯域制限)
│   ├── proxmox-firewall.md            ← PVE Firewall 運用・ロックアウト復旧
│   ├── proxmox-host-self-healing.md   ← network-watchdog / vm-health-monitor 自律復旧層
│   ├── admin-vm-tooling.md            ← admin-vm の pct/qm/pvesh ラッパー
│   ├── internal-dns.md                ← Technitium dns/dns2 (Primary/Secondary + DHCP)
│   ├── internal-tls.md                ← step-ca + サービス TLS 自動更新
│   ├── puter-selfhost.md              ← Puter (LXC 102) セルフホスト
│   ├── pg-db-postgresql.md            ← pg-db (LXC 106) アプリ用 PostgreSQL 17
│   ├── rke2-cluster.md                ← RKE2 クラスタの workload と最適化履歴
│   ├── rke2-workloads.md              ← RKE2 上のアプリカタログ (ICS / WordPress / Gitea / Harbor)
│   ├── rke2-lessons-learned.md        ← K8s / cert-manager / Bitnami のハマりポイント集
│   ├── single-instance-rwo-rollout-deadlock.md ← 単一インスタンス + RWO PVC + 内蔵 DB の rollout デッドロック (Gitea 経験から横展開)
│   ├── backup-strategy.md             ← 多層バックアップの俯瞰 (vzdump / CronJob / Longhorn / Velero / etcd)
│   ├── proxmox-zabbix-monitoring.md   ← Zabbix Phase 1-6 構築記録 + 運用知見
│   ├── homelab-git-workflow.md        ← Git 運用ルール
│   ├── github-post-setup.md           ← GitHub 設定の継続作業
│   └── remaining-tasks.md             ← 残タスク一覧
├── scripts/                      ← デプロイ・運用スクリプト + 救出済の runtime 系
│   ├── git-hooks/                     ← Git hooks の正本（install-hooks.sh で symlink）
│   │   └── pre-commit
│   ├── install-hooks.sh
│   ├── github-create-initial-issues.sh
│   ├── proxmox-deploy-puter-cloudflare-access.sh
│   ├── proxmox-deploy-zabbix-cloudflare-access.sh
│   ├── proxmox-setup-extra-storage-sda-sdb.sh
│   ├── proxmox-zabbix-apply-nextcloud-template.sh
│   ├── proxmox-zabbix-set-host-location.sh
│   ├── admin-vm/                      ← admin-vm 配置物
│   │   └── pve-wrapper                   ← pct/qm/pvesh/pveum SSH ラッパー
│   ├── pve-host/                      ← PVE host 配置物
│   │   ├── network-watchdog.{sh,service}     ← NIC 障害検知・段階エスカレーション
│   │   ├── vm-health-monitor.{sh,service}    ← VM/LXC 死活監視・自動復旧
│   │   ├── vm-health-monitor.targets.conf.example
│   │   └── jobs.cfg.example                  ← vzdump スケジュールサンプル
│   ├── lxc-pg-db/                     ← LXC 106 (pg-db) 配置物
│   │   ├── pg_backup.sh                      ← PG 日次 dump スクリプト
│   │   └── pg_backup.cron                    ← 同 cron 登録
│   └── systemd-units/                 ← step-ca + Cilium 経路 unit 群
│       ├── step-renew-nextcloud.service
│       ├── step-renew-zabbix.service
│       └── k8s-pod-routes.service
└── zabbix-configs/               ← Zabbix 設定スナップショット
    ├── .gitkeep
    └── README.md                       ← 配置ルール
```

## クイックリファレンス

### システム基盤
- **ハードウェア構成**: [docs/hardware.md](docs/hardware.md)
- **PVE Firewall 運用**: [docs/proxmox-firewall.md](docs/proxmox-firewall.md)
- **PVE ホスト自律復旧**: [docs/proxmox-host-self-healing.md](docs/proxmox-host-self-healing.md)
- **バックアップ多層構造**: [docs/backup-strategy.md](docs/backup-strategy.md)
- **K8s / RKE2 Lessons Learned**: [docs/rke2-lessons-learned.md](docs/rke2-lessons-learned.md)
- **admin-vm 運用ツール**: [docs/admin-vm-tooling.md](docs/admin-vm-tooling.md)

### サービス
- **内部 DNS (Technitium)**: [docs/internal-dns.md](docs/internal-dns.md)
- **内部 TLS / PKI (step-ca)**: [docs/internal-tls.md](docs/internal-tls.md)
- **Puter セルフホスト**: [docs/puter-selfhost.md](docs/puter-selfhost.md)
- **pg-db (アプリ用 PostgreSQL)**: [docs/pg-db-postgresql.md](docs/pg-db-postgresql.md)
- **RKE2 クラスタ (インフラ層)**: [docs/rke2-cluster.md](docs/rke2-cluster.md)
- **RKE2 ワークロード (アプリ層)**: [docs/rke2-workloads.md](docs/rke2-workloads.md)
- **Zabbix 監視 (Phase 1-6 構築記録)**: [docs/proxmox-zabbix-monitoring.md](docs/proxmox-zabbix-monitoring.md)

### 運用・リポジトリ
- **Git ワークフロー**: [docs/homelab-git-workflow.md](docs/homelab-git-workflow.md)
- **GitHub 継続作業**: [docs/github-post-setup.md](docs/github-post-setup.md)
- **残タスク一覧**: [docs/remaining-tasks.md](docs/remaining-tasks.md)

## 運用ルール

1. **機微情報は `.env` に書く** — `.gitignore` で除外、テンプレートは `.env.example`
2. **1 commit = 1 つの論理変更** — 後でレビュー・revert しやすい
3. **commit message には「なぜ」を書く** — コードから読めない情報を残す
4. **環境変更時は docs を同じ commit で更新** — コードとドキュメントの乖離を防ぐ
5. **平文の認証情報は会話・ドキュメントにも残さない** — 必要なら `<masked>` 表記

## 初期セットアップ（clone 直後）

```bash
npm install                      # secretlint (devDependency) を取得
bash scripts/install-hooks.sh   # pre-commit hook を有効化 (gitleaks + secretlint 連携)
cp .env.example .env             # 値を埋める (CF/Zabbix tokens)
```

機微情報スキャンは三層構成:

| 層 | ツール | 起点 |
|---|---|---|
| 1. ローカル commit 前 | pre-commit hook 内の identity check / gitleaks / secretlint | `bash scripts/install-hooks.sh` |
| 2. push 時 | GitHub Secret Scanning + Push Protection | リポジトリ Settings (既定で有効) |
| 3. push 後 | GitHub CodeQL default setup (対象言語追加時に自動起動) | Settings > Code security > Default setup |

> CodeQL は現状 Shell のみのため対象言語ゼロ。JavaScript / Python / Go 等を追加した時点で自動的に走り出す。

`ZBX_API_TOKEN` は Zabbix UI → ユーザー → API トークン から発行 (User=Admin, 期限なし推奨)。
Zabbix Admin に MFA 有効な環境では `user.login` の session が即 invalidate するため、
`scripts/proxmox-zabbix-*.sh` は ZBX_API_TOKEN を優先 read する設計。

詳細は [docs/homelab-git-workflow.md](docs/homelab-git-workflow.md) §6 を参照。

## 主要スクリプト

| Script | 用途 |
|---|---|
| [scripts/install-hooks.sh](scripts/install-hooks.sh) | `scripts/git-hooks/*` を `.git/hooks/` に symlink (clone 後の初期化) |
| [scripts/github-create-initial-issues.sh](scripts/github-create-initial-issues.sh) | 残作業を GitHub Issues として一括登録（冪等） |
| [scripts/proxmox-deploy-puter-cloudflare-access.sh](scripts/proxmox-deploy-puter-cloudflare-access.sh) | Puter LXC + Cloudflare Tunnel デプロイ |
| [scripts/proxmox-setup-extra-storage-sda-sdb.sh](scripts/proxmox-setup-extra-storage-sda-sdb.sh) | 追加ディスク (store-sda/sdb) セットアップ |
| [scripts/proxmox-zabbix-set-host-location.sh](scripts/proxmox-zabbix-set-host-location.sh) | Zabbix 全ホストの inventory に座標を API 一括設定 |
| [scripts/proxmox-zabbix-apply-nextcloud-template.sh](scripts/proxmox-zabbix-apply-nextcloud-template.sh) | Phase 4-B: Nextcloud HTTP テンプレ + macros を API 適用 (Issue #1) |
| [scripts/proxmox-deploy-zabbix-cloudflare-access.sh](scripts/proxmox-deploy-zabbix-cloudflare-access.sh) | Zabbix UI を CF Tunnel + CF Access で外部公開 (Issue #7) |

## 通知経路

```
Zabbix Trigger 発火
    │
    ▼
Action "All triggers to Admin" (actionid=7)
    │
    ▼
Admin user の 3 media に同時配信
    │
    ├──→ ntfy (mediatypeid=72)
    │       Bearer token 認証で http://192.168.11.56/zabbix-alerts に POST
    │       モバイルアプリは https://ntfy.yagamin.net 経由で受信 (CF Tunnel)
    │
    ├──→ Discord (mediatypeid=39)
    │       組込 webhook テンプレート、channel home.yagamin.net
    │
    └──→ Mailgun (mediatypeid=73)
            smtp.mailgun.org:465 SSL/TLS、SMTP auth
            送信先: <your-email>
```

## ロードマップ

完了済:
- Phase 1-3: Zabbix 構築 + agent 配布 (v1.0.0)
- Phase 4-A: DNS サービス監視 (v1.0.0)
- Phase 4-C: step-ca 監視 (v1.0.0)
- Phase 5: 通知 3 系統 + アクション (v1.0.0)
- Phase 6: バックアップ + Config export + docs (v1.0.0)
- Phase 4-B: Nextcloud 監視 (2026-05-15、ntfy/Discord/Mailgun 3 系統に実 trigger 配信を実証)
- Phase 6-E: クレデンシャル rotation (2026-05-15、Mailgun/Discord/ntfy/Zabbix Admin/DNS PFX)
- Phase 4-D: RKE2 クラスタ監視 (2026-05-16、Linux agent + `Kubernetes cluster state by HTTP` + Cilium pod 網への static route で 3397 items 取得)
- RKE2 etcd 安定化 (2026-05-16、cp1 を NVMe `local-lvm` / worker1 を `store-sda` SPCC SSD に live migrate、Fanxiang QLC は backup 専用に)
- **dns2 DoT/DoH 復旧** (2026-05-19、`/etc/dns/dns.config` の cert path フィールド末尾に literal タブ混入が真因と判明、binary patch で復旧。Zabbix item/trigger も再有効化。PR #38)
- **dns/dns2 admin UI HTTPS (53443) 復旧** (2026-05-19、`webservice.config` の trailing-tab + 空 password の二重バグ、両ノードで TLSv1.3 + HTTP 200 確認。PR #39)
- **dns/dns2 cert を step-ca 由来に切替 + 自動更新** (2026-05-19、JWK provisioner で発行 → PEM→PFX 変換、`step-renew-dns.service` で 7d cert を残り 5d 切ったら更新。`Verify return code: 0 (ok)` 確認。PR #40)
- **admin-vm Zabbix 監視追加** (2026-05-19、zabbix-agent2 7.0.26 + hostid=10704、103 items 取得確認。本 PR #41)

未完了:
- 残タスク全体は [docs/remaining-tasks.md](docs/remaining-tasks.md) を参照

## ライセンス

[MIT License](LICENSE)。個人のホームラボ運用記録だが、構成や手順は学習資料として再利用可。

実環境のドメイン名・IP・トポロジーをそのまま記載しているため、フォークして自宅に流用する場合は各自の環境に置き換えること。
