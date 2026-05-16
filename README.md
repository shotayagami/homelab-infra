# homelab-infra

ホームラボ Proxmox VE 環境の構成管理リポジトリ。Zabbix 監視基盤 + 通知 (ntfy / Discord / Email) を中心に、関連スクリプトとドキュメントを集約する。

## 主要対象

| 役割 | VMID/CTID | 種別 | IP | 概要 |
|---|---|---|---|---|
| Proxmox VE 9.1 (ハイパーバイザ) | — | host | 192.168.11.11 | Debian 13 ベース |
| Zabbix 7.0 LTS | 190 | LXC | 192.168.11.55 | 監視サーバ + Web UI + PostgreSQL 16 |
| ntfy 2.22 | 191 | LXC | 192.168.11.56 | モバイル push 通知、CF Tunnel 公開 |
| dns / dns2 (Technitium DNS) | 104 / 105 | LXC | 192.168.11.53 / .54 | 内部 DNS Primary/Secondary |
| step-ca | 107 | LXC | 192.168.11.61 | 内部 PKI (smallstep) |
| nextcloud | 108 | LXC | 192.168.11.62 | ファイル共有 + Office |
| pg-db | 106 | LXC | 192.168.11.60 | アプリ用 PostgreSQL |
| puter | 102 | LXC | (停止中) | セルフホスト Internet OS |
| k8s-cp1 (RKE2 control plane) | 110 | VM | 192.168.11.80 | RKE2 v1.34.3、ArgoCD/Harbor/Gitea/Longhorn 等を載せる検証クラスタ |
| k8s-worker1 (RKE2 worker) | 120 | VM | 192.168.11.83 | Longhorn replica ホスト (`store-sda` 上) |
| admin-vm | 150 | VM | (PVE 経由 SSH) | 運用クライアント、`/usr/local/bin` に `pct/qm/pvesh/pveum` SSH ラッパー設置済 |

## ディレクトリ構成

```
.
├── README.md                     ← 本書（リポジトリの入口）
├── .gitignore                    ← 機微情報を除外する設定
├── .env.example                  ← .env のテンプレート
├── docs/                         ← 運用ドキュメント
│   ├── proxmox-zabbix-monitoring.md   ← Phase 1-6 構築記録 + 運用知見
│   ├── homelab-git-workflow.md        ← Git 運用ルール
│   └── github-post-setup.md           ← GitHub 設定の継続作業
├── scripts/                      ← デプロイ・運用スクリプト
│   ├── git-hooks/                     ← Git hooks の正本（install-hooks.sh で symlink）
│   │   └── pre-commit
│   ├── install-hooks.sh
│   ├── github-create-initial-issues.sh
│   ├── proxmox-deploy-puter-cloudflare-access.sh
│   ├── proxmox-setup-extra-storage-sda-sdb.sh
│   └── proxmox-zabbix-set-host-location.sh
└── zabbix-configs/               ← Zabbix 設定スナップショット
    ├── .gitkeep
    └── README.md                       ← 配置ルール
```

## クイックリファレンス

- **構築経緯と運用知見**: [docs/proxmox-zabbix-monitoring.md](docs/proxmox-zabbix-monitoring.md)
- **Git ワークフロー**: [docs/homelab-git-workflow.md](docs/homelab-git-workflow.md)
- **GitHub 継続作業**: [docs/github-post-setup.md](docs/github-post-setup.md)

## 運用ルール

1. **機微情報は `.env` に書く** — `.gitignore` で除外、テンプレートは `.env.example`
2. **1 commit = 1 つの論理変更** — 後でレビュー・revert しやすい
3. **commit message には「なぜ」を書く** — コードから読めない情報を残す
4. **環境変更時は docs を同じ commit で更新** — コードとドキュメントの乖離を防ぐ
5. **平文の認証情報は会話・ドキュメントにも残さない** — 必要なら `<masked>` 表記

## 初期セットアップ（clone 直後）

```bash
bash scripts/install-hooks.sh   # pre-commit hook を有効化 (gitleaks 連携)
cp .env.example .env             # 値を埋める (CF/Zabbix tokens)
```

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

未完了:
- dns2 の DoT/DoH 再有効化（Technitium 15.x の cert load 不具合の追跡、Issue #3）
- 残タスク全体は [docs/remaining-tasks.md](docs/remaining-tasks.md) を参照

## ライセンス

[MIT License](LICENSE)。個人のホームラボ運用記録だが、構成や手順は学習資料として再利用可。

実環境のドメイン名・IP・トポロジーをそのまま記載しているため、フォークして自宅に流用する場合は各自の環境に置き換えること。
