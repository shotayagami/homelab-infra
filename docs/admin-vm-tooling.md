# admin-vm の運用ツール

PVE ホスト (192.168.11.11) に直接 SSH せず、**運用クライアント `admin-vm` (VMID 150)** から `pct` / `qm` / `pvesh` / `pveum` 等の PVE 専用コマンドを直接叩けるようにしてある。本書はその実装と運用ルール。

## 1. なぜ admin-vm 経由か

- PVE ホスト本体に常用シェルを増やしたくない（rootfs を肥らせない、変更履歴を分離）
- LXC/VM 管理操作と一般運用 (Zabbix API 操作、git、kubectl 等) を 1 つのワークスペースに集約したい
- 自動化スクリプトを admin-vm 側で完結させたい (PVE 本体には常駐させない)

admin-vm 自体は cloud-init で `ubuntu` ユーザー、PVE ホストの root SSH 鍵を信頼する設定で起動済み。

## 2. ラッパースクリプトの実体

`/usr/local/bin/pve-wrapper` (bash 一枚):

- 引数を `printf %q` で安全に再クォートして SSH に渡す
- 接続先は環境変数 `PVE_HOST` で上書き可能、default `root@192.168.11.11`
- stdin/stdout が端末なら `ssh -t` を自動付与 → `pct enter` 等のインタラクティブ操作もそのまま動く

symlink で各コマンド名にエイリアス:

```
/usr/local/bin/pct    -> pve-wrapper
/usr/local/bin/qm     -> pve-wrapper
/usr/local/bin/pvesh  -> pve-wrapper
/usr/local/bin/pveum  -> pve-wrapper
```

## 3. 使い方の典型例

```bash
# LXC 一覧
pct list

# LXC 内でコマンド実行 (クォート/パイプもそのまま)
pct exec 190 -- bash -lc 'echo "hello world" | jq .'

# VM 一覧
qm list

# PVE API 呼び出し
pvesh get /cluster/resources --type vm --output-format json

# user/group 操作
pveum user list

# 別ノードを叩く場合
PVE_HOST=root@192.168.11.12 pct list

# インタラクティブシェル
pct enter 190    # ssh -t 自動付与で TTY が通る
```

## 4. 拡張: 新しいコマンドを追加したい時

PVE 専用コマンドを増やしたい場合、symlink を 1 本貼るだけ:

```bash
sudo ln -sfn pve-wrapper /usr/local/bin/pvecm    # クラスタ管理
sudo ln -sfn pve-wrapper /usr/local/bin/vzdump   # バックアップ
sudo ln -sfn pve-wrapper /usr/local/bin/pveperf  # ベンチ
```

`pve-wrapper` 本体は `basename "$0"` で呼び出されたコマンド名を判別する設計なので、symlink 名がそのまま PVE 側で実行される。

## 5. ラッパー化していないコマンド（明示的に SSH を使う）

ホスト固有のシステム管理系はラッパー化しておらず、明示的に SSH を経由する:

```bash
# パッケージ管理
ssh root@192.168.11.11 'apt update && apt list --upgradable'

# システムログ
ssh root@192.168.11.11 'journalctl -u pve-firewall -n 100 --no-pager'

# ハードウェア確認
ssh root@192.168.11.11 'dmidecode -t memory'
```

**Why**: `apt` や `journalctl` を admin-vm 側のシェル履歴から無自覚に叩くと、admin-vm のものか PVE ホストのものかが追えなくなる。明示 SSH で区別する。

## 6. 前提条件

- admin-vm から `ssh root@192.168.11.11` が **鍵認証で通る** こと (パスワードプロンプトが出ないこと)
- PVE ホストの `/root/.ssh/authorized_keys` に admin-vm の公開鍵を登録済み
- admin-vm 側で `ssh-agent` か `~/.ssh/config` で鍵を読み込み済み

設定時に確認: `ssh -o BatchMode=yes -o ConnectTimeout=5 root@192.168.11.11 'echo OK'` が `OK` を返せば前提クリア。

## 7. セキュリティ上の留意

- admin-vm の `shotayagami` ユーザー (sudo 可) が侵害されると **PVE ホスト root に等価のアクセス権が渡る**。admin-vm 自体のログイン保護 (SSH 鍵のみ、パスワード認証無効) を維持すること
- ラッパー経由のコマンド実行ログは admin-vm 側 (`~/.bash_history`) と PVE 側 (`/var/log/auth.log`) の両方に残る。監査時はどちらか一方だけ見ないこと

## 関連

- [docs/proxmox-firewall.md](proxmox-firewall.md) — PVE ホストへの 22/tcp 許可は management IPSet に admin-vm の IP を含めて担保
- [docs/proxmox-zabbix-monitoring.md](proxmox-zabbix-monitoring.md) — Zabbix の `host_metadata` 設定や agent 配布も admin-vm から実施
