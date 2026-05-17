# 単一インスタンス + RWO PVC + 内蔵データ層 ワークロードの rollout デッドロック

最終更新: 2026-05-17

## 案内

Gitea で 2026-05-17 に観測した「rollout 中の LevelDB ロック競合によるデッドロック」と同じ罠が、本 cluster 内の **他のワークロードでも同じ条件で再発する可能性が高い**。原則として「単一ファイルロックを取る内蔵データ層 (SQLite, LevelDB, MongoDB の WT lock, MinIO のシングルノード state 等) を、RWO PVC 上に持つ Deployment / StatefulSet」が該当する。

該当ワークロードのオーナーは本ドキュメントの「影響評価」を読み、「対応方法」のいずれかを採用すること。

## 症状と発火条件

| 項目 | 内容 |
|---|---|
| 発火イベント | `kubectl rollout restart`、Helm upgrade、ConfigMap/Secret 更新による pod template hash 変化など、Deployment が新 RS を作るあらゆる契機 |
| 必要条件 | (1) Deployment strategy = `RollingUpdate`、(2) PVC accessMode = `ReadWriteOnce`、(3) 内蔵 DB / queue / state file (single-file lock) を `/data` 系ディレクトリに持つコンテナ |
| 症状 | 新 pod が起動 → init container 通過 → main container が DB を開こうとして `resource temporarily unavailable` (LevelDB)、`Failed to acquire lock` (SQLite WAL)、`Connection refused` (BoltDB) などで CrashLoopBackOff |
| 結果 | `maxUnavailable: 0` の場合は **rollout デッドロック** (旧 pod が新 pod ready 待ち、新 pod は旧 pod のロック解放待ち)。`maxUnavailable > 0` の場合は新 pod が落ちる間に旧 pod も間欠的に止まる ([crash flap]) |

## 影響評価 (2026-05-17 時点)

| Workload | データ層 | 戦略 | リスク | 推奨アクション |
|---|---|---|---|---|
| `gitea/gitea` | 旧: SQLite + LevelDB + memory / 現: 外部 PG + Redis | RollingUpdate | **解消済** | 既に外部化 ([Phase 1-3](https://github.com/shotayagami/homelab-infra/pull/29)、[#31](https://github.com/shotayagami/homelab-infra/pull/31)、[#32](https://github.com/shotayagami/homelab-infra/pull/32)) |
| `monitoring/prometheus-stack-grafana` | 内蔵 SQLite (`/var/lib/grafana/grafana.db`) | RollingUpdate | **高** | (A) `strategy.type: Recreate` に切替、または (B) 外部 PG/MySQL へ移行 |
| `databases/mongodb` | MongoDB WT engine (`/data/db`) | RollingUpdate (maxUnavailable: 25%) | **中** | `strategy.type: Recreate` に切替。replicas=1 の単一インスタンスなら Recreate が正解。将来クラスタ化するなら StatefulSet + ReplicaSet 構成へ |
| `velero/minio` | MinIO object storage state | RollingUpdate (maxUnavailable: 25%) | **中** | `strategy.type: Recreate` に切替。MinIO 公式も single-node は Recreate を推奨 |
| `harbor/harbor-jobservice` | append-only log files (`/var/log/jobs`) | RollingUpdate | 低 | 緊急の対応不要。再起動時にログが二重出力される可能性のみ |
| `harbor/harbor-registry` | Docker blob storage (`/storage`) | RollingUpdate | 低 | 緊急の対応不要。blob は per-file 命名で衝突しない |
| `ics/backend` | Django media files (`/app/media`) | RollingUpdate (replicas=2) | 低 | 既に並走前提。DB は外部 (pg-db) で構造的に問題なし |
| `wordpress/my-wordpress` | wp-content files のみ (DB は外部 PG) | RollingUpdate | 低 | DB が外部のため緊急対応不要。wp-content の同時書き込み (画像アップロード等) は短時間 rollout 中なら確率的に大きな問題にならない |

未調査のワークロード (Deployment / StatefulSet 追加時) は本ドキュメントの基準で必ず評価すること。

## 対応方法

### 案 A: `strategy.type: Recreate` への切替 (最小修正)

新 pod が立ち上がる前に旧 pod を完全に停止することで、PVC + 内蔵 lock の競合を構造的に避ける。

メリット:
- 5 行程度の patch で済む
- データ移行不要
- 確実

デメリット:
- 切替時に数十秒〜1 分のサービス断が発生する (Recreate の本質)
- ロールアウトのたびに毎回発生

実装例 (Helm chart 経由):

```yaml
# values.yaml
strategy:
  type: Recreate
  rollingUpdate: null   # チャート default の rollingUpdate ブロックを消す
```

実装例 (kubectl patch、Helm 未使用の場合):

```bash
kubectl -n <ns> patch deploy <name> --type=merge -p '{
  "spec": {
    "strategy": {
      "type": "Recreate",
      "rollingUpdate": null
    }
  }
}'
```

### 案 B: データ層を pod 外に出す (恒久対策)

DB / queue / cache を pod 外 (外部 PG / Redis / Valkey) に移し、内蔵データ層を持たない設計にすることで、RollingUpdate を恒久的に許容できるようにする。

メリット:
- ゼロダウンタイム rollout が可能
- データ層とアプリ層を独立にスケール
- バックアップ・モニタリングが標準化される

デメリット:
- 移行工数大 (DB 移行手順の設計、データ整合性の検証、サービス断を伴うカットオーバー)
- 運用すべきコンポーネントが増える

実装パターン: Gitea で採用した二段階手法を流用 (詳細は [gitea/README.md の「SQLite → PostgreSQL 移行ノウハウ」](../gitea/README.md))

1. アプリ専用の PG / Redis StatefulSet を新規に立てる ([gitea/k8s/base/](../gitea/k8s/base/) と同パターン)
2. アプリを `replicas=0` に
3. 外部 PG を完全に空に
4. アプリを `replicas=1` で起動 → アプリの ORM (xorm, Django ORM, etc) に正規スキーマを作らせる
5. アプリを `replicas=0` に
6. pgloader (sqlite source の場合) を `WITH data only, truncate;` で実行してデータコピー
7. アプリを `replicas=1` に戻して動作確認

pgloader を使うときの典型的な落とし穴は [gitea/README.md](../gitea/README.md) を参照 (sqlite_autoindex の UNIQUE constraint 化と xorm DROP INDEX の衝突を回避するための data-only 二段階手法)。

### 案 A と案 B の使い分け

| 観点 | 案 A (Recreate) | 案 B (外部化) |
|---|---|---|
| 実装工数 | 数分 | 半日〜数日 |
| サービス断 (毎ロールアウト) | 数十秒〜1 分 | ゼロ (理想) |
| サービス断 (移行時) | なし | 数分〜10 分 |
| 運用負荷 | 不変 | DB / Redis の運用が増える |
| 検証環境向き | **◎** | △ (オーバースペック) |
| 本番向き | △ (ロールアウトの頻度次第) | **◎** |

ホームラボの検証ワークロードでは原則 **案 A (Recreate) を採用**、Gitea のように「データ層を持ったまま rollout する頻度が高い」ものに限り案 B を検討する、という方針が現実的。

## 優先度別の推奨対応

| 優先度 | 対象 | 推奨案 |
|---|---|---|
| 1 (即時) | `monitoring/prometheus-stack-grafana` | 案 A (`strategy.type: Recreate`)。`kube-prometheus-stack` chart の `grafana.deploymentStrategy.type: Recreate` で values 化可能 |
| 2 (近日) | `databases/mongodb` | 案 A。ホームラボでは単一インスタンス確定なので Recreate で問題なし |
| 2 (近日) | `velero/minio` | 案 A |
| 3 (任意) | Harbor jobservice / registry, ICS backend, WordPress | 経過観察。新たな書き込み競合が観測されたら案 A |

## 関連ドキュメント

- [gitea/README.md](../gitea/README.md) — Gitea で採用した案 A → 案 B の移行手順
- [docs/rke2-lessons-learned.md](rke2-lessons-learned.md) — クラスタ運用上の他のハマりポイント
- 個別 PR: [#29 (Phase 1)](https://github.com/shotayagami/homelab-infra/pull/29) / [#31 (Phase 2)](https://github.com/shotayagami/homelab-infra/pull/31) / [#32 (Phase 3)](https://github.com/shotayagami/homelab-infra/pull/32)
