#!/usr/bin/env bash
#
# Nextcloud LXC (host id 10687, 192.168.11.62) に Zabbix の
# 「Nextcloud server by HTTP」テンプレートを適用し、必要な macro を設定する。
#
# 前提:
#   - Zabbix 7.0 に「Nextcloud server by HTTP」テンプレートが import 済
#     (Templates → 検索: "Nextcloud" → 標準テンプレに含まれる)
#   - Nextcloud 側で monitoring 用ユーザ + app password を生成済
#     Settings → Security → App passwords → "zabbix-monitor" などの名前で発行
#
# 使い方:
#   $ NC_USER="monitor" \
#     NC_APP_PASS="xxxx-xxxx-xxxx-xxxx-xxxx" \
#     bash scripts/proxmox-zabbix-apply-nextcloud-template.sh
#
#   - NC_APP_PASS は環境変数で渡し、シェル履歴に残さないこと
#     (一時的に履歴を切りたい場合は `set +o history` → 実行 → `set -o history`)
#
# 冪等性:
#   - 既にテンプレートが link 済みなら skip
#   - macro は upsert（同名があれば更新、無ければ追加）
#
# 履歴:
#   2026-05-15 初版 (Issue #1 / Phase 4-B)

set -euo pipefail

ZBX_URL="http://192.168.11.55/api_jsonrpc.php"
NC_HOST_NAME="nextcloud"            # Zabbix 側のホスト名
NC_URL="https://nextcloud.home.yagamin.net"
TEMPLATE_NAME="Nextcloud server by HTTP"

: "${NC_USER:?env NC_USER (Nextcloud monitoring user) を設定してください}"
: "${NC_APP_PASS:?env NC_APP_PASS (Nextcloud app password) を設定してください}"

# ─────────────────────────────────────────────
# Login
# ─────────────────────────────────────────────
read -rsp "Zabbix Admin password: " ZBX_PASS; echo
AUTH=$(curl -sS -X POST -H "Content-Type: application/json-rpc" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"Admin\",\"password\":\"$ZBX_PASS\"},\"id\":1}" \
  "$ZBX_URL" | jq -r '.result')
unset ZBX_PASS
[[ -n "$AUTH" && "$AUTH" != "null" ]] || { echo "Zabbix 認証失敗"; exit 1; }

call() {
  local method="$1" params="$2"
  curl -sS -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $AUTH" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" "$ZBX_URL"
}

cleanup() {
  call user.logout '[]' >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# ホストとテンプレートの ID を解決
# ─────────────────────────────────────────────
HOSTID=$(call host.get "{\"filter\":{\"host\":[\"$NC_HOST_NAME\"]},\"output\":[\"hostid\",\"host\"]}" | jq -r '.result[0].hostid // empty')
[[ -n "$HOSTID" ]] || { echo "ERROR: ホスト '$NC_HOST_NAME' が見つかりません"; exit 1; }
echo "host '$NC_HOST_NAME' → hostid=$HOSTID"

TEMPLATEID=$(call template.get "{\"filter\":{\"host\":[\"$TEMPLATE_NAME\"]},\"output\":[\"templateid\",\"host\"]}" | jq -r '.result[0].templateid // empty')
[[ -n "$TEMPLATEID" ]] || { echo "ERROR: テンプレート '$TEMPLATE_NAME' が見つかりません (import 済か確認)"; exit 1; }
echo "template '$TEMPLATE_NAME' → templateid=$TEMPLATEID"

# ─────────────────────────────────────────────
# Macros (upsert) - 既存リスト取得 → マージ → 一括 update
# ─────────────────────────────────────────────
declare -A NEW_MACROS=(
  ["{\$NEXTCLOUD.URL}"]="$NC_URL"
  ["{\$NEXTCLOUD.USER}"]="$NC_USER"
  ["{\$NEXTCLOUD.PASSWORD}"]="$NC_APP_PASS"
  ["{\$NEXTCLOUD.HTTP.SSL_VERIFY_PEER}"]="0"
  ["{\$NEXTCLOUD.HTTP.SSL_VERIFY_HOST}"]="0"
)
declare -A SECRET_TYPE=(
  ["{\$NEXTCLOUD.PASSWORD}"]="1"     # 1 = Secret text
)

EXISTING_JSON=$(call usermacro.get "{\"hostids\":[\"$HOSTID\"],\"output\":[\"hostmacroid\",\"macro\",\"value\",\"type\"]}" | jq -c '.result')

echo "Updating macros..."
for macro in "${!NEW_MACROS[@]}"; do
  value="${NEW_MACROS[$macro]}"
  mtype="${SECRET_TYPE[$macro]:-0}"   # 0 = Text (default), 1 = Secret text
  existing_id=$(echo "$EXISTING_JSON" | jq -r --arg m "$macro" '.[] | select(.macro==$m) | .hostmacroid // empty')

  if [[ -n "$existing_id" ]]; then
    echo "  UPDATE: $macro (id=$existing_id, type=$mtype)"
    call usermacro.update "{\"hostmacroid\":\"$existing_id\",\"value\":$(jq -Rs . <<<"$value"),\"type\":\"$mtype\"}" | jq -c '.result // .error'
  else
    echo "  CREATE: $macro (type=$mtype)"
    call usermacro.create "{\"hostid\":\"$HOSTID\",\"macro\":$(jq -Rs . <<<"$macro"),\"value\":$(jq -Rs . <<<"$value"),\"type\":\"$mtype\"}" | jq -c '.result // .error'
  fi
done

# ─────────────────────────────────────────────
# Template を host に link (既に link 済なら skip)
# ─────────────────────────────────────────────
LINKED=$(call host.get "{\"hostids\":[\"$HOSTID\"],\"selectParentTemplates\":[\"templateid\",\"host\"],\"output\":[\"hostid\"]}" \
  | jq -r --arg tid "$TEMPLATEID" '.result[0].parentTemplates[]?.templateid | select(. == $tid)')

if [[ "$LINKED" == "$TEMPLATEID" ]]; then
  echo "SKIP: template '$TEMPLATE_NAME' は既に link 済"
else
  echo "Linking template '$TEMPLATE_NAME' to host '$NC_HOST_NAME'..."
  # host.massadd は既存テンプレートを温存して追加 link する (host.update の templates は完全置換)
  call host.massadd "{\"hosts\":[{\"hostid\":\"$HOSTID\"}],\"templates\":[{\"templateid\":\"$TEMPLATEID\"}]}" | jq -c '.result // .error'
fi

echo
echo "=== 完了 ==="
echo "次のステップ:"
echo "  1. Zabbix UI → Hosts → $NC_HOST_NAME → Latest data で値が取れているか確認"
echo "  2. Configuration → Hosts → $NC_HOST_NAME → Discovery rules で apps/users/storage が展開されるか確認"
echo "  3. Triggers をテスト発火 (例: 一時的に閾値を 0 にして apps 数 > 0 で発火)"
echo "  4. 通知 3 系統 (ntfy/Discord/Mailgun) が届くことを確認"
