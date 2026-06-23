# RKE2 上の主要ワークロード カタログ

[docs/rke2-cluster.md](rke2-cluster.md) がクラスタ全体のインフラ層 (CNI, ストレージ, GitOps, 監視, セキュリティの 23 Helm release) を扱うのに対し、本書は **個別アプリケーションの構造** — Repo / 公開 URL / 構成 / 依存 DB / credential 管理 / 既知の注意点 — のカタログ。

> ⚠ **現状ステータス**: 多くのアプリは 2026-05-15 Phase 2 で **`kubectl scale --replicas=0` の休眠中** ([docs/rke2-cluster.md §4](rke2-cluster.md)) 。本書は構成情報の保存先、再開時のリファレンス。

---

## 1. ICS Corporate Site

`icsdb` (PostgreSQL on LXC 106、[docs/pg-db-postgresql.md](pg-db-postgresql.md)) の真の consumer。

| 項目 | 値 |
|---|---|
| Repo | `gitea.home.yagamin.net/gitea/ics-corporate` |
| 内部 URL | `https://ics.home.yagamin.net` |
| 外部 URL | `https://ics.yagamin.net` (Cloudflare Tunnel) |
| K8s namespace | `ics` |
| デプロイ管理 | ArgoCD auto-sync (`k8s/overlays/production/`) |
| Frontend | Next.js 14 |
| Backend | Django 5 + DRF + JWT 認証 + django_prometheus |
| Image | `harbor.home.yagamin.net/ics/{frontend,backend}:latest` |
| RDB | PostgreSQL `icsdb` ([docs/pg-db-postgresql.md](pg-db-postgresql.md))、経路 `Frontend → Backend → PgBouncer → pg-db (LXC 106)` |
| PgBouncer | `harbor.home.yagamin.net/ics/pgbouncer:latest` (edoburu/pgbouncer ベース)、port 6432、`AUTH_TYPE=scram-sha-256` 必須 ([docs/rke2-lessons-learned.md](rke2-lessons-learned.md)) |
| Document DB | MongoDB `mongodb.databases.svc.cluster.local:27017`、DB `ics_corporate` |
| Collections | `access_logs`, `django_sessions`, `cms_pages`, `cms_blocks` |
| 主要 app | analytics (middleware + API)、cms (CRUD + public/admin API)、session backend |
| メトリクス | `/metrics` (django_prometheus を root mount) |
| Grafana | ConfigMap `ics-corporate-dashboard` (`monitoring` ns) |

### 注意点

- Backend の `ALLOWED_HOSTS` に Pod CIDR or `*` を含めること ([docs/rke2-lessons-learned.md](rke2-lessons-learned.md) §Django)
- `SECURE_SSL_REDIRECT=False` (TLS は Ingress 終端のため)

---

## 2. ICS Admin Portal

ICS Corporate と並列の管理 UI。AdminUser モデルで独立した認証系を持つ。

| 項目 | 値 |
|---|---|
| 内部 URL | `https://admin.home.yagamin.net` |
| 外部 URL | `https://admin.yagamin.net` (Cloudflare Tunnel + **Cloudflare Access** 多要素保護) |
| 認証 | 独立 JWT (`AdminUser` モデル + `ADMIN_JWT_SECRET_KEY`) |
| Image | `harbor.home.yagamin.net/ics/admin-portal:latest` |
| credential | `admin` user — 旧 PW は要 rotation 確認 ([docs/remaining-tasks.md](remaining-tasks.md)) |

### 認証実装の注意

- `AdminUser` はカスタムユーザーモデルで `is_authenticated` 属性を持たない場合がある
  - 安全な参照: `getattr(request.user, 'is_authenticated', False)` ([docs/rke2-lessons-learned.md](rke2-lessons-learned.md) §Django)
- Cloudflare Access の email 認証と Backend の JWT がどちらも有効。Access 通過後に JWT 検証する 2 段構え

---

## 3. WordPress

Bitnami Helm chart ベース。CMS + 一部静的サイト用途。

| 項目 | 値 |
|---|---|
| Repo | `gitea.home.yagamin.net/gitea/wordpress` |
| 内部 URL | `https://wordpress.home.yagamin.net` |
| 外部 URL | `https://wordpress.yagamin.net` (Cloudflare Tunnel) |
| Stack | Bitnami WordPress (Helm chart) + MariaDB |
| K8s namespace | `wordpress` |
| デプロイ管理 | **Helm 直接管理 (ArgoCD 管理外)** |
| MariaDB | `mariadb.databases.svc.cluster.local`、user `wordpress` / DB `wordpress` |
| SealedSecrets | `my-wordpress`, `my-wordpress-externaldb` (Gitea `k8s/sealed-secrets/`) |
| Deployment 戦略 | **Recreate** (RWO PVC 対応のため Rolling 不可) |
| 外部公開 | `httpHostHeader` リライト**なし** (Cookie 経路で wp-admin が壊れる) |

### Bitnami WordPress の罠 (重要)

- **DB_PASSWORD は `wp-config.php` に焼き付き、PVC に永続化される**。Secret 値を変えても再起動だけでは反映されない
- パスワード変更の正規手順:
  1. MariaDB 側で `ALTER USER 'wordpress'@'%' IDENTIFIED BY '...'`
  2. Pod を停止 → 一時 Pod に PVC を mount → `wp-config.php` の `DB_PASSWORD` を直接編集
  3. Pod 起動
  4. WP-CLI で WordPress admin パスワードも別途変更
- `WP_HOME` / `WP_SITEURL` は `$_SERVER['HTTP_HOST']` から動的生成されるため、外部公開ホスト名を Ingress に追加する形にする (httpHostHeader リライトしない)
- 詳細は [docs/rke2-lessons-learned.md](rke2-lessons-learned.md) §Bitnami WordPress 参照

---

## 4. Gitea + Act Runner

クラスタの **GitOps の source of truth**。ArgoCD はここを reference している。

| 項目 | 値 |
|---|---|
| 内部 URL | `https://gitea.home.yagamin.net` (LAN / WARP) |
| 外部 URL | `https://gitea.yagamin.net` (Cloudflare Tunnel + CF Access、studio policy 踏襲) |
| TLS | Let's Encrypt (DNS-01)。ingress に両ホストの cert (`gitea-home-yagamin-net-tls` / `gitea-yagamin-net-tls`) |
| 主要 Repo | `ics-corporate`、`wordpress`、`homelab-infra` (mirror)、その他個人 repo |

> **外部公開の構成 (2026-06-16):** `gitea.yagamin.net` は tunnel ingress (`cloudflared/tunnel-config.yaml`、Host 保持・noTLSVerify) → RKE2 ingress-nginx の第2ホストルール (`gitea/values.yaml`) → `gitea-http:3000` という経路。CF Access app/policy は `scripts/cloudflared-ensure-access.sh` で studio.yagamin.net を踏襲。
>
> **ROOT_URL は内部のまま** (`gitea.home.yagamin.net`)。Gitea は ROOT_URL を1つしか持てず、clone URL や絶対リンクはこの内部ホスト名で描画される。よって `gitea.yagamin.net` は **CF Access 下での閲覧 / admin 用**であり、外部からの匿名 git-over-HTTP clone はそのままでは成立しない (git 操作を外部公開する場合は別途 CF Access service token + credential helper が必要)。

### Act Runner

| 項目 | 値 |
|---|---|
| 配置 | **PVE host 上**、K8s 外 |
| パス | `/etc/act_runner/` |
| systemd unit | `act_runner.service` |
| Runner ラベル | `ubuntu-latest` (Docker mode) |
| 登録方式 | **repo 固有トークン**で repo-level 登録 (instance-level トークンは不可、[docs/rke2-lessons-learned.md](rke2-lessons-learned.md)) |
| 内部 DNS 解決 | `container.options: --add-host=gitea.home.yagamin.net:192.168.11.80` を runner 設定に追加 |
| credential helper | `store --file=/tmp/.git-credentials` |

### Gitea デプロイ初回の罠

- Helm 初回デプロイ後、`must-change-password` フラグが ON になっているとログインできない
- 解除: `gitea admin user must-change-password --all --unset` を Pod 内で実行
- Repo Secrets の例: `HARBOR_PASSWORD` ほか

---

## 5. Harbor

コンテナレジストリ。ArgoCD/Gitea Actions ともにここから image を pull する。

| 項目 | 値 |
|---|---|
| 内部 URL | `https://harbor.home.yagamin.net` |
| 外部 URL | `https://harbor.yagamin.net` (Cloudflare Access 保護) |
| TLS | Let's Encrypt |
| ストレージ | Longhorn PVC 20 GiB (registry)、別途 PostgreSQL / Redis を Bitnami chart で持つ |
| credential | `admin` user — 要 rotation ([docs/remaining-tasks.md](remaining-tasks.md)) |

### imagePullSecrets 運用

- アプリ namespace ごとに `kubectl create secret docker-registry harbor-cred --docker-server=harbor.home.yagamin.net ...` で作成
- Deployment spec の `imagePullSecrets` に追加。**新規 Deployment 作成時は既存 (backend など) の `imagePullSecrets` を必ずコピー** (漏れがちな運用ミス)

---

## 6. ArgoCD

GitOps エンジン。Gitea repo を source of truth として、`ics`、`monitoring` 等の namespace を sync する。

| 項目 | 値 |
|---|---|
| 内部 URL | `https://argocd.home.yagamin.net` |
| 外部 URL | `https://argocd.yagamin.net` (Cloudflare Access 保護) |
| Sync 対象 | `ics-corporate` / `monitoring` (kube-prometheus-stack) / sealed-secrets / Kyverno など |

### ArgoCD の運用上の罠

- **K8s Secret 上書き問題**: ArgoCD auto-sync が手動編集の Secret を上書きする → Secret 変更は **必ず Git 経由** で。`kubectl edit secret ...` はすぐ revert される
- **repoURL 変更時の残骸**: Application status の `history` / `operationState` に古い URL が残る → `kubectl replace` で修正 + ArgoCD Redis の `FLUSHALL` で完全反映

---

## 7. Misskey (yagamin.com) — 移設土台

別 k8s 環境からの ActivityPub 連合 SNS `yagamin.com` 移設プロジェクト。manifest は本リポジトリ
[misskey/](../misskey/) で管理。本番のレプリカは **1 固定** (HPA 不使用)、アップロードファイルは
Longhorn RWX ではなく **Cloudflare R2 (S3 互換)** に保存する方針。

現状はチャート非依存の **依存スタック (土台) のみ**を先行構築する段階。

| 項目 | 値 |
|---|---|
| 外部 URL | `https://yagamin.com` (移設後も不変、連合維持) |
| K8s namespace | `misskey` |
| デプロイ管理 | Kustomize + ArgoCD Application `misskey-infra` (source = GitHub homelab-infra、循環依存回避) |
| Database | **PostgreSQL 18 (Debian)** `misskey-postgres` (StatefulSet, Longhorn RWO 10Gi)。移行元 18.3 とメジャー一致、locale `en_US.UTF-8` 揃え (alpine 不可) |
| 全文検索 | **Meilisearch v1.41.0** (StatefulSet, Longhorn RWO 5Gi、インデックスは PG から再構築) |
| SealedSecrets | `misskey-db` (DB 認証)、`misskey-meilisearch` (master key) |
| 公開経路 (予定) | `yagamin.com` 専用 Cloudflare Tunnel を新設し CNAME 切替 (カットオーバー当日) |

### 後続フェーズ (受領待ち)

- **Misskey 本体**: 移行元 Helm chart (R2/NetworkPolicy 対応版) を ArgoCD で参照。`db.host` / `meilisearch.host` を本土台の Service に差し替え。受け渡しは tarball vendoring
- **Redis**: 移行元チャートに**同梱** (`misskey-redis`、揮発)。本土台側の用意は不要 (2026-06-23 確定)
- **R2 / 内部 TLS**: バケット `misskey-yagamin` + `media.yagamin.com`、ingress `misskey-tls` は cert-manager 発行。`misskey-secret` に R2 キー + Meili apiKey を SealedSecret 化

詳細は [misskey/README.md](../misskey/README.md) を一次資料とする。

---

## 8. ネットワーク・公開経路

### Ingress / cert-manager

- Ingress controller: nginx-ingress、LoadBalancer IP = `192.168.11.80` (MetalLB pool)
- cert-manager Issuer 2 種:
  - `step-ca-issuer` (内部 ACME、[docs/internal-tls.md](internal-tls.md))
  - `letsencrypt-prod` (外部 `*.yagamin.net`、cloudflare DNS-01)

### Cloudflare Access 適用ドメイン (2026-03 旧カタログ、要 CF dashboard 再確認)

外部公開のうち管理 UI 系:
- `admin.yagamin.net`、`harbor.yagamin.net`、`argocd.yagamin.net`、`gitea.yagamin.net`
- `grafana.yagamin.net`、`prometheus.yagamin.net`、`app.yagamin.net`

許可 email domain: `circle-ics.com`、`yagamin.com`、`nekomin.jp`、`yagamin.net`。

### Cloudflare Tunnel の host rewrite 注意

- **使う**: 単純な reverse proxy 用途で、内部 FQDN と外部 FQDN が違う場合 (例: `ics.yagamin.net` → `ics.home.yagamin.net`)
- **使うな**: Cookie ベース認証アプリ (Grafana、WordPress)。`httpHostHeader` 書き換えで Cookie domain 不一致 → セッション失敗、Grafana 全ダッシュボード "No data" / WordPress 管理画面ループ
- 詳細は [docs/rke2-lessons-learned.md](rke2-lessons-learned.md) §Cloudflare 参照

---

## 関連

- [docs/rke2-cluster.md](rke2-cluster.md) — クラスタインフラ層 (CNI / Longhorn / ArgoCD 等のシステム)
- [docs/rke2-lessons-learned.md](rke2-lessons-learned.md) — Bitnami / Django / ArgoCD / Cloudflare のハマりポイント詳細
- [docs/pg-db-postgresql.md](pg-db-postgresql.md) — `icsdb` (ICS Corporate の RDB) 構成
- [docs/backup-strategy.md](backup-strategy.md) — 各 DB / Volume / Namespace のバックアップ層
- [docs/remaining-tasks.md](remaining-tasks.md) — credential rotation 一覧
