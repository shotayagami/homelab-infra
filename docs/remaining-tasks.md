# 残タスク一覧

**最終更新**: 2026-05-16 (RKE2 関連を追加)
**前回棚卸し時に完了済**: Issue #5 (Nextcloud zabbix-monitor app password rotation)、Phase 4-D RKE2 監視、cp1 etcd fsync 解消

GitHub Issues、`docs/proxmox-zabbix-monitoring.md` の業務本番化チェックリスト、`~/.claude/projects/-home-shotayagami/memory/` の宿題記述を横断的に集約したもの。優先度は当面の運用影響と着手コストで仮置き。

---

## 🔴 セキュリティ系 (rotation 推奨度高)

会話履歴に平文で残っているクレデンシャル群。本番運用前にローテすることで業務環境としての清潔さを保つ。

| # | 内容 | 出所 | 備考 |
|---|---|---|---|
| 1 | Zabbix API token (`ZBX_TOKEN`) | 2026-05-15 セッションで露出 | Zabbix UI → User → API tokens で revoke + 再発行、`~/.env` の `ZBX_API_TOKEN` を更新 |
| 2 | Mailgun SMTP credential | 業務本番化チェックリスト #2、`docs/proxmox-zabbix-monitoring.md` 230行 | Mailgun ダッシュボード → SMTP credentials → reset、Zabbix media type "Mailgun" の設定更新 |
| 3 | Discord webhook URL | チェックリスト #3 | Discord チャンネル設定 → Webhooks → 既存 delete + 再作成、Zabbix media type "Discord" の URL 更新 |
| 4 | ntfy zabbix user token | チェックリスト #4 | ntfy `zabbix` user の access token を `tk_...` 再発行、Zabbix media type "ntfy" の Bearer 値更新 |
| 5 | Zabbix Admin パスワード強度確認 | チェックリスト #1 | 既に強化済か再確認のみ。問題なければチェック外す |

**手順テンプレート** (Issue #5 の流れと同型):
```bash
set +o history
read -rs -p "NEW_TOKEN: " NEW; echo
# usermacro.update or media type 更新を curl で実行
unset NEW
set -o history
```

---

## 🟡 インフラ堅牢化 (中優先)

| # | 内容 | 出所 | 備考 |
|---|---|---|---|
| 6 | PVE firewall 再有効化 | チェックリスト #6 | 現状 `enable: 0`。datacenter / node / VM-CT 各レベルで段階的に再有効化、ロックアウト回避ルール (memory `proxmox_firewall.md`) を遵守 |
| 7 | バックアップ外部ストレージ同期 | チェックリスト #5 | rsync / restic / rclone で `store-sdb` の vzdump を NAS / クラウドに退避。Zabbix DB は LXC 内のみ → 障害時 DR 強化 |
| 8 | [Issue #9](https://github.com/shotayagami/homelab-infra/issues/9) Nextcloud `app:update --all` + occ upgrade (33.0.0.16 → 最新) | GitHub | アプリ + 本体のアップグレード。バックアップ取得後に実施 |
| 15 | RKE2 cp1 etcd fsync 経過観察 (移行後) | 2026-05-16 作業 doc §8 | `qm move-disk` 完了直後で 9 分時点で `slow fdatasync` ゼロ確認まで。数時間〜数日後の継続観察、再発時は worker1 を NVMe へ退避が次の手 |
| 16 | RKE2 休眠 workloads の去就決定 (wordpress / app / ics) | memory `proxmox_rke2_cluster.md` Phase 2 | `kubectl scale --replicas=0` で定義は残しつつ停止中。再開しないなら `helm uninstall` / namespace 削除、再開するなら `replicas=1` で復帰 |
| 17 | Longhorn `default-replica-count=1` のリスク承知 | memory `proxmox_rke2_cluster.md` Phase 1 | worker1 disk 故障 = データロスト。重要 PVC (Harbor registry / Gitea repos / DB) は **個別に numberOfReplicas を引き上げる** か、Velero/MinIO バックアップを定期実行する運用に |
| 18 | SPCC SSD (store-sda) の worker1 ワークロード耐性監視 | memory `proxmox_rke2_etcd_fsync.md` | consumer 級なので将来詰まる可能性あり。Longhorn replica latency / etcd fsync 系メトリクスを継続観察 |

---

## 🟢 クリーンアップ・記録系 (低優先)

| # | 内容 | 出所 | 備考 |
|---|---|---|---|
| 9 | `{$PVE.TOKEN}` 旧マクロ削除 (`{$PVE.TOKEN.SECRET}` に統一) | 作業 doc 163行目 | 2026-05-16 削除試行で API エラー、未完了。host.update 経由なら可能な可能性 |
| 10 | Phase 4-B Nextcloud 監視「未対応」表記を「完了」に修正 | チェックリスト #7 | 2026-05-16 確認時点で template `Nextcloud by HTTP` リンク済 + items collection 正常稼働。表記が古いだけ |
| 11 | [Issue #6](https://github.com/shotayagami/homelab-infra/issues/6) 旧 files_external mount 3 件削除の経緯記録 | GitHub | 過去の作業記録の整理 |
| 12 | yagamin.net 内部 DNS 解決問題 (NXDOMAIN) 原因究明 | 作業 doc 217行目 | Technitium が `ntfy.yagamin.net` を NXDOMAIN 相当で返す。回避策 (`ntfy.home.yagamin.net` 利用) で運用中 |
| 13 | homelab-infra Public 化 (LICENSE / README / Secret Scanning) | メモリ `homelab_infra_public_release.md` | サニタイズは完了済 (2026-05-15)、残作業は本人判断待ち |

---

## 🔵 外部依存 (アップストリーム待ち)

| # | 内容 | 出所 | 備考 |
|---|---|---|---|
| 14 | [Issue #3](https://github.com/shotayagami/homelab-infra/issues/3) dns2 DoT/DoH 再有効化 | GitHub + チェックリスト #8 | Technitium 15.x の cert load 異常 (`BadImageFormatException`) 待ち。代替実装 (CoreDNS / PowerDNS) 移行も選択肢 |

---

## 関連リンク

- GitHub Issues: <https://github.com/shotayagami/homelab-infra/issues>
- 業務本番化チェックリスト本体: [proxmox-zabbix-monitoring.md](./proxmox-zabbix-monitoring.md) §7
- RKE2 関連の作業ログ: [proxmox-zabbix-monitoring.md](./proxmox-zabbix-monitoring.md) §8 (2026-05-16 の 3 エントリ)
- 関連メモリ:
  - `homelab_infra_repo.md` (検証環境という温度感)
  - `homelab_infra_public_release.md` (Public化保留中)
  - `proxmox_zabbix_monitoring.md` (Zabbix 構築サマリ)
  - `proxmox_zabbix_k8s_monitoring.md` (RKE2 監視構築)
  - `proxmox_rke2_cluster.md` (RKE2 クラスタ全容)
  - `proxmox_rke2_etcd_fsync.md` (cp1 etcd 安定化)

---

## 進め方の目安

- **🔴 1-5 を一括で**: 同じ rotation パターン (revoke → 再発行 → secret macro 更新) で 30 分前後。`read -rs` で silent 入力、`set +o history` で履歴回避を必ず使う
- **🟡 6 (firewall)** は段階的に。一気に有効化するとロックアウトのリスク
- **🟡 7 (backup 外部同期)** はスクリプト 1 本書けば cron で回せる。restic + S3 互換が現代的
- **🟡 15 (etcd 経過観察)** は Zabbix で `slow fdatasync` 系の頻度を眺める運用。再発兆候があれば worker1 も NVMe へ
- **🟡 16-18 (RKE2 運用判断)** は次回クラスタを触るタイミングで方針確定。休眠は無料ではない (定義 + PVC が残る)
- **🟢 9-10** は次回 Zabbix 触るタイミングで一緒に
- **🔵 14** は時々 Technitium changelog をチェックする運用で
