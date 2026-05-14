# homelab-infra

ホームラボ Proxmox VE 環境の構成管理リポジトリ。

## 構成

```
.
├── docs/                       運用ドキュメント
├── scripts/                    デプロイ・運用スクリプト
└── zabbix-configs/             Zabbix 設定スナップショット (configuration.export)
```

## 主要対象

- **Proxmox VE 9.1** (192.168.11.11) — ハイパーバイザ
- **Zabbix 7.0 LTS** (LXC 190 / 192.168.11.55) — 監視
- **ntfy 2.22** (LXC 191 / 192.168.11.56) — モバイル push 通知
- 各種 LXC (dns, dns2, step-ca, nextcloud, pg-db, puter, mail, etc.)

## 運用ルール

1. **機微情報は `.env` に書く** — `.gitignore` で除外、`.env.example` を参照
2. **1 commit = 1 つの論理変更** — 後でレビュー・revert しやすい
3. **commit message には「なぜ」を書く** — コードからは読めない情報を残す
4. **環境変更時は docs を同じ commit で更新** — コードとドキュメントを乖離させない
5. **平文の認証情報は会話・ドキュメントにも残さない** — 必要なら `<masked>` 表記

## クイックリファレンス

- 構築経緯と運用知見: [docs/proxmox-zabbix-monitoring.md](docs/proxmox-zabbix-monitoring.md)
- Git ワークフロー: [docs/homelab-git-workflow.md](docs/homelab-git-workflow.md)

## 主要スクリプト

| Script | 用途 |
|---|---|
| `scripts/proxmox-deploy-puter-cloudflare-access.sh` | Puter LXC + CF Tunnel デプロイ |
| `scripts/proxmox-setup-extra-storage-sda-sdb.sh` | 追加ストレージ (store-sda/sdb) セットアップ |
| `scripts/proxmox-zabbix-set-host-location.sh` | Zabbix 全ホストに座標を API 一括設定 |
