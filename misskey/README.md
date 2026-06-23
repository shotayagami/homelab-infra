# Misskey (yagamin.com) — 移設先 (受け入れ側)

別 k8s 環境からの ActivityPub 連合 SNS `yagamin.com` を本 RKE2 クラスタへ移設する一式。

- **土台スタック** (`k8s/`): 専用 PostgreSQL 18 + Meilisearch + 単一 SealedSecret + 補助 NetworkPolicy
- **Misskey 本体** (`chart/` + `values/`): 移行元から受領した Helm チャートを vendoring (ics-corporate@fd9e5e8b)

レプリカは **1 固定** (HPA 無効)、アップロードは **Cloudflare R2** (RWX PVC 不要)。

## 構成概要

| 項目 | 値 |
|---|---|
| Namespace | `misskey` |
| Database | **PostgreSQL 18 (Debian)** `misskey-postgres` — locale `en_US.UTF-8` で移行元と一致 (`k8s/base/postgres.yaml`) |
| 全文検索 | **Meilisearch v1.41.0** `meilisearch` (`k8s/base/meilisearch.yaml`、インデックスは PG から再構築) |
| 本体 | **Misskey 2026.6.0** (vendored chart `chart/` appVersion 2026.5.0、image tag を `values/yagamin.yaml` で 2026.6.0 に上書き) + 同梱 Redis (揮発) |
| Secret | 単一 **`misskey-secret`** (SealedSecret) — 土台と本体で共有 (single source of truth) |
| 管理 | Kustomize (土台) + Helm/ArgoCD (本体)。ArgoCD App `misskey-infra` (土台) / `misskey` (本体) |

## ディレクトリ

```
misskey/
├── README.md
├── chart/                          vendored Helm chart (ics-corporate@fd9e5e8b)
│   ├── Chart.yaml / values.yaml / templates/
│   ├── PROVENANCE.txt / HANDOVER-SOURCE.md
├── values/
│   └── yagamin.yaml                移行先 values (本クラスタ向け修正込み)
└── k8s/                            土台 (chart 非依存)
    ├── base/{namespace,postgres,meilisearch,networkpolicy-backends}.yaml + kustomization
    ├── overlays/production/{kustomization, sealed-secrets/misskey-secret.yaml}
    └── argocd/{application.yaml (misskey-infra), application-misskey.yaml (misskey 本体)}
```

## 単一 Secret `misskey-secret`

土台 (PG/Meili) と本体チャートが**同一 secret** を参照する。チャートは `envFrom` + initContainer の
sed でプレースホルダ置換する契約のため、injected 値を 1 つの secret に集約している。

| キー | 使う側 | 備考 |
|---|---|---|
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | misskey-postgres (init) / 本体 (接続) | |
| `MEILISEARCH_API_KEY` | meilisearch (`MEILI_MASTER_KEY`) / 本体 (`apiKey`) | 両者同値 |
| `SETUP_PASSWORD` | 本体 | Misskey セットアップ |
| `OBJECT_STORAGE_ACCESS_KEY` / `OBJECT_STORAGE_SECRET_KEY` | 本体 (R2) | 現環境の既存 R2 キーを流用、封緘済み |
| `OBJECT_STORAGE_ENDPOINT` | 本体 (R2) | `<account_id>.r2.cloudflarestorage.com`。公開 repo に account_id を出さないため secret 注入 |

### bootstrap / R2 キー追加

```bash
# 初期 (DB/setup/meili キー)。別クラスタ = 別 keypair では再暗号化が必要。
kubectl -n misskey create secret generic misskey-secret \
  --from-literal=DB_NAME=misskey --from-literal=DB_USER=misskey \
  --from-literal=DB_PASSWORD="$(openssl rand -hex 24)" \
  --from-literal=SETUP_PASSWORD="$(openssl rand -hex 24)" \
  --from-literal=MEILISEARCH_API_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system \
      --format=yaml --namespace=misskey \
  > misskey/k8s/overlays/production/sealed-secrets/misskey-secret.yaml

# R2 フェーズ: 既存 SealedSecret に R2 キーだけ追加 (既存キーは再暗号化しない)
kubectl -n misskey create secret generic misskey-secret \
  --from-literal=OBJECT_STORAGE_ACCESS_KEY="<r2-access-key>" \
  --from-literal=OBJECT_STORAGE_SECRET_KEY="<r2-secret-key>" \
  --dry-run=client -o yaml \
  | kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system \
      --merge-into misskey/k8s/overlays/production/sealed-secrets/misskey-secret.yaml
```

## デプロイ手順

```bash
# 1. 土台 (namespace + PG18 + Meilisearch + misskey-secret + 補助 netpol)
kubectl apply -k misskey/k8s/overlays/production
kubectl apply -f misskey/k8s/argocd/application.yaml          # misskey-infra

# 2. 本体 (R2 キー merge 済 + values の account_id 反映 + cert 前提を満たした後)
kubectl apply -f misskey/k8s/argocd/application-misskey.yaml   # misskey
```

## この環境向けの結合修正 (values/yagamin.yaml)

チャートは汎用のため、本クラスタ固有の差分を values で吸収している。

- **`networkPolicy.ingressNamespaceLabel: kube-system`** — 本環境の nginx ingress は `kube-system` で稼働
  (`ingress-nginx` という ns は存在しない)。chart default のままだと `default-deny-ingress` で web pod への
  流入が全遮断される。
- **補助 NetworkPolicy** (`k8s/base/networkpolicy-backends.yaml`) — chart の `default-deny-ingress`
  (`podSelector:{}`) が同一 ns の PG/Meili も巻き込むため、`component: web` → PG:5432 / Meili:7700 の
  ingress を明示許可。これが無いと Misskey が自分の DB/検索に到達できない。
- **`objectStorage`** — 現環境の R2 設定をそのまま流用 (bucket `yagamincom` / prefix `misskey` /
  baseUrl `files.yagamin.com`)。`endpoint`(account_id) は公開 repo に出さないため secret 注入
  (`__OBJECT_STORAGE_ENDPOINT__` を chart の initContainer が sed 置換)。

## PostgreSQL locale (確定)

移行元 `UTF8 / en_US.UTF-8 / en_US.UTF-8` に一致させ、Debian `postgres:18` +
`POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8"` で構築済み。
→ restore 前の DROP/CREATE 不要、`pg_restore --no-owner --no-acl -d misskey misskey.dump` をそのまま実施可。

## 本体 deploy の前提 (gate)

1. 土台 (misskey-infra) が Healthy (PG18 + Meilisearch 起動)
2. R2: **現環境の設定を流用済み**（キー封緘済み・endpoint secret 注入済み・values 反映済み）。R2 は外部共有のため**ファイル移送不要**
3. **TLS**: `ingress.clusterIssuer: selfsigned-issuer`。Cloudflare Tunnel 背後 (noTLSVerify) なので origin
   証明書は公開信頼不要。step-ca/letsencrypt は ACME チャレンジ検証が要り、公開ドメイン yagamin.com を
   内部CAで HTTP-01 検証するのは hairpin で不成立 (solver も chart の default-deny に阻まれる) → selfsigned
   が即時発行でループしない。
4. **Tunnel**: `yagamin.com` 専用 Tunnel + 専用 cloudflared connector（認証 JSON 待ち）

## 後続フェーズ

| フェーズ | 内容 | 状態 |
|---|---|---|
| R2 | 現環境設定を流用 (bucket `yagamincom` / prefix `misskey` / files.yagamin.com)。既存キー封緘済み・endpoint secret 注入済み。**ファイル移送不要** | 完了 |
| TLS | `selfsigned-issuer` (Tunnel 背後で信頼不要、ACME不要) | 完了 |
| Tunnel | `yagamin.com` 専用 Cloudflare Tunnel 新設 + 専用 cloudflared connector → CNAME 切替 (カットオーバー当日) | 認証 JSON 待ち |
| カットオーバー | 移行元 書き込み停止 → 最終 `pg_dump -Fc` → restore → Meilisearch 再インデックス → CNAME 切替 | 日程調整中 |
