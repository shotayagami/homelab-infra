# 内部 DNS — Technitium dns / dns2

LAN 内 DNS を **Technitium DNS Server** の Primary / Secondary 構成で運用。DHCP 機能もこれが担当。

## 1. 配置

| ホスト名 | VMID | IP (v4 / v6) | 役割 |
|---|---|---|---|
| `dns` | 104 (LXC) | 192.168.11.53 / fd00:11::53 | Primary、ゾーンマスタ、DHCP |
| `dns2` | 105 (LXC) | 192.168.11.54 / fd00:11::54 | Secondary、ゾーン転送先 |

両 LXC とも Debian ベース、Technitium DNS Server を systemd unit で常駐。

## 2. 有効化している機能

| プロトコル | ポート | 備考 |
|---|---|---|
| 通常 DNS (UDP/TCP) | 53 | LAN 内全クライアント |
| DoT (DNS-over-TLS) | 853 | step-ca 発行証明書を使用、[internal-tls.md](internal-tls.md) |
| DoH (DNS-over-HTTPS) | 443 | 同上 |
| Web 管理 UI | 5380 / 53443 (HTTPS) | LAN 限定 |
| DHCP サーバ | 67 (UDP) | Primary 側のみ稼働、Secondary は待機 |

## 3. 冗長構成

- **ゾーン転送あり**: Primary (`dns`) で編集 → Secondary (`dns2`) に AXFR/IXFR で同期
- クライアントの DNS 設定は両方を渡す (DHCP オプション 6 で `192.168.11.53, 192.168.11.54`)
- Primary がダウンしても Secondary が応答を継続するが、**ゾーン編集と DHCP は止まる**

## 4. PVE Firewall 要件

両 LXC の `/etc/pve/firewall/104.fw` / `105.fw` で共通の最低構成:

```
[OPTIONS]
enable: 1
policy_in: DROP
dhcp: 1

[RULES]
IN ACCEPT -source 192.168.11.0/24 -p udp -dport 53
IN ACCEPT -source 192.168.11.0/24 -p tcp -dport 53
IN ACCEPT -source 192.168.11.0/24 -p tcp -dport 853
IN ACCEPT -source 192.168.11.0/24 -p tcp -dport 443
IN ACCEPT -source 192.168.11.0/24 -p tcp -dport 5380
IN ACCEPT -source 192.168.11.0/24 -p tcp -dport 53443
IN ACCEPT -p udp -dport 67          # DHCP DISCOVER (source 制限なし、後述)
# IPv6 側も同様に fd00:11::/64 から許可
```

NIC 側に `firewall=1` を付けて初めて per-CT firewall が有効化される。**反映には CT 再起動が必要**なので、Primary/Secondary の片方ずつ施工して DNS 継続を担保する (2026-04-18 に実証済み)。

## 5. `dhcp: 1` の罠（重要）

`fw` 設定の `dhcp: 1` オプションは **DHCP クライアント用** で、`udp spt:67 dpt:68` を許可する = 外部 DHCP サーバからの応答を受け取るための設定。

**CT 側を DHCP サーバとして動かす場合はこれだけでは不十分。** `IN ACCEPT -p udp -dport 67` を `[RULES]` に明示追加する必要がある (source 指定なし、DHCP DISCOVER は `0.0.0.0` から来るため source 限定できない)。

**症状**:
- クライアントの DISCOVER が CT に届かない
- `iptables -L -nv | grep <chain>` で `veth<vmid>i0-IN` チェーン末尾の DROP カウンタが増える
- CT 内 `tcpdump -i eth0 port 67 or port 68` で 0 packets

**切り分け**: `sed -i 's/^enable: 1/enable: 0/' /etc/pve/firewall/104.fw` で一時無効化 → DHCP 取得確認 → 原因確定 → RULES に明示追加。

詳細経緯は [proxmox-firewall.md](proxmox-firewall.md) §6 参照。

## 6. dns2 の DoT/DoH (2026-05-19 復旧)

dns2 (LXC 105) の DoT 853 / DoH 443 は長期間停止していたが、2026-05-19 に **dns.config バイナリの cert path フィールド末尾に literal タブ文字 (0x09) が混入** していたことが根本原因と判明し、binary patch で復旧した。

### 症状
起動時ログに以下が出続け、`/etc/dns/certs/dns2.pfx` が確かに存在するにも関わらず Technitium が `File.Exists` で false を返していた:

```
DNS Server encountered an error while loading DNS Server TLS certificate: /etc/dns/certs/dns2.pfx
System.ArgumentException: DNS Server TLS certificate file does not exists: /etc/dns/certs/dns2.pfx
```

結果、`853` (DoT) と `443` (DoH) の bind がスキップされ、`5380` (HTTP) と `53` (DNS) のみで稼働していた。

### 根本原因
`/etc/dns/dns.config` の cert path フィールド (Technitium 独自バイナリ形式、長さプレフィックス + 文字列) が:
- 期待値: `\x00\x0e certs/dns2.pfx` (length=14 + 14 chars)
- 実値: `\x00\x0f certs/dns2.pfx\t` (length=15 + 14 chars + literal タブ)

.NET の `BinaryReader.ReadString` が 15 バイト読み取って `"certs/dns2.pfx\t"` を path として保持 → `File.Exists` 失敗。Technitium 15.x の Web UI で cert path を入力した際の trim 漏れバグの後遺症と推測。

### 修正手順
```bash
# dns2 LXC 内で実施
systemctl stop dns
cp /etc/dns/dns.config /etc/dns/dns.config.bak.$(date +%Y%m%d-%H%M%S)

python3 <<'PY'
with open("/etc/dns/dns.config", "rb") as f: data = f.read()
needle = b"\x00\x0fcerts/dns2.pfx\t"           # length=15, tab 付き
fix    = b"\x00\x0ecerts/dns2.pfx"             # length=14, tab なし
data = data.replace(needle, fix, 1)
with open("/etc/dns/dns.config", "wb") as f: f.write(data)
PY

systemctl start dns
```

### 復旧確認
- `ss -tln`: `0.0.0.0:853` / `:443` / `:53` / `:5380` 全て LISTEN
- `openssl s_client -connect 192.168.11.54:853 -servername dns2.home.yagamin.net`: TLSv1.3 handshake 成功
- DoH curl: `https://dns2.home.yagamin.net/dns-query?dns=...` で `HTTP 200` と DNS message を取得
- Zabbix item 51661 (`DoT TCP/853`) / 51662 (`DoH HTTPS/443`) と trigger 25589/25590 を `status=0` (enabled) に戻し、value=1 (up) を継続取得

### 残課題
`/etc/dns/webservice.config` 側にも同種の trailing-tab バグがあり、両ノードで Web admin UI HTTPS (`53443`) が bind しない。`5380` HTTP で運用しているため触っていないが、HTTPS 化したい場合は同手法で patch 可能。

## 7. クライアント設定の確認

DHCP で配布される DNS 設定をクライアント側で確認:

```bash
# Linux (systemd-resolved)
resolvectl status | grep "DNS Servers"

# 想定: 192.168.11.53 192.168.11.54

# 名前解決テスト
dig @192.168.11.53 step-ca.home.yagamin.net +short
dig @192.168.11.54 step-ca.home.yagamin.net +short    # Secondary 経由
```

両方から同じ応答が返るならゾーン転送 OK。

## 関連

- [docs/proxmox-firewall.md](proxmox-firewall.md) — `dhcp: 1` 罠と片方ずつ施工パターンの一般化
- [docs/internal-tls.md](internal-tls.md) — DoT/DoH に使う step-ca 証明書の発行
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Zabbix での DNS サービス監視 (Phase 4-A)
