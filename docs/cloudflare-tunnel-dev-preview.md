# Dev preview hosts via Cloudflare Tunnel

`dev-*.yagamin.net` を関係者限定プレビューとして Cloudflare Tunnel で公開する仕組み。**一般公開はしない**が、URL を知っていれば Cloudflare Access の認証なしで誰でも閲覧できる (URL シェア型)。

## 公開先

| ホスト | 上流アプリ | ingress namespace |
|---|---|---|
| `dev-dealmatch.yagamin.net` | dealmatch (top) | `dealmatch` |
| `dev-seller-dealmatch.yagamin.net` | dealmatch (seller) | `dealmatch` |
| `dev-buyer-dealmatch.yagamin.net` | dealmatch (buyer) | `dealmatch` |
| `dev-pairs.yagamin.net` | crossing (pairs) | `crossing` |
| `dev-mensbar.yagamin.net` | crossing (mensbar) | `crossing` |
| `dev-lilies.yagamin.net` | crossing (lilies) | `crossing` |

## 構成

```
Browser
  ↓ HTTPS (Cloudflare Universal SSL で edge 終端)
Cloudflare Tunnel  8b20116a-8d95-4f00-8edc-f50a647451c7  (name: home-yagamin)
  ↓ HTTPS noTLSVerify、Host ヘッダはそのまま
in-cluster cloudflared (cloudflare namespace, 2 replicas)
  ↓ HTTPS https://192.168.11.80:443
rke2 ingress-nginx (Host ヘッダで分岐)
  ↓
Service / Pod (dealmatch / crossing)
```

Tunnel は **remotely-managed** モード (`remote_config: true`) — ingress ルールは CF API 側に保管され、connector の local config.yaml の `ingress:` セクションは無視される。Source-of-truth は `cloudflared/tunnel-config.yaml`、CF API への push は `scripts/cloudflared-push-tunnel-config.sh`。

Dev preview は Host ヘッダ書き換えなしで cloudflared から ingress-nginx に渡す。理由:

- アプリ側 middleware で `X-Robots-Tag: noindex` を dev-* host だけに付与しやすい
- Django で `request.get_host()` が `dev-*` の時に `/robots.txt` を `Disallow: /` で返す分岐を素直に書ける
- LAN / 外部 で cookie domain や CSRF origin を分離しやすい

## 検索エンジン除外 (二重)

ingress-nginx は `allow-snippet-annotations: false` (CVE-2024-7646 緩和) で運用しているため、`server-snippet` annotation は admission webhook が拒否する。`X-Robots-Tag` は **アプリ側の Django middleware** で付与する。

1. **Django middleware** (dev-* host を判定して response header に付与):
   ```python
   if host.startswith("dev-") and host.endswith(".yagamin.net"):
       response["X-Robots-Tag"] = "noindex, nofollow, noarchive"
   ```
2. **アプリの `/robots.txt`** (Host が `dev-` で始まる時のみ):
   ```
   User-agent: *
   Disallow: /
   ```

## デプロイ手順

### 1. cloudflared 側 (homelab-infra)

`cloudflared/tunnel-config.yaml` に dev-* 6 件は既に含まれている。差分を CF API へ push、DNS CNAME を作成:

```bash
cd ~/homelab-infra
DRY_RUN=1 scripts/cloudflared-push-tunnel-config.sh   # 差分確認
scripts/cloudflared-push-tunnel-config.sh             # 適用 (idempotent)
DRY_RUN=1 scripts/cloudflared-ensure-dns.sh           # DNS plan
scripts/cloudflared-ensure-dns.sh                     # DNS upsert (idempotent)
```

接続子マニフェストは ArgoCD Application で sync する。最初の bootstrap だけ:

```bash
kubectl apply -f cloudflared/k8s/argocd/application.yaml
```

### 2. dealmatch (別リポジトリ)

`k8s/base/ingress-dev-preview.yaml` で dev-* 3 host の Ingress を定義 (annotation での noindex は admission webhook で拒否されるため不可)。Django middleware で response に `X-Robots-Tag: noindex, nofollow, noarchive` を付与。Django settings の `ALLOWED_HOSTS` / `CSRF_TRUSTED_ORIGINS` に dev-* を追加。`/robots.txt` view で Host 分岐。

### 3. crossing (別リポジトリ)

`k8s/overlays/production/ingress.yaml` (または overlay 追加) で同様に dev-* 3 host を追加。backend settings と robots.txt も同様。

## 動作確認

```bash
for h in dev-dealmatch dev-seller-dealmatch dev-buyer-dealmatch dev-pairs dev-mensbar dev-lilies; do
  echo "=== $h.yagamin.net ==="
  curl -sSI "https://$h.yagamin.net/" | head -8
  echo "--- robots.txt ---"
  curl -sS "https://$h.yagamin.net/robots.txt"
  echo
done
```

期待値:

- HTTP 200 (または 30x → 200)
- `X-Robots-Tag: noindex, nofollow, noarchive`
- `/robots.txt` が `Disallow: /` を返す

PR1 単体マージ直後はまだ ingress に dev-* host が無いので、nginx default backend の 404 が返れば「tunnel + DNS は OK、上流アプリの ingress 設定待ち」と判断できる。

## 解除する場合

1. CF zone から該当 CNAME を削除 (DNS 先行) — `cloudflared-ensure-dns.sh` には削除モードはまだ無いので CF Dashboard or `curl` で直
2. `cloudflared/tunnel-config.yaml` から該当 ingress エントリを削除し `scripts/cloudflared-push-tunnel-config.sh` を再実行
3. dealmatch / crossing 側の ingress / settings から dev-* を外す

## 関連

- [`cloudflared/README.md`](../cloudflared/README.md) — cloudflared 全体構成
- [`cloudflared/tunnel-config.yaml`](../cloudflared/tunnel-config.yaml) — ingress ルール source-of-truth
- [`scripts/cloudflared-push-tunnel-config.sh`](../scripts/cloudflared-push-tunnel-config.sh)
- [`scripts/cloudflared-ensure-dns.sh`](../scripts/cloudflared-ensure-dns.sh)
