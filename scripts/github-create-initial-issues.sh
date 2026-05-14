#!/usr/bin/env bash
#
# 残作業を GitHub Issues として一括登録するスクリプト。
#
# 前提:
#   - gh CLI (>= 2.x) インストール済
#   - gh auth status で認証済 (リポジトリへの write 権限が必要)
#   - 本リポジトリのワーキングディレクトリで実行
#
# 冪等性:
#   - 同じタイトルで既存 Issue があれば作成スキップ
#
# 使い方:
#   $ cd ~/homelab-infra
#   $ bash scripts/github-create-initial-issues.sh
#
# 履歴:
#   2026-05-15 初版 (Phase 1-6 完走後の残作業を可視化)

set -euo pipefail

REPO="shotayagami/homelab-infra"

# ─────────────────────────────────────────────
# 必要なラベルを先に確保 (冪等)
# ─────────────────────────────────────────────
ensure_label() {
  local name="$1"
  local color="$2"
  local desc="$3"
  if ! gh label list --repo "$REPO" --limit 100 --json name --jq '.[].name' | grep -qxF "$name"; then
    echo "  CREATE label: $name"
    gh label create "$name" --repo "$REPO" --color "$color" --description "$desc"
  else
    echo "  SKIP label (exists): $name"
  fi
}

echo "=== Ensuring labels ==="
ensure_label "phase-4" "1d76db" "Phase 4 (service-layer monitoring)"
ensure_label "security" "d73a4a" "Security-related: rotation, audit, hardening"
ensure_label "chore"    "cfd3d7" "Maintenance and cleanup tasks"
ensure_label "external" "fbca04" "Depends on an external party/upstream"
ensure_label "dx"       "0e8a16" "Developer experience / tooling"
echo

# ─────────────────────────────────────────────
# 既存 Issue のタイトル一覧を取得 (冪等性のため)
# ─────────────────────────────────────────────
existing=$(gh issue list --repo "$REPO" --state all --limit 200 --json title --jq '.[].title' 2>/dev/null || echo "")

create_issue() {
  local title="$1"
  local body="$2"
  local labels="$3"

  if grep -qxF "$title" <<<"$existing"; then
    echo "  SKIP (already exists): $title"
    return 0
  fi

  echo "  CREATE: $title"
  gh issue create \
    --repo "$REPO" \
    --title "$title" \
    --body "$body" \
    --label "$labels"
}

# ─────────────────────────────────────────────
# Issue 1: Phase 4-B Nextcloud monitoring
# ─────────────────────────────────────────────
create_issue \
  "Phase 4-B: Add Nextcloud monitoring" \
  "$(cat <<'EOF'
## Goal

Apply the official `Nextcloud server by HTTP` template to the Nextcloud
LXC (host id 10687, 192.168.11.62) so the Zabbix server starts collecting
storage usage, active users, cron health, update notifications, and TLS
expiry.

## Background

Phase 4-B was deferred during initial monitoring rollout in favor of
finishing notification plumbing first. See
[docs/proxmox-zabbix-monitoring.md](../blob/main/docs/proxmox-zabbix-monitoring.md)
section "Phase 4 サブステップ案 → 4-B".

## Acceptance criteria

- [ ] Generate a Nextcloud app password for monitoring (Settings →
      Security → App passwords)
- [ ] Add the template macros on the `nextcloud` host:
      - `{$NEXTCLOUD.URL}` = `https://nextcloud.home.yagamin.net`
      - `{$NEXTCLOUD.USER}` = monitoring user
      - `{$NEXTCLOUD.PASSWORD}` = app password (Secret text)
      - `{$NEXTCLOUD.HTTP.SSL_VERIFY_PEER}` = `0`
      - `{$NEXTCLOUD.HTTP.SSL_VERIFY_HOST}` = `0`
- [ ] Verify discovery picks up apps / users / storage breakdown
- [ ] Make sure existing notification action fires on a synthetic trigger
- [ ] Update docs/proxmox-zabbix-monitoring.md
EOF
)" \
  "enhancement,phase-4"

# ─────────────────────────────────────────────
# Issue 2: Phase 6-E credential rotation
# ─────────────────────────────────────────────
create_issue \
  "Phase 6-E: Rotate credentials exposed during initial build" \
  "$(cat <<'EOF'
## Goal

Rotate every credential that was transcribed in plain text during the
initial build (chat transcripts, screenshots, working notes) and update
the corresponding Zabbix media types / config files.

## Scope

- [ ] **Mailgun SMTP password** (`<mailgun-sender>`)
  - Reset via Mailgun dashboard → Sending → Domain Settings → SMTP creds
  - Update Zabbix media type 73 (Mailgun) `passwd` field via UI or API
- [ ] **Discord webhook URL** (channel: home.yagamin.net)
  - Regenerate via Discord channel → Integrations → Webhooks
  - Update Admin user's media (mediaid=1) `sendto` to the new URL
- [ ] **ntfy zabbix user token** (`<masked-token>...`)
  - `pct exec 191 -- ntfy token remove zabbix <id>`
  - Issue a new token; update Zabbix media type 72 (ntfy) `Token` parameter
- [ ] **Zabbix Admin password**
  - Change via UI (Users → Admin → Change password)
  - Update any saved credential locations
- [ ] **DNS cert PFX password** (24-char hex)
  - Regenerate cert/PFX with a new password (or refresh from step-ca)
  - Re-import to Technitium

## Acceptance criteria

- [ ] All rotated; previous values fully invalidated
- [ ] Test notifications still fire for all 3 channels
- [ ] gitleaks scan of repo shows no leaks of old or new credentials
EOF
)" \
  "security,chore"

# ─────────────────────────────────────────────
# Issue 3: dns2 DoT/DoH retry
# ─────────────────────────────────────────────
create_issue \
  "dns2 の DoT/DoH を Technitium 15.x で再有効化する" \
  "$(cat <<'EOF'
## Background

During Phase 4-A we hit a Technitium 15.x quirk where the dns2 LXC
(192.168.11.54) refused to load the TLS certificate for DoT/DoH, logging
`TLS certificate file does not exists` even though the file was present
and readable. dns (192.168.11.53) worked after several UI saves; dns2
never did. We disabled the DoT/DoH monitoring items on dns2 to silence
the alerts and moved on.

See docs/proxmox-zabbix-monitoring.md section
"Phase 4-A 部分撤退（業務時間優先）".

## Hypotheses to test

- [ ] Technitium 15.2 vs 15.x latest — upgrade dns2 first
- [ ] PFX file regenerated with stronger / weaker password
- [ ] Self-signed vs step-ca issued cert
- [ ] dns.config corruption on dns2 (compare bytes with dns)
- [ ] Underlying .NET runtime issue (`System.BadImageFormatException`
      seen during initial setup)

## Acceptance criteria

- [ ] dns2 `:443` and `:853` listening
- [ ] Re-enable the disabled Zabbix items (DoT/DoH on dns2)
- [ ] Triggers fire only on actual failures, not on this misconfig
EOF
)" \
  "bug,external"

# ─────────────────────────────────────────────
# Issue 4: hook 共有化
# ─────────────────────────────────────────────
create_issue \
  "scripts/install-hooks.sh で pre-commit hook をリポジトリ管理化" \
  "$(cat <<'EOF'
## Goal

Make the pre-commit hook (gitleaks-based) reproducible across clones by
storing the canonical version in the repo and installing it via a setup
script.

## Background

`.git/hooks/pre-commit` lives outside Git's tracked tree, so each fresh
clone starts with no hook. Today the hook exists only in the original
admin-vm working copy.

## Implementation idea

- Add `scripts/git-hooks/pre-commit` (the tracked source)
- Add `scripts/install-hooks.sh` which:
  - Symlinks `scripts/git-hooks/pre-commit` to `.git/hooks/pre-commit`
  - Verifies gitleaks is installed; warns if not
- Document the install command in README and docs/homelab-git-workflow.md

## Acceptance criteria

- [ ] Fresh clone → run `bash scripts/install-hooks.sh` → hook active
- [ ] Hook still uses `gitleaks git --pre-commit --staged --redact --no-banner`
- [ ] Fallback regex path preserved for environments without gitleaks
EOF
)" \
  "dx,enhancement"

echo
echo "=== 完了 ==="
gh issue list --repo "$REPO" --state open --limit 20
