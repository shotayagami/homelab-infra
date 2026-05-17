# Gitea (RKE2)

検証用 Gitea インスタンスの Helm values, ステートフル依存 (PostgreSQL / Redis) のマニフェスト, ArgoCD Application を本ディレクトリで管理する。

## 構成概要

| 項目 | 値 |
|---|---|
| Helm chart | `oci://docker.gitea.com/charts/gitea` version `12.5.0` |
| Namespace | `gitea` |
| Release 名 | `gitea` |
| Gitea 永続化 | Longhorn RWO PVC `gitea-shared-storage` (10Gi、リポジトリ data / 添付ファイル / SSH key 等) |
| **Database** | **PostgreSQL 17 on `gitea-postgres`** (StatefulSet, 5Gi PVC) — 本ディレクトリ `k8s/base/postgres.yaml` |
| **Queue / Cache / Session** | **Redis 7 on `gitea-redis`** (StatefulSet, 1Gi PVC) — 本ディレクトリ `k8s/base/redis.yaml` |
| Ingress | `gitea.home.yagamin.net` (cert-manager + Let's Encrypt) |
| Deployment 戦略 | `RollingUpdate` (PG/Redis 化により LevelDB ロック制約が消失したため復帰) |
| 管理 | Helm chart + ArgoCD Application `gitea-infra` (依存スタック専用) |

## ディレクトリ

```
gitea/
├── values.yaml                Helm values (gitea chart)
├── README.md                  本ファイル
└── k8s/
    ├── base/                  Kustomize base
    │   ├── postgres.yaml
    │   ├── redis.yaml
    │   └── kustomization.yaml
    ├── overlays/production/   Kustomize overlay (namespace 焼き込み)
    │   └── kustomization.yaml
    └── argocd/
        └── application.yaml   ArgoCD Application (gitea-infra)
```

## なぜ依存スタックを分けて持つか

Gitea 本体は Helm chart で運用するが、PostgreSQL / Redis は **chart 内蔵の subchart (Bitnami) を使わず、本ディレクトリの raw manifest** で管理している。

- Gitea chart の `postgresql.enabled: true` は Bitnami subchart 経由となり、依存関係の継承や values の競合が起きやすい
- 同 cluster 内の `crossing-postgres` と同一パターン (StatefulSet + Headless Service + Secret + Longhorn RWO PVC) を採用し、運用の一貫性を優先した

## なぜ ArgoCD のソースが GitHub (homelab-infra) なのか

cluster 内の他の ArgoCD Application は internal Gitea (`gitea.home.yagamin.net`) をソースに使っているが、**gitea 依存スタック (`gitea-postgres` / `gitea-redis`) だけは GitHub の homelab-infra をソースに使う**。

理由: 内部 Gitea 自身をソースに使うと **循環依存** になる。Gitea がダウンしている時に Gitea を立て直すための manifests が Gitea にしか無い、という詰みパターンを避けるためにあえて切り離している。

## 必要な Secret

values.yaml と StatefulSet が以下の Secret を参照する。Secret は ArgoCD で管理しない (kubectl で out-of-band 作成)。

| Secret | キー | 用途 |
|---|---|---|
| `gitea-db` | `DB_NAME`, `DB_USER`, `DB_PASSWORD` | gitea-postgres の初期化と Gitea からの接続 |
| `gitea-redis` | `REDIS_PASSWORD` | gitea-redis の `requirepass` と Gitea からの接続 |

将来的に SealedSecret 化することは未対応の宿題 (本リポジトリは Public のため平文 Secret は git 管理外)。

```bash
# 新規 cluster での Bootstrap (パスワードはランダム 24-byte hex)
kubectl -n gitea create secret generic gitea-db \
  --from-literal=DB_NAME=gitea \
  --from-literal=DB_USER=gitea \
  --from-literal=DB_PASSWORD="$(openssl rand -hex 24)"
kubectl -n gitea create secret generic gitea-redis \
  --from-literal=REDIS_PASSWORD="$(openssl rand -hex 24)"
```

admin 認証情報は values.yaml の `gitea.admin.*` を空文字にすることでチャートの init container を skip させ、既存の Gitea 内部 admin user は手付かずにする (admin 変更は Gitea Web UI または `gitea admin user change-password` で行う)。

## デプロイ / アップグレード手順

前提: `~/bin/helm` (v3.16+) と `kubectl` 設定済みの admin-vm から実行する。

```bash
# 1. 依存スタック (gitea-postgres + gitea-redis) の apply
kubectl apply -k gitea/k8s/overlays/production

# 2. ArgoCD Application (初回のみ、依存スタックの自動同期化)
kubectl apply -f gitea/k8s/argocd/application.yaml

# 3. Gitea 本体 (Helm)
helm -n gitea upgrade --install gitea oci://docker.gitea.com/charts/gitea \
  --version 12.5.0 \
  -f gitea/values.yaml \
  --atomic --timeout 6m
```

### ロールバック

Gitea (Helm) 側:

```bash
helm -n gitea history gitea
helm -n gitea rollback gitea <REVISION>
```

依存スタック (StatefulSet) 側はデータが PVC にあるため、`kubectl delete` で消しても再 apply で復帰する。データ破損時は Longhorn snapshot から PVC を復元する。

## SQLite → PostgreSQL 移行ノウハウ (2026-05-17 実施)

移行手法 (案 A): **Gitea 自身に空 PG でスキーマを作らせ、pgloader を data-only モードで使う**。

理由: pgloader は SQLite の `sqlite_autoindex_*` を PG の UNIQUE constraint として再現するため、xorm migrate と PRIMARY KEY が衝突して rollout がデッドロックする (`cannot drop index ... because constraint requires it`)。空 PG で Gitea にスキーマを作らせ、データだけ pgloader で流し込めばこの衝突を回避できる。

切替手順:

1. `gitea dump` で最新の SQLite を取得 (`data/gitea.db` を `dimitri/pgloader` pod にコピーする用)
2. Longhorn snapshot を取得 (PVC `gitea-shared-storage` 対応)
3. Gitea Deployment を `replicas=0` でスケールダウン → サービス断開始
4. gitea-postgres に対し `DROP DATABASE gitea; CREATE DATABASE gitea ... LC_COLLATE 'C' LC_CTYPE 'C' ENCODING 'UTF8' TEMPLATE template0;`
5. Gitea Deployment を `replicas=1` で再起動 → xorm migrate が空 PG にスキーマ作成 → ready を確認
6. `replicas=0` で再度停止 (Gitea の動的書き込みと pgloader の COPY が衝突しないため)
7. pgloader pod を起動、SQLite ファイルをコピー、`WITH data only, truncate;` で実行
8. `replicas=1` に戻して Gitea を起動 → HTTP 疎通 / API / 内部ログ確認

実測サービス断時間: 約 5 分 8 秒。

### pgloader 設定の落とし穴

- `WITH include drop, create tables, create indexes` (default) は **使えない**。SQLite の `sqlite_autoindex_*` が PG の UNIQUE constraint として複製され、xorm の DROP INDEX が constraint violation で失敗する
- `no create indexes` 構文は SQLite source では受け付けられない
- 正解は **`WITH data only, truncate;`** + 事前に Gitea に xorm でスキーマを作らせる二段階方式
- type mismatch warning (`text` vs `varchar`, `bigint` vs `boolean`) は data only モードでは pgloader が target 型に合わせて変換するため無視して OK

## 将来計画

- Secret の SealedSecret 化 (現状は kubectl で out-of-band 管理)
- 失敗時の自動 failover (replica) — 検証環境としては現状 1 replica で十分
- Redis を Valkey ベースに切り替える (Redis ライセンス変更を踏まえて)
