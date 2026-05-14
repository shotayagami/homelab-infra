# Proxmox 環境の死活監視 — Zabbix 導入記録

最終更新: 2026-05-14

## 1. 目的と前提

### 目的
Proxmox VE (192.168.11.11) 上で稼働している VM/LXC の **死活監視を自動化**する。
さらに将来的に CPU/メモリ/ディスク/ネットワーク等のメトリクスやサービス層の監視まで拡張できる基盤とする。

### 監視対象（現時点で把握しているもの）
- **PVE ホスト**: `proxmox` (192.168.11.11)
- **LXC 102 `puter`**: Puter セルフホスト（[[proxmox_puter]]）
- **LXC 104 `dns`** : 192.168.11.53 — Technitium DNS Primary（[[proxmox_dns_vms]]）
- **LXC 105 `dns2`**: 192.168.11.54 — Technitium DNS Secondary
- **LXC 107 `step-ca`**: 内部CA（[[proxmox_step_ca_nextcloud]]）
- **LXC 108 `nextcloud`**: Nextcloud + TLS
- その他、追加されるVM/CT

### 設計の制約
- 監視サーバ自身も Proxmox 上の LXC として運用する。
- PVE Firewall が有効化済み（[[proxmox_firewall]]）。Zabbix Server/Agent 通信ポートの開放が必要。
- 管理用サブネット `192.168.11.0/24` 内に閉じた構成。

## 2. 検討した選択肢

死活監視ソリューションを以下のカテゴリで比較検討した。

### 軽量・可用性監視
- **Uptime Kuma**: シンプル、UI美麗、5分で導入可。メトリクスは弱い。
- **Gatus**: YAML駆動、GitOps向き。
- **Beszel**: 新興のGo製、超軽量。

### リアルタイム/メトリクス重視
- **Netdata**: 各ホストにagentで秒粒度メトリクス、自動検出。
- **Prometheus + Grafana + Alertmanager**: 王道だが構築は重い。`prometheus-pve-exporter` あり。
- **PVE Metric Server（組込）→ InfluxDB → Grafana**: 追加agent不要、Proxmox公式ダッシュボードあり。

### Push型・補助
- **Healthchecks（自前ホスト可）**: cron/バックアップの欠落検知。
- **ntfy / Gotify**: 通知ハブ単体。

### オールインワン（フル機能監視）
- **Zabbix**: エンタープライズ定番。Proxmox公式テンプレートあり。学習コスト高だが極めて強力。← **採用**
- **Checkmk Raw Edition**: 自動検出が業界トップクラス、GUI中心。家庭ラボなら最有力候補。
- **LibreNMS**: SNMP/ICMPベース。ネットワーク機器中心の環境向き。

## 3. 決定：Zabbix を採用

### 採用理由
- **業務でも今後使用する可能性があるため**、エンタープライズで広く使われている Zabbix のスキルを身につける価値が大きい。
- Proxmox 公式テンプレート `Proxmox VE by HTTP` が秀逸。API トークンを発行するだけで、クラスタ → ノード → VM → CT を自動 LLD（low-level discovery）でツリー化し、CPU・メモリ・I/O・ディスク・状態を取得できる。
- Trigger（条件式）+ Action（通知/スクリプト）の組み合わせで、依存関係・メンテナンス時間枠・複雑な計算式まで自由に組める。
- 将来的に k3s/アプリ層/IoT まで含めて一台で完結させる拡張余地が大きい。
- ライセンスは GPL、全機能無料。

### 採用に伴うトレードオフ
- 用語と概念が多く（template / item / trigger / macro / host group / discovery rule…）、最初の学習コストは高い。
- DB（MySQL or PostgreSQL）込みで概ね 2GB+ RAM を確保したい。
- 設定を GUI ですべて組むと迷子になりやすいので、テンプレートをベースに最小限から積み上げる方針とする。

### 比較対照（参考）

| 観点 | Zabbix (採用) | Checkmk Raw | LibreNMS |
|---|---|---|---|
| 得意分野 | サーバ/アプリ/ネット網羅 | サーバ/仮想化 自動検出 | ネットワーク機器 |
| 収集方式 | Agent / API / SNMP / トラップ | Agent / 特殊Agent / SNMP | SNMP中心 + Unix Agent |
| Proxmox統合 | 公式テンプレ (API token) | 公式 Special Agent | 簡易 (Application) |
| VM/CT個別検出 | ◎ 自動 | ◎ 自動 | △ 限定的 |
| 学習コスト | 高 | 中 | 低〜中 |
| UI | 機能密、やや古風 | モダン、洗練 | ネットワーク特化 |
| アラート | 超柔軟（依存・エスカレ） | ルールベース、十分 | ルールビルダ |
| リソース | 重め (DB込 2GB+) | 中 (1GB+) | 軽 |
| ライセンス | GPL（全機能無料） | Raw=GPL、Ent=有償 | MIT風 |

## 4. これからの作業計画

### Phase 1: Zabbix Server の構築

**確定したパラメータ (2026-05-14)**

| 項目 | 値 |
|---|---|
| VMID | **190** |
| ホスト名 | `zabbix` |
| IPv4 | `192.168.11.55/24`, gw `192.168.11.1` |
| DNS | `192.168.11.53`, `192.168.11.54`（自前の `dns`/`dns2`） |
| OS テンプレート | Ubuntu 24.04 LTS |
| CPU | 2 cores |
| RAM | 4 GB (swap 1 GB) |
| Disk | 32 GB（root） |
| ストレージ | `local-lvm`（要確認、`pvesm status` で空きあるプール） |
| ネットワーク | `vmbr0`, NIC firewall=`1` |
| 種別 | Unprivileged LXC |
| onboot | 1（PVE起動時に自動起動） |
| DB | PostgreSQL（同一CT内） |
| Web frontend | nginx |

**手順**
1. LXC コンテナを上記パラメータで作成。
2. PVE Firewall は **NIC で `firewall=1` のみ有効化、ルール適用は後段**（ロックアウト回避、[[proxmox_firewall]] の教訓）。
3. Zabbix **7.0 LTS** 公式リポジトリから Zabbix Server + Frontend (nginx) + PostgreSQL を導入。
   - リポジトリ deb: `https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb`
   - 7.0 LTS はサポート 2029-06 まで。8.0 LTS が GA リリース後（2026-06 頃見込み）に計画的にアップグレード予定。
4. 初期ログイン (`Admin` / `zabbix`)、タイムゾーン・言語設定、`Admin` パスワード変更。
5. Zabbix が安定動作することを確認後に PVE Firewall ルールを適用（管理サブネット `192.168.11.0/24` から TCP 80/443、Agent 通信用 10050/10051、SSH 22 を許可）。

### Phase 2: Proxmox 監視テンプレートの適用
5. PVE WebUI で監視用 API トークンを発行（権限: PVEAuditor）。
6. Zabbix 側にホスト `proxmox` を登録、テンプレート `Proxmox VE by HTTP` を適用、マクロにトークン設定。
7. LLD で VM/CT が自動検出されることを確認。

### Phase 3: 各 LXC への Zabbix Agent 導入
8. 各 LXC (`dns`, `dns2`, `puter`, `step-ca`, `nextcloud` 他) に `zabbix-agent2` を導入。
9. PVE Firewall: 各 CT で TCP 10050（Zabbix Server からの passive 接続）を許可、または active モードで Zabbix Server へ push 構成。
10. テンプレート `Linux by Zabbix agent` を適用、基本リソース監視を有効化。

### Phase 4: サービス層の監視
11. **DNS**: `Technitium` 専用テンプレートはないため、`Net.dns` アイテムや HTTP モニタで `https://dns:53443` のヘルス確認を組む。DoT (853)/DoH (443)/通常 DNS (53) の3レイヤ確認。
12. **Nextcloud**: `Nextcloud by HTTP` テンプレートあり、admin トークンで導入。
13. **step-ca**: ACME エンドポイント `/health` への HTTP モニタを自作。
14. **Puter**: HTTPS フロント (nginx) への web シナリオ + 認証付きヘルス確認を検討。

### Phase 5: 通知設定
15. メディアタイプ追加（メール最初、必要に応じて Slack/Discord/ntfy 等の webhook）。
16. アクション設定: 障害発生時とメンテナンス時の挙動を分離。
17. メンテナンス時間枠の運用ルール策定（CT 再起動時の誤検知抑止）。

### Phase 6: 運用整備
18. バックアップ: Zabbix 設定 export と PostgreSQL ダンプを定期取得。
19. ドキュメント整備（このファイルを継続更新）。
20. 業務でも応用できるよう、テンプレート/マクロ/タグの設計指針をメモ化。

## 5. 作業ログ

### 2026-05-14
- 監視ソリューションを比較検討し、**Zabbix 採用**を決定。
- 本ドキュメントを作成、以降の作業を本ドキュメントに記録する方針。
- Phase 1 のパラメータ確定: VMID=190、その他は提案値通り。Phase 1 着手。
- Phase 1-B: LXC 190 作成成功（`zabbix` / 192.168.11.55、Ubuntu 24.04、unprivileged、firewall=1）。
- Phase 1-C: `Systemd 255` 警告対応で `features=nesting=1` を設定し reboot。
- Phase 1-D 試行 1: `apt-get install` が古いキャッシュで 404 → `apt-get update` を先頭に入れた版へ。
- Phase 1-D 試行 2: Zabbix repo の URL を誤認（`7.0/release/ubuntu/...` は 404）。
- **Zabbix バージョン決定の変更（試行 2 → 試行 3）**: 当初 7.0 LTS を想定していたが、リポジトリ調査で **8.0 LTS が Ubuntu 24.04 用 deb を公開済み**であることを確認。業務利用前提で「最新版で揃えたい」とのご意向に沿い、**Zabbix 8.0 LTS を採用**（2026-06 リリース予定の最新 LTS、サポート 2031-06 まで）。
- **Zabbix 8.0 のリポジトリ URL 構造変更を確認**: 7.x までの `/zabbix/<ver>/<distro>/...` から、8.0 では `/zabbix/8.0/release/<distro>/...` に変更。`release/` 配下に複数 OS バージョンの deb を集約する形式に。
  - 正しい URL: `https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_8.0+ubuntu24.04_all.deb`
- **重大: Zabbix 8.0 はまだ alpha 段階だった**。実際にインストールしてみたところ、入ったのは `8.0.0~alpha2` で `unstable/ubuntu` チャネル由来。`release/` チャネルには `zabbix-release` deb はあるが、Zabbix 本体パッケージはまだ存在せず（Packages: 416B、ほぼ空）。
- **方針再決定: Zabbix 7.0 LTS に切替**。8.0 GA リリース（2026-06 頃想定）までは 7.0 LTS で運用、8.0 GA 後に計画的にアップグレード。in-place で purge → 7.0 LTS インストールに変更（LXC 破棄せず流用）。
  - 教訓: 「最新版」の判断は、リポジトリの URL/deb の存在だけでなく、`Packages` ファイルの実体（バージョンや`~alpha`等の pre-release マーカー）まで見る必要がある。`zabbix-release` deb はリポジトリ設定だけで、本体パッケージとは別物。
- **Phase 1-D 完了**: Zabbix **7.0.26** LTS (`1:7.0.26-2+ubuntu24.04`) インストール成功。zabbix-server / zabbix-agent2 / nginx / php8.3-fpm すべて `active (running)`、ポート 80/10050/10051 で待受。
  - DB: PostgreSQL 16、認証情報は CT の `/root/.zabbix-db-credentials` に保存（600 権限）。
  - スキーマパス: `/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz`
- **Phase 1-E トラブル**: 初回ブラウザアクセスでデフォルト nginx の "Welcome to nginx!" が表示。原因は `/etc/nginx/sites-enabled/default` が `listen 80 default_server` で動いていて、IP直アクセス時にこちらが優先されたため。`rm /etc/nginx/sites-enabled/default && systemctl reload nginx` で解決。
- **Phase 1-E 完了**: Web UI セットアップウィザード完走、Admin ログイン成功、Admin パスワード変更済み。Dashboard で `Zabbixサーバーの起動: はい`、バージョン 7.0.26 "最新バージョン" 表示確認。タイムゾーン Tokyo / 日本語 UI。
- **Phase 1 完了。** Phase 2（PVE API トークン発行 + Proxmox VE テンプレ適用）に着手。
- **Phase 2 トラブル 1（nginx デフォルトサイト）**: 初回 Web UI アクセスでデフォルト nginx の Welcome が表示。`/etc/nginx/sites-enabled/default` が `listen 80 default_server` で動いており、IP直アクセス時に Host ヘッダの server_name 解決で Zabbix の server_name に一致しないため default に流れていた。`rm /etc/nginx/sites-enabled/default && systemctl reload nginx` で解決。
- **Phase 2 PVE 側準備完了**: `monitoring@pve` ユーザー + PVEAuditor ロール、API トークン `monitoring@pve!ztoken`（UUID は 1Password 等の安全な場所に保管推奨、ここには記載しない）を発行。
- **Phase 2 トラブル 2（マクロ不足）**: ホストに 3 マクロ（`{$PVE.URL.PORT}`, `{$PVE.TOKEN.ID}`, `{$PVE.TOKEN}`）だけ設定して、`{$PVE.URL.HOST}` を忘れた。ログに `Proxmox API failed: <SET PVE HOST> Error: cannot get URL: URL using bad/illegal format or missing URL.` で発覚。**教訓: 継承マクロタブで `<SET ...>` 既定値が残っていないか必ず確認すること**。
- **Phase 2 トラブル 3（bash 履歴展開）**: PVE ホストで `curl -H "...!ztoken=..."` を試したら bash の `!` 履歴展開で `event not found`。マクロ設定とは無関係だが、PVE 上で curl テストする時は `'シングルクォート'` または `set +H` を使うべし。
- **Phase 2 トラブル 4（マクロ反映待ち）**: マクロ修正後すぐは「サポート対象外」状態の LLD が再評価されず止まって見えた。**データ収集 → ホスト → ディスカバリ → 実行** で即時再実行が効く（自動 retry は最大 10 分待ち）。
- **Phase 2 完了**: PVE API 接続成功、LLD で VM/CT 群（VMID 100 openmediaVault, 101 mail, 102 puter, 103 Bazzite, 110 k8s-cp1, 120 k8s-worker1 等）を自動展開。
- **Phase 2 チューニング**: 意図的停止の VM/CT（mail, puter, Bazzite, k8s-cp1, k8s-worker1）を LLD フィルタで除外（`{#NAME}` が `^(...)$` にマッチしないもののみ採用）。テンプレに専用フィルタマクロがないので、ホスト側 LLD 規則のフィルタタブで直接設定。
- **Phase 2 で残った宿題**: `{$PVE.TOKEN}` と `{$PVE.TOKEN.SECRET}` の二重定義。`{$PVE.TOKEN.SECRET}` がテンプレ流儀のためそちらに統一推奨（時間がある時に整理）。
- Phase 3（各 LXC への Zabbix Agent 配布）に着手。
- **Phase 3-0 完了（PVE ホスト本体に agent 導入）**: `zabbix-agent2 1:7.0.26-2+debian13` を PVE ホスト (Debian 13/Trixie) に導入。`Server=192.168.11.55`, `Hostname=proxmox`。**ハマりポイント: apt install 直後の auto-start でデフォルト設定 (Server=127.0.0.1, Hostname=Zabbix server) がメモリに乗ったまま、sed 後に restart せず → "connection from 192.168.11.55 rejected, allowed hosts: 127.0.0.1" で接続拒否**。`systemctl restart zabbix-agent2` で解消。**教訓: install → config 編集 → restart をワンセット必須**。
- Zabbix UI で `proxmox` ホストに `Linux by Zabbix agent` テンプレを追加 (既存 `Proxmox VE by HTTP` と並列適用)、緑 ZBX 確認。Items 186→457, Triggers 73→174 に増加。
- **Phase 3 拡張対象判明**: 新発見の稼働中 VM/CT として VMID 106 `pg-db`（PostgreSQL の可能性、メモリ未記録）、VMID 150 `admin-vm`、VMID 100 `openmediaVault` (qemu)。これらは Phase 3 完了後に追加対象として検討。
- **Phase 3 本番（4 LXC へ agent 配布）OS 状況**:
  - 104 dns: Ubuntu 24.04.4 LTS
  - 105 dns2: Ubuntu 24.04.4 LTS
  - 107 step-ca: **Ubuntu 22.04.5 LTS**（他と違う）
  - 108 nextcloud: Ubuntu 24.04 LTS
- **Phase 3 本番 agent インストール完了**: 全 4 CT に `zabbix-agent2 1:7.0.26-2` 配布、active 起動、10050 リッスン、Zabbix CT から疎通 OK。firewall は 4 CT 共に `enable: 0` または未定義のため追加ルール不要。
- **Phase 3 本番 で残作業**: Zabbix Web UI でのホスト登録 4 件（dns, dns2, step-ca, nextcloud）。
- **Phase 3 完了（API 登録）**: Zabbix API (`user.login` → `host.create`) で 4 ホストを一括登録。`Linux servers` グループ（既存 groupid=2）と `Linux by Zabbix agent` テンプレート（templateid=10001）に紐付け。hostid 10684-10687。
- **学んだ業務 Tips**: Zabbix 7.0 API は `user.login` の `username` パラメータ（旧 `user`）、認証は `Authorization: Bearer <token>` ヘッダ推奨（旧 body `auth` フィールドは非推奨化）。インターフェース type は `1=Agent, 2=SNMP, 3=IPMI, 4=JMX`。
- **Phase 3 完了。** Phase 4（サービス層監視）へ進む。
- **Phase 4-A (DNS) 着手**: Technitium DNS の DoT/DoH 監視のため、Zabbix テンプレート `Technitium DNS by Zabbix agent` を作成し dns/dns2 に適用。アイテム 5 + トリガー 5（API 経由でテンプレ・アイテム・トリガー一括作成、host.massadd でリンク）。
- **Phase 4-A トラブル**: 監視適用で「実態とメモリの食い違い」が顕在化。dns/dns2 とも DoT 853 が未稼働、dns2 は DoH 443 も未稼働だった。Technitium UI で DoT/DoH を有効化しようとして:
  - cert を自己署名 PFX で生成し配置
  - Technitium 14.3 → 15.2 にアップグレード
  - PFX の password 不一致 → 既知パスワード `<masked, 24-char hex>` (実値は dns/dns2 LXC の /root/.dns-cert-password 参照) で再生成
  - 15.2 の `BadImageFormatException: Bad IL range` クラッシュを目撃（cert load 失敗の派生）
  - cert path 相対化（UI で絶対パス入力しても `certs/dns.pfx` に正規化）
  - **dns では複数回 Save と restart で動作開始**（`DNS Server TLS certificate was loaded` 確認）
  - **dns2 では同じ手順で再現しても "TLS certificate file does not exists" が出続け、File.Exists() が false を返す**（config 完全同一、PFX 存在＋読み取り可、AppArmor 無し、symlink も配置済み、原因不明）
- **Phase 4-A 部分撤退（業務時間優先）**: dns2 の DoT 853 / DoH 443 監視アイテム・トリガーを無効化。dns2 は通常 DNS (53) と Web UI (5380) のみ監視。dns は DoT/DoH も含めて完全監視。
- **dns2 の DoT/DoH 問題は宿題化**: 後日 Technitium 15.x のバグ報告確認、または別実装（CoreDNS, PowerDNS）への移行検討。
- **Phase 4-A クローズ**、4-B (Nextcloud) と 4-C (step-ca) は別アプローチなので次フェーズで進める。
- **Phase 4-C (step-ca) 完了**: テンプレ `Smallstep step-ca by HTTP` を API で作成、step-ca ホストに適用。
  - `stepca.health` (HTTP agent → JSONPath で `status` 抽出 → JS で 1/0 化)
  - `web.certificate.get[host,port]` (Zabbix agent2 内蔵キー、raw JSON 取得)
  - `stepca.cert.remaining` (依存アイテム、`$.x509.not_after.timestamp` から残秒数計算)
  - Triggers: /health 3 連続失敗で HIGH、cert 残 < 6h で WARN、cert 残 < 1h で HIGH
  - Macros: `{$STEPCA.URL.HOST}=step-ca.home.yagamin.net`, `{$STEPCA.URL.PORT}=443`, `{$STEPCA.CERT.WARN}=21600`, `{$STEPCA.CERT.CRIT}=3600`
- **学び（API テンプレ作成のハマりどころ）**:
  - bash の heredoc-in-`$(...)` は破綻しやすい → **テンプファイル + `curl -d @file`** に分離するのが安定
  - preprocessing の `error_handler` は preprocessing type / item value type の組み合わせで許容値が変わる → JS preprocessing (type=21) では `0` だけ受け付ける場合あり
  - `web.certificate.get` の JSON 構造は `not_after: {value: "May 15...", timestamp: 1778827893}` の**ネスト**。`$.x509.not_after.timestamp` で直接 Unix epoch が取れて JS 不要級にシンプル化できる
  - Trigger 作成は同一テンプレ内のアイテムを参照するので、**アイテムが先に存在しないと FAIL**。順序大事
- **Phase 5-A 完了（ntfy LXC 構築）**: VMID 191 (`ntfy`, 192.168.11.56) を Ubuntu 24.04 で作成。ntfy 2.22.0 を GitHub Release から deb 直 DL でインストール（apt repo の pubkey.txt が 404 だったため）。
  - `/etc/ntfy/server.yml` で `auth-default-access: deny-all`、HTTP 80 で listen
  - `admin` user (role=admin)、`zabbix` user (write-only to topic `zabbix-alerts`) を作成
  - 認証情報は `/root/.ntfy-credentials` に保存（600）
  - Zabbix CT から curl publish テスト成功
  - 注意: 内部 HTTP のため**ブラウザ Web Push は使えない**（Web Push API は HTTPS 必須）。モバイルアプリは HTTP でも push 受信可。将来 step-ca で TLS 化検討。
- **Phase 5-A.2 完了（内部 HTTPS 化）**: step-ca (LXC 107) の JWK admin プロビジョナで `ntfy.home.yagamin.net` の cert を発行（SAN: ntfy.home.yagamin.net, 192.168.11.56、30 日有効）。`/etc/ntfy/certs/ntfy.{crt,key}` に配置、`ntfy:ntfy 644/600`。ntfy server.yml で HTTPS (443) + HTTP (80) 両方 listen 化。Technitium DNS に A レコード追加（手動 UI）。Zabbix CT から `https://ntfy.home.yagamin.net/v1/health` で `200 OK` 確認。
  - 教訓: pct 経由のクロス CT ファイル転送は `pct exec src cat ... | pct exec dst bash -c "cat > ..."` で完結（ホスト経由 file scp 不要）。
- **Phase 5-A.3 完了（CF Tunnel で外部公開）**: 専用 tunnel `ntfy` (UUID `<tunnel-id>`) を CF API で作成。Puter 用 `home-yagamin` トンネルとは別管理（per-LXC 設計のため）。
  - Ingress: `ntfy.yagamin.net` → `https://127.0.0.1:443`（origin TLS は step-ca cert なので `noTLSVerify:true`、Host ヘッダは `ntfy.home.yagamin.net` に書き換え）
  - DNS: `ntfy.yagamin.net` CNAME → `<tunnel_id>.cfargotunnel.com` (CF proxied)
  - cloudflared を ntfy LXC に apt 経由インストール、`cloudflared service install <token>` で systemd 化、4 接続確立 (QUIC, kix04/06/03)
  - 動作確認: 外部 DNS で CF IP 解決 OK、`curl --resolve` で `HTTPS 200`
- **Phase 5-A.3 の知見**:
  - **per-LXC cloudflared は per-tunnel 必須**: 同一 tunnel token で複数 LXC に cloudflared を立てると、CF からのリクエストがランダムにどの connector にも届く可能性があり、各 LXC の `127.0.0.1` が想定外サービスを指す事態に。
  - **split DNS 構成**: 内部 (`ntfy.home.yagamin.net`、Technitium が解決) と外部 (`ntfy.yagamin.net`、CF が解決) で別 FQDN にすると保守が楽。
  - **`yagamin.net` の内部 DNS 解決問題（残課題）**: Technitium が `ntfy.yagamin.net` を NXDOMAIN 相当で返す。内部からの利用は `ntfy.home.yagamin.net` に統一する運用で回避済。原因究明は後日。
- **Phase 5-A.4 完了（Zabbix Media Type "ntfy"）**: HTTP webhook (type=4) で `http://192.168.11.56/zabbix-alerts` に Bearer token 認証 POST。severity → priority マップ、recovery 時は緑タグ。トークンは zabbix user の access token (`<masked-token>...`、自動更新可能)。
- **Phase 5-B 完了（Discord Webhook + Admin に media 設定）**: Zabbix 組込みの Discord template (mediatypeid=39) を再活用。built-in script が `discord_endpoint = {ALERT.SENDTO}` で webhook URL を取得する仕組みなので、Admin の Discord media の sendto に webhook URL を入れる構成。
  - **トラブル**: 試しに我々で `mediatype.update` で parameters を独自命名に上書き → built-in script が読めなくなり「URL value {$ZABBIX.URL} must contain a schema」エラー。built-in 14 parameters を復元、`{$ZABBIX.URL}` グローバルマクロを `http://192.168.11.55` で定義して復旧。
  - 教訓: **Zabbix 7.0 には多数のサービス（Discord, Slack, Telegram, etc.）の組込み媒体テンプレが既存**。自前作成より既存を活用する方が確実。
- **Phase 5-D 完了（通知アクション）**: `action.create` で「All triggers to Admin」を作成（actionid=7）。
  - フィルタ: 「ホストがメンテナンス中でない」のみ（trigger source = 0, conditiontype 16 operator 11、`value` 未指定がポイント）。
  - operations: Admin user に default メッセージ送信 (mediatypeid=0 = 全 media)。
  - recovery_operations: type 11 (notify all involved)、update_operations: type 12 (notify all involved on ack)。
  - 実発火テスト: `last(/Zabbix server/system.uptime)>0` の常時 PROBLEM な test trigger 作成 → ntfy/Discord 両方に通知到達確認。
- **Phase 5-C 完了（Mailgun メール通知）**: Puter LXC の `/opt/puter-selfhosted/puter/config/config.json` から SMTP 認証情報抽出（host=smtp.mailgun.org、port=465、SSL/TLS、user=`<mailgun-sender>`）。
  - Zabbix Email media type "Mailgun" を API で作成 (mediatypeid=73)、`message_templates` で HTML 形式のメール作成（問題/復旧/更新の 3 種）。
  - Admin user に 3 個目の media として追加（送信先 `<your-email>`）。test trigger 再発火で ntfy/Discord/Mailgun 全 3 チャンネル同時到達確認。
  - **業務 TODO**: Mailgun SMTP password と Discord webhook URL は会話履歴に平文残存 → 作業区切り後に rotate 推奨。
- **Phase 5-E スキップ判断**: メンテナンス枠運用は実際にメンテが必要になった時点で設定する方針。基本動作の確認は完了済みのため運用フェーズで対応。
- **Phase 6-A 完了（Zabbix DB 自動バックアップ）**: Zabbix CT (190) 内に `pg_dump -Fc -Z6` を毎日 03:00 JST で実行する cron を作成 (`/etc/cron.d/zabbix-db-backup`)。保管先 `/var/backups/zabbix/`、保持 14 日。初回 dump 5.9 MB。
- **Phase 6-B 完了（PVE vzdump 自動バックアップ）**: jobs.cfg 未設定だったので新規作成。対象 CT: 104,105,106,107,108,190,191（dns/dns2/pg-db/step-ca/nextcloud/zabbix/ntfy）。
  - スケジュール: 毎日 02:00、`schedule` 形式 (systemd timer)
  - storage: store-sdb (686GB 空き)
  - 圧縮: zstd、mode: snapshot (無停止)
  - 保持: keep-daily=7, keep-weekly=4, keep-monthly=6
  - notification-mode: notification-system (PVE 8+ ネイティブ通知)
  - 初回手動実行: ntfy=318 MB, zabbix=554 MB
- **Phase 6-C 完了（Zabbix configuration export）**: `configuration.export` で YAML 6.2 MB、actions/users/global_macros を JSON で個別保存。保存先 `~/zabbix-configs/<日付>/`。Git 管理推奨。
  - 注意: Templates/Applications グループに Zabbix 組込テンプレが多数含まれるため、custom のみで絞りたい場合は templateids: [10688, 10689] 等で個別指定が必要。
- **Phase 6-D 完了**: 本ドキュメントを継続更新。memory 系も別途更新。
- **Phase 6 残課題**:
  - Phase 6-E: Mailgun SMTP password、Discord webhook URL、ntfy zabbix user token、Zabbix Admin パスワードのローテーション
  - Zabbix DB backup を **外部ストレージ (store-sdb 等) に同期** すれば DR 強化（zabbix CT 自体が壊れても復旧可能）。今回は CT 内に置いたのみ。
  - vzdump backup の **オフサイト退避** (Cloud, NAS) は別途

## 7. 全体まとめと運用引き継ぎメモ

### システム構成

| 役割 | LXC ID | IP | 備考 |
|---|---|---|---|
| Zabbix Server + Web + DB | 190 | 192.168.11.55 | Zabbix 7.0 LTS + nginx + PostgreSQL 16, Ubuntu 24.04 |
| ntfy notification server | 191 | 192.168.11.56 | ntfy 2.22.0, HTTPS (step-ca cert), CF tunnel 公開 `ntfy.yagamin.net` |
| 監視対象 (Linux agent) | 104,105,107,108,190 | (各 IP) | DNS, step-ca, Nextcloud, Zabbix self |
| 監視対象 (HTTP API) | (PVE 192.168.11.11) | - | `Proxmox VE by HTTP` テンプレ, monitoring@pve!ztoken |

### 通知経路

- **ntfy** (mediatypeid=72): モバイル push、トピック `zabbix-alerts`、Bearer token 認証
- **Discord** (mediatypeid=39): チャンネル `home.yagamin.net` Webhook
- **Mailgun** (mediatypeid=73): メール `<your-email>`、SMTP via smtp.mailgun.org:465 SSL
- **アクション**: 「All triggers to Admin」(actionid=7) が全 trigger を捕捉 → Admin の 3 media すべてに配信

### 主要トラブル & 教訓

| Phase | トラブル | 教訓 |
|---|---|---|
| 1-D | install.sh 後すぐ apt 失敗 | LXC は新規でも `apt update` 必須 |
| 1-D | Zabbix 8.0 が alpha だけ公開 | バージョン選定は `Packages` index 内まで確認 |
| 1-E | nginx default サイトが port 80 横取り | `sites-enabled/default` 削除で解消 |
| 2 | PVE テンプレで `<SET PVE HOST>` プレースホルダ忘れ | `{$PVE.URL.HOST}` 必須、継承マクロタブで `<SET ...>` 残存チェック |
| 3 | systemd 255 警告でハマり | LXC `features=nesting=1` を Ubuntu 24.04 で付与 |
| 3 | agent install 後の auto-start が前 config で動く | **install → conf 変更 → restart** をワンセットに |
| 4-A | Technitium DoT/DoH cert 設定で BadImageFormatException | 業務的判断で dns2 撤退、宿題化 |
| 5-A | ntfy 内部 HTTPS で `{$ZABBIX.URL}` 未定義エラー | グローバルマクロ事前定義 |
| 5-B | Discord 組込テンプレを我々が parameters 上書きして壊した | **既存テンプレを使う場合は parameters いじらない**、必要なら別名で新規作成 |
| 5-D | `mediatype.test` が Zabbix 7.0 API に存在しない | UI のテストボタン使用、または実 trigger で確認 |

### 業務本番化チェックリスト

- [ ] Zabbix Admin パスワード強度（既に強化済か再確認）
- [ ] Mailgun SMTP credential のローテーション (Mailgun ダッシュボード)
- [ ] Discord webhook URL のローテーション (Discord チャンネル設定)
- [ ] ntfy zabbix user token のローテーション + media type 更新
- [ ] バックアップを外部ストレージに同期するスクリプト (rsync, restic, rclone 等)
- [ ] PVE firewall 再有効化検討（現状 enable: 0）
- [ ] Phase 4-B: Nextcloud 監視（未対応）
- [ ] dns2 の DoT/DoH 再有効化検討（Technitium 15.x の挙動次第）

### 参考リンク

- Zabbix 7.0 ドキュメント: <https://www.zabbix.com/documentation/7.0/>
- ntfy ドキュメント: <https://docs.ntfy.sh/>
- Proxmox VE 9 ドキュメント: <https://pve.proxmox.com/pve-docs/>
- step-ca: <https://smallstep.com/docs/step-ca/>

## 8. 運用知見メモ（継続追加）

### 2026-05-15: 地理マップ (Geomap) widget の調査

- **用途**: ホスト Inventory に latitude/longitude を設定すると、リアルマップ上にホストをプロット
- **業務的価値**: 複数拠点・複数 DC・グローバル展開で真価を発揮、シングル拠点ホームラボでは装飾的
- **デフォルト中心はラトビア (Riga = Zabbix 本社)**、座標設定されたホストがゼロの場合の挙動
- **設定方法**:
  - Per-host: データ収集 → ホスト → Inventory タブ → Location lat/lon
  - System default: 管理 → 一般設定 → 地理マップ（タイルプロバイダ、デフォルト中心、最大ズーム等）
- **API 一括設定**: `host.update` の `inventory.location_lat`/`location_lon` で全ホストに座標投入可
- **タイルプロバイダ**: デフォルト OSM (無料)、Mapbox/MapTiler は有料
- **実施 (2026-05-15)**: 全ホストに座標 `<masked-location> (lat=<masked-lat>, lon=<masked-lon>)` を API 一括設定。スクリプト保存先: [/home/t-ando/proxmox-zabbix-set-host-location.sh](/home/t-ando/proxmox-zabbix-set-host-location.sh)。今後の拠点増設時はこのスクリプトをコピペで複製、`LAT/LON/LOCATION` を編集 → 該当 host group に絞って実行が可能。


<!-- 以降、作業を進めるごとに追記 -->

## 6. 参考リンク

- Zabbix 公式: <https://www.zabbix.com/>
- 公式ドキュメント (最新版): <https://www.zabbix.com/documentation/current/>
- Proxmox VE by HTTP テンプレート: <https://www.zabbix.com/integrations/proxmox>
- インストールガイド: <https://www.zabbix.com/download>
