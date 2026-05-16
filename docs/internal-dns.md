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

## 6. dns2 の DoT/DoH 未復旧 (既知の課題)

dns2 (LXC 105) の DoT/DoH は **Technitium 15.x の cert load 周りの不具合** で動作していない。Zabbix 側の DoT/DoH 監視アイテムは disable で対応中 (Issue #3、[docs/remaining-tasks.md](remaining-tasks.md) 参照)。

- DNS (53) と Web UI は正常稼働
- Primary 側 (dns) の DoT/DoH は正常稼働しているため、外部公開していない LAN 用途では実害なし
- Technitium のバージョン据置 (15.x) と、上流の修正待ち、または別 DNS 実装 (Unbound + nsd 等) への移行が選択肢

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
