# 残タスク一覧

**最終更新**: 2026-05-16 (PVE 旧 Claude rescue 由来タスクを追加)
**前回棚卸し時に完了済**: Issue #5 (Nextcloud zabbix-monitor app password rotation)、Phase 4-D RKE2 監視、cp1 etcd fsync 解消、pg-db 整備 (myappdb drop / Zabbix 登録 / step-ca 適用、PR #16)

GitHub Issues、`docs/proxmox-zabbix-monitoring.md` の業務本番化チェックリスト、ローカル運用者の Claude memory (`~/.claude/projects/<project-cwd>/memory/`) の宿題記述を横断的に集約したもの。優先度は当面の運用影響と着手コストで仮置き。

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
| 19 | **Cloudflare API token (DNS/cert-manager 用) ローテ** | PVE 旧 Claude rescue (memory `pve_rescue_2026_05_16.md`) | CF dashboard → My Profile → API Tokens で旧 token revoke + 再作成、cert-manager の `Secret cloudflare-api-token-secret` を更新。**外部公開系なので最優先** |
| 20 | **Cloudflare API token (Access 用) ローテ** | 同上 | Zero Trust ダッシュボードの API token 再発行、関連スクリプトの `.env` を更新 |
| 21 | Harbor admin パスワードローテ | 同上 | Harbor UI → Administration → Users → admin で変更、`imagePullSecret` 系の SealedSecret を再生成 |
| 22 | Gitea admin パスワードローテ | 同上 | Gitea UI Profile で変更、関連 SealedSecret 更新 |
| 23 | ArgoCD admin パスワードローテ | 同上 | `argocd account update-password` で変更、CLI `~/.argocd/config` 等も更新 |
| 24 | step-ca admin provisioner パスワードローテ | 同上 | step CA admin password を `step ca provisioner update admin --password-file=...` で変更、cert-manager ClusterIssuer の Secret 更新 |
| 25 | DB credential 一斉ローテ (Redis / MariaDB root / MongoDB root / pg-db `ics_user` / `postgres`) | 同上 | K8s Secret + アプリ接続文字列 + pg-db 側 `ALTER USER` を同期。**pg-db `app_user` は drop 済** ([docs/pg-db-postgresql.md](pg-db-postgresql.md) 参照) |
| 26 | アプリ admin credential ローテ (WordPress / Nextcloud / OMV root / ICS Admin Portal) | 同上 | 各アプリ UI 経由で変更 + SealedSecret 更新 (Bitnami WordPress は DB_PASSWORD が wp-config.php に焼き付くので手順注意、ローカル運用者 memory `k8s_lessons_learned.md` の WordPress 節参照) |

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
| 14 | ~~[Issue #3](https://github.com/shotayagami/homelab-infra/issues/3) dns2 DoT/DoH 再有効化~~ | GitHub + チェックリスト #8 | **2026-05-19 完了** ([internal-dns.md §6](internal-dns.md#6-dns2-の-dotdoh-2026-05-19-復旧))。真因は Technitium バグではなく `dns.config` バイナリの cert path 末尾に literal タブ混入で `File.Exists` が false 返却していたこと。binary patch (1 byte 削除) で復旧、Zabbix item/trigger も再有効化済 |

---

## 📚 PVE 旧 Claude rescue 由来 (2026-05-16)

PVE host (192.168.11.11) の `/root/.claude/` を `/home/shotayagami/.claude-pve-rescue/claude-pve-root-2026-05-16.tar.gz` (3.5MB / 370 ファイル) に退避完了。本人 admin-vm 移行で孤立していた root 時代の作業履歴・memory・会話履歴 (76 セッション、2026-02-07〜03-30 期間) を回収。

新 memory への構造化済 (homelab-infra 外、ローカル運用者の Claude memory `~/.claude/projects/<project-cwd>/memory/`):

| 新 memory | 内容 |
|---|---|
| `pve_rescue_2026_05_16.md` | 救出経緯と退避物の所在 (reference 型) |
| `k8s_lessons_learned.md` | cert-manager / ArgoCD / Bitnami / Django / Harbor / Longhorn の過去ハマり 25+ 項目 |
| `rke2_workloads_catalog.md` | ICS Corporate Site / Admin Portal / WordPress / Gitea / Harbor / ArgoCD の構成カタログ |
| `rke2_backup_strategy.md` | per-DB CronJob + Longhorn snapshot + Velero + etcd の多層バックアップ |
| `proxmox_network_watchdog.md` | PVE host の自律復旧スクリプト 2 本 (network-watchdog / vm-health-monitor) |

### 重要な発見

- **`icsdb` の真の consumer が判明** — RKE2 `ics` namespace の **Django backend (ICS Corporate Site)**、PgBouncer 経由で pg-db に接続。今日 `proxmox-zabbix-monitoring.md` で観測した「30 秒間隔の `ics_user@icsdb` 接続」と完全に一致

### 由来する宿題

- credential rotation 8 件: 上記 #19〜#26 (🔴 セキュリティ系セクション)
- 旧 root memory に書かれていた構成情報の現環境差分確認 — `kubectl get all -A` / `helm list -A` で現状と照合する作業 (時間があるとき)
- **退避 tarball に含まれる `.claude/.credentials.json` (Claude Code OAuth) は機微情報として扱う** — refresh token が残存している可能性があるので「失効済」と楽観視しないこと。tarball 自体を mode 600 で保管し、念のため Anthropic console / `claude` CLI 側で該当 session を sign out した上で保管 (または不要なら tarball 展開後に `.credentials.json` だけ shred で削除) する判断を後日入れる

### 作業ルール

- 退避 tarball は **絶対 git にコミットしない**。`/home/shotayagami/.claude-pve-rescue/` 配下に mode 600 (推奨: ディレクトリも 700) で保管し、必要に応じてさらに暗号化ストレージへ
- PVE host の `/root/.claude` 自体は当面残す (read-only で再アクセス可能、将来 host 作り直し時に自然消滅)

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
- **🔴 19-20 (Cloudflare token)** は最優先で。外部公開系の credential なので漏洩リスクが大きい
- **🔴 21-26** は K8s/RKE2 を本格的に触るタイミングで一斉実施。各アプリ Helm/SealedSecret の更新作業を伴う
- **🟡 6 (firewall)** は段階的に。一気に有効化するとロックアウトのリスク
- **🟡 7 (backup 外部同期)** はスクリプト 1 本書けば cron で回せる。restic + S3 互換が現代的
- **🟡 15 (etcd 経過観察)** は Zabbix で `slow fdatasync` 系の頻度を眺める運用。再発兆候があれば worker1 も NVMe へ
- **🟡 16-18 (RKE2 運用判断)** は次回クラスタを触るタイミングで方針確定。休眠は無料ではない (定義 + PVC が残る)
- **🟢 9-10** は次回 Zabbix 触るタイミングで一緒に
- **🔵 14** は時々 Technitium changelog をチェックする運用で
- **📚 PVE rescue** はメモリ整備済、当面は構造化された memory を参照する運用で OK。tarball 直読みは archeology が必要なときだけ
