#!/usr/bin/env bash
#
# Zabbix の全ホストの Inventory に Location 座標 (lat/lon) を一括設定する。
# Dashboard の「地理マップ」widget でプロットされる位置を制御するため。
#
# 業務的応用:
#   - 複数拠点運用なら、各拠点の座標を host group ごとに切り替え
#   - VPS/クラウドのリージョンごとに座標差し替え
#
# 使い方:
#   $ bash proxmox-zabbix-set-host-location.sh
#   → Zabbix Admin パスワード入力 → 全ホストに座標が反映される
#
# 注意:
#   - inventory_mode=0 は "Manual" モード。既に Manual/Automatic なら影響なし
#   - 既存の他 inventory フィールドは温存（host.update は部分更新）
#
# 履歴:
#   2026-05-15 初版 (Phase 6 後の地理マップ widget 設定)

set -euo pipefail

ZBX_URL="http://192.168.11.55/api_jsonrpc.php"

# .env を source して ZBX_API_TOKEN を拾う (MFA 強制環境では token 必須)
ENV_FILE="${ENV_FILE:-${HOME}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -n "${ZBX_API_TOKEN:-}" ]]; then
  AUTH="$ZBX_API_TOKEN"
  AUTH_MODE="token"
  echo "Auth: ZBX_API_TOKEN from $ENV_FILE"
else
  echo "Auth: user.login fallback (ZBX_API_TOKEN 未設定)"
  echo "  ※ Zabbix Admin に MFA 有効な場合は user.login の session が即 invalidate されます"
  read -rsp "Zabbix Admin password: " ZBX_PASS; echo
  AUTH=$(curl -sS -X POST -H "Content-Type: application/json-rpc" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"username\":\"Admin\",\"password\":\"$ZBX_PASS\"},\"id\":1}" \
    "$ZBX_URL" | jq -r '.result')
  unset ZBX_PASS
  AUTH_MODE="session"
fi
[[ -n "$AUTH" && "$AUTH" != "null" ]] || { echo "Zabbix 認証失敗" >&2; exit 1; }

# 設定する座標（変更する場合はここを編集）
LOCATION="<masked-location>"
LAT="<masked-lat>"
LON="<masked-lon>"

echo "Setting location: $LOCATION (lat=$LAT, lon=$LON)"

# 全ホスト取得
HIDS=$(curl -sS -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $AUTH" \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid","host"]},"id":1}' \
  "$ZBX_URL" | jq -r '.result[].hostid')

for HID in $HIDS; do
  HOST=$(curl -sS -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $AUTH" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"hostids\":[\"$HID\"],\"output\":[\"host\"]},\"id\":1}" \
    "$ZBX_URL" | jq -r '.result[0].host')
  echo "Updating $HOST (hostid=$HID)..."
  curl -sS -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $AUTH" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"host.update\",\"params\":{\"hostid\":\"$HID\",\"inventory_mode\":0,\"inventory\":{\"location_lat\":\"$LAT\",\"location_lon\":\"$LON\",\"location\":\"$LOCATION\"}},\"id\":1}" \
    "$ZBX_URL" | jq -c .
done

# session のときだけ logout (API token は永続なので logout 不要)
if [[ "$AUTH_MODE" == "session" ]]; then
  curl -sS -X POST -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $AUTH" \
    -d '{"jsonrpc":"2.0","method":"user.logout","params":[],"id":1}' "$ZBX_URL" >/dev/null
fi

echo Done.
