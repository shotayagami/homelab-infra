# Misskey yagamin.com 移設 — チャート引き渡しバンドル

- ソース commit: ics-corporate@fd9e5e8b
- チャート: misskey (appVersion 2026.5.0)
- 同梱:
  - misskey-*.tgz ... Helm チャート本体 (R2 objectStorage / Redis同梱 / Meili apiKey secret注入 対応)
  - yagamin-target-cluster.yaml ... 移行先用 values テンプレート (プレースホルダ入り)

## 受け入れ側の手順 (概要)
1. tgz を自 GitOps repo に vendoring、ArgoCD Application の source に設定
2. yagamin-target-cluster.yaml のプレースホルダを実値に置換:
   - objectStorage.endpoint の <account_id>
   - (apiKey は values に書かず secret 投入: MEILISEARCH_API_KEY)
3. secret (misskey-secret 相当) に投入: DB_PASSWORD / SETUP_PASSWORD /
   MEILISEARCH_API_KEY / OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY
4. misskey DB を locale UTF8 / en_US.UTF-8 / en_US.UTF-8 で作成
5. 空デプロイ疎通 → カットオーバー当日に pg_restore + CNAME 切替

詳細は別送の misskey-migration-reply2.md を参照。
