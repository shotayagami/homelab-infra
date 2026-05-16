# Proxmox VE Firewall 運用

PVE Firewall の有効化・ルール記述・**ロックアウト復旧** までの実運用ノート。2026-04-18 の事故と教訓を起点に整理している。

## 1. ファイルパス（最初のハマりどころ）

PVE Firewall の設定ファイルは 3 階層に分かれており、**Node (ホスト) のパスを間違えると RULES が完全に無視される**:

| 階層 | パス |
|---|---|
| Datacenter (クラスタ全体) | `/etc/pve/firewall/cluster.fw` |
| **Node (PVE ホスト個別)** | **`/etc/pve/nodes/<nodename>/host.fw`** |
| VM / CT (個別) | `/etc/pve/firewall/<VMID>.fw` |

注意: Node 用は `/etc/pve/firewall/<nodename>.fw` ではなく `/etc/pve/nodes/<nodename>/host.fw`。`pvecm status` で取れるノード名（本リポジトリ環境では `proxmox`）を使う。

2026-04-18 に `/etc/pve/firewall/proxmox.fw` に書いて「ルールが効かない」と長時間デバッグした経緯あり。

## 2. `management` IPSet の自動挙動

`cluster.fw` に `[IPSET management]` を定義すると、PVE が以下のポートに対する許可ルールを **自動生成** する:

| サービス | ポート |
|---|---|
| SSH | 22 |
| Web UI | 8006 |
| VNC (noVNC コンソール) | 5900–5999 |
| SPICE proxy | 3128 |
| Live migration | 60000–60050 |

**罠**: この auto-gen ルールは host.fw のユーザールールより **後** に評価されることがある。host.fw の先頭で `IN DROP` を書くと、management IPSet の auto-allow より先に DROP が当たり SSH が落ちる。

## 3. 2026-04-18 ロックアウト事故と教訓

**事象**: 誤パス (`/etc/pve/firewall/proxmox.fw`) で長時間設定をデバッグ → 正しいパス `/etc/pve/nodes/proxmox/host.fw` に移動した直後、テスト用の `IN ACCEPT -p tcp -dport 9999` と `IN DROP` だけを書いて `pve-firewall restart` した結果、**SSH も Web UI も遮断され、物理コンソール復旧が必要に**なった。

**教訓**:

1. **パスを正確に**: 設定変更前に `ls -la /etc/pve/nodes/<node>/host.fw` で実体確認
2. **DROP を書く前に必ず ACCEPT を明示**: `IN ACCEPT -source +dc/management -p tcp -dport 22` を **最初の RULE** として置く
3. **別 SSH セッションを保険に**: 設定変更時はもう 1 本生きた接続を残しておく
4. **テスト用 `pve-firewall restart` は避け、`pve-firewall compile` で構文確認** → `pve-firewall start` の順

## 4. ロックアウト復旧手順

物理コンソール / IPMI / Proxmox UI のノードコンソールから:

```bash
# 即時無効化
pve-firewall stop

# または設定ファイルごと削除（次の restart で再生成される）
rm /etc/pve/nodes/<nodename>/host.fw

# enable: 0 にして残す方法
sed -i 's/^enable: 1/enable: 0/' /etc/pve/nodes/<nodename>/host.fw
```

VM/CT の firewall でロックアウトした場合は同様に `/etc/pve/firewall/<VMID>.fw` を編集 (`enable: 0`) → CT 再起動。

## 5. 推奨運用フロー（事故防止）

```bash
# 1. 編集前に必ずバックアップ
cp /etc/pve/nodes/proxmox/host.fw{,.bak.$(date +%Y%m%d-%H%M%S)}

# 2. 別ターミナルで SSH を確保
ssh root@192.168.11.11    # 保険セッション

# 3. 編集
vi /etc/pve/nodes/proxmox/host.fw

# 4. 構文チェック
pve-firewall compile

# 5. 適用
pve-firewall restart

# 6. 別セッションから動作確認 (まだ繋がるか、想定通り遮断されるか)
ss -tlnp | grep :22
```

## 6. VM/CT (LXC) firewall の `dhcp: 1` 罠

LXC で **DHCP サーバを動かしている場合** (例: Technitium DNS の DHCP 機能、[internal-dns.md](internal-dns.md))、`fw` 設定の `dhcp: 1` だけでは不十分:

- `dhcp: 1` は **クライアント用** = `udp spt:67 dpt:68` を許可 (外部 DHCP サーバからの応答を受け取る用)
- **DHCP サーバ側**は `IN ACCEPT -p udp -dport 67` を **RULES に明示追加** する必要あり (source なし、DISCOVER は 0.0.0.0 から来るため)

症状: クライアントの DISCOVER が CT に届かず、`veth<vmid>i0-IN` チェーン末尾 DROP のカウンタが増える。`tcpdump -i eth0` を CT 内で取ると 0 packets。

切り分け: `sed -i 's/^enable: 1/enable: 0/' /etc/pve/firewall/<VMID>.fw` で一時無効化 → DHCP 取得確認 → 原因確定。

## 7. NIC の `firewall=1` 反映

LXC / VM の NIC に `firewall=1` を付けると初めて per-VM firewall が有効化される。**付与・解除はコンテナ再起動が必要**。dns / dns2 のように Primary/Secondary 構成のサービスは **片方ずつ施工**して DNS 継続を担保する (2026-04-18 に実証済み)。

## 関連

- [internal-dns.md](internal-dns.md) — dns/dns2 LXC の firewall 要件と `dhcp: 1` 罠の実例
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Zabbix Server (LXC 190) と PVE Firewall のポート整合
