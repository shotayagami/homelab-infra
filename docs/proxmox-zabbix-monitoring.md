# Proxmox 環境の死活監視 — Zabbix 導入記録

最終更新: 2026-05-16

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
- **2026-05-19 dns2 DoT/DoH + 両ノード admin UI HTTPS (53443) 一括復旧**: 根本原因は Technitium 自体ではなく **バイナリ config 中の cert path フィールド末尾に literal タブ (0x09) が混入** していた点 (例: dns2 で `\x00\x0fcerts/dns2.pfx\t` で length=15 + tab 含む 15 文字)。`File.Exists("...pfx\t")` が false 返却するため cert load 失敗 → TLS bind skip。Technitium 15.x の Web UI で cert path を入力した際の trim 漏れ後遺症と推測。
  - `/etc/dns/dns.config` (DoT/DoH 用): dns2 のみ被害、binary patch (1 byte 減) で復旧、TLSv1.3 handshake と DoH `/dns-query` HTTP 200 を確認、Zabbix item 51661/51662 + trigger 25589/25590 を `status=0` に再有効化
  - `/etc/dns/webservice.config` (admin UI HTTPS 用): 両ノードに同種の trailing-tab + さらに **password フィールドが空** という二重バグあり。cert path 修正に加えて空 password を 24 byte 注入する必要があった (`CryptographicException: ... password may be incorrect` 経由で判明)。両ノードで `[::]:53443` HTTPS bind 成功、`curl -sk https://...:53443/` で HTTP 200 確認
  - 詳細は [internal-dns.md §6](internal-dns.md#6-dns2-の-dotdoh-2026-05-19-復旧)
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

| 役割 | VMID/CTID | 種別 | IP | 備考 |
|---|---|---|---|---|
| Zabbix Server + Web + DB | 190 | LXC | 192.168.11.55 | Zabbix 7.0 LTS + nginx + PostgreSQL 16, Ubuntu 24.04 |
| ntfy notification server | 191 | LXC | 192.168.11.56 | ntfy 2.22.0, HTTPS (step-ca cert), CF tunnel 公開 `ntfy.yagamin.net` |
| 監視対象 (Linux agent, LXC) | 104, 105, 106, 107, 108, 190 | LXC | (各 IP) | dns, dns2, pg-db (2026-05-16 追加), step-ca, nextcloud, Zabbix self |
| 監視対象 (Linux agent, VM) | 100, 110, 120 | VM | (各 IP) | openmediaVault (2026-05-18 Phase 1 追加), k8s-cp1, k8s-worker1 (Phase 4-D 追加) |
| 監視対象 (HTTP API: PVE) | — | host | 192.168.11.11 | `Proxmox VE by HTTP` テンプレ, monitoring@pve!ztoken |
| 監視対象 (HTTP API: k8s) | `k8s-cluster` (10692) | virtual | https://192.168.11.80:6443 | `Kubernetes cluster state by HTTP` テンプレ、ServiceAccount + permanent token、3397 items |
| 監視対象外 | 102, 150, 191 | LXC/VM | — | puter / admin-vm / ntfy は Zabbix host 未登録 (PVE LLD の discovered items のみ)。mail (101) は stopped |

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
| 4-A | Technitium DoT/DoH cert 設定で BadImageFormatException | 業務的判断で dns2 撤退、宿題化 → **2026-05-19 復旧**: dns.config バイナリの cert path に literal タブ混入が真因 ([internal-dns.md §6](internal-dns.md#6-dns2-の-dotdoh-2026-05-19-復旧)) |
| 5-A | ntfy 内部 HTTPS で `{$ZABBIX.URL}` 未定義エラー | グローバルマクロ事前定義 |
| 5-B | Discord 組込テンプレを我々が parameters 上書きして壊した | **既存テンプレを使う場合は parameters いじらない**、必要なら別名で新規作成 |
| 5-D | `mediatype.test` が Zabbix 7.0 API に存在しない | UI のテストボタン使用、または実 trigger で確認 |
| 4-D | `Kubernetes cluster state by HTTP` の Script item が pod IP (10.42.x.x) に直接 HTTP → クラスタ外から到達不可で KSM 系 LLD が全滅 | Zabbix LXC に `10.42.0.0/24 via cp1`, `10.42.1.0/24 via worker1` の static route を入れる。systemd oneshot で永続化 |
| 4-D | KSM `/metrics` が 1.6MB と大きく Zabbix 7.0 default の 3s timeout で切れる | global `timeout_script=30s`, `timeout_http_agent=30s`, `connect_timeout=10s`, `socket_timeout=30s` に引き上げ |
| 4-D | 計画 reboot で leader-elect 系コントローラの crashloop alert が大量に湧く | テンプレ側 LLD override (`Suppress crashloop alerts for leader-elected controllers`) + 計画作業時は `maintenance.create` で 抑止 |
| 4-D | cp1 の etcd で `slow fdatasync` 多発 → controller の self-exit | VM 110 raw を Fanxiang QLC (store-sdb) → NVMe (local-lvm) に `qm move-disk` でオンライン移行。詳細は §8 |

### 業務本番化チェックリスト

> 残タスクの一覧は [remaining-tasks.md](./remaining-tasks.md) で別途集約管理。

- [ ] Zabbix Admin パスワード強度（既に強化済か再確認）
- [ ] Mailgun SMTP credential のローテーション (Mailgun ダッシュボード)
- [ ] Discord webhook URL のローテーション (Discord チャンネル設定)
- [ ] ntfy zabbix user token のローテーション + media type 更新
- [ ] バックアップを外部ストレージに同期するスクリプト (rsync, restic, rclone 等)
- [ ] PVE firewall 再有効化検討（現状 enable: 0）
- [x] ~~Phase 4-B: Nextcloud 監視~~ → 2026-05-15 完了 (§8.2 参照)
- [x] ~~Phase 4-D: RKE2 クラスタ監視~~ → 2026-05-16 完了 (§8.5 参照)
- [x] ~~dns2 の DoT/DoH 再有効化検討（Technitium 15.x の挙動次第）~~ → **2026-05-19 復旧完了** ([internal-dns.md §6](internal-dns.md#6-dns2-の-dotdoh-2026-05-19-復旧))

### 参考リンク

- Zabbix 7.0 ドキュメント: <https://www.zabbix.com/documentation/7.0/>
- ntfy ドキュメント: <https://docs.ntfy.sh/>
- Proxmox VE 9 ドキュメント: <https://pve.proxmox.com/pve-docs/>
- step-ca: <https://smallstep.com/docs/step-ca/>

## 8. 運用知見メモ（継続追加）

### 2026-05-15: Phase 4-B Nextcloud 監視 (Issue #1)

#### 経緯と詰まりポイント
- Nextcloud 側で監視用 app password 発行を試みたが、admin パスワードが不明 → **専用ユーザ `zabbix-monitor` を `occ user:add --group=admin` で新設** (鍵分離の原則、Issue #2 で扱った rotation 容易性のため)
- ログイン画面が「読み込み中」のまま固まる → 原因は **`/mnt/omv/nas/*` を指す壊れた `files_external` mount 3 件** が apache worker を詰まらせていた。`occ files_external:list` で発見、`files_external:delete` で除去後 restart で復旧 (load avg 9.44 → 1.90)
- Zabbix 7.0 LTS には Nextcloud HTTP テンプレが**初期インポートされていない** → `git.zabbix.com` の release/7.0 archive を tar.gz で取得 (`/rest/api/1.0/.../archive?at=refs%2Fheads%2Frelease%2F7.0&format=tar.gz`)、`templates/app/nextcloud/template_app_nextcloud_http.yaml` を抽出 → Zabbix API `configuration.import` で投入
- 初実装の apply スクリプトは macro 名を upstream と取り違えて（`URL/USER/PASSWORD/SSL_VERIFY_*` と推測） → 実際は `ADDRESS/SCHEMA/USER.NAME/USER.PASSWORD`。スクリプト修正後に再実行
- `jq -Rs .` を heredoc 入力に使うと末尾改行が string 値に混入し `Invalid parameter "/1/macro": incorrect syntax near "\n"` で API が拒否 → `jq -nc --arg key val '...'` 形式に書き換えて解消

#### 反映内容
- Zabbix host `nextcloud` (hostid=10687) に template `Nextcloud by HTTP` (templateid=10602) を `host.massadd` で追加 link (既存 Linux テンプレ温存)
- Host macros 4 件 upsert:
  - `{$NEXTCLOUD.ADDRESS}` = `nextcloud.home.yagamin.net`
  - `{$NEXTCLOUD.SCHEMA}` = `https`
  - `{$NEXTCLOUD.USER.NAME}` = `zabbix-monitor`
  - `{$NEXTCLOUD.USER.PASSWORD}` = (Secret text)

#### 動作確認 (実証)
- nextcloud.* item 全件 state=0 (正常)。例: active_users.last1h=2, apps.installed=49, db.version=11.8.6 (MariaDB), freespace=25.8GB
- LLD: `nextcloud.user.discovery` rule active、計 59 discovered items (Linux テンプレ由来含む)
- Triggers 実発火 3 件 → 既存 action "All triggers to Admin" 経由で **ntfy / Discord / Mailgun 3 系統に正常配信** (initial build 以来の実 trigger による初の通知系 end-to-end 検証):
  - Nextcloud: Application updates are available (Warning)
  - Nextcloud: Server not up to date (Information)
  - Nextcloud: User "admin": inactive over 30 days (Information)

#### 残る関連タスク (別 Issue 化候補)
- `zabbix-monitor` の app password はチャットに平文露出したのでローテ必須 (運用引き継ぎ後に実施)
- `files_external` で削除した 3 mount は backup `/root/nc-files_external-backup-20260515.json` 保管。NAS 再構築時の参考用
- NC33 系で `-dev.0` 末尾の app バージョンが多数 → nightly/RC channel? 安定版運用への切替検討
- Zabbix server が `nextcloud.home.yagamin.net` への HTTPS 接続に成功している = 何らかの形で step-ca CA を信頼しているか、HTTP agent 側の SSL_VERIFY が無効。詳細は未確認 (調査タスク化候補)

### 2026-05-15: Zabbix UI を CF Tunnel + Access で外部公開 (Issue #7)

#### 構成
```
[Browser] --HTTPS--> [CF Edge] --HTTPS--> [cloudflared in LXC 190] --HTTP--> [nginx :80] --> Zabbix
                              ↑
                       CF Access (One-time PIN) で先に email 認証
```

- 公開 FQDN: `zabbix.yagamin.net`
- Tunnel: 名前 `zabbix` (id `edbe2625-...`)、CF Dashboard で事前作成済の tunnel をスクリプトが API 経由で発見・利用
- Access app `Zabbix (zabbix.yagamin.net)`、policy `Allow listed emails`
- Access 許可 email domain: `nekomin.jp / yagamin.net` (`.env` の `CF_ACCESS_INCLUDE_EMAIL_DOMAINS`)
- cloudflared を LXC 190 内 systemd service として常駐

#### 成果物
- [scripts/proxmox-deploy-zabbix-cloudflare-access.sh](../scripts/proxmox-deploy-zabbix-cloudflare-access.sh) — Tunnel/Access/DNS を CF API で冪等構成、`.env` を読み込んで `bash` 1 発で完了
- puter スクリプトと同じヘルパー (`cf_api`, `ensure_access_app`, `ensure_access_policy`) を移植

#### 2FA (TOTP) 追加
- システム全体で MFA 有効化 + method `ZABBIX YAGAMIN.COM` (TOTP/SHA-1/6 桁)
- User group `Zabbix administrators` に MFA method を紐付け
  - **UI からは「多要素認証: Disabled」のラベルがクリックできず編集不可だった**
  - `usergroup.update` API で `mfaid` と `mfa_status` を直接更新して回避:
    ```json
    {"usrgrpid":"7","mfaid":"2","mfa_status":1}
    ```
- Admin で再ログインすると TOTP QR + Base32 シークレット表示 → 認証アプリ登録 + 1Password に秘密鍵保管 (lock-out 保険)
- 以降は password + 6 桁コードの 2 段認証

#### Defense-in-depth の残課題 (Issue #8)
- 経路最後の `cloudflared -> nginx:80` は同一 LXC 内 loopback とはいえ HTTP
- LAN 内から `192.168.11.55:80` に直接アクセス可能
- → step-ca 証明書で nginx を HTTPS 化する作業を Issue #8 で別途トラッキング (Nextcloud LXC 108 と同型)

### 2026-05-15: Zabbix nginx を step-ca 証明書で内部 HTTPS 化 (Issue #8)

#### 動機
- Issue #7 で外部公開 (CF Tunnel + Access) を実現したが、LAN 内 `192.168.11.55:80` は平文のまま
- 他 LXC が侵害された場合の横展開耐性を上げるため、Nextcloud と同型の step-ca cert で nginx を HTTPS 化

#### 構成
```
LAN client  ──HTTP 80──► 192.168.11.55:80  ─301─► https://zabbix.home.yagamin.net
LAN client  ──HTTPS────► 192.168.11.55:443 (step-ca cert) ──► Zabbix php
CF Tunnel   ──HTTP 80──► 127.0.0.1:80      (loopback only)  ──► Zabbix php
```

#### 反映内容

| 項目 | 詳細 |
|---|---|
| 内部 DNS | Technitium に A レコード `zabbix.home.yagamin.net → 192.168.11.55` 追加 (dns/dns2 両系) |
| step CLI | LXC 190 に smallstep deb 導入、CA bootstrap (URL `https://step-ca.home.yagamin.net`, fingerprint `31b8...`) |
| 証明書 | `step ca certificate` で `zabbix.home.yagamin.net` 用、SAN `192.168.11.55` 込み、寿命 30 日 |
| 証明書配置 | `/etc/nginx/ssl/zabbix.{crt,key,ca.crt}` (key は 0600) |
| nginx 設定 | `/etc/nginx/conf.d/zabbix.conf` の symlink を `.symlink.bak` に退避し、3 server block の実体ファイルへ:<br>1. `listen 127.0.0.1:80` (CF Tunnel 専用、平文 OK)<br>2. `listen 192.168.11.55:80` → 301 to `https://zabbix.home.yagamin.net`<br>3. `listen 443 ssl http2` (step-ca cert) |
| 自動更新 daemon | `step-renew-zabbix.service` (systemd) で 5 日前 (`--expires-in 120h`) renewal + nginx reload。`ProtectHome=read-only` 必須 ([[proxmox-step-ca-nextcloud]] と同じ罠)。リポジトリ内コピー: [scripts/systemd-units/step-renew-zabbix.service](../scripts/systemd-units/step-renew-zabbix.service) |

#### 詰まりポイント
- **nginx 1.24.0 (LXC 190 同梱) は `http2 on;` 未対応** → 旧 syntax `listen 443 ssl http2;` で記述
- **`systemctl reload nginx` では既存 socket (0.0.0.0:80) を引きずる** → bind 構成が変わるケースは `systemctl restart nginx` 必須
- ssh 経由の heredoc 入れ子 quote で破綻 → ローカルにファイル書いて `cat | ssh ... 'cat > /tmp/xxx'` → `pct push` の 2 段階に分けると安全

#### 動作確認 (3 経路)

| 経路 | 結果 |
|---|---|
| CF Tunnel loopback → `http://127.0.0.1/` | `HTTP/1.1 200 OK` (Zabbix 直接応答) |
| LAN HTTP → `http://192.168.11.55/` | `HTTP/1.1 301 Moved Permanently` (Location: https://zabbix.home.yagamin.net/) |
| LAN HTTPS → `https://zabbix.home.yagamin.net/` | `HTTP/2 200` (TLS 終端、step-ca cert) |
| 外部 → `https://zabbix.yagamin.net/` (CF Tunnel 経由) | dashboard 到達確認 |

#### 残課題
- `/etc/nginx/conf.d/zabbix.conf.symlink.bak` は退避ファイル、package 更新時の rollback 起点として保持

#### Issue #8 完了後の修正 (Issue #10 作業中に発見)
- **cert に hostname の SAN が抜けていた**: 初回の `step ca certificate zabbix.home.yagamin.net /etc/nginx/ssl/zabbix.{crt,key} --san 192.168.11.55` では、positional 引数の subject (CN) が SAN に自動追加されない挙動。curl は RFC 6125 で SAN 必須なので "no alternative certificate subject name matches" で TLS 検証失敗。
- **対処**: `--san zabbix.home.yagamin.net --san 192.168.11.55` を**両方明示**して再発行。step-renew-zabbix.service も restart。
- **教訓**: step CLI で cert を発行する際は subject (CN) も常に `--san` で明示すること。

#### admin-vm への CA 信頼インストール (Issue #10 動作確認のため実施済)
- `/etc/nginx/ssl/ca.crt` を `/usr/local/share/ca-certificates/home-yagamin-ca.crt` に配置 → `sudo update-ca-certificates`
- 同じ Root CA で署名された Nextcloud 等の他サービスにも curl が `-k` なしでアクセス可能になった

#### クライアント側の追加対応 (任意、未実施)
- step-ca の Root CA は Windows / macOS の信頼ストアに**入っていない**ため、ブラウザは「保護されていない接続」と表示する (実際は TLS だが chain 検証不可)
- Edge の InPrivate モードは特にこれを「HTTPS 非サポート」扱いに見せる
- 解決: `/etc/nginx/ssl/ca.crt` (= step-ca Root CA) を `home-yagamin-ca.crt` 等として書き出し → Windows の `信頼されたルート証明機関` にインポート
- 同じ Root CA で署名された Nextcloud 等の他サービスも同時に警告なしになる
- 外部 (`https://zabbix.yagamin.net` 経由 CF Tunnel) は CF 発行証明書なので影響なし、インポート不要
- 現状: 検証環境なので未実施、本格運用したくなったタイミングでクライアント PC ごとに導入

### 2026-05-15: 地理マップ (Geomap) widget の調査

- **用途**: ホスト Inventory に latitude/longitude を設定すると、リアルマップ上にホストをプロット
- **業務的価値**: 複数拠点・複数 DC・グローバル展開で真価を発揮、シングル拠点ホームラボでは装飾的
- **デフォルト中心はラトビア (Riga = Zabbix 本社)**、座標設定されたホストがゼロの場合の挙動
- **設定方法**:
  - Per-host: データ収集 → ホスト → Inventory タブ → Location lat/lon
  - System default: 管理 → 一般設定 → 地理マップ（タイルプロバイダ、デフォルト中心、最大ズーム等）
- **API 一括設定**: `host.update` の `inventory.location_lat`/`location_lon` で全ホストに座標投入可
- **タイルプロバイダ**: デフォルト OSM (無料)、Mapbox/MapTiler は有料
- **実施 (2026-05-15)**: 全ホストに座標 `<masked-location> (lat=<masked-lat>, lon=<masked-lon>)` を API 一括設定。スクリプト保存先: [/home/shotayagami/proxmox-zabbix-set-host-location.sh](/home/shotayagami/proxmox-zabbix-set-host-location.sh)。今後の拠点増設時はこのスクリプトをコピペで複製、`LAT/LON/LOCATION` を編集 → 該当 host group に絞って実行が可能。

### 2026-05-16: Phase 4-D RKE2 クラスタ監視

#### 経緯
- PVE 上の RKE2 クラスタ (VMID 110 `k8s-cp1` / VMID 120 `k8s-worker1`、v1.34.3-rke2r3) が **97 日稼働で 23 Helm release / ~110 pods** を抱える「検証環境という名の小規模本番級」状態で、PVE ホストの memory peak 92.9% / load 12.46 まで跳ねる事態だった
- Zabbix で pod 単位までメトリクスを取れるようにして最適化作業 (Phase 0/1/2) の効果検証ができる土台を作る、というのが本フェーズのゴール

#### 反映内容 (3 段構成)

**Layer 1: Linux agent 監視 (k8s-cp1 / k8s-worker1)**
- 両 VM に `zabbix-agent2 1:7.0.26-2+ubuntu22.04` 導入、`Server=192.168.11.55` / `Hostname=k8s-cp1`,`k8s-worker1`
- Zabbix host: `k8s-cp1` (hostid=10690), `k8s-worker1` (hostid=10691)
- Group: `Linux servers` (groupid=2)、Template: `Linux by Zabbix agent` (templateid=10001)

**Layer 2: Kubernetes by HTTP テンプレ (k8s-cluster ホスト)**
- Zabbix host: `k8s-cluster` (hostid=10692)、Group: `Kubernetes` (groupid=23, 新規)
- Template: `Kubernetes cluster state by HTTP` (templateid=10510) + 5 サブテンプレ
- ServiceAccount: `monitoring/zabbix-monitoring` + 専用 ClusterRole (nodes/services/services/proxy ほか全 read 系)
- 永続 token Secret: `monitoring/zabbix-monitoring-token` (RKE2 v1.34 で動作)
- マクロ:
  - `{$KUBE.API.URL}` = `https://192.168.11.80:6443`
  - `{$KUBE.API.TOKEN}` = Secret macro
  - `{$KUBE.STATE.ENDPOINT.NAME}` = `prometheus-stack-kube-state-metrics`
- 結果: **LLD で 3397 items 自動生成** (pod / namespace / deployment / PV / kubelet 系含む)

**Layer 3: Cilium pod network への static route (ハマりポイント)**
- 公式テンプレの Script item は `endpoints` API で取った **pod IP (10.42.0.x) に直接 HTTP** する設計。クラスタ外の Zabbix LXC から pod 網に到達できず、最初は KSM 系 LLD が `cannot get URL: Timeout was reached` で全滅
- 解決: Zabbix LXC (190, 192.168.11.55) に static route を追加
  ```
  10.42.0.0/24 via 192.168.11.80  (cp1)
  10.42.1.0/24 via 192.168.11.83  (worker1)
  ```
- 永続化: systemd oneshot `/etc/systemd/system/k8s-pod-routes.service` (After=network-online.target、`ip route replace ...` を ExecStart)。リポジトリ内コピー: [scripts/systemd-units/k8s-pod-routes.service](../scripts/systemd-units/k8s-pod-routes.service)
- RKE2 default Cilium は外部からの forward traffic を許可していたので route だけで開通。BGP / native routing 不要

#### Global timeout 調整
- 公式テンプレが大きい KSM `/metrics` (1.6MB, 11127 行) を回すので、Zabbix 7.0 の global timeout を引き上げ:
  - `timeout_script` = 30s (元 3s)
  - `timeout_http_agent` = 30s
  - `connect_timeout` = 10s
  - `socket_timeout` = 30s
- 他テンプレを増やす際もこの設定は流用可能

#### 教訓
- 「KSM 系だけタイムアウト」が出たら **pod IP への経路が無い** ことを疑う。`curl http://<pod-IP>:8080/metrics` を Zabbix LXC から打って即判定可能
- token はチャットに貼らない。`/root/.zabbix-k8s-token` (chmod 600) に保管、必要に応じてローテ
- 関連 memory: `proxmox_zabbix_k8s_monitoring.md`, `proxmox_rke2_cluster.md`

### 2026-05-16: cp1 etcd slow fdatasync 解消 (VM disk live migration)

#### 観測されたパターン
- Phase 4-D 監視を入れた直後の 2026-05-16 15:30 JST、Zabbix から RKE2 cluster の crashloop alert が **9 件連続発火 → 10 分で resolved**
- cp1 (VMID 110) で `etcd` の WAL `slow fdatasync` が 1〜10 秒で頻発（5.5h で 46 件、毎時 1〜8 件のペース）
- 連続 5〜10 秒の fsync 遅延が発生 → leader-elect renew deadline (10s) を超え、**リーダー選出系コントローラが exit 1 → kubelet が即再起動** という挙動
- 巻き込まれる pod: `kube-controller-manager`, `kube-scheduler`, `cloud-controller-manager`, `rke2-snapshot-controller`, `kyverno-{admission,background,cleanup,reports}-controller`, `cilium-operator-*`, `longhorn` の `csi-snapshotter` / `external-attacher`
- **etcd / kube-apiserver / VM は再起動していない**、controller の self-exit だけ

#### 根本原因
- PVE host の `/dev/sdb` (`store-sdb`) は **Fanxiang S101Q 1TB SATA SSD** (consumer DRAMless QLC 級)
- そこに VM 110 raw (200G, etcd WAL を含む) + VM 120 raw (250G, Longhorn replica を含む) + LXC backup dump が同居
- consumer QLC は持続 fsync が弱く、複数 writer 競合で秒オーダーの遅延が発生

#### 実施した対応 (3 段)

1. **vm-health-monitor の VMID 121 ターゲット停止** — PVE ホストの `/etc/vm-health-monitor/targets.conf` で `121 vm 192.168.11.84 k8s-worker2` 行をコメントアウト (存在しない VM を毎分 ping → `qm reset` 失敗が大量ログを出していた)。`systemctl restart vm-health-monitor.service` で反映

2. **Zabbix crashloop アラートで leader-election 系を除外** — `Kubernetes cluster state by HTTP` テンプレ (itemid=40029) の Pod discovery に LLD override 1 件追加 (`Suppress crashloop alerts for leader-elected controllers`)
   - `{#NAME}` 正規表現で `kube-(controller-manager|scheduler)`, `cloud-controller-manager`, `cilium-operator-`, `kyverno-*-controller-`, `rke2-snapshot-controller-`, `csi-(snapshotter|attacher|resizer|provisioner)-` に match → trigger prototype `Pod is crash looping` を `opdiscover.discover=1` で生成抑止
   - 既存 22 件の discovered trigger は `task.create type=6` で LLD 即時再評価し自動消滅
   - **編集場所はテンプレ側 (10510)**。ホスト側 (53126) は read-only

3. **VM disk のオンラインライブ移行 (qm move-disk)**
   - VM 110 (k8s-cp1): `qm move-disk 110 scsi0 local-lvm --delete 1` で online live mirror、3 分 39 秒で完了。VM/etcd ともに無停止 (etcd container attempt は 18 のまま)
   - VM 120 (k8s-worker1): `qm move-disk 120 scsi0 store-sda --delete 1` で 5 分 34 秒。store-sda は SPCC SSD 512GB (fsync ベンチで Fanxiang の約 2 倍)。worker1 / Longhorn ともに無停止、volume 全部 healthy 維持

#### 最終的な物理配置 (2026-05-16 終了時)

| デバイス | 容量・銘柄 | 用途 | 使用 |
|---|---|---|---|
| `nvme0n1` | Samsung 970 EVO Plus 1TB | PVE root + local-lvm 上の全 LXC + cp1 (200GB) | 173GB |
| `sda` (store-sda) | SPCC SSD 512GB | worker1 (250GB) | 147GB / 残 318GB |
| `sdb` (store-sdb) | Fanxiang QLC 1TB | **vzdump backups のみ** | 66GB / 残 867GB |

- cp1 (etcd ホスト) と worker1 (Longhorn replica ホスト) が物理 disk レベルで分離
- Fanxiang は事実上バックアップ専用に格下げ

#### 結果
- cp1 移行完了 (07:13:24 UTC) から 9 分時点で `slow fdatasync` イベント 0 (移行前は 6h で 46 件)
- 解消の見込み大、最終確認は数時間後の経過観察で

#### 教訓 / How to apply
- Zabbix で似た crashloop バースト alert が来たら、**VM や etcd が落ちたわけではない** ことを最初に切り分け:
  1. `kubectl -n kube-system get pods` で `*-k8s-cp1` 系の RESTARTS と `(Nm ago)` を確認
  2. `etcd-k8s-cp1` / `kube-apiserver-k8s-cp1` の RESTARTS が増えていないことを確認（これらが増えていれば別問題）
  3. etcd container log を `crictl logs` で取り `grep "slow fdatasync"` で頻度確認
- 設定の場所:
  - vm-health-monitor 本体: `/usr/local/bin/vm-health-monitor.sh`、設定: `/etc/vm-health-monitor/targets.conf`、unit: `/etc/systemd/system/vm-health-monitor.service`
  - Zabbix API は `ZBX_API_TOKEN` (`~/.env`) + `https://192.168.11.55/api_jsonrpc.php` (Authorization: Bearer)
- 計画 reboot 時は host を maintenance window に入れて alert 抑止 (override で抑止していない DaemonSet/StatefulSet 系 = longhorn-manager, longhorn-csi-plugin, metallb-speaker, alertmanager 等で crashloop alert が発火する):
  ```bash
  NOW=$(date +%s); END=$((NOW + 1800))
  source ~/.env
  curl -sL -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $ZBX_API_TOKEN" \
    https://192.168.11.55/api_jsonrpc.php -k -d "{
      \"jsonrpc\":\"2.0\",
      \"method\":\"maintenance.create\",
      \"params\":{
        \"name\":\"cp1 planned reboot $(date -Iseconds)\",
        \"active_since\":$NOW,
        \"active_till\":$END,
        \"maintenance_type\":1,
        \"hosts\":[{\"hostid\":\"10690\"},{\"hostid\":\"10692\"}],
        \"timeperiods\":[{\"timeperiod_type\":0,\"start_date\":$NOW,\"period\":1800}]
      },\"id\":1}"
  # 10690=k8s-cp1, 10691=k8s-worker1, 10692=k8s-cluster
  # maintenance_type 1=no data collection (alert+データ両方止め), 0=alert のみ止め
  ```
- SPCC SSD (store-sda) も consumer 級なので、worker1 のワークロードが重くなったら NVMe (local-lvm 残 562GB) への退避が次の手
- 関連 memory: `proxmox_rke2_etcd_fsync.md`, `proxmox_rke2_cluster.md`

### 2026-05-16: KubeJobFailed 過渡的失敗の掃除 (運用ノート)

- Phase 0/1/2 最適化 (VM 再起動 + Longhorn replica patch 等) の時間帯に、`backups/mariadb-backup`, `backups/redis-backup`, `longhorn-system/daily-snapshot`, `longhorn-system/weekly-snapshot` の各 1 回が **Failed** 状態で残った
- いずれも後続ジョブは Complete、CronJob は SUSPEND=False で健全 → 過渡的失敗で確定
- 対処: `kubectl -n <ns> delete job <name>` で 4 件削除して `KubeJobFailed` alert を resolve
- 教訓: 大規模オペレーション (VM 再起動 / Longhorn replica patch / namespace scale 0) の直後は `kubectl get jobs -A | grep Failed` をワンスショットで掃除する流れにする


<!-- 以降、作業を進めるごとに追記 -->

## 6. 参考リンク

- Zabbix 公式: <https://www.zabbix.com/>
- 公式ドキュメント (最新版): <https://www.zabbix.com/documentation/current/>
- Proxmox VE by HTTP テンプレート: <https://www.zabbix.com/integrations/proxmox>
- インストールガイド: <https://www.zabbix.com/download>
