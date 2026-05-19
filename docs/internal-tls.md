# 内部 PKI と TLS 自動更新 — step-ca + サービス連携

LAN 内 HTTPS 用の内部 CA を **smallstep step-ca** で立て、Nextcloud と Zabbix の nginx に発行 + 自動更新まで運用している。本書は構成と「同型を別 LXC に展開する」雛形手順。

## 1. step-ca 本体 (LXC 107)

| 項目 | 内容 |
|---|---|
| 配置 | LXC 107、IP 192.168.11.61、Ubuntu 22.04 |
| サービス | `step-ca.service` (systemd) で常駐 |
| 内部 CA URL | `https://step-ca.home.yagamin.net` (LAN 内 DNS で名前解決) |
| Fingerprint | `31b8254e433a181603744750416e6c8b7bc06bb112fcbee30fbd1be3e307da91` |
| プロビジョナ | `admin` (JWK) + `acme` (ACME)  |
| 証明書最長寿命 | **720h = 30 日** (`ca.json` の `maxTLSCertDuration` で強制) |
| JWK admin パスワード | step-ca LXC の `/root/.step/secrets/password` (step-ca サービス起動用と共通) |

30 日上限のため自動更新は **5 日前 (`--expires-in 120h`)** に設定し、renew 失敗時のリトライ余裕を確保している。

## 2. 自動更新の仕組み (Nextcloud LXC 例)

Nextcloud (LXC 108、192.168.11.62) で nginx の TLS 終端を行うため、step-ca 発行証明書を `/etc/nginx/ssl/` に配置し、`step ca renew --daemon` で自動更新:

### 配置

```
/etc/nginx/ssl/nextcloud.crt    # サーバ証明書 (644)
/etc/nginx/ssl/nextcloud.key    # 秘密鍵 (600)
/etc/nginx/ssl/ca.crt           # step-ca のルート (信頼チェーン用)
```

### systemd unit (`step-renew-nextcloud.service`)

**リポジトリ内コピー**: [scripts/systemd-units/step-renew-nextcloud.service](../scripts/systemd-units/step-renew-nextcloud.service) (Zabbix 用も同型: [scripts/systemd-units/step-renew-zabbix.service](../scripts/systemd-units/step-renew-zabbix.service))

```ini
[Unit]
Description=Renew Nextcloud TLS cert from step-ca
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/step ca renew --daemon \
  --expires-in 120h \
  --exec "systemctl reload nginx" \
  /etc/nginx/ssl/nextcloud.crt \
  /etc/nginx/ssl/nextcloud.key
Restart=on-failure
ProtectHome=read-only    # ★ 後述、yes だと起動失敗する

[Install]
WantedBy=multi-user.target
```

**ポイント**:

- `--daemon` モードは内部で `time.Sleep` ループしながら閾値を監視し、自動 renew + 後続コマンド実行までやってくれる
- 期限切れ前に renew する場合、cert ベースの mTLS で step-ca に再接続するためプロビジョナパスワードは不要
- 初回発行のみ JWK admin パスワードが必要 (`step ca certificate <subject> --provisioner admin`)

## 3. ハマりポイント

### 3-1. `ProtectHome=yes` で起動失敗

systemd unit に `ProtectHome=yes` を付けると `step` CLI が `/root/.step/config/defaults.json` を読めず、起動時に:

```
'step ca renew' requires the '--ca-url' flag
```

というエラーで失敗する。`ProtectHome=read-only` 以下に緩めること。

### 3-2. SAN が空のまま発行されてしまう罠

`step ca certificate <subject>` だけだと **SAN (Subject Alternative Name) に CN が自動追加されない**。curl は RFC 6125 で SAN 必須なので、TLS verify が失敗する:

```
curl: (60) SSL: no alternative certificate subject name matches target host name
```

**対処**: 発行時に `--san <hostname>` と必要に応じて `--san <ip>` を **必ず明示**する:

```bash
step ca certificate zabbix.home.yagamin.net \
  /etc/nginx/ssl/zabbix.crt \
  /etc/nginx/ssl/zabbix.key \
  --provisioner admin \
  --san zabbix.home.yagamin.net \
  --san 192.168.11.55
```

Zabbix 構築時に CN だけで発行 → TLS verify 失敗 → 再発行で解消した経緯あり。

### 3-3. 期限切れ後は renew が使えない

`step ca renew` は既存の有効な cert を mTLS で提示する仕組みのため、**期限が切れると使えない**。期限切れになったら JWK admin パスワードで再発行 (`step ca certificate ...`) するしかない。

→ だからこそ `--expires-in 120h` (5 日前) で余裕を持たせている。

## 4. 同型展開済みのサービス

同じ仕組みを以下にも適用済み:

| サービス | LXC | 公開ホスト名 | unit | 適用日 |
|---|---|---|---|---|
| Nextcloud | 108 | `nextcloud.home.yagamin.net` | `step-renew-nextcloud.service` | 2026-04 初頭 |
| Zabbix Web UI | 190 | `zabbix.home.yagamin.net` | `step-renew-zabbix.service` | 2026-05-15 (Issue #8) |
| pg-db PostgreSQL SSL | 106 | `pg-db.home.yagamin.net` (IP=.60) | cron `/etc/cron.d/step-ca-renew` | 2026-05-16 |
| Technitium DNS (dns/dns2) | 104 / 105 | `dns/dns2.home.yagamin.net` の 853/443/53443 | `step-renew-dns.service` ([scripts/systemd-units/step-renew-dns.service](../scripts/systemd-units/step-renew-dns.service)) | 2026-05-19 ([internal-dns.md §7](internal-dns.md#7-step-ca-由来-cert-への置き換え-2026-05-19)) |

新規 LAN サービスを HTTPS 化する際は **Nextcloud か Zabbix の構成を雛形にする**のが最速。

## 5. 新規サービス HTTPS 化の手順 (雛形)

```bash
# 1. 対象 LXC 内で step CLI をインストール (smallstep の deb)
curl -sLO https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.deb
dpkg -i step-cli_amd64.deb

# 2. step-ca のルート CA を信頼
step ca bootstrap \
  --ca-url https://step-ca.home.yagamin.net \
  --fingerprint 31b8254e433a181603744750416e6c8b7bc06bb112fcbee30fbd1be3e307da91

# 3. 証明書を発行 (SAN 必須!)
mkdir -p /etc/nginx/ssl
step ca certificate <service>.home.yagamin.net \
  /etc/nginx/ssl/<service>.crt \
  /etc/nginx/ssl/<service>.key \
  --provisioner admin \
  --san <service>.home.yagamin.net \
  --san <LXC IP>

# 4. nginx に組み込み (Nextcloud / Zabbix の nginx.conf を雛形に)

# 5. 自動更新の systemd unit を作成 (step-renew-<service>.service)
#    ProtectHome=read-only を忘れない

# 6. enable + start
systemctl daemon-reload
systemctl enable --now step-renew-<service>.service
```

## 6. クライアント側の信頼

step-ca のルート CA を各クライアントの信頼ストアに追加する必要がある:

- **Linux**: `cp ca.crt /usr/local/share/ca-certificates/step-ca.crt && update-ca-certificates`
- **macOS / Windows**: GUI で「信頼されたルート」に追加
- **モバイル**: プロファイルとして配布、または各アプリ個別設定
- **admin-vm**: 2026-05-15 に CA 信頼インストール済み (Zabbix Issue #10 対応の一環)

## 関連

- [docs/internal-dns.md](internal-dns.md) — DoT/DoH に使う証明書の発行先 dns/dns2 LXC
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) §「Zabbix nginx を step-ca 証明書で内部 HTTPS 化」— Zabbix 適用の詳細
- [docs/proxmox-firewall.md](proxmox-firewall.md) — 各 LXC への 443 アクセス許可
