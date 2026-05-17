# Gitea (RKE2)

検証用 Gitea インスタンスの Helm values と運用手順を本ディレクトリで管理する。

## 構成概要

| 項目 | 値 |
|---|---|
| Helm chart | `oci://docker.gitea.com/charts/gitea` version `12.5.0` |
| Namespace | `gitea` |
| Release 名 | `gitea` |
| 永続化 | Longhorn RWO PVC `gitea-shared-storage` (10Gi) |
| DB / cache / queue / session | すべて単一 pod 内 (sqlite3 / memory / leveldb / memory) |
| Ingress | `gitea.home.yagamin.net` (cert-manager + Let's Encrypt) |
| Deployment 戦略 | `Recreate` (理由は下記) |

## なぜ `strategy.type: Recreate` 必須か

Gitea は永続データの一部 (LevelDB キュー `/data/queues/common`) を **PVC 上の単一ファイル** として保持する。チャートのデフォルト `RollingUpdate / maxSurge: 100% / maxUnavailable: 0` を使うと、rollout 中の数十秒間 新旧 pod が同じ RWO PVC に同時マウントされ、新 pod が LevelDB ロックを取得できず `unable to lock level db ... resource temporarily unavailable` で CrashLoopBackOff となり、`maxUnavailable: 0` のため旧 pod が排除されず rollout が永久にデッドロックする。

この構造的制約は **DB / queue / session / cache をすべて pod 外に出す** ことでしか解消できない。詳細な根拠は [docs/k8s-lessons-learned.md](../docs/rke2-lessons-learned.md) の Gitea セクション参照。

## 管理方針

- admin user 認証情報は本 values.yaml では扱わない (`gitea.admin.*` を空文字)。チャートの init container 条件式によって admin user 作成/更新ロジックがスキップされ、既存の admin user が保護される
- admin パスワードの変更は Gitea Web UI または `gitea admin user change-password` で行う
- LDAP / OAuth 等の認証統合を将来追加する場合は existingSecret 経由とし、Secret は cluster 上に kubectl で別途作成する (本リポジトリには平文を置かない)

## デプロイ / アップグレード手順

前提: `~/bin/helm` (v3.16+) と `kubectl` 設定済みの admin-vm から実行する。

```bash
# 適用前に dry-run で差分を確認する
helm -n gitea diff upgrade gitea oci://docker.gitea.com/charts/gitea \
  --version 12.5.0 \
  -f gitea/values.yaml

# 実適用 (--atomic で失敗時自動ロールバック)
helm -n gitea upgrade gitea oci://docker.gitea.com/charts/gitea \
  --version 12.5.0 \
  -f gitea/values.yaml \
  --atomic --timeout 5m
```

`helm diff` プラグインが無い場合は `helm template -f gitea/values.yaml ...` で manifest をレンダリングし、`helm get manifest gitea -n gitea` の出力と diff する。

## ロールバック

```bash
helm -n gitea history gitea
helm -n gitea rollback gitea <REVISION>
```

## 将来計画 (Phase 2)

PostgreSQL (lxc-pg-db 上の `gitea` データベース) + Valkey (Redis 互換, queue / cache / session 用) へバックエンドを移行する。これが完了すれば `strategy.type: RollingUpdate` への復帰、ゼロダウンタイムローリングデプロイが可能になる。
