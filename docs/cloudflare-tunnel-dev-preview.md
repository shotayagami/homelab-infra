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

## WARP private network 経由のリモート LAN アクセス (2026-05)

公開ホスト名 (ingress) は HTTP/WebSocket(TCP) 専用で **SIP/RTP のような UDP は通せない**。外部の端末から LAN 上のサービス (例: FreePBX `192.168.11.57` の SIP/RTP) に届かせたい場合は、Cloudflare WARP + tunnel の private network routing を使う。WARP は実体が WireGuard なので UDP を含む全 IP を運べ、connector は outbound 接続のみ (MAP-E ルータの inbound 制限を回避)。

構成:
```
[外部端末: WARP on] → Cloudflare edge → 同じ home-yagamin tunnel の connector → 192.168.11.0/24 の対象 IP
```

有効化:
1. `cloudflared/tunnel-config.yaml` の `warp-routing.enabled: true` (本リポジトリで管理) を `scripts/cloudflared-push-tunnel-config.sh` で push
2. private network route を登録 (configurations PUT には含まれない別 API)。冪等な管理スクリプトで:
   ```bash
   DRY_RUN=1 scripts/cloudflared-ensure-teamnet-routes.sh   # plan
   scripts/cloudflared-ensure-teamnet-routes.sh             # apply (CIDR=comment を引数で上書き可)
   ```
   desired set (最小権限の観点で対象 IP だけを `/32` で登録):

   | CIDR | 用途 |
   |---|---|
   | `192.168.11.57/32` | FreePBX SIP remote ([[FreePBX 構内内線 (LXC 109)]]) |
   | `192.168.11.20/32` | ICS-TV playout SRT ingest (送出ノード LXC131 の MediaMTX `:8890`) |

   (Zero Trust > Networks > Routes でも可)
3. Zero Trust の WARP device profile の Split Tunnel で対象 CIDR を WARP 経由にする (既定の Exclude モードは 192.168.0.0/16 を除外するため、その CIDR を除外から外す / carve-out しないと WARP を通らない)
4. SRT ingest (UDP) のアクセス制御は CF Access (HTTP 用) ではなく Gateway > Firewall Policies > Network で行う (例: `dst 192.168.11.20` / `dst port 8890` を配信担当の identity/device にのみ許可 + 既定 block)
5. 端末に Cloudflare WARP アプリを入れ、組織に enroll。接続状態でアプリは LAN にいるのと同じ IP (`192.168.11.57` / `192.168.11.20`) で到達

注意: connector を Puter LXC (LXC 102, 同一 L2) と RKE2 Pod で共有。どちらの connector でも対象 LAN IP に到達可能。

### ICS-TV playout SRT ingest (192.168.11.20) の実体 (2026-06-14)

送出ノード LXC131 の MediaMTX (`:8890`, UDP) へ現場端末から SRT publish させるための WARP 設定。`teamnet/routes` 以外は Zero Trust ダッシュボード/API の状態でリポジトリ管理外のため、ロールバック用に実値を控える。

1. **private network route**: `scripts/cloudflared-ensure-teamnet-routes.sh` で `192.168.11.20/32` を登録済。
2. **Split Tunnel carve-out** (default device policy, Exclude モード): 既定の `192.168.11.0/27` を `.20` だけ抜いた最小集合へ置換。
   - 削除: `192.168.11.0/27`
   - 追加: `192.168.11.0/28`, `192.168.11.16/30`, `192.168.11.21/32`, `192.168.11.22/31`, `192.168.11.24/29`
   - 効果: `.20` が除外から外れ WARP 経由に (`.57` の carve-out と同じ手法)。他レンジは不変。
   - 注意: custom device profile (`Onboarding Device profile`) が別に存在。現場端末が default profile に乗っていることを確認すること。
   - ロールバック: 上記 5 件を削除し `192.168.11.0/27` を戻す。
3. **Gateway network (L4) ポリシー** (UDP は CF Access 不可のため Gateway で制御。`.20` のみにスコープし global default-block は使わない):
   - allow (prec 10): `net.dst.ip == 192.168.11.20 and net.dst.port == 8890` + `identity.email` が studio と同じ staff ドメイン (`nekomin.jp` / `yagamin.net` / `circle-ics.com` / `eqwel.co.jp` / `whatsapp.co.jp`) にマッチ
   - block (prec 20): `net.dst.ip == 192.168.11.20` (それ以外全部)
   - ロールバック: 当該 2 ルールを名前 `ICS-TV playout SRT — …` で削除。
4. **現場端末**: Cloudflare WARP を入れ組織に enroll (上記 staff ドメインの identity でログイン)。SRT URL は `srt://192.168.11.20:8890?streamid=publish:live/ch1&latency=2000&passphrase=<pp>`。

## 関連

- [`cloudflared/README.md`](../cloudflared/README.md) — cloudflared 全体構成
- [`cloudflared/tunnel-config.yaml`](../cloudflared/tunnel-config.yaml) — ingress ルール source-of-truth
- [`scripts/cloudflared-push-tunnel-config.sh`](../scripts/cloudflared-push-tunnel-config.sh)
- [`scripts/cloudflared-ensure-dns.sh`](../scripts/cloudflared-ensure-dns.sh)
