# cloudflared (in-cluster Cloudflare Tunnel)

`*.yagamin.net` を Cloudflare Tunnel 経由でクラスタ外へ公開するための in-cluster cloudflared コネクタと、その tunnel の ingress ルール source-of-truth。

- Tunnel UUID: `8b20116a-8d95-4f00-8edc-f50a647451c7` (CF Zero Trust 上の名前は `home-yagamin`)
- 接続子: in-cluster Deployment (`cloudflare` namespace, 2 replicas)
- 認証情報: SealedSecret `tunnel-credentials` (`k8s/overlays/production/sealed-secrets/`)
- **Tunnel は `remote_config: true` (remotely-managed)** — ingress ルールは CF API 側に保管され、connector の `config.yaml` の `ingress:` セクションは無視される
- ingress ルールの source-of-truth は [`tunnel-config.yaml`](tunnel-config.yaml)、push は [`scripts/cloudflared-push-tunnel-config.sh`](../scripts/cloudflared-push-tunnel-config.sh)

## レイアウト

```
cloudflared/
├── README.md
├── tunnel-config.yaml              # ingress ルール source-of-truth (CF API へ push)
└── k8s/
    ├── argocd/application.yaml     # ArgoCD Application (一度だけ kubectl apply)
    ├── base/
    │   ├── namespace.yaml
    │   ├── deployment.yaml
    │   ├── configmap.yaml          # tunnel UUID / credentials path / metrics のみ
    │   └── kustomization.yaml
    └── overlays/production/
        ├── kustomization.yaml
        └── sealed-secrets/tunnel-credentials.yaml
```

## 公開ホスト一覧

詳細は `tunnel-config.yaml` を参照。要点:

### Puter (LXC 102 上のローカル nginx に直接)

`puter` / `api` / `site` / `host` / `app` / `dev` `.yagamin.net` → `http://127.0.0.1:80`

これらは Puter LXC の cloudflared コネクタが処理する前提のルート。in-cluster コネクタが拾うと 502 になる可能性がある (LXC を別 tunnel ID へ分離するかは将来課題)。

### Dev preview (RKE2 ingress-nginx 経由)

| 公開ホスト | 上流アプリ |
|---|---|
| `dev-dealmatch.yagamin.net` | dealmatch (top) |
| `dev-seller-dealmatch.yagamin.net` | dealmatch (seller) |
| `dev-buyer-dealmatch.yagamin.net` | dealmatch (buyer) |
| `dev-pairs.yagamin.net` | crossing (pairs) |
| `dev-mensbar.yagamin.net` | crossing (mensbar) |
| `dev-lilies.yagamin.net` | crossing (lilies) |

すべて `https://192.168.11.80:443` (cp1 上の rke2 ingress-nginx) に `noTLSVerify: true` で繋ぐ。Host ヘッダは書き換えず、ingress 側で `dev-*.yagamin.net` を直接受ける。`dev-*` は **一般公開せず** 関係者限定。検索エンジン除外は ingress-nginx の `server-snippet` annotation が cluster admission webhook で拒否される (`allow-snippet-annotations: false`、CVE-2024-7646 緩和) ため、アプリ側 Django middleware で `X-Robots-Tag: noindex, nofollow, noarchive` を付与、加えて `/robots.txt` で `Disallow: /` を返す二重防御。

## 運用手順

### 公開ホストを足す

1. [`tunnel-config.yaml`](tunnel-config.yaml) に ingress エントリを追加 (catch-all `http_status:404` の上)
2. PR を上げて main へ merge
3. ローカルで CF API へ push:
   ```bash
   cd ~/homelab-infra
   DRY_RUN=1 scripts/cloudflared-push-tunnel-config.sh   # 差分確認
   scripts/cloudflared-push-tunnel-config.sh             # 適用
   ```
4. DNS CNAME を作成:
   ```bash
   scripts/cloudflared-ensure-dns.sh <new-host>          # 個別指定
   # または scripts/cloudflared-ensure-dns.sh だけで dev-preview 既定セット
   ```

`scripts/cloudflared-push-tunnel-config.sh` / `cloudflared-ensure-dns.sh` は idempotent。

### 公開ホストを止める

1. CF zone から該当 CNAME を削除 (DNS 側を先に落とす)
2. `tunnel-config.yaml` から該当 ingress エントリを削除
3. `scripts/cloudflared-push-tunnel-config.sh` で適用

### Tunnel credentials のローテーション

1. Cloudflare Zero Trust ダッシュボードで新規 credentials.json を発行
2. ```bash
   kubectl create secret generic tunnel-credentials -n cloudflare \
     --from-file=credentials.json=./credentials.json --dry-run=client -o yaml \
   | kubeseal --controller-name sealed-secrets --controller-namespace kube-system --format yaml \
   > cloudflared/k8s/overlays/production/sealed-secrets/tunnel-credentials.yaml
   ```
3. PR → merge → ArgoCD sync。古い credentials は Cloudflare 側で revoke

## 接続子側 (k8s) の bootstrap

PR merge 後に一度だけ:

```bash
kubectl apply -f cloudflared/k8s/argocd/application.yaml
```

ArgoCD が `cloudflare` namespace の Deployment / ConfigMap / Secret を自動 sync する。既存の手動デプロイ済みリソースは ArgoCD が adopt する。

## 関連

- [`docs/cloudflare-tunnel-dev-preview.md`](../docs/cloudflare-tunnel-dev-preview.md) — dev preview の運用全体像
- [`scripts/cloudflared-push-tunnel-config.sh`](../scripts/cloudflared-push-tunnel-config.sh) — tunnel ingress の CF API push
- [`scripts/cloudflared-ensure-dns.sh`](../scripts/cloudflared-ensure-dns.sh) — DNS CNAME upsert
