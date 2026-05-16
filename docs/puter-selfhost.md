# Puter セルフホスト (LXC 102)

[Puter](https://github.com/HeyPuter/puter) (heyputer) を Docker Compose で LXC 102 にセルフホストしている。本書は構成、ハマりどころ、用途整理。

> **現状ステータス**: 2026-05 時点で **停止中** (RKE2 クラスタにリソースを譲るため一時停止)。構成自体は残置しており、`docker compose up -d` で復帰可能。

## 1. Puter とは

ブラウザで動く「クラウド OS 風アプリ + 開発プラットフォーム」。デスクトップ UI / ファイルマネージャ / エディタ / ターミナルが組み込まれ、加えて:

- ユーザー向け静的サイトホスティング (`<sub>.site.yagamin.net`)
- Workers (Cloudflare Workers 的な JS 実行環境)
- `puter.js` SDK で認証 / FS / KV / AI を Firebase ライクに使える

ポジションとしては **Nextcloud と Replit と Firebase の中間**。

## 2. 配置

| 項目 | 内容 |
|---|---|
| LXC | VMID 102 (hostname: `puter`) |
| IP | 192.168.11.174 |
| compose プロジェクト | `/opt/puter-selfhosted/` (host) |
| OS | Debian 12 ベース、Docker Engine + compose plugin |

## 3. コンテナ構成

| サービス | イメージ | 役割 |
|---|---|---|
| `puter` | `ghcr.io/heyputer/puter:main` | コアアプリ、内部 port 4100 |
| `puter-nginx` | `nginx:1.27-alpine` | リバプロ、host port **80** で受ける |
| `puter-mariadb` | `mariadb` | メタデータ DB |
| `puter-valkey` | `valkey` | キャッシュ / セッション |
| `puter-dynamo` | `amazon/dynamodb-local` | KV |
| `puter-s3` | rustfs (互換 S3) | ユーザーアップロードの実体置き場 |
| `cloudflared-puter` | `cloudflare/cloudflared` | CF Tunnel、token 式 |

## 4. 公開ホスト名と Cloudflare Tunnel ingress

全部 `http://127.0.0.1:80` (= puter-nginx) に向ける:

| ホスト名 | 用途 |
|---|---|
| `puter.yagamin.net` | GUI (デスクトップ UI) |
| `api.yagamin.net` | API |
| `site.yagamin.net` / `host.yagamin.net` | 静的サイトホスティング系 |
| `app.yagamin.net` / `dev.yagamin.net` | アプリ / 開発系 |

CF Tunnel の ingress は Zero Trust ダッシュボードで管理 (compose 内の cloudflared は token 式、ingress 定義はクラウド側)。

### `api.yagamin.net` の DNS が平坦な点に注意

通常 Puter の慣習は `api.<config.domain>` (= `api.puter.yagamin.net`、4 ラベル) だが、本構成では **DNS は `api.yagamin.net` (3 ラベル)** に平坦化している。これは Cloudflare Universal SSL が 1 階層しかカバーしないため (後述「アイコン配信」参照)。

平坦 DNS のままだと Puter 内部の subdomain 判定が空になるので、**nginx で Host 書き換え**が必要 → 次節。

## 5. nginx Host 書き換え（重要パターン）

Puter は `config.json::domain = puter.yagamin.net` で動作し、Express の `subdomain offset = 3` を設定する。そのため `api.yagamin.net` (3 ラベル) を直接渡しても `req.subdomains = []` となり、API ルートが認識されず 404。

**対処**: `puter-nginx` の nginx.conf 側で `map $host $puter_upstream_host` を使い `api.yagamin.net` → `api.puter.yagamin.net` に書き換え、**`Host` と `X-Forwarded-Host` の両方** を `$puter_upstream_host` でセット:

```nginx
map $host $puter_upstream_host {
    default              $host;
    api.yagamin.net      api.puter.yagamin.net;
    site.yagamin.net     site.puter.yagamin.net;
    # ... 他サブドメインも同様
}

location / {
    proxy_pass http://puter:4100;
    proxy_set_header Host              $puter_upstream_host;
    proxy_set_header X-Forwarded-Host  $puter_upstream_host;   # ← これが肝
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

**Why**: `trust_proxy: 2` の設定で Puter は `X-Forwarded-Host` から `req.hostname` を導出する。`X-Forwarded-Host` を `$host` (= `api.yagamin.net`) のままにすると、Puter 内では subdomain 計算が空配列になり API 判定が失敗する。`Host` と `X-Forwarded-Host` の両方を書き換える必要がある。

設定ファイル: `/opt/puter-selfhosted/nginx/nginx.conf`。古い版 (`X-Forwarded-Host` が `$host` のまま) のバックアップは `nginx.conf.bak.20260514-165927`。

## 6. bind mount の inode 罠（ハマりどころ）

`puter-nginx` の `/etc/nginx/nginx.conf` はホストの `/opt/puter-selfhosted/nginx/nginx.conf` を bind mount している。

**罠**: `pct push` や `sed -i` のようにファイルを **置換 (inode 変更)** する操作だと、**コンテナは古い inode を握り続けて新内容が見えない**。`docker exec puter-nginx nginx -s reload` しても古い設定のまま。

**Why**: Docker の bind mount はファイルレベルで inode を bind しているため。

**対処**:

```bash
# Bad (inode が変わる)
sed -i 's/foo/bar/' /opt/puter-selfhosted/nginx/nginx.conf

# Good (in-place 上書き、inode 維持)
cat new_content > /opt/puter-selfhosted/nginx/nginx.conf
docker exec puter-nginx nginx -s reload

# または、コンテナを再起動 (inode 再 bind)
docker restart puter-nginx
```

同じ罠は `docker-compose.yml` で bind mount している他のファイル (`config.json`、ソースパッチ等) すべてに当てはまる。

## 7. アプリアイコン配信のサブドメイン問題とソースパッチ

Puter は本来 `puter-app-icons.<static_hosting_domain>` (= `puter-app-icons.site.yagamin.net`、4 ラベル) からアプリアイコンを配信する。

**問題**: Cloudflare Universal SSL は 1 階層 (= `*.<domain>`) しか無料でカバーしない。`*.yagamin.net` は OK だが、`*.site.yagamin.net` (2 階層) は **Advanced Certificate Manager ($10/月)** が必要。Universal SSL のままだと `puter-app-icons.site.yagamin.net` で証明書エラー → アイコン表示が壊れる。

**対処** (2026-05-14): ソースパッチで `/app-icon/<uid>/<size>` API ハンドラを「302 リダイレクトしない、fs から読んで `res.pipe()` する」に変更。

### パッチ対象ファイル (host から bind mount)

```
/opt/puter-selfhosted/puter/src/dist/src/backend/services/appIcon/AppIconService.js
  → resolveIconEntry(appUid, size) 新メソッド追加 (FSEntry を返す)

/opt/puter-selfhosted/puter/src/dist/src/backend/controllers/apps/AppController.js
  → serveIcon の 302 redirect 部分を
    services.fs.readContent(entry).body.pipe(res) に置換
```

### docker-compose.yml の bind mount 追加

`puter` サービスの `volumes` に以下を追加してソース改造を永続化:

```yaml
volumes:
  - ./puter/src/dist:/opt/puter/dist:z
```

コピー元はコンテナ初回起動時の `/opt/puter/dist` を `docker cp puter:/opt/puter/dist ./puter/src/` で host へ取得。

**注意**: `ghcr.io/heyputer/puter:main` を pull するとアップストリームのコードが新しくなるため、bind mount している dist を上書きするとパッチが消える可能性がある。**コンテナ更新時はホスト側 dist を新イメージのものと merge → パッチ再適用が必要**。バックアップは `*.js.bak` がペアで残してある。

## 8. Cloudflare Access の上塗り注意（未解決の運用注意）

`puter.yagamin.net` を Cloudflare Zero Trust の Access Application で **保護してはいけない**。

**症状**: Puter GUI が `/dist/manifest.json` を fetch する際に Access ログインへリダイレクトされ、CORS で死ぬ。

**Why**: Puter は自前の JWT 認証を持つアプリで、Cloudflare Access の上塗りは不要。Access の認証 cookie とアプリの JWT が衝突する。

**How to apply**:
- `puter.yagamin.net` と `api.yagamin.net` (および他のサブドメイン) は **Access Application から外す**
- どうしても CF Access で保護したい場合は Bypass Service Auth Policy を全パスに適用 (実質保護なし)
- Puter のサブドメインは Cloudflare Access で保護しない方針

## 9. 用途整理（できること / 不向きなこと）

| 用途 | 適性 | 備考 |
|---|---|---|
| 個人クラウド (軽い編集) | ◯ | Notepad / Editor / File Manager で日常作業 |
| マルチデバイス同一環境 | ◯ | ブラウザだけあれば同じデスクトップ |
| デスクトップ sync (Nextcloud client 相当) | × | 該当機能なし |
| 大量写真/動画の本格管理 | × | 専用サービス推奨 |
| 静的サイトホスティング | △ | `<sub>.site.yagamin.net` で配信、ただし CF Tunnel ingress に `*.site.yagamin.net` 登録要 (未登録) |
| Puter SDK で自作 Web アプリ | ◯ | `puter.js` で認証 / FS / KV / AI を Firebase 的に利用、`api_base_url = api.yagamin.net` |
| 家族 / 小規模グループ共有 | ◯ | 招待制ユーザー、Mailgun 無料枠 (100/日) で招待メール |
| ローカル AI | △ | `providers.ollama.enabled = false` で無効中、LXC 4C/8G で軽量モデル (tinyllama 1.1B) なら動作可、compose に `--profile ai` |

## 10. バックアップ対象

復旧時に必要なデータ:

```
/opt/puter-selfhosted/
├── puter/config/config.json    # Puter 本体設定
├── puter/data/
│   ├── mariadb/                 # メタデータ DB
│   ├── valkey/                  # キャッシュ (rebuild 可だが性能差)
│   ├── dynamo/                  # KV
│   ├── s3/                      # ★ ユーザーアップロードの実体、肥大化注意
│   └── puter/                   # アプリ内部状態
├── nginx/nginx.conf             # リバプロ設定 (host 書き換えロジック含む)
├── puter/src/dist/              # ソースパッチ (app-icon 配信改造)
└── docker-compose.yml
```

S3 (rustfs) は肥大化しやすいので、容量監視と古いデータの掃除が必要。

## 関連

- [docs/proxmox-firewall.md](proxmox-firewall.md) — LXC 102 への 80/tcp 許可
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Zabbix での Puter LXC 監視 (現状停止中だが host 自体は残っている)
- [scripts/proxmox-deploy-puter-cloudflare-access.sh](../scripts/proxmox-deploy-puter-cloudflare-access.sh) — Puter LXC + CF Tunnel デプロイスクリプト
