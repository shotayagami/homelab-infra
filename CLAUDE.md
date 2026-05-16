# Claude Code への運用ルール (homelab-infra)

このリポジトリで作業するときは以下を遵守すること。詳細仕様は `docs/` と `README.md` を一次資料とする。

## 1. ブランチと PR

- **`main` への直 push は禁止。** feature branch + `gh pr create` 経由のみ。Claude が `git push origin main` を打とうとした場合は `.claude/hooks/guard-main-push.sh` が BLOCK する。
- 緊急の `--force-with-lease` が必要なら、ホスト側のシェルから手動で実行する (Claude からは試みない)。
- セッション開始時に `main` にいる場合は `.claude/hooks/session-start.sh` が警告する。先に `git switch -c feature/<topic>` で切り替えること。

## 2. コミット品質

- pre-commit hook (identity check + gitleaks + secretlint) と commit-msg hook (メッセージ内の識別子チェック) は `bash scripts/install-hooks.sh` で symlink される。clone 直後に必ず実行。secretlint は `npm install` で取得 (devDependency)。
- **`--no-verify` でバイパスしない。** ユーザレベル hook (`~/.claude/hooks/guard-bash.sh`) が `git commit --no-verify` を BLOCK する。検知が誤判定なら `.gitleaksignore` を増やす方向で。
- 個人識別子 (Linux ユーザ名 / メールローカル部) を本文・コミットメッセージに書かない。pre-commit / commit-msg が hex escape で構築したパターンで検知する。具体パターンは `scripts/git-hooks/pre-commit` の `_P1` / `_P2` を参照。

## 3. 機微情報

- リポジトリは **Public** (`homelab_infra_public_release.md`)。`.env`, `*.tunnel_token`, `*.pem` などは `.gitignore` 対象。Claude からは `.claude/hooks/guard-write.sh` (ユーザレベル) で書き込み拒否される。
- 機微情報の混入を過去 3 回 filter-repo で削除した経緯あり。早期検知のため、homelab-infra 配下の Edit/Write 後に `.claude/hooks/post-edit-gitleaks.sh` (プロジェクト) が自動で gitleaks を回す。

## 4. Proxmox / インフラ操作の安全則

### PVE Firewall

- **ファイルパスを間違えると rules が無視される:**
  - Datacenter: `/etc/pve/firewall/cluster.fw`
  - Node (host): `/etc/pve/nodes/<nodename>/host.fw` (NOT `/etc/pve/firewall/proxmox.fw`)
  - VM/CT: `/etc/pve/firewall/<VMID>.fw`
- DROP ルール追加時は SSH (22/tcp) と PVE Web UI (8006/tcp) の ACCEPT を必ず先に置く。
- 編集前に **Terminal A を保険 SSH として別窓で開いておく**。
- ロックアウト復旧: コンソールから `pve-firewall stop` または `rm /etc/pve/nodes/<node>/host.fw`。これらは `.claude/hooks/guard-bash.sh` で BLOCK されるので、本当に必要な時はホスト側で手動。
- 編集手順を間違えないために `/pve-fw-edit` slash command を用意してある。

### DNS / DHCP

- LXC コンテナで DHCP サーバを立てる場合、container option の `dhcp: 1` だけでは不足。`IN ACCEPT -p udp -dport 67` を明示する必要あり (2026-04-20 dns2 インシデント)。

### RKE2 / etcd

- cp1 は NVMe (`local-lvm`)、worker1 は SPCC SSD (`store-sda`) 上。Fanxiang QLC (`store-sdb`) はバックアップ専用 (2026-05-16 移行)。
- etcd の挙動確認は `/etcd-health` slash command で一括取得できる。

### バックアップ多層構造

- per-DB CronJob / Longhorn snapshot / Velero / etcd snapshot / vzdump の 5 層 (`docs/backup-strategy.md`)。
- 一括ステータスは `/rke2-snapshot` で確認。

## 5. ドキュメント運用

- **環境変更時は docs を同じ commit で更新する** (README.md の topology 表 + 該当 `docs/*.md`)。
- ドリフトがないか機械チェックしたいときは `homelab-doc-sync` サブエージェントを呼ぶ。

## 6. Claude Code カスタム機能の所在

| 場所 | 用途 |
|---|---|
| `~/.claude/settings.json` | グローバル hooks (PVE safety, secret-write, --no-verify), statusline, 共通権限 |
| `~/.claude/hooks/` | guard-bash.sh, guard-write.sh |
| `~/.claude/commands/memory-update.md` | auto-memory の点検 (どこからでも使える) |
| `.claude/settings.json` | homelab-infra 固有 hooks と権限 |
| `.claude/hooks/` | guard-main-push.sh, post-edit-gitleaks.sh, session-start.sh |
| `.claude/commands/` | pre-pr, pve-fw-edit, etcd-health, rke2-snapshot |
| `.claude/agents/` | pve-safety-reviewer, homelab-doc-sync |

## 7. PR 提出前のセルフチェック

`/pre-pr [title]` で gitleaks フル走査 + identity check + link check + shellcheck をまとめて回す。すべて `[OK]` なら `gh pr create` を推奨。
