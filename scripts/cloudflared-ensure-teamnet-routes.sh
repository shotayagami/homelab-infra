#!/usr/bin/env bash
#
# Idempotently ensure WARP private-network routes (CIDR -> tunnel) exist for
# the home-yagamin tunnel. These routes let enrolled Cloudflare WARP devices
# reach LAN IPs over the tunnel's connectors (UDP included), which public
# ingress hostnames cannot carry. They are registered via the teamnet/routes
# API and are NOT part of the tunnel configurations PUT (see
# scripts/cloudflared-push-tunnel-config.sh).
#
# Desired routes are matched by network CIDR (default virtual network). An
# existing non-deleted route for the same CIDR is left untouched; a missing one
# is created.
#
# Required env (from ENV_FILE / shell):
#   CF_API_TOKEN     token with Account:Cloudflare Tunnel:Edit
#   CF_ACCOUNT_ID
#   CF_TUNNEL_ID
#
# Usage:
#   scripts/cloudflared-ensure-teamnet-routes.sh                 # apply default set
#   DRY_RUN=1 scripts/cloudflared-ensure-teamnet-routes.sh       # plan only
#   scripts/cloudflared-ensure-teamnet-routes.sh "192.168.11.99/32=some comment" ...
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
: "${CF_TUNNEL_ID:?CF_TUNNEL_ID is required}"

# Desired routes as "CIDR=comment". Keep the FreePBX route here so the managed
# set reflects the full live intent (it was originally created by hand).
DEFAULT_ROUTES=(
  "192.168.11.57/32=FreePBX SIP remote"
  "192.168.11.20/32=ICS-TV playout SRT ingest"
)

if [[ $# -gt 0 ]]; then
  ROUTES=("$@")
else
  ROUTES=("${DEFAULT_ROUTES[@]}")
fi

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}" "$@"
}

# Snapshot existing (non-deleted) routes once.
LIST=$(api GET "/accounts/${CF_ACCOUNT_ID}/teamnet/routes?per_page=1000")
LIST_OK=$(echo "$LIST" | jq -r '.success // false')
if [[ "$LIST_OK" != "true" ]]; then
  echo "FAIL: GET teamnet/routes did not return success=true." >&2
  echo "$LIST" | jq '.errors // .' >&2 2>/dev/null || echo "$LIST" >&2
  exit 1
fi

for spec in "${ROUTES[@]}"; do
  network="${spec%%=*}"
  comment="${spec#*=}"
  [[ "$comment" == "$network" ]] && comment=""

  existing=$(echo "$LIST" | jq -c --arg n "$network" \
    '[.result[] | select(.network == $n and (.deleted_at == null))]')
  count=$(echo "$existing" | jq 'length')

  if [[ "$count" != "0" ]]; then
    ex_tunnel=$(echo "$existing" | jq -r '.[0].tunnel_id')
    if [[ "$ex_tunnel" == "$CF_TUNNEL_ID" ]]; then
      echo "ok           $network (already routed -> this tunnel)"
    else
      echo "WARN         $network exists but points at a different tunnel ($ex_tunnel); leaving as-is" >&2
    fi
    continue
  fi

  body=$(jq -nc --arg net "$network" --arg tid "$CF_TUNNEL_ID" --arg c "$comment" \
    '{network:$net, tunnel_id:$tid} + (if $c == "" then {} else {comment:$c} end)')

  if [[ "${DRY_RUN:-}" == "1" ]]; then
    echo "would CREATE  $network -> tunnel ${CF_TUNNEL_ID} (\"$comment\")"
  else
    resp=$(api POST "/accounts/${CF_ACCOUNT_ID}/teamnet/routes" --data "$body")
    ok=$(echo "$resp" | jq -r '.success')
    if [[ "$ok" != "true" ]]; then
      echo "FAIL create $network: $(echo "$resp" | jq -c '.errors // .')" >&2
      exit 1
    fi
    echo "created      $network -> tunnel ${CF_TUNNEL_ID} (\"$comment\")"
  fi
done

echo "done."
