#!/usr/bin/env bash
#
# Push cloudflared/tunnel-config.yaml as the remote-managed tunnel
# configuration via the Cloudflare API.
#
# Required env (from ENV_FILE / shell):
#   CF_API_TOKEN     token with Account:Cloudflare Tunnel:Edit
#   CF_ACCOUNT_ID
#   CF_TUNNEL_ID
#
# Usage:
#   scripts/cloudflared-push-tunnel-config.sh                   # apply
#   DRY_RUN=1 scripts/cloudflared-push-tunnel-config.sh         # show plan
#   CONFIG_FILE=path/to/other.yaml scripts/cloudflared-...sh    # alternate file
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
CONFIG_FILE="${CONFIG_FILE:-${REPO_ROOT}/cloudflared/tunnel-config.yaml}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${CF_TUNNEL_ID:?CF_TUNNEL_ID is required}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Convert YAML -> JSON via python (avoid yq dep)
DESIRED=$(python3 - <<PY
import json, yaml, sys
with open("$CONFIG_FILE") as f:
    data = yaml.safe_load(f)
print(json.dumps(data, separators=(",", ":")))
PY
)

LIVE=$(curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
  | jq -c '.result.config // {}')

# Normalize both sides for comparison (sorted keys, drop nulls)
DESIRED_NORM=$(echo "$DESIRED" | jq -S -c 'del(.. | nulls?)')
LIVE_NORM=$(echo "$LIVE" | jq -S -c 'del(.. | nulls?)')

if [[ "$DESIRED_NORM" == "$LIVE_NORM" ]]; then
  echo "ok: tunnel config already matches"
  exit 0
fi

echo "--- diff (live vs desired) ---"
diff <(echo "$LIVE" | jq -S .) <(echo "$DESIRED" | jq -S .) || true
echo "------------------------------"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "DRY_RUN=1: not applying"
  exit 0
fi

PAYLOAD=$(jq -nc --argjson cfg "$DESIRED" '{config:$cfg}')
RESP=$(curl -sS -X PUT \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations")

OK=$(echo "$RESP" | jq -r '.success')
if [[ "$OK" != "true" ]]; then
  echo "FAIL: $RESP" >&2
  exit 1
fi
echo "applied."
